import { LightningElement, api, wire, track } from 'lwc';
import { ShowToastEvent }          from 'lightning/platformShowToastEvent';
import { FlowNavigationBackEvent, FlowNavigationFinishEvent } from 'lightning/flowSupport';
import { getRecordNotifyChange }   from 'lightning/uiRecordApi';

import getQuoteContext    from '@salesforce/apex/PricebookRequestController.getQuoteContext';
import getProductsByIds      from '@salesforce/apex/PricebookRequestController.getProductsByIds';
import getCatalogProducts    from '@salesforce/apex/PricebookRequestController.getCatalogProducts';
import getVariantPrices      from '@salesforce/apex/PricebookRequestController.getVariantPrices';
import submitPricebookRequest from '@salesforce/apex/PricebookRequestController.submitPricebookRequest';
import DEFAULT_APPROVER from '@salesforce/label/c.DE_Default_Pricebook_Approver_Id';

const PREFIX_TO_CATEGORY = {
    CAB:'Space', CAG:'Space', HYS:'Space', SPC:'Space',
    POW:'Power', PCM:'Power',
    CCL:'Cross Connect', CCX:'Cross Connect', DPP:'Cross Connect', RIS:'Cross Connect',
    IPT:'IP & Internet', IXP:'IP & Internet',
    MCS:'Managed Connectivity', NMS:'Managed Connectivity',
    RMH:'Remote Hands',
    EMS:'Managed Services', VAS:'Managed Services',
    OFC:'Office Services',
    CTM:'Professional Services', PRO:'Professional Services',
    RPT:'Reports', STR:'Storage', TER:'Other',
    CUS:'Professional Services', HEM:'Managed Services',
};
function categoryFromCode(code) {
    if (!code) return 'Other';
    return PREFIX_TO_CATEGORY[(code.substring(0, 3) || '').toUpperCase()] || 'Other';
}
const CATEGORY_ORDER = [
    'All','Space','Power','Cross Connect','IP & Internet',
    'Managed Connectivity','Remote Hands','Managed Services',
    'Office Services','Professional Services','Reports','Storage','Other',
];

function formatPrice(price, currency) {
    if (price == null) return '-';
    return new Intl.NumberFormat('en-US', { style: 'currency', currency: currency || 'USD' }).format(price);
}

export default class CustomPricebookBuilder extends LightningElement {

    // ─── Flow screen inputs ───────────────────────────────────────────────────
    @api pricebookId;     // from varPricebookId (flow) or resolved via wiredCtx (direct action)
    @api quoteId;         // from flow — takes precedence over recordId
    @api recordId;        // auto-set by platform when invoked as a quick action directly
    @api preSelectedIds;  // semicolon-delimited product IDs from varSelectedProductIds
    @api siteId;          // Target_Site__c from the quote — passed by Discover_Products flow
    @api currencyIsoCode; // Quote currency — passed from flow to avoid wire race

    // Resolved quote ID: flow passes quoteId, direct quick action passes recordId
    get _quoteId() { return this.quoteId || this.recordId; }

    // ─── State ────────────────────────────────────────────────────────────────
    @track isLoading       = true;
    @track isCatalogLoading = true;
    @track isCatalogLoaded  = false;
    @track isSubmitting    = false;
    @track errorMessage    = '';
    @track nextApproverId  = DEFAULT_APPROVER;

    @track accountName   = '';
    @track currencyCode  = '';
    @track existingPbName  = '';
    @track existingPbProductCount = 0;
    hasExistingPb = false;
    @track accountId;

    @track lines         = [];   // selected products: { key, productId, productName, productCode, listPrice, unitPrice }
    @track allProducts   = [];   // full catalog from pricebook
    @track searchTerm    = '';
    @track activeCategory = 'All';
    @track openCategories = new Set();

    _lineCounter  = 0;
    _preLoaded    = false;  // guard so wire data only seeds lines once

    // ─── Wire: Quote context ──────────────────────────────────────────────────
    @wire(getQuoteContext, { quoteId: '$_quoteId' })
    wiredCtx({ data, error }) {
        if (data) {
            this.accountName = data.accountName || '';
            this.accountId   = data.accountId;
            if (!this.currencyCode) this.currencyCode = data.currencyCode || '';
            if (!this.pricebookId && data.currentPricebookId) {
                this.pricebookId = data.currentPricebookId;
            }
            // Surface existing custom pricebook and pre-populate lines
            if (data.existingPricebookId && data.existingProducts) {
                this.hasExistingPb = true;
                this.existingPbName = data.existingPricebookName || '';
                this.existingPbProductCount = data.existingProducts.length;
                // Pre-populate builder with existing PB products (unless flow passed preSelectedIds)
                if (!this.preSelectedIds || !this.preSelectedIds.trim()) {
                    this._preLoaded = true;
                    this.lines = data.existingProducts.map(p => {
                        this._lineCounter++;
                        return {
                            key:         'line-' + this._lineCounter,
                            productId:   p.productId,
                            productName: p.productName,
                            productCode: p.productCode,
                            listPrice:   p.listPrice,
                            listPriceFormatted: formatPrice(p.listPrice, this.currencyCode),
                            unitPrice:   p.listPrice,
                        };
                    });
                }
            }
            this._checkLoading();
        } else if (error) {
            this.errorMessage = 'Could not load quote context.';
            this.isLoading = false;
        }
    }

    // Strip composite IDs (productId::attr) down to plain Product2 IDs for the wire
    get _cleanPreSelectedIds() {
        if (!this.preSelectedIds) return null;
        const seen = new Set();
        const ids = [];
        for (const entry of this.preSelectedIds.split(';').filter(Boolean)) {
            const pid = entry.includes('::') ? entry.substring(0, entry.indexOf('::')) : entry;
            if (!seen.has(pid)) { seen.add(pid); ids.push(pid); }
        }
        return ids.length > 0 ? ids.join(';') : null;
    }

    // ─── Wire: Pre-selected product details ──────────────────────────────────
    @wire(getProductsByIds, { productIdsCsv: '$_cleanPreSelectedIds', pricebookId: '$pricebookId', currencyCode: '$currencyCode' })
    wiredPreSelected({ data, error }) {
        if (data && data.length > 0) {
            this._preSelectedProductData = data;
            this._preLoaded = true;
            this._buildPreSelectedLines();
        } else if (error) {
            this._checkLoading();
        }
    }

    @wire(getVariantPrices, { siteId: '$siteId' })
    wiredVariantPrices({ data }) {
        if (data) {
            this._variantPriceMap = data;
            // Rebuild lines if product data already loaded
            if (this._preSelectedProductData) {
                this._buildPreSelectedLines();
            }
        }
    }

    _preSelectedProductData = null;
    _variantPriceMap = {};

    _buildPreSelectedLines() {
        const data = this._preSelectedProductData;
        if (!data) return;

        const productMap = {};
        for (const p of data) productMap[p.productId] = p;
        const prices = this._variantPriceMap || {};

        const entries = (this.preSelectedIds || '').split(';').filter(Boolean);
        const newLines = [];
        for (const entry of entries) {
            let pid, attr;
            if (entry.includes('::')) {
                pid  = entry.substring(0, entry.indexOf('::'));
                attr = entry.substring(entry.indexOf('::') + 2);
            } else {
                pid  = entry;
                attr = null;
            }
            const p = productMap[pid];
            if (!p) continue;
            this._lineCounter++;

            // Look up per-variant price from CMT; fall back to PBE list price
            let variantPrice = p.listPrice;
            if (attr && p.productCode) {
                const priceKey = (p.productCode + '|' + attr).toLowerCase();
                if (prices[priceKey] != null) {
                    variantPrice = prices[priceKey];
                }
            }

            newLines.push({
                key:            'line-' + this._lineCounter,
                productId:      p.productId,
                productName:    p.productName,
                productCode:    p.productCode,
                attributeValue: attr || null,
                listPrice:      variantPrice,
                listPriceFormatted: formatPrice(variantPrice, this.currencyCode),
                unitPrice:      variantPrice,
            });
        }
        this.lines = newLines;
        this._checkLoading();
    }

    // ─── Wire: Full product catalog ───────────────────────────────────────────
    @wire(getCatalogProducts, { pricebookId: '$pricebookId', currencyCode: '$currencyCode' })
    wiredCatalog({ data, error }) {
        this.isCatalogLoading = false;
        this.isCatalogLoaded  = true;
        if (data) {
            this.allProducts = data.map(p => ({
                id:            p.productId,
                name:          p.productName || '',
                code:          p.productCode || '-',
                category:      categoryFromCode(p.productCode),
                listPrice:     p.listPrice,
                priceFormatted: formatPrice(p.listPrice, this.currencyCode),
            }));
        } else if (error) {
            this.errorMessage = 'Could not load product catalog.';
        }
    }

    _checkLoading() {
        // Stay in loading until both context and pre-selected data are back
        if (this.accountName !== undefined && this._preLoaded !== false) {
            this.isLoading = false;
        }
        // Also clear loading if preSelectedIds is empty (nothing to pre-load)
        if (!this.preSelectedIds || !this.preSelectedIds.trim()) {
            this._preLoaded = true;
            this.isLoading = false;
        }
    }

    connectedCallback() {
        // Set currency from flow input immediately (avoids wire race)
        if (this.currencyIsoCode) this.currencyCode = this.currencyIsoCode;
        // If no pre-selected IDs, don't wait for the wire
        if (!this.preSelectedIds || !this.preSelectedIds.trim()) {
            this._preLoaded = true;
            this.isLoading = false;
        }
    }

    // ─── Computed: catalog view ───────────────────────────────────────────────

    get addedIds() {
        return new Set(this.lines.map(l => l.productId));
    }

    get filteredProducts() {
        let products = this.allProducts;
        if (this.activeCategory !== 'All') {
            products = products.filter(p => p.category === this.activeCategory);
        }
        if (this.searchTerm) {
            const term = this.searchTerm.toLowerCase();
            products = products.filter(
                p => p.name.toLowerCase().includes(term) || p.code.toLowerCase().includes(term)
            );
        }
        return products;
    }

    get groupedProducts() {
        const groups = {};
        const added  = this.addedIds;
        this.filteredProducts.forEach(p => {
            if (!groups[p.category]) groups[p.category] = [];
            groups[p.category].push({
                ...p,
                alreadyAdded:   added.has(p.id),
                addTitle:       added.has(p.id) ? 'Already added' : 'Add to custom pricebook',
                rowClass:       added.has(p.id) ? 'cpb-cat-row cpb-cat-row_added' : 'cpb-cat-row',
            });
        });
        return CATEGORY_ORDER
            .filter(c => c !== 'All' && groups[c])
            .map(c => ({
                category:     c,
                products:     groups[c],
                count:        groups[c].length,
                sectionClass: 'cat-section' + (this.openCategories.has(c) ? ' cat-section_open' : ''),
            }));
    }

    get categories() {
        const presentCats = new Set(this.allProducts.map(p => p.category));
        return CATEGORY_ORDER
            .filter(c => c === 'All' || presentCats.has(c))
            .map(c => ({
                value:    c,
                label:    c,
                cssClass: 'cat-pill' + (this.activeCategory === c ? ' cat-pill_active' : ''),
            }));
    }

    get hasFilteredProducts() {
        return !this.isCatalogLoading && this.filteredProducts.length > 0;
    }

    get catalogStatusLabel() {
        if (this.isCatalogLoading) return 'Loading products...';
        const total = this.filteredProducts.length;
        if (this.searchTerm) return `${total} products match "${this.searchTerm}"`;
        return this.activeCategory === 'All'
            ? `${total} products in pricebook`
            : `${total} products in ${this.activeCategory}`;
    }

    get validLines() { return this.lines.filter(l => l.productId); }
    get hasLines()   { return this.validLines.length > 0; }

    // ─── Catalog handlers ──────────────────────────────────────────────────────

    handleCategoryClick(event) {
        this.activeCategory = event.currentTarget.dataset.value;
    }

    handleSearchChange(event) {
        this.searchTerm = event.target.value;
    }

    handleSectionToggle(event) {
        const cat  = event.currentTarget.dataset.category;
        const next = new Set(this.openCategories);
        if (next.has(cat)) next.delete(cat); else next.add(cat);
        this.openCategories = next;
    }

    handleAddProduct(event) {
        const btn       = event.currentTarget;
        const productId = btn.dataset.id;

        if (!productId || this.addedIds.has(productId)) return;

        // Resolve from in-memory catalog — dataset on base components is unreliable
        const catalogEntry = this.allProducts.find(p => p.id === productId);
        if (!catalogEntry) {
            this.errorMessage = 'Product data not available. Please wait for the catalog to finish loading.';
            return;
        }
        const productName  = catalogEntry.name || btn.dataset.name || 'Product';
        const productCode  = catalogEntry.code || btn.dataset.code || '';
        const listPrice    = catalogEntry.listPrice || parseFloat(btn.dataset.price) || 0;

        this.errorMessage = '';
        this._lineCounter++;
        this.lines = [
            ...this.lines,
            {
                key:              'line-' + this._lineCounter,
                productId,
                productName,
                productCode,
                listPrice,
                listPriceFormatted: formatPrice(listPrice, this.currencyCode),
                unitPrice:        listPrice,
            }
        ];
    }

    // ─── Table handlers ────────────────────────────────────────────────────────

    handlePriceChange(event) {
        const key   = event.currentTarget.dataset.key;
        const price = parseFloat(event.detail.value) || 0;
        this.lines  = this.lines.map(l => l.key === key ? { ...l, unitPrice: price } : l);
    }

    handleRemoveLine(event) {
        const key  = event.currentTarget.dataset.key;
        this.lines = this.lines.filter(l => l.key !== key);
    }

    // ─── Navigation ────────────────────────────────────────────────────────────

    handleBack() {
        this.dispatchEvent(new FlowNavigationBackEvent());
    }

    handleApproverChange(event) {
        this.nextApproverId = event.detail.recordId || null;
    }

    handleSubmit() {
        if (!this.hasLines) {
            this.errorMessage = 'Add at least one product before submitting.';
            return;
        }
        if (this.validLines.length === 0) {
            this.errorMessage = 'No valid products to submit. Remove and re-add products from the catalog.';
            return;
        }
        if (!this.nextApproverId) {
            this.errorMessage = 'Select an approver before submitting.';
            return;
        }
        // Validate all lines have a product ID
        const missingProduct = this.lines.find(l => !l.productId);
        if (missingProduct) {
            this.errorMessage = `"${missingProduct.productName || 'Unknown'}" is missing product data. Remove it and re-add from the catalog.`;
            return;
        }
        this.errorMessage  = '';
        this.isSubmitting  = true;

        const lineInputs = this.lines
            .filter(l => l.productId)
            .map(l => ({
                productId:      l.productId,
                productName:    l.productName,
                unitPrice:      l.unitPrice,
                attributeValue: l.attributeValue || null,
            }));

        submitPricebookRequest({
            quoteId:        this._quoteId,
            accountId:      this.accountId,
            siteId:         this.siteId || null,
            currencyCode:   this.currencyCode,
            lines:          JSON.stringify(lineInputs),
            approvalNotes:  '',
            nextApproverId: this.nextApproverId,
        })
            .then(requestId => {
                getRecordNotifyChange([{ recordId: this._quoteId }]);
                this.dispatchEvent(new ShowToastEvent({
                    title:   'Submitted for Approval',
                    message: '{0}',
                    messageData: [{
                        url: '/lightning/r/Pricebook_Request__c/' + requestId + '/view',
                        label: 'View Pricebook Request'
                    }],
                    variant: 'success',
                    mode:    'sticky',
                }));
                this.dispatchEvent(new FlowNavigationFinishEvent());
            })
            .catch(err => {
                this.isSubmitting  = false;
                this.errorMessage  = err?.body?.message || 'Submission failed. Please try again.';
            });
    }
}