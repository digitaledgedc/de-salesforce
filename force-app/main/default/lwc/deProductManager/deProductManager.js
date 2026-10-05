import { LightningElement, wire, track } from 'lwc';
import { NavigationMixin }  from 'lightning/navigation';
import { ShowToastEvent }   from 'lightning/platformShowToastEvent';
import { refreshApex }      from '@salesforce/apex';

import getProducts                from '@salesforce/apex/DeProductManagerController.getProducts';
import getProductDetail           from '@salesforce/apex/DeProductManagerController.getProductDetail';
import toggleProductActive        from '@salesforce/apex/DeProductManagerController.toggleProductActive';
import deleteProduct              from '@salesforce/apex/DeProductManagerController.deleteProduct';
import getProductFamilies         from '@salesforce/apex/DeProductManagerController.getProductFamilies';
import createProduct              from '@salesforce/apex/DeProductManagerController.createProduct';
import getPricebooks              from '@salesforce/apex/DeProductManagerController.getPricebooks';
import getSites                   from '@salesforce/apex/DeProductManagerController.getSites';
import getPricebookEntries        from '@salesforce/apex/DeProductManagerController.getPricebookEntries';
import updatePricebookEntry       from '@salesforce/apex/DeProductManagerController.updatePricebookEntry';
import toggleEntryActive          from '@salesforce/apex/DeProductManagerController.toggleEntryActive';
import deletePricebookEntry       from '@salesforce/apex/DeProductManagerController.deletePricebookEntry';
import createPricebook            from '@salesforce/apex/DeProductManagerController.createPricebook';
import addProductsToPricebook     from '@salesforce/apex/DeProductManagerController.addProductsToPricebook';
import massUpdatePricebookEntries from '@salesforce/apex/DeProductManagerController.massUpdatePricebookEntries';
import getPricebookRequests       from '@salesforce/apex/DeProductManagerController.getPricebookRequests';
import getRequestDetail           from '@salesforce/apex/DeProductManagerController.getRequestDetail';
import upsertRequestLine          from '@salesforce/apex/DeProductManagerController.upsertRequestLine';
import deleteRequestLine          from '@salesforce/apex/DeProductManagerController.deleteRequestLine';
import approveRequest             from '@salesforce/apex/DeProductManagerController.approveRequest';
import rejectRequest              from '@salesforce/apex/DeProductManagerController.rejectRequest';
import searchAccounts             from '@salesforce/apex/DeProductManagerController.searchAccounts';
import searchProductsForPairing   from '@salesforce/apex/DeProductManagerController.searchProductsForPairing';
import linkProducts               from '@salesforce/apex/DeProductManagerController.linkProducts';
import unlinkProducts             from '@salesforce/apex/DeProductManagerController.unlinkProducts';
import updateProduct              from '@salesforce/apex/DeProductManagerController.updateProduct';
import updateProductCatalog       from '@salesforce/apex/DeProductManagerController.updateProductCatalog';
import deletePricingTier          from '@salesforce/apex/DeProductManagerController.deletePricingTier';
import linkPricebookToAccount     from '@salesforce/apex/DeProductManagerController.linkPricebookToAccount';
import linkPricebookToSite        from '@salesforce/apex/DeProductManagerController.linkPricebookToSite';
import unlinkPricebook            from '@salesforce/apex/DeProductManagerController.unlinkPricebook';
import getVariantPricing          from '@salesforce/apex/DeProductManagerController.getVariantPricing';
import getPricingTiers             from '@salesforce/apex/DeProductManagerController.getPricingTiers';
import updatePricingTier           from '@salesforce/apex/DeProductManagerController.updatePricingTier';
import createPricingTier           from '@salesforce/apex/DeProductManagerController.createPricingTier';
import importPricingTiers          from '@salesforce/apex/DeProductManagerController.importPricingTiers';
import addCurrencyEntry             from '@salesforce/apex/DeProductManagerController.addCurrencyEntry';
import getCategoryMappings         from '@salesforce/apex/DeProductManagerController.getCategoryMappings';
import getProductPricebooks        from '@salesforce/apex/DeProductManagerController.getProductPricebooks';
import syncSitePricebooks          from '@salesforce/apex/DeProductManagerController.syncSitePricebooks';

// Fallback category map (used until CMT data loads)
const DEFAULT_PREFIX_MAP = {
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
const DEFAULT_FAMILIES = [
    'All', 'Space', 'Power', 'Cross Connect', 'IP & Internet',
    'Managed Connectivity', 'Remote Hands', 'Managed Services',
    'Office Services', 'Professional Services', 'Reports', 'Storage', 'Other',
];
const REQUEST_STATUSES = [
    { value: 'All',              label: 'All' },
    { value: 'Draft',            label: 'Draft' },
    { value: 'Pending Approval', label: 'Pending Approval' },
    { value: 'Approved',         label: 'Approved' },
    { value: 'Rejected',         label: 'Rejected' },
];
const STATUS_CLASS = {
    'Draft':            'dpm-status-pill dpm-req-draft',
    'Pending Approval': 'dpm-status-pill dpm-req-pending',
    'Approved':         'dpm-status-pill dpm-req-approved',
    'Rejected':         'dpm-status-pill dpm-req-rejected',
};
const STATUS_DOT = {
    'Draft':            'dpm-dot dpm-dot-draft',
    'Pending Approval': 'dpm-dot dpm-dot-pending',
    'Approved':         'dpm-dot dpm-dot-approved',
    'Rejected':         'dpm-dot dpm-dot-rejected',
};
const STATUS_SHORT = {
    'Draft':            'Draft',
    'Pending Approval': 'Pending',
    'Approved':         'Approved',
    'Rejected':         'Rejected',
};
const STATUS_BAR = {
    'Draft':            'dpm-req-card-bar dpm-req-bar-draft',
    'Pending Approval': 'dpm-req-card-bar dpm-req-bar-pending',
    'Approved':         'dpm-req-card-bar dpm-req-bar-approved',
    'Rejected':         'dpm-req-card-bar dpm-req-bar-rejected',
};
const PB_TYPE_LABEL = {
    'Standard': 'Standard',
    'Site':     'Site-Specific',
    'Account':  'Named Account',
    'Reseller': 'Reseller',
};

function fmtCurrency(price, currency) {
    if (price == null) return '—';
    const c = currency || 'USD';
    const decimals = ['JPY', 'KRW', 'IDR'].includes(c) ? 0 : 2;
    const num = new Intl.NumberFormat('en-US', {
        minimumFractionDigits: decimals, maximumFractionDigits: decimals,
    }).format(price);
    const symbols = { USD: '$', JPY: '¥', SGD: 'S$', HKD: 'HK$', IDR: 'Rp', KRW: '₩', CNY: '¥', PHP: '₱' };
    return (symbols[c] || c + ' ') + num;
}
function fmtDate(iso) {
    if (!iso) return '';
    return new Date(iso).toLocaleDateString('en-SG', {
        day: '2-digit', month: 'short', year: 'numeric',
    });
}

export default class DeProductManager extends NavigationMixin(LightningElement) {

    // ─── View navigation (replaces tabs) ────────────────────────────────────
    @track activeView = 'queue';

    get isQueueView()      { return this.activeView === 'queue'; }
    get isCatalogView()    { return this.activeView === 'catalog'; }
    get isPricingView()    { return this.activeView === 'pricing'; }

    get queueNavClass()      { return 'dpm-nav-item' + (this.isQueueView      ? ' dpm-nav-active' : ''); }
    get catalogNavClass()    { return 'dpm-nav-item' + (this.isCatalogView     ? ' dpm-nav-active' : ''); }
    get pricingNavClass()    { return 'dpm-nav-item' + (this.isPricingView     ? ' dpm-nav-active' : ''); }

    handleViewChange(event) {
        const newView = event.currentTarget.dataset.view;
        // Close column menus and clear mass selection when switching views
        if (newView !== this.activeView) {
            this.showColumnMenu        = false;
            this.showProductColumnMenu = false;
            this.selectedEntryIds      = new Set();
            this._removeClickOutsideListener();
            this._computeDisplay();
        }
        this.activeView = newView;
        // Pre-load sites for linking when pricing view opens
        if (newView === 'pricing' && this._sites.length === 0) {
            getSites().then(data => { this._sites = data; }).catch(() => {});
        }
    }

    // ─── Category Mappings (Product_Category_Map__mdt — replaces hardcoded PREFIX_TO_CATEGORY) ──
    _categoryMap = { ...DEFAULT_PREFIX_MAP };   // start with fallback
    _categoryOrder = [...DEFAULT_FAMILIES];
    _categoriesLoaded = false;

    _loadCategoryMappings() {
        if (this._categoriesLoaded) return;
        getCategoryMappings()
            .then(data => {
                if (data && data.length > 0) {
                    const map = {};
                    const cats = new Set();
                    const sorted = [...data].sort((a, b) => (a.sortOrder || 99) - (b.sortOrder || 99));
                    for (const m of sorted) {
                        map[m.prefix.toUpperCase()] = m.category;
                        cats.add(m.category);
                    }
                    this._categoryMap = map;
                    // 'Other' is the catch-all bucket for unknown/blank prefixes (see _categoryFromCode).
                    // Filter it out of the CMT-derived cats so it isn't rendered twice, then pin it last.
                    this._categoryOrder = ['All', ...[...cats].filter(c => c !== 'Other'), 'Other'];
                }
                this._categoriesLoaded = true;
            })
            .catch(() => { this._categoriesLoaded = true; });
    }

    _categoryFromCode(code) {
        if (!code) return 'Other';
        return this._categoryMap[(code.substring(0, 3) || '').toUpperCase()] || 'Other';
    }

    // ─── Pricing Tiers (consolidated Product_Pricing_Tier__mdt) ─────────────────
    @track _pricingTiers = [];
    @track _tiersLoaded  = false;

    _loadPricingTiers() {
        if (this._tiersLoaded) return;
        getPricingTiers()
            .then(data => {
                this._pricingTiers = data || [];
                this._tiersLoaded  = true;
            })
            .catch(() => { /* tier load failed silently */ });
    }

    /**
     * Returns kVA pricing rows filtered for a specific product code.
     * Shows product-specific rows + generic fallback rows.
     */
    /**
     * Returns pricing tier rows for a product from the consolidated CMT.
     * Groups by attribute value, shows all currencies per tier.
     */
    _getKvaRowsForProduct(productCode) {
        if (!this._tiersLoaded || !productCode) return [];
        // Group tiers by attribute value
        const byAttr = {};
        for (const t of this._pricingTiers) {
            if (t.productCode !== productCode) continue;
            if (!byAttr[t.attributeValue]) byAttr[t.attributeValue] = {};
            byAttr[t.attributeValue][t.currencyCode] = t.price;
        }
        const sortKey = (v) => { const m = v.match(/[\d.]+/); return m ? parseFloat(m[0]) : 999; };
        return Object.keys(byAttr).sort((a, b) => sortKey(a) - sortKey(b)).map(attr => {
            const prices = byAttr[attr];
            return {
                key: productCode + '_' + attr,
                kvaValue: attr,
                priceUSDFmt: prices.USD ? fmtCurrency(prices.USD, 'USD') : '—',
                priceJPYFmt: prices.JPY ? fmtCurrency(prices.JPY, 'JPY') : '—',
                priceIDRFmt: prices.IDR ? fmtCurrency(prices.IDR, 'IDR') : '—',
                priceKRWFmt: prices.KRW ? fmtCurrency(prices.KRW, 'KRW') : '—',
                priceSGDFmt: prices.SGD ? fmtCurrency(prices.SGD, 'SGD') : '—',
                priceHKDFmt: prices.HKD ? fmtCurrency(prices.HKD, 'HKD') : '—',
                priceCNYFmt: prices.CNY ? fmtCurrency(prices.CNY, 'CNY') : '—',
                pricePHPFmt: prices.PHP ? fmtCurrency(prices.PHP, 'PHP') : '—',
                productCodeDisplay: productCode,
                isGeneric: false,
            };
        });
    }

    // ─── Products (wire) ─────────────────────────────────────────────────────
    @track productSearch    = '';
    @track activeFamily     = 'All';
    @track openFamilies     = new Set();
    @track productsLoading  = true;
    @track productsLoaded   = false;
    @track productsError    = '';
    _products        = [];
    _wiredProducts;
    _togglingProduct = null;
    @track _confirmDeleteProductId = null;
    @track _expandedProdPbs = null; // { productId, pricebooks: [...], loading }

    @wire(getProducts)
    wiredProducts(result) {
        this._wiredProducts  = result;
        this.productsLoading = false;
        if (result.data) {
            this._products      = result.data;
            this.productsLoaded = true;
            this.productsError  = '';
        } else if (result.error) {
            this.productsError = result.error?.body?.message || 'Failed to load products.';
        }
    }

    get filteredProductList() {
        let list = this._products;
        if (this.productSearch) {
            // Search overrides family filter - search across ALL products
            const t = this.productSearch.toLowerCase();
            list = list.filter(p =>
                p.name.toLowerCase().includes(t) ||
                (p.productCode || '').toLowerCase().includes(t)
            );
        } else if (this.activeFamily !== 'All') {
            list = list.filter(p => this._categoryFromCode(p.productCode) === this.activeFamily);
        }
        return list;
    }

    get groupedProducts() {
        const groups = {};
        this.filteredProductList.forEach(p => {
            const fam = this._categoryFromCode(p.productCode);
            if (!groups[fam]) groups[fam] = [];
            groups[fam].push({
                ...p,
                statusDotClass: p.isActive ? 'dpm-dot dpm-dot-approved' : 'dpm-dot dpm-dot-draft',
                statusLabel:    p.isActive ? 'Active' : 'Inactive',
                toggleTitle:    p.isActive ? 'Deactivate' : 'Activate',
                toggleIcon:     p.isActive ? 'utility:toggle_panel_close' : 'utility:toggle_panel_open',
                isToggling:     p.id === this._togglingProduct,
            });
        });
        // add rowNum per-product within each group
        Object.keys(groups).forEach(fam => {
            groups[fam] = groups[fam].map((p, i) => ({ ...p, rowNum: i + 1 }));
        });
        const knownSet = new Set(this._categoryOrder);
        const extraFamilies = Object.keys(groups).filter(f => !knownSet.has(f)).sort();
        const orderedFamilies = this._categoryOrder.filter(f => f !== 'All' && groups[f]).concat(extraFamilies.filter(f => groups[f]));
        return orderedFamilies.map(f => ({
                family:       f,
                products:     groups[f],
                count:        groups[f].length,
                sectionClass: 'cat-section' + (this.openFamilies.has(f) ? ' cat-section_open' : ''),
            }));
    }

    get productFamilyFilters() {
        const present = new Set(this._products.map(p => this._categoryFromCode(p.productCode)));
        const knownSet = new Set(this._categoryOrder);
        const extraFamilies = [...present].filter(f => !knownSet.has(f)).sort();
        const allFamilies = this._categoryOrder.concat(extraFamilies);
        return allFamilies
            .filter(f => f === 'All' || present.has(f))
            .map(f => ({
                value:    f,
                label:    f,
                cssClass: 'cat-pill' + (this.activeFamily === f ? ' cat-pill_active' : ''),
            }));
    }

    // ── Category cards (horizontal scroll tier) ──────────────────────────────
    get productCategoryCards() {
        const counts = {};
        const active = {};
        this._products.forEach(p => {
            const fam = this._categoryFromCode(p.productCode);
            counts[fam] = (counts[fam] || 0) + 1;
            if (p.isActive) active[fam] = (active[fam] || 0) + 1;
        });
        const total = this._products.length;
        const totalActive = this._products.filter(p => p.isActive).length;
        const knownSet = new Set(this._categoryOrder);
        const extraFamilies = Object.keys(counts).filter(f => !knownSet.has(f)).sort();
        const allFamilies = this._categoryOrder.concat(extraFamilies);
        return allFamilies
            .filter(f => f === 'All' || counts[f])
            .map(f => ({
                value:       f,
                label:       f,
                count:       f === 'All' ? total : (counts[f] || 0),
                activeCount: f === 'All' ? totalActive : (active[f] || 0),
                cardClass:   'dpm-cat-card' + (this.activeFamily === f ? ' dpm-cat-card-sel' : ''),
            }));
    }

    // ── Flat product list (no section grouping) ──────────────────────────────
    get flatProducts() {
        return this.filteredProductList.map((p, i) => ({
            ...p,
            rowNum:           i + 1,
            statusDotClass:   p.isActive ? 'dpm-dot dpm-dot-approved' : 'dpm-dot dpm-dot-draft',
            statusLabel:      p.isActive ? 'Active' : 'Inactive',
            toggleTitle:      p.isActive ? 'Deactivate' : 'Activate',
            toggleIcon:       p.isActive ? 'utility:toggle_panel_close' : 'utility:toggle_panel_open',
            isToggling:       p.id === this._togglingProduct,
            chargeTypeLabel:  p.chargeType || '—',
            chargeTypeBadge:  p.chargeType ? ('dpm-charge-badge dpm-charge-' + p.chargeType.toLowerCase()) : '',
            hasChargeType:    !!p.chargeType,
            hasPairedProduct: !!p.pairedProductId,
            hasEntries:       (p.entryCount || 0) > 0,
            confirmDelete:    p.id === this._confirmDeleteProductId,
            pbListExpanded:   this._expandedProdPbs?.productId === p.id,
            pbListLoading:    this._expandedProdPbs?.productId === p.id && this._expandedProdPbs?.loading,
            pbList:           this._expandedProdPbs?.productId === p.id ? (this._expandedProdPbs?.pricebooks || []) : [],
            pbExpandKey:      'pblist_' + p.id,
        }));
    }

    get hasFilteredProducts() { return !this.productsLoading && this.filteredProductList.length > 0; }
    get productCount()         { return this._products.filter(p => p.isActive).length; }
    get productStatusLabel() {
        if (this.productsLoading) return 'Loading...';
        const n = this.filteredProductList.length;
        if (this.productSearch) return `${n} product${n !== 1 ? 's' : ''} match "${this.productSearch}"`;
        if (this.activeFamily === 'All') return `${n} product${n !== 1 ? 's' : ''}`;
        const act = this.filteredProductList.filter(p => p.isActive).length;
        const inact = n - act;
        return `${n} product${n !== 1 ? 's' : ''} in ${this.activeFamily}  ·  ${act} active` + (inact > 0 ? `  ·  ${inact} inactive` : '');
    }

    // ── Catalog view states (progressive disclosure) ──────────────────────
    get showCatalogDrillIn()  { return !this.productSearch && this.activeFamily !== 'All'; }
    get showCatalogSearch()   { return !!this.productSearch; }
    get showProductTable()    { return this.activeFamily !== 'All' || !!this.productSearch; }

    get catalogCategoryGrid() {
        const counts = {};
        const active = {};
        this._products.forEach(p => {
            const fam = this._categoryFromCode(p.productCode);
            counts[fam] = (counts[fam] || 0) + 1;
            if (p.isActive) active[fam] = (active[fam] || 0) + 1;
        });
        return this._categoryOrder
            .filter(f => f !== 'All' && counts[f])
            .map(f => ({
                value:        f,
                label:        f,
                count:        counts[f] || 0,
                activeCount:  active[f] || 0,
                inactiveCount: (counts[f] || 0) - (active[f] || 0),
                cardClass:    'dpm-catalog-card' + (this.activeFamily === f ? ' dpm-catalog-card-sel' : ''),
            }));
    }

    get catalogDrillInLabel() {
        const n = this.filteredProductList.length;
        const act = this.filteredProductList.filter(p => p.isActive).length;
        return `${n} product${n !== 1 ? 's' : ''}  ·  ${act} active`;
    }

    handleProductSearch(event)      { this.productSearch = event.target.value; }
    handleClearProductSearch()      { this.productSearch = ''; }
    handleProductFamilyClick(event) {
        const val = event.currentTarget.dataset.value;
        this.activeFamily = this.activeFamily === val ? 'All' : val;
    }
    handleCatalogBack()             { this.activeFamily  = 'All'; this.productSearch = ''; }
    handleProductSectionToggle(event) {
        const fam  = event.currentTarget.dataset.family;
        const next = new Set(this.openFamilies);
        if (next.has(fam)) next.delete(fam); else next.add(fam);
        this.openFamilies = next;
    }

    // ─── New / Edit Product Modal ────────────────────────────────────────────────
    @track _editingProductId    = null;
    @track showNewProductModal  = false;
    @track newProductName       = '';
    @track newProductCode       = '';
    @track newProductFamily     = '';
    @track newProductChargeType = '';
    @track newProductDesc       = '';
    @track newProductAttribute     = '';
    @track newProductAttrValues    = '';
    @track newProductShowCustom    = false;
    @track newProductCountries     = [];
    @track newProductSites         = [];
    @track newProductAllowedUom    = [];   // SFDC-366: extra units this product may use
    @track newProductError      = '';
    @track isCreatingProduct    = false;
    _productFamilies = [];

    handleNewProduct() {
        this._editingProductId    = null;
        this.newProductName       = '';
        this.newProductCode       = '';
        this.newProductFamily     = '';
        this.newProductChargeType = '';
        this.newProductDesc       = '';
        this.newProductAttribute     = '';
        this.newProductAttrValues    = '';
        this.newProductShowCustom    = false;
        this.newProductCountries     = [];
        this.newProductSites         = [];
        this.newProductAllowedUom    = [];
        this.newProductError      = '';
        // Auto-select site from current pricebook context
        if (this.selectedPricebook?.linkedTo) {
            const site = this.selectedPricebook.linkedTo;
            if (!site.includes(' ')) { // Not an account name
                this.newProductSites = [site];
            }
        } else if (this.selectedPricebook?.name) {
            const m = this.selectedPricebook.name.match(/[A-Z]{3}\d/);
            if (m) this.newProductSites = [m[0]];
        }
        if (!this._productFamilies.length) {
            getProductFamilies()
                .then(data => { this._productFamilies = data; })
                .catch(err => { this.newProductError = err.body?.message ?? 'Could not load product families.'; });
        }
        this.showNewProductModal = true;
    }

    handleEditProductFromCatalog(event) {
        const id = event.currentTarget.dataset.id;
        const prod = (this._wiredProducts?.data || []).find(p => p.id === id);
        if (!prod) return;
        this._editingProductId = id;
        this.newProductName = prod.name || '';
        this.newProductCode = prod.productCode || '';
        this.newProductFamily = prod.family || '';
        this.newProductChargeType = prod.chargeType || '';
        this.newProductDesc = prod.description || '';
        this.newProductAttribute = prod.attributeType || '';
        this.newProductAttrValues = prod.attributeValues || '';
        this.newProductShowCustom = prod.showCustomValue || false;
        this.newProductCountries = prod.availableCountries ? prod.availableCountries.split(';') : [];
        this.newProductSites = prod.availableSites ? prod.availableSites.split(';') : [];
        // SFDC-366: ';'-delimited multi-select, same shape as the detail-panel modal
        this.newProductAllowedUom = prod.allowedUom ? prod.allowedUom.split(';').map(v => v.trim()).filter(Boolean) : [];
        this.newProductError = '';
        if (!this._productFamilies.length) {
            getProductFamilies()
                .then(data => { this._productFamilies = data; })
                .catch(() => {});
        }
        this.showNewProductModal = true;
    }

    get isEditingProduct() { return !!this._editingProductId; }
    get newProductModalTitle() { return this._editingProductId ? 'Edit Product' : 'New Product'; }
    get newProductSaveLabel() { return this._editingProductId ? 'Save Changes' : 'Save Product'; }

    get productFamilyOptions() {
        const opts = [{ label: '-- Select Family --', value: '' }];
        this._productFamilies.forEach(f => opts.push({ label: f, value: f }));
        return opts;
    }
    get hasProductFamilyOptions() { return this._productFamilies.length > 0; }

    handleNewProductName(e)       { this.newProductName       = e.target.value; }
    handleNewProductCode(e)       { this.newProductCode       = e.target.value; }
    handleNewProductFamily(e)     { this.newProductFamily     = e.detail ? e.detail.value : e.target.value; }
    handleNewProductChargeType(e) { this.newProductChargeType = e.detail ? e.detail.value : e.target.value; }
    handleNewProductDesc(e)       { this.newProductDesc       = e.target.value; }
    handleNewProductAttribute(e)  { this.newProductAttribute  = e.detail ? e.detail.value : e.target.value; }
    handleNewProductAttrValues(e) { this.newProductAttrValues  = e.target.value; }
    handleNewProductShowCustom(e) { this.newProductShowCustom  = e.target.checked; }
    handleNewProductCountries(e) { this.newProductCountries = e.detail.value || []; }
    handleNewProductSites(e) { this.newProductSites = e.detail.value || []; }
    handleNewProductAllowedUom(e) { this.newProductAllowedUom = e.detail.value || []; }
    get siteOptions() {
        return [
            { label: 'BKK1', value: 'BKK1' }, { label: 'BKK2', value: 'BKK2' },
            { label: 'BOM1', value: 'BOM1' }, { label: 'BOM2', value: 'BOM2' }, { label: 'BOM3', value: 'BOM3' },
            { label: 'CGK1', value: 'CGK1' }, { label: 'CGK2', value: 'CGK2' }, { label: 'CGK7', value: 'CGK7' },
            { label: 'JKT1', value: 'JKT1' }, { label: 'JKT2', value: 'JKT2' },
            { label: 'MNL1', value: 'MNL1' },
            { label: 'OSA1', value: 'OSA1' }, { label: 'OSA2', value: 'OSA2' },
            { label: 'PEK1', value: 'PEK1' }, { label: 'PUS1', value: 'PUS1' },
            { label: 'SEL1', value: 'SEL1' }, { label: 'SEL2', value: 'SEL2' }, { label: 'SEL3', value: 'SEL3' },
            { label: 'TYO1', value: 'TYO1' }, { label: 'TYO2', value: 'TYO2' }, { label: 'TYO3', value: 'TYO3' },
            { label: 'TYO4', value: 'TYO4' }, { label: 'TYO5', value: 'TYO5' }, { label: 'TYO6', value: 'TYO6' }, { label: 'TYO7', value: 'TYO7' },
        ];
    }
    get countryOptions() {
        return [
            { label: 'Japan', value: 'JP' }, { label: 'Korea', value: 'KR' },
            { label: 'Indonesia', value: 'ID' }, { label: 'Philippines', value: 'PH' },
            { label: 'China', value: 'CN' }, { label: 'India', value: 'IN' },
            { label: 'Thailand', value: 'TH' }, { label: 'Malaysia', value: 'MY' },
            { label: 'Singapore', value: 'SG' }, { label: 'Hong Kong', value: 'HK' },
        ];
    }
    handleNewProductModalClose()  { this.showNewProductModal  = false; this._editingProductId = null; this._newProductFromAddPanel = false; }

    get productAttributeOptions() {
        return [
            { label: '-- None --', value: '' },
            { label: 'Amps', value: 'Amps' },
            { label: 'Bandwidth', value: 'Bandwidth' },
            { label: 'Connector Type', value: 'Connector Type' },
            { label: 'Draw Cap in kVA', value: 'Draw Cap in kVA' },
            { label: 'Draw Cap in kW', value: 'Draw Cap in kW' },
            { label: 'Number of Cores', value: 'Number of Cores' },
            { label: 'Z-side Operation Site', value: 'Z-side Operation Site' },
        ];
    }

    get chargeTypeOptions() {
        return [
            { label: '-- Select Charge Type --', value: '' },
            { label: 'MRC (Monthly Recurring)',   value: 'MRC' },
            { label: 'NRC (Non-Recurring)',        value: 'NRC' },
        ];
    }

    handleSaveNewProduct() {
        if (!this.newProductName?.trim()) { this.newProductError = 'Product name is required.'; return; }
        this.newProductError   = '';
        this.isCreatingProduct = true;

        if (this._editingProductId) {
            // ── Edit existing product ──
            updateProductCatalog({
                productId: this._editingProductId,
                name: this.newProductName.trim(),
                productCode: this.newProductCode || null,
                family: this.newProductFamily || null,
                chargeType: this.newProductChargeType || null,
                productAttribute: this.newProductAttribute || null,
                attributeValues: this.newProductAttrValues || null,
                showCustomAttrVal: this.newProductShowCustom,
                availableCountries: this.newProductCountries.length ? this.newProductCountries.join(';') : null,
                availableSites: this.newProductSites.length ? this.newProductSites.join(';') : null,
                allowedUom: this.newProductAllowedUom.length ? this.newProductAllowedUom.join(';') : null,
            })
            .then(() => {
                this.showNewProductModal = false;
                this._editingProductId = null;
                refreshApex(this._wiredProducts);
                this._toast('Product Updated', '', 'success');
            })
            .catch(err => { this.newProductError = err?.body?.message || 'Failed to update product.'; })
            .finally(() => { this.isCreatingProduct = false; });
        } else {
            // ── Create new product ──
            createProduct({
                name:        this.newProductName.trim(),
                productCode: this.newProductCode      || null,
                family:      this.newProductFamily     || null,
                description: this.newProductDesc       || null,
                isActive:    true,
                chargeType:  this.newProductChargeType || null,
                productAttribute:  this.newProductAttribute  || null,
                attributeValues:   this.newProductAttrValues  || null,
                showCustomAttrVal: this.newProductShowCustom,
                availableCountries: this.newProductCountries.length ? this.newProductCountries.join(';') : null,
                availableSites: this.newProductSites.length ? this.newProductSites.join(';') : null,
                allowedUom: this.newProductAllowedUom.length ? this.newProductAllowedUom.join(';') : null,
            })
            .then((newProductId) => {
                const addToPanel = this._newProductFromAddPanel;
                const savedName = this.newProductName.trim();
                const savedCode = this.newProductCode || '';
                this._newProductFromAddPanel = false;
                this.showNewProductModal = false;
                this._toast('Product Created', `"${savedName}" created.`, 'success');
                return refreshApex(this._wiredProducts).then(() => {
                    if (addToPanel && newProductId) {
                        this.addProdSelections = [...this.addProdSelections, {
                            id: newProductId, name: savedName, code: savedCode, unitPrice: 0
                        }];
                    }
                });
            })
            .catch(err => { this.newProductError = err?.body?.message || 'Failed to create product.'; })
            .finally(() => { this.isCreatingProduct = false; });
        }
    }

    handleManageProductFamilies() {
        this[NavigationMixin.Navigate]({
            type: 'standard__webPage',
            attributes: { url: '/lightning/setup/ObjectManager/Product2/FieldsAndRelationships/Family/view' },
        });
    }

    handleOpenProduct(event) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: event.currentTarget.dataset.id, actionName: 'view' },
        });
    }
    handleGoToPricingForProduct(event) {
        event.stopPropagation();
        const id = event.currentTarget.dataset.id;
        const code = event.currentTarget.dataset.code;
        // Toggle: if already expanded for this product, collapse
        if (this._expandedProdPbs && this._expandedProdPbs.productId === id) {
            this._expandedProdPbs = null;
            return;
        }
        this._expandedProdPbs = { productId: id, productCode: code, pricebooks: [], loading: true };
        getProductPricebooks({ productId: id })
            .then(data => {
                this._expandedProdPbs = { ...this._expandedProdPbs, pricebooks: data || [], loading: false };
            })
            .catch(() => {
                this._expandedProdPbs = { ...this._expandedProdPbs, loading: false };
            });
    }

    handlePbListClick(event) {
        const pbId = event.currentTarget.dataset.id;
        this._expandedProdPbs = null; // collapse
        // Navigate to Pricing tab with this pricebook selected
        this.activeView = 'pricing';
        this.entrySearch = '';
        const pb = this._pricebooks.find(p => p.id === pbId);
        if (pb) {
            this.selectedPricebookType = pb.pricebookType;
            this.selectedPricebook = pb;
            this._setEntries([]);
            this._loadEntries(pb.id);
        }
    }
    handleProductEye(event) {
        const id = event.currentTarget.dataset.id;
        if (id) {
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: { recordId: id, actionName: 'view' }
            });
        }
    }
    handlePairedProductClick(event) {
        const id = event.currentTarget.dataset.id;
        if (!id) return;
        this._detailLoading = true;
        this._detailPanel   = null;
        getProductDetail({ productId: id })
            .then(data => {
                this._detailPanel = {
                    type: 'product',
                    data: this._enrichProductDetail(data),
                };
            })
            .catch(err => this._toast('Error', err?.body?.message || 'Failed to load paired product.', 'error'))
            .finally(() => { this._detailLoading = false; });
    }
    handleAdditionalChargeOfClick(event) {
        const id = event.currentTarget.dataset.id;
        if (!id) return;
        this._detailLoading = true;
        this._detailPanel   = null;
        getProductDetail({ productId: id })
            .then(data => {
                this._detailPanel = {
                    type: 'product',
                    data: this._enrichProductDetail(data),
                };
            })
            .catch(err => this._toast('Error', err?.body?.message || 'Failed to load product.', 'error'))
            .finally(() => { this._detailLoading = false; });
    }
    // ─── MRC ↔ NRC Pairing (product detail panel) ─────────────────────────
    @track _pairingSearch        = '';
    @track _pairingSearchResults = [];
    @track _showPairingResults   = false;
    @track _linkingProduct       = false;
    @track _unlinkingProduct     = false;

    get hasPairingSearchResults() { return this._showPairingResults && this._pairingSearchResults.length > 0; }

    handlePairingSearchInput(event) {
        const val = event.target.value;
        this._pairingSearch = val;
        if (!val || val.length < 2) {
            this._pairingSearchResults = [];
            this._showPairingResults   = false;
            return;
        }
        const productId = this.detailData.id;
        searchProductsForPairing({ productId, searchTerm: val })
            .then(data => {
                this._pairingSearchResults = (data || []).map(p => ({
                    ...p,
                    label: `${p.name}${p.productCode ? ' (' + p.productCode + ')' : ''}`,
                    chargeLabel: p.chargeType || '',
                    chargeBadge: p.chargeType ? ('dpm-charge-badge dpm-charge-' + p.chargeType.toLowerCase()) : '',
                }));
                this._showPairingResults = this._pairingSearchResults.length > 0;
            })
            .catch(() => { this._pairingSearchResults = []; this._showPairingResults = false; });
    }

    handleLinkProduct(event) {
        const nrcId = event.currentTarget.dataset.id;
        const currentProduct = this.detailData;
        if (!currentProduct || !nrcId) return;

        // Determine which is MRC and which is NRC
        // If current product is MRC (or no charge type), it links to the selected NRC
        // If current product is NRC, the selected product becomes the MRC that links to this one
        const isMrc = !currentProduct.chargeType || currentProduct.chargeType === 'MRC';
        const mrcId = isMrc ? currentProduct.id : nrcId;
        const nrcIdFinal = isMrc ? nrcId : currentProduct.id;

        this._linkingProduct     = true;
        this._pairingSearch      = '';
        this._pairingSearchResults = [];
        this._showPairingResults = false;

        linkProducts({ mrcProductId: mrcId, nrcProductId: nrcIdFinal })
            .then(() => {
                this._toast('Products Linked', 'MRC ↔ NRC pairing saved.', 'success');
                // Refresh product detail to show updated pairing
                return getProductDetail({ productId: currentProduct.id });
            })
            .then(data => {
                this._detailPanel = {
                    type: 'product',
                    data: this._enrichProductDetail(data),
                };
                // Also refresh the product list cache
                return refreshApex(this._wiredProducts);
            })
            .catch(err => this._toast('Error', err?.body?.message || 'Failed to link products.', 'error'))
            .finally(() => { this._linkingProduct = false; });
    }

    handleUnlinkProduct() {
        const currentProduct = this.detailData;
        if (!currentProduct?.pairedProductId) return;

        // If current product has explicit pair and is MRC, unlink from this product
        // If current product is NRC, the MRC side owns the lookup — find the MRC that links to us
        const isMrc = currentProduct.chargeType === 'MRC';
        const mrcId = isMrc ? currentProduct.id : currentProduct.pairedProductId;

        this._unlinkingProduct = true;
        unlinkProducts({ mrcProductId: mrcId })
            .then(() => {
                this._toast('Products Unlinked', 'Pairing removed.', 'success');
                return getProductDetail({ productId: currentProduct.id });
            })
            .then(data => {
                this._detailPanel = {
                    type: 'product',
                    data: this._enrichProductDetail(data),
                };
                return refreshApex(this._wiredProducts);
            })
            .catch(err => this._toast('Error', err?.body?.message || 'Failed to unlink products.', 'error'))
            .finally(() => { this._unlinkingProduct = false; });
    }

    // ─── Edit Product Modal ──────────────────────────────────────────────────
    @track showEditProductModal     = false;
    @track editProductId            = '';
    @track editProductName          = '';
    @track editProductDesc          = '';
    @track editProductAttrType      = '';
    @track editProductAttrValues    = '';
    @track editProductShowCustom    = false;
    @track editProductCapAssign     = '';
    @track editProductUom           = '';
    @track editProductAllowedUom    = [];   // SFDC-366: extra units this product may use
    @track editProductError         = '';
    @track isSavingProduct          = false;

    get capacityAssignmentOptions() {
        return [
            { label: '-- None --',   value: '' },
            { label: 'Space ID',     value: 'Space ID' },
            { label: 'Breaker ID',   value: 'Breaker ID' },
        ];
    }

    handleEditProduct() {
        const d = this.detailData;
        this.editProductId          = d.id;
        this.editProductName        = d.name || '';
        this.editProductDesc        = d.description || '';
        this.editProductAttrType    = d.attributeType || '';
        this.editProductAttrValues  = d.attributeValues || '';
        this.editProductShowCustom  = d.showCustomValue === true;
        this.editProductCapAssign   = d.capacityAssignment || '';
        this.editProductUom         = d.uom || '';
        // SFDC-366: Allowed_UoM__c is a multi-select picklist, stored ';'-delimited
        this.editProductAllowedUom  = (d.allowedUom || '').split(';').map(v => v.trim()).filter(Boolean);
        this.editProductError       = '';
        this.showEditProductModal   = true;
    }
    handleEditProductModalClose() { this.showEditProductModal = false; }
    handleEditProductName(e)      { this.editProductName       = e.target.value; }
    handleEditProductDesc(e)      { this.editProductDesc       = e.target.value; }
    handleEditProductAttrType(e)  { this.editProductAttrType   = e.target.value; }
    handleEditProductAttrValues(e){ this.editProductAttrValues  = e.target.value; }
    handleEditProductShowCustom(e){ this.editProductShowCustom  = e.target.checked; }
    handleEditProductCapAssign(e) { this.editProductCapAssign   = e.detail ? e.detail.value : e.target.value; }
    handleEditProductUom(e)       { this.editProductUom         = e.target.value; }
    handleEditProductAllowedUom(e){ this.editProductAllowedUom  = e.detail.value; }

    // SFDC-366: the DE_Unit_Of_Measure value set. Hard-coded rather than wired to a
    // picklist describe because this screen already hard-codes its other option lists,
    // and the set is stable. If a value is added to the global value set, add it here
    // and to Product2.QuantityUnitOfMeasure too.
    get allowedUomOptions() {
        return ['Each','Cab','sqm','Unit','kVA','Mbps','Pair','Working Hours','Days','kwh','15-minutes']
            .map(v => ({ label: v, value: v }));
    }

    handleSaveEditProduct() {
        if (!this.editProductName?.trim()) {
            this.editProductError = 'Product name is required.';
            return;
        }
        this.editProductError = '';
        this.isSavingProduct  = true;
        updateProduct({
            productId:       this.editProductId,
            name:            this.editProductName.trim(),
            description:     this.editProductDesc || null,
            attributeType:   this.editProductAttrType || null,
            attributeValues: this.editProductAttrValues || null,
            showCustomValue: this.editProductShowCustom,
            capacityAssignment: this.editProductCapAssign || null,
            uom:             this.editProductUom || null,
            allowedUom:      this.editProductAllowedUom.length ? this.editProductAllowedUom.join(';') : null,
        })
        .then(() => {
            this.showEditProductModal = false;
            this._toast('Product Updated', `"${this.editProductName}" saved.`, 'success');
            // Refresh both the list and the detail panel
            return refreshApex(this._wiredProducts).then(() => {
                return getProductDetail({ productId: this.editProductId });
            });
        })
        .then(data => {
            if (data) {
                const listRow = (this._products || []).find(p => p.id === this.editProductId);
                this._detailPanel = {
                    type: 'product',
                    data: this._enrichProductDetail(data, listRow),
                };
            }
        })
        .catch(err => { this.editProductError = err?.body?.message || 'Failed to update product.'; })
        .finally(() => { this.isSavingProduct = false; });
    }

    handleToggleProductActive(event) {
        const id       = event.currentTarget.dataset.id;
        const newActive = event.currentTarget.dataset.active === 'true' ? false : true;
        this._togglingProduct = id;
        toggleProductActive({ productId: id, isActive: newActive })
            .then(() => {
                this._products = this._products.map(p =>
                    p.id === id ? { ...p, isActive: newActive } : p
                );
                if (this._detailPanel?.type === 'product' && this._detailPanel.data.id === id) {
                    this._detailPanel = {
                        ...this._detailPanel,
                        data: this._enrichProductDetail({ ...this._detailPanel.data, isActive: newActive }),
                    };
                }
                this._toast('Success', `Product ${newActive ? 'activated' : 'deactivated'}.`, 'success');
            })
            .catch(err => this._toast('Error', err?.body?.message || 'Failed to update product.', 'error'))
            .finally(() => { this._togglingProduct = null; });
    }

    handleDeleteProduct(event) {
        this._confirmDeleteProductId = event.currentTarget.dataset.id;
    }
    handleCancelDeleteProduct() {
        this._confirmDeleteProductId = null;
    }
    handleConfirmDeleteProduct(event) {
        const id = event.currentTarget.dataset.id;
        deleteProduct({ productId: id })
            .then(() => {
                this._confirmDeleteProductId = null;
                refreshApex(this._wiredProducts);
                this._toast('Product Deleted', '', 'success');
            })
            .catch(err => {
                this._confirmDeleteProductId = null;
                this._toast('Error', err?.body?.message || 'Failed to delete product.', 'error');
            });
    }

    _enrichProductDetail(data, listRow) {
        // Merge config fields from the list row (ProductRow) if available,
        // since ProductDetailRow does not carry them.
        const lr = listRow || (this._products || []).find(p => p.id === data.id) || {};
        const merged = {
            ...data,
            attributeType:          data.attributeType          ?? lr.attributeType          ?? '',
            attributeValues:        data.attributeValues        ?? lr.attributeValues        ?? '',
            showCustomValue:        data.showCustomValue        ?? lr.showCustomValue        ?? false,
            capacityAssignment:     data.capacityAssignment     ?? lr.capacityAssignment     ?? '',
            uom:                    data.uom                    ?? lr.uom                    ?? '',
            additionalChargeOfId:   data.additionalChargeOfId   ?? lr.additionalChargeOfId   ?? '',
            additionalChargeOfName: data.additionalChargeOfName ?? lr.additionalChargeOfName ?? '',
            additionalChargeOfCode: data.additionalChargeOfCode ?? lr.additionalChargeOfCode ?? '',
        };

        const enrichedMatrix = (merged.pricingMatrix || []).map(m => ({
            ...m,
            unitPriceFormatted: fmtCurrency(m.unitPrice, m.currencyIsoCode),
            activeLabel:    m.isActive ? 'Active' : 'Inactive',
            activeDotClass: m.isActive ? 'dpm-dot dpm-dot-approved' : 'dpm-dot dpm-dot-draft',
        }));
        // Group by pricebook type for cleaner panel display
        const typeOrder  = ['Standard', 'Site', 'Account', 'Reseller'];
        const typeGroups = {};
        enrichedMatrix.forEach(m => {
            const t = m.pricebookType || 'Account';
            if (!typeGroups[t]) typeGroups[t] = [];
            typeGroups[t].push(m);
        });
        const pricingMatrixGroups = typeOrder
            .filter(t => typeGroups[t]?.length)
            .map(t => ({
                type:  t,
                label: PB_TYPE_LABEL[t] || t,
                items: typeGroups[t],
                count: typeGroups[t].length,
            }));

        // Attribute values as pills array
        const attrValuesRaw = merged.attributeValues || '';
        const attributePills = attrValuesRaw
            ? attrValuesRaw.split(',').map((v, i) => ({ key: 'av_' + i, label: v.trim() })).filter(p => p.label)
            : [];

        const kvaForProduct = this._getKvaRowsForProduct(merged.productCode);

        return {
            ...merged,
            familyLabel:      merged.family || '—',
            statusClass:      merged.isActive ? 'dpm-status-pill dpm-status-active' : 'dpm-status-pill dpm-status-inactive',
            statusLabel:      merged.isActive ? 'Active' : 'Inactive',
            toggleTitle:      merged.isActive ? 'Deactivate' : 'Activate',
            chargeTypeLabel:  merged.chargeType || '—',
            chargeTypeBadge:  merged.chargeType ? ('dpm-charge-badge dpm-charge-' + merged.chargeType.toLowerCase()) : '',
            hasChargeType:    !!merged.chargeType,
            hasPairedProduct: !!merged.pairedProductId,
            isExplicitPair:   !!merged.isExplicitPair,
            isCodeConvention: !!merged.pairedProductId && !merged.isExplicitPair,
            pairedLabel:      merged.chargeType === 'MRC' ? 'Paired NRC Product' : 'Paired MRC Product',
            pricingMatrix:       enrichedMatrix,
            pricingMatrixGroups: pricingMatrixGroups,
            hasPricingMatrix:    pricingMatrixGroups.length > 0,
            // Config section fields
            attributeTypeLabel:        merged.attributeType || '—',
            attributePills:            attributePills,
            hasAttributePills:         attributePills.length > 0,
            showCustomValueLabel:      merged.showCustomValue ? 'Yes' : 'No',
            showCustomValueIcon:       merged.showCustomValue ? 'utility:check' : 'utility:close',
            capacityAssignmentLabel:   merged.capacityAssignment || '—',
            uomLabel:                  merged.uom || '—',
            hasAdditionalChargeOf:     !!merged.additionalChargeOfId,
            additionalChargeOfDisplay: merged.additionalChargeOfName
                ? `${merged.additionalChargeOfName}${merged.additionalChargeOfCode ? ' (' + merged.additionalChargeOfCode + ')' : ''}`
                : '—',
            hasConfigSection:          !!(merged.attributeType || merged.attributeValues || merged.showCustomValue || merged.capacityAssignment || merged.uom || merged.additionalChargeOfId),
            // kVA pricing rows for this product
            kvaRows:    kvaForProduct,
            hasKvaRows: kvaForProduct.length > 0,
        };
    }

    // ─── Pricebooks (wire) ────────────────────────────────────────────────────
    @track pricebooksLoading      = true;
    @track selectedPricebook      = null;
    @track selectedPricebookType  = null;   // null = type overview, 'Site'/'Account' etc = drilled in
    @track pricebookFilter        = '';
    entrySearch            = '';  // NOT @track — only _displayList drives re-renders
    @track entriesLoading         = false;
    @track openPricebookGroups    = new Set();
    _pricebooks           = [];
    _rawEntries           = [];
    @track _entryVersion  = 0;
    @track _displayList = [];
    _lastSearchTerm = '';
    @track _expandedGroups = new Set();
    _renderTick = 0;
    _editingEntryId       = null;
    _draftPrice           = '';
    _savingEntry          = false;
    _togglingEntry        = null;
    _deletingEntry        = null;
    _confirmDeleteEntryId = null;

    _setEntries(arr) {
        this._rawEntries = arr;
        this._enrichedEntries = null; // invalidate cache
        this._entryVersion = this._entryVersion + 1;
        this._computeDisplay();
    }

    // Heavy computation done ONCE per entry load, cached until entries change
    _enrichedEntries = null;
    _buildEnrichedEntries() {
        const raw = this._rawEntries;
        // ── Determine preferred currency for site pricebooks ──
        const SITE_CCY = {
            TYO:'JPY',OSA:'JPY',SEL:'KRW',PUS:'KRW',JKT:'IDR',CGK:'IDR',
            MNL:'PHP',PEK:'CNY',BOM:'INR',BKK:'THB',JHB:'MYR',SHA:'MYR'
        };
        let preferredCcy = 'USD';
        if (this.selectedPricebook?.linkedTo) {
            const sc = this.selectedPricebook.linkedTo;
            if (sc && !sc.includes(' ')) {
                const prefix = sc.replace(/\d+$/, '');
                if (SITE_CCY[prefix]) preferredCcy = SITE_CCY[prefix];
            }
        }
        // ── Deduplicate entries by product — prefer site local currency ──
        const mainByProduct = {};
        const extraByProduct = {};
        const deduped = [];
        for (const entry of raw) {
            const pk = entry.productCode || entry.id;
            if (entry.isStandardEntry) {
                if (!extraByProduct[pk]) extraByProduct[pk] = [];
                extraByProduct[pk].push(entry);
            } else if (!mainByProduct[pk]) {
                mainByProduct[pk] = entry;
                deduped.push(entry);
            } else if (entry.currencyIsoCode === preferredCcy && mainByProduct[pk].currencyIsoCode !== preferredCcy) {
                // Swap: prefer local currency as the main display entry
                if (!extraByProduct[pk]) extraByProduct[pk] = [];
                extraByProduct[pk].push(mainByProduct[pk]);
                const idx = deduped.indexOf(mainByProduct[pk]);
                if (idx !== -1) deduped[idx] = entry;
                mainByProduct[pk] = entry;
            } else {
                if (!extraByProduct[pk]) extraByProduct[pk] = [];
                extraByProduct[pk].push(entry);
            }
        }

        // ── Build tier data from consolidated Product_Pricing_Tier__mdt ──
        let siteCode = this.selectedPricebook?.linkedTo || '';
        // If linkedTo is an account name (has spaces), it's not a site code
        if (siteCode && siteCode.includes(' ')) siteCode = '';
        if (!siteCode && this.selectedPricebook?.name) {
            const m = this.selectedPricebook.name.match(/[A-Z]{3}\d/);
            if (m) siteCode = m[0];
        }
        const isSiteSpecific = this.selectedPricebook?.pricebookType === 'Site';
        const tiersByProduct = {};
        if (this._tiersLoaded) {
            for (const t of this._pricingTiers) {
                if (!t.productCode || !t.attributeValue) continue;
                if (siteCode && t.siteCode && t.siteCode !== siteCode) continue;
                const pk = t.productCode;
                if (!tiersByProduct[pk]) tiersByProduct[pk] = {};
                const av = t.attributeValue;
                if (!tiersByProduct[pk][av]) tiersByProduct[pk][av] = { devNames: {}, prices: {} };
                const existing = tiersByProduct[pk][av];
                const hasSiteVersion = existing.prices[t.currencyCode]?._hasSite;
                if (t.siteCode && t.siteCode === siteCode) {
                    existing.prices[t.currencyCode] = { price: t.price, devName: t.developerName, _hasSite: true };
                } else if (!hasSiteVersion) {
                    existing.prices[t.currencyCode] = existing.prices[t.currencyCode] || { price: t.price, devName: t.developerName, _hasSite: false };
                }
                if (t.odooComboId) existing.odooComboId = t.odooComboId;
            }
        }
        const sitesByProduct = {};
        if (this._tiersLoaded) {
            for (const t of this._pricingTiers) {
                if (!t.productCode || !t.siteCode) continue;
                if (!sitesByProduct[t.productCode]) sitesByProduct[t.productCode] = new Set();
                sitesByProduct[t.productCode].add(t.siteCode);
            }
        }

        // ── Enrich each deduped entry (expensive, done once) ──
        const ccyPropMap = { USD:'priceUSD', JPY:'priceJPY', SGD:'priceSGD', HKD:'priceHKD',
                             IDR:'priceIDR', KRW:'priceKRW', CNY:'priceCNY', PHP:'pricePHP' };
        const rawPropMap = { USD:'rawUSD', JPY:'rawJPY', SGD:'rawSGD', HKD:'rawHKD',
                             IDR:'rawIDR', KRW:'rawKRW', CNY:'rawCNY', PHP:'rawPHP' };
        const rawPropForCcy = rawPropMap;

        this._enrichedEntries = deduped.map(e => {
            const attrMap = tiersByProduct[e.productCode] || {};
            const attrKeys = Object.keys(attrMap);
            const productSites = sitesByProduct[e.productCode] ? [...sitesByProduct[e.productCode]].sort() : [];
            const allCurrencies = new Set();
            for (const av of attrKeys) {
                for (const ccy of Object.keys(attrMap[av].prices)) allCurrencies.add(ccy);
            }
            const ccyList = [...allCurrencies].sort();
            const isMultiCcy = ccyList.length > 1;
            const tiers = attrKeys
                .sort((a, b) => (parseFloat(a) || 0) - (parseFloat(b) || 0))
                .map(av => {
                    const data = attrMap[av];
                    const firstDevName = Object.values(data.prices)[0]?.devName || '';
                    const row = { key: 'tier_' + e.productCode + '_' + av, attrLabel: av, source: 'consolidated' };
                    for (const ccy of ccyList) {
                        const p = data.prices[ccy];
                        row[ccyPropMap[ccy] || ('price' + ccy)] = p ? fmtCurrency(p.price, ccy) : '—';
                        row[rawPropMap[ccy] || ('raw' + ccy)] = p ? p.price : 0;
                        row['dev_' + ccy] = p ? p.devName : '';
                    }
                    // Set price + formatted for single-currency display
                    const firstPrice = Object.values(data.prices)[0];
                    const firstCcy = Object.keys(data.prices)[0] || 'USD';
                    row.price = firstPrice?.price || 0;
                    row.priceCcy = firstCcy;
                    row.priceFormatted = firstPrice ? fmtCurrency(firstPrice.price, firstCcy) : '—';
                    row.developerName = firstDevName;
                    return row;
                })
                .filter(r => r.price > 0);
            const hasTiers = tiers.length > 0;
            // Single-currency header label
            const tierPriceCcyLabel = ccyList.length === 1 ? ccyList[0] : 'USD';

            // Currency sub-rows
            const pk = e.productCode || e.id;
            const extras = extraByProduct[pk] || [];
            const ccySubRows = extras
                .filter(x => x.currencyIsoCode !== e.currencyIsoCode)
                .map(x => ({
                    ...x,
                    key: 'ccy_' + x.id,
                    unitPriceFormatted: fmtCurrency(x.unitPrice, x.currencyIsoCode),
                    sourceLabel: x.isStandardEntry ? 'Standard' : 'Site',
                }));

            // Tier sub-rows - use first available currency price, not entry currency
            const tierSubRows = hasTiers ? tiers.map(t => {
                // Find the best price: entry currency > first available
                const mainCcy = e.currencyIsoCode || 'USD';
                const rp = rawPropForCcy[mainCcy] || 'rawUSD';
                let tp = t[rp];
                let displayCcy = mainCcy;
                if (tp == null || tp === 0) {
                    // Fallback: use first available currency with a price
                    for (const ccy of ccyList) {
                        const raw = t[rawPropMap[ccy] || ('raw' + ccy)];
                        if (raw != null && raw > 0) { tp = raw; displayCcy = ccy; break; }
                    }
                }
                if (tp == null) tp = 0;
                return {
                    key: 'tsub_' + t.key, attrLabel: t.attrLabel,
                    price: tp,
                    priceFormatted: fmtCurrency(tp, displayCcy),
                };
            }) : [];

            return {
                ...e,
                _searchName: (e.productName || '').toLowerCase(),
                _searchCode: (e.productCode || '').toLowerCase(),
                familyLabel: e.family || '—',
                chargeTypeLabel: e.chargeType || '—',
                chargeTypeBadge: e.chargeType ? ('dpm-charge-badge dpm-charge-' + e.chargeType.toLowerCase()) : '',
                hasChargeType: !!e.chargeType,
                hasKvaTiers: hasTiers || !!e.attributeValues,
                hasAttributeValues: !!e.attributeValues,
                productAttribute: e.productAttribute || '',
                kvaTiers: tiers,
                tierCurrencies: ccyList,
                isKvaTierMultiCcy: isMultiCcy && hasTiers,
                isPavTierSingleCcy: !isMultiCcy && hasTiers,
                tierPriceCcyLabel: tierPriceCcyLabel,
                tierSubRows: tierSubRows,
                hasTierSubRows: tierSubRows.length > 0,
                tierSites: productSites.map(s => ({ key: 'site_' + s, label: s, isActive: s === siteCode })),
                hasTierSites: isSiteSpecific && productSites.length > 0,
                currentSiteCode: siteCode,
                kvaTableKey: 'kvat_' + e.id,
                currencySubRows: ccySubRows,
                hasCurrencySubRows: ccySubRows.length > 0,
                statusDotClass: e.isActive ? 'dpm-dot dpm-dot-approved' : 'dpm-dot dpm-dot-draft',
                statusPillClass: e.isActive ? 'dpm-status-pill dpm-status-active' : 'dpm-status-pill dpm-status-inactive',
                activeLabel: e.isActive ? 'Active' : 'Inactive',
                toggleTitle: e.isActive ? 'Deactivate' : 'Activate',
                toggleIcon: e.isActive ? 'utility:toggle_panel_close' : 'utility:toggle_panel_open',
                priceTextClass: (e.unitPrice == null || e.unitPrice === 0) ? 'dpm-price-text dpm-price-zero' : 'dpm-price-text',
                availableCountries: e.availableCountries || '',
                countryGroup: this._countryGroupLabel(e.availableCountries),
                countryBadges: this._countryBadges(e.availableCountries),
                hasCountryBadges: !!(e.availableCountries) && (this.selectedPricebook?.isStandard || false),
            };
        });
    }

    _countryGroupLabel(countries) {
        return countries ? 'Country-Specific' : 'Global';
    }
    _countryBadges(countries) {
        if (!countries) return [];
        const LABELS = { JP:'Japan', KR:'Korea', ID:'Indonesia', PH:'Philippines', CN:'China', IN:'India', TH:'Thailand', MY:'Malaysia', SG:'Singapore', HK:'Hong Kong' };
        return countries.split(';').map(c => ({ key: c.trim(), label: LABELS[c.trim()] || c.trim() }));
    }

    _computeDisplay() {
        if (!this._enrichedEntries) this._buildEnrichedEntries();
        const enriched = this._enrichedEntries || [];
        const term = (this.entrySearch || '').toLowerCase().trim();
        let list = enriched;
        if (term) {
            const filtered = [];
            for (let i = 0; i < enriched.length; i++) {
                const e = enriched[i];
                if (e._searchName.indexOf(term) !== -1 || e._searchCode.indexOf(term) !== -1) {
                    filtered.push(e);
                }
            }
            list = filtered;
        }
        // For Standard PB: hide customer-specific (have sites but no countries), sort Global first
        if (this.selectedPricebook?.isStandard) {
            list = list.filter(e => !!e.availableCountries || !e.availableSites);
            list = [...list].sort((a, b) => {
                const aGlobal = !a.availableCountries;
                const bGlobal = !b.availableCountries;
                if (aGlobal && !bGlobal) return -1;
                if (bGlobal && !aGlobal) return 1;
                return (a.productName || '').localeCompare(b.productName || '');
            });
        }
        const editId = this._editingEntryId;
        const draft = this._draftPrice;
        const confirmDel = this._confirmDeleteEntryId;
        const editVarKey = this._editingVariantKey;
        const isStdPb = this.selectedPricebook?.isStandard || false;
        // Pre-compute group counts for Standard PB headers
        const groupCounts = {};
        if (isStdPb) {
            for (const e of list) {
                const g = e.countryGroup || 'Global';
                groupCounts[g] = (groupCounts[g] || 0) + 1;
            }
        }
        let lastGroup = null;
        const expandedGroups = this._expandedGroups || new Set();
        const result = list.map((e, idx) => {
            const group = isStdPb ? (e.countryGroup || 'Global') : null;
            const showHeader = isStdPb && group !== lastGroup;
            const groupOpen = !isStdPb || expandedGroups.has(group);
            lastGroup = group;
            return {
            ...e,
            showGroupHeader: showHeader,
            groupHeaderLabel: group,
            groupHeaderDisplay: group ? (group + ' (' + (groupCounts[group] || 0) + ')') : group,
            groupOpen: groupOpen,
            rowNum: idx + 1,
            kvaOpen: this._kvaExpandedEntries.has(e.id),
            kvaExpandCls: 'dpm-expand-chevron' + (this._kvaExpandedEntries.has(e.id) ? ' dpm-expand-chevron-open' : ''),
            showCcyToggle: e.hasCurrencySubRows && !e.hasKvaTiers,
            isCcyExpanded: this._kvaExpandedEntries.has(e.id + '_ccy'),
            isEditing: e.id === editId,
            draftPrice: e.id === editId ? draft : (e.unitPrice != null ? String(e.unitPrice) : '0'),
            isSaving: e.id === editId && this._savingEntry,
            isToggling: e.id === this._togglingEntry,
            isDeleting: e.id === this._deletingEntry,
            confirmDelete: e.id === confirmDel,
            isSelected: this.selectedEntryIds.has(e.id),
            currencySubRows: (e.currencySubRows || []).map(ccy => ({
                ...ccy,
                isEditing: ccy.id === editId,
                draftPrice: ccy.id === editId ? draft : (ccy.unitPrice != null ? String(ccy.unitPrice) : '0'),
            })),
            kvaTiers: (e.kvaTiers || []).map(t => ({
                ...t,
                isEditing: t.key === editVarKey,
            })),
        };});
        // Use Promise.resolve reset only when search/filter changed (forces DOM rebuild).
        // For expand/collapse/edit actions, assign directly to preserve scroll.
        const searchChanged = this._lastSearchTerm !== (this.entrySearch || '');
        this._lastSearchTerm = this.entrySearch || '';
        if (searchChanged) {
            this._displayList = [];
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            Promise.resolve().then(() => { this._displayList = result; });
        } else {
            this._displayList = result;
        }
    }

    // Mass update state
    @track selectedEntryIds  = new Set();
    @track massUpdatePrice   = '';
    _massUpdating = false;

    // ─── Add Products to existing Pricebook ──────────────────────────────────
    @track showAddProductsPanel = false;
    @track addProdSearch        = '';
    @track addProdResults       = [];
    @track addProdSelections    = [];
    _addingProducts = false;
    _newProductFromAddPanel = false;

    get showAddProdDrop()       { return this.addProdSearch.length >= 2 && (this.addProdResults.length > 0 || this.showAddProdCreateNew); }
    get showAddProdCreateNew()  { return this.addProdSearch.length >= 2 && this.addProdResults.length === 0; }
    get hasAddProdSelections()  { return this.addProdSelections.length > 0; }
    get isAddingProducts()      { return this._addingProducts; }
    get addProductsButtonLabel() {
        if (this._addingProducts) return 'Adding...';
        const n = this.addProdSelections.length;
        return 'Add ' + n + ' Product' + (n !== 1 ? 's' : '');
    }
    @track _addProdCurrencyOverride = null;
    get addProdCurrency() { return this._addProdCurrencyOverride || this.selectedPricebook?.currencyIsoCode || 'USD'; }
    get currencyOptions() {
        return [
            { label: 'USD', value: 'USD' }, { label: 'PHP', value: 'PHP' },
            { label: 'JPY', value: 'JPY' }, { label: 'KRW', value: 'KRW' },
            { label: 'IDR', value: 'IDR' }, { label: 'CNY', value: 'CNY' },
            { label: 'SGD', value: 'SGD' }, { label: 'MYR', value: 'MYR' },
            { label: 'THB', value: 'THB' }, { label: 'HKD', value: 'HKD' },
            { label: 'INR', value: 'INR' },
        ];
    }
    handleAddProdCurrencyChange(e) { this._addProdCurrencyOverride = e.detail.value; }

    // ─── Column visibility (Pricebooks tab) ───────────────────────────────────
    // Default: show only Product + Price + Status. Users add more via Columns button.
    @track visibleColumns = new Set(['code', 'chargeType', 'status']);
    @track showColumnMenu = false;

    get showColCode()       { return this.visibleColumns.has('code'); }
    get showColFamily()     { return this.visibleColumns.has('family'); }
    get showColChargeType() { return this.visibleColumns.has('chargeType'); }
    get showColCurrency()   { return this.visibleColumns.has('currency'); }
    get showColStatus()     { return this.visibleColumns.has('status'); }
    get columnMenuOptions() {
        // Include visibility state in key so LWC recreates the checkbox element
        // when toggled — native <input checked={val}> doesn't update the DOM
        // property reliably on reactive state changes.
        const ck = (v) => v ? 'dpm-toggle-tick dpm-toggle-tick-on' : 'dpm-toggle-tick';
        return [
            { key: 'code',       label: 'Code',        visible: this.visibleColumns.has('code'),       tickCls: ck(this.visibleColumns.has('code')),       fieldKey: 'code_'       + (this.visibleColumns.has('code')       ? '1' : '0') },
            { key: 'chargeType', label: 'Charge Type',  visible: this.visibleColumns.has('chargeType'), tickCls: ck(this.visibleColumns.has('chargeType')), fieldKey: 'chargeType_' + (this.visibleColumns.has('chargeType') ? '1' : '0') },
            { key: 'family',     label: 'Family',       visible: this.visibleColumns.has('family'),     tickCls: ck(this.visibleColumns.has('family')),     fieldKey: 'family_'     + (this.visibleColumns.has('family')     ? '1' : '0') },
            { key: 'currency',   label: 'Currency',     visible: this.visibleColumns.has('currency'),   tickCls: ck(this.visibleColumns.has('currency')),   fieldKey: 'currency_'   + (this.visibleColumns.has('currency')   ? '1' : '0') },
            { key: 'status',     label: 'Status',       visible: this.visibleColumns.has('status'),     tickCls: ck(this.visibleColumns.has('status')),     fieldKey: 'status_'     + (this.visibleColumns.has('status')     ? '1' : '0') },
        ];
    }
    handleToggleColumnMenu(event) {
        event.stopPropagation();
        this.showColumnMenu = !this.showColumnMenu;
        if (this.showColumnMenu) this._addClickOutsideListener();
    }
    handleToggleColumn(event) {
        const key  = event.currentTarget.dataset.key;
        const next = new Set(this.visibleColumns);
        if (next.has(key)) { next.delete(key); } else { next.add(key); }
        this.visibleColumns = next;
    }

    // ─── Column visibility (Products tab) ─────────────────────────────────────
    @track visibleProductColumns = new Set(['code', 'chargeType', 'status', 'pricebooks']);
    @track showProductColumnMenu = false;

    get showProdColCode()       { return this.visibleProductColumns.has('code'); }
    get showProdColChargeType() { return this.visibleProductColumns.has('chargeType'); }
    get showProdColStatus()     { return this.visibleProductColumns.has('status'); }
    get showProdColPricebooks() { return this.visibleProductColumns.has('pricebooks'); }
    get columnMenuProductOptions() {
        return [
            { key: 'code',       label: 'Code',        visible: this.visibleProductColumns.has('code'),       fieldKey: 'pc_code_'       + (this.visibleProductColumns.has('code')       ? '1' : '0') },
            { key: 'chargeType', label: 'Charge Type',  visible: this.visibleProductColumns.has('chargeType'), fieldKey: 'pc_chargeType_' + (this.visibleProductColumns.has('chargeType') ? '1' : '0') },
            { key: 'status',     label: 'Status',       visible: this.visibleProductColumns.has('status'),     fieldKey: 'pc_status_'     + (this.visibleProductColumns.has('status')     ? '1' : '0') },
            { key: 'pricebooks', label: 'Pricebooks',   visible: this.visibleProductColumns.has('pricebooks'), fieldKey: 'pc_pricebooks_' + (this.visibleProductColumns.has('pricebooks') ? '1' : '0') },
        ];
    }
    handleToggleProductColumnMenu(event) {
        event.stopPropagation();
        this.showProductColumnMenu = !this.showProductColumnMenu;
        if (this.showProductColumnMenu) this._addClickOutsideListener();
    }
    handleToggleProductColumn(event) {
        const key  = event.currentTarget.dataset.key;
        const next = new Set(this.visibleProductColumns);
        if (next.has(key)) { next.delete(key); } else { next.add(key); }
        this.visibleProductColumns = next;
    }

    // ─── JS hover detection (guarantees opacity hides shadow-DOM icons) ───────
    handleEntryRowEnter(event) { event.currentTarget.classList.add('dpm-row-hovered'); }
    handleEntryRowLeave(event) { event.currentTarget.classList.remove('dpm-row-hovered'); }
    handleProdRowEnter(event)  { event.currentTarget.classList.add('dpm-row-hovered'); }
    handleProdRowLeave(event)  { event.currentTarget.classList.remove('dpm-row-hovered'); }
    handleReqRowEnter(event)   { event.currentTarget.classList.add('dpm-row-hovered'); }
    handleReqRowLeave(event)   { event.currentTarget.classList.remove('dpm-row-hovered'); }

    // getPricebooks is loaded imperatively (not via @wire) because @AuraEnabled(cacheable=true)
    // enforces user mode in API 58+ which restricts catalog pricebook visibility.
    _loadPricebooks() {
        this.pricebooksLoading = true;
        return getPricebooks()
            .then(data => {
                this._pricebooks       = data || [];
                this.pricebooksLoading = false;
                // Refresh selectedPricebook if one is active
                if (this.selectedPricebook) {
                    const id = this.selectedPricebook.id;
                    this.selectedPricebook = this._pricebooks.find(p => p.id === id) || null;
                }
            })
            .catch(err => { this.pricebooksLoading = false; this._pricebookError = err.body?.message ?? 'Could not load pricebooks.'; });
    }

    get pricebookGroups() {
        const groups = { Standard: [], Site: [], Account: [], Reseller: [] };
        this._pricebooks.forEach(pb => {
            const type = pb.pricebookType || 'Account';
            if (!groups[type]) groups[type] = [];
            groups[type].push({
                ...pb,
                rowClass: 'dpm-pb-row' + (this.selectedPricebook?.id === pb.id ? ' dpm-pb-row_active' : ''),
                statusDotClass: pb.isActive ? 'dpm-dot dpm-dot-approved' : 'dpm-dot dpm-dot-draft',
                cardClass: 'dpm-pbcard' + (this.selectedPricebook?.id === pb.id ? ' dpm-pbcard-active' : ''),
            });
        });
        return ['Standard', 'Site', 'Account', 'Reseller']
            .filter(t => groups[t] && groups[t].length > 0)
            .map(t => ({
                key:        t,
                label:      PB_TYPE_LABEL[t] || t,
                books:      groups[t],
                count:      groups[t].length,
                isOpen:     this.openPricebookGroups.has(t),
                groupClass: 'dpm-pb-group' + (this.openPricebookGroups.has(t) ? ' dpm-pb-group_open' : ''),
            }));
    }

    get pricebookCount() { return this._pricebooks.length; }

    // ── Pricing view states (3-layer progressive disclosure) ─────────────────
    // Layer 1: type overview cards (Standard, Site, Account, Reseller)
    // Layer 2: type selected → show only that type's pricebook cards + back
    // Layer 3: pricebook selected → entries table inline below cards
    get hasPricebookTypeSelected() { return !!this.selectedPricebookType; }
    get showPricingDrillIn()       { return !!this.selectedPricebook; }

    get pricingTypeCards() {
        const types = {};
        this._pricebooks.forEach(pb => {
            const t = pb.pricebookType || 'Account';
            if (!types[t]) types[t] = { count: 0, active: 0 };
            types[t].count++;
            if (pb.isActive) types[t].active++;
        });
        return ['Standard', 'Site', 'Account', 'Reseller']
            .filter(t => types[t])
            .map(t => ({
                value:          t,
                label:          PB_TYPE_LABEL[t] || t,
                count:          types[t].count,
                activeCount:    types[t].active,
                cardClass:      'dpm-catalog-card' + (this.selectedPricebookType === t ? ' dpm-catalog-card-sel' : ''),
                typeStripClass: 'dpm-type-chip' + (this.selectedPricebookType === t ? ' dpm-type-chip-sel' : ''),
            }));
    }

    get selectedPricebookTypeLabel() { return PB_TYPE_LABEL[this.selectedPricebookType] || this.selectedPricebookType || ''; }
    get isSiteSpecificType() { return this.selectedPricebookType === 'Site'; }

    get selectedTypePricebooks() {
        if (!this.selectedPricebookType) return [];
        let list = this._pricebooks
            .filter(pb => (pb.pricebookType || 'Account') === this.selectedPricebookType);
        if (this.pricebookFilter) {
            const t = this.pricebookFilter.toLowerCase();
            list = list.filter(pb => pb.name.toLowerCase().includes(t) || (pb.linkedTo || '').toLowerCase().includes(t));
        }
        return list.map(pb => ({
                ...pb,
                statusDotClass: pb.isActive ? 'dpm-dot dpm-dot-approved' : 'dpm-dot dpm-dot-draft',
                cardClass: 'dpm-pbcard' + (this.selectedPricebook?.id === pb.id ? ' dpm-pbcard-active' : ''),
            }));
    }
    get selectedTypePricebookCount() { return this.selectedTypePricebooks.length; }
    get selectedTypeTotalCount() {
        if (!this.selectedPricebookType) return 0;
        return this._pricebooks.filter(pb => (pb.pricebookType || 'Account') === this.selectedPricebookType).length;
    }
    get showTypePricebookGrid() { return !!this.selectedPricebookType && !this.selectedPricebook; }

    handlePricebookTypeSelect(event) {
        const val = event.currentTarget.dataset.value;
        if (this.selectedPricebookType === val) {
            // Toggle off — collapse pricebook cards
            this.selectedPricebookType = null;
            this.selectedPricebook     = null;
            this.pricebookFilter       = '';
            this.entrySearch           = '';
        } else {
            this.selectedPricebookType = val;
            this.selectedPricebook     = null;
            this.pricebookFilter       = '';
            this.entrySearch           = '';
        }
        this._computeDisplay();
    }
    handlePricebookTypeBack() {
        this.selectedPricebookType  = null;
        this.selectedPricebook      = null;
        this.pricebookFilter        = '';
        this.entrySearch            = '';
        this._editingEntryId        = null;
        this._confirmDeleteEntryId  = null;
        this.selectedEntryIds       = new Set();
        this.massUpdatePrice        = '';
        this.showAddProductsPanel   = false;
        this.addProdSelections      = [];
        this._computeDisplay();
    }

    handlePricebookFilter(event) { this.pricebookFilter = event.target.value; }

    handlePricingBack() {
        this.selectedPricebook      = null;
        this.pricebookFilter        = '';
        this.entrySearch            = '';
        this._editingEntryId        = null;
        this._confirmDeleteEntryId  = null;
        this.selectedEntryIds       = new Set();
        this.massUpdatePrice        = '';
        this.showAddProductsPanel   = false;
        this.addProdSelections      = [];
        this._computeDisplay();
    }

    get displayList() { return this._displayList; }
    get hasFilteredEntries() { return this._displayList.length > 0; }
    get filteredEntryCount() { return this._displayList.length; }
    get hasMassSelection()   { return this.selectedEntryIds.size > 0; }
    get selectedEntryCount() { return this.selectedEntryIds.size; }
    get allEntriesSelected() {
        const list = this._displayList;
        return list.length > 0 && list.every(e => this.selectedEntryIds.has(e.id));
    }
    get massUpdateButtonLabel() {
        const n = this.selectedEntryIds.size;
        return 'Update ' + n + (n !== 1 ? ' Entries' : ' Entry');
    }

    handlePricebookGroupToggle(event) {
        const type = event.currentTarget.dataset.type;
        const next = new Set(this.openPricebookGroups);
        if (next.has(type)) next.delete(type); else next.add(type);
        this.openPricebookGroups = next;
    }

    handlePricebookSelect(event) {
        const id = event.currentTarget.dataset.id;
        if (this.selectedPricebook?.id === id) {
            this.handlePricingBack();
            return;
        }
        this.selectedPricebook      = this._pricebooks.find(p => p.id === id) || null;
        this.entrySearch            = '';
        this._editingEntryId        = null;
        this._confirmDeleteEntryId  = null;
        this.selectedEntryIds       = new Set();
        this.massUpdatePrice        = '';
        this._computeDisplay();
        if (this.selectedPricebook) this._loadEntries(id);
    }
    @track _variantLines = [];

    _loadEntries(pricebookId) {
        this.entriesLoading = true;
        this._setEntries([]);
        this._variantLines  = [];
        const promises = [
            getPricebookEntries({ pricebookId }).then(data => {
                this._setEntries(data.map(e => ({
                    ...e,
                    unitPriceFormatted: fmtCurrency(e.unitPrice, e.currencyIsoCode),
                })));
            }),
        ];
        // Load variant pricing for Account pricebooks
        if (this.selectedPricebook?.pricebookType === 'Account') {
            promises.push(
                getVariantPricing({ pricebookId }).then(data => {
                    this._variantLines = (data || []).map(ln => ({
                        ...ln,
                        displayName: ln.productName + (ln.attributeValue ? ' [' + ln.attributeValue + ']' : ''),
                        unitPriceFormatted: fmtCurrency(ln.unitPrice, this.selectedPricebook?.currencyIsoCode || 'USD'),
                    }));
                }).catch(() => { this._variantLines = []; })
            );
        }
        Promise.all(promises)
            .catch(err => this._toast('Error loading entries', err?.body?.message || 'Could not load entries.', 'error'))
            .finally(() => { this.entriesLoading = false; this._computeDisplay(); });
    }

    get hasVariantLines() { return this._variantLines.length > 0; }

    // Attribute tier inline expand + edit on PBE rows
    @track _kvaExpandedEntries  = new Set();
    @track _editingVariantKey   = null;
    @track _draftVariantPrice   = '';
    @track _savingVariant       = false;

    handleEntryKvaToggle(event) {
        event.stopPropagation();
        const id = event.currentTarget.dataset.id;
        if (!id) return;
        const entry = this._displayList.find(e => e.id === id);
        if (!entry || !entry.hasKvaTiers) return;
        const next = new Set(this._kvaExpandedEntries);
        if (next.has(id)) next.delete(id); else next.add(id);
        this._kvaExpandedEntries = next;
        this._computeDisplay();
    }

    handleToggleCcyRows(event) {
        event.stopPropagation();
        const id = event.currentTarget.dataset.id;
        if (!id) return;
        const ccyKey = id + '_ccy';
        const next = new Set(this._kvaExpandedEntries);
        if (next.has(ccyKey)) next.delete(ccyKey); else next.add(ccyKey);
        this._kvaExpandedEntries = next;
        this._computeDisplay();
    }

    @track _draftKvaPrices = {};

    handleVariantEdit(event) {
        event.stopPropagation();
        const key   = event.currentTarget.dataset.key;
        const price = event.currentTarget.dataset.price;
        // Find the tier to pre-fill draft values
        let tier = null;
        for (const entry of this._displayList) {
            tier = (entry.kvaTiers || []).find(t => t.key === key);
            if (tier) break;
        }
        this._editingVariantKey = key;
        if (tier && tier.source === 'kva') {
            this._draftKvaPrices = {
                USD: String(tier.rawUSD || 0), JPY: String(tier.rawJPY || 0),
                SGD: String(tier.rawSGD || 0), HKD: String(tier.rawHKD || 0),
                IDR: String(tier.rawIDR || 0), KRW: String(tier.rawKRW || 0),
                CNY: String(tier.rawCNY || 0), PHP: String(tier.rawPHP || 0),
            };
        } else {
            this._draftVariantPrice = price != null ? String(price) : '0';
        }
        this._computeDisplay();
    }
    handleVariantDraftChange(event) {
        this._draftVariantPrice = event.target.value;
    }
    handleKvaDraftChange(event) {
        const ccy = event.currentTarget.dataset.ccy;
        this._draftKvaPrices = { ...this._draftKvaPrices, [ccy]: event.target.value };
    }
    handleVariantKeydown(event) {
        if (event.key === 'Enter')  { event.stopPropagation(); this.handleVariantSave(event); }
        else if (event.key === 'Escape') { event.stopPropagation(); this.handleVariantCancel(); }
    }
    handleVariantCancel() {
        this._editingVariantKey = null;
        this._draftVariantPrice = '';
        this._draftKvaPrices = {};
        this._computeDisplay();
    }
    handleVariantSave(event) {
        event.stopPropagation();
        const key = this._editingVariantKey;
        if (!key) return;
        let tier = null;
        for (const entry of this._displayList) {
            tier = (entry.kvaTiers || []).find(t => t.key === key);
            if (tier) break;
        }
        if (!tier) return;

        this._savingVariant = true;
        const promises = [];
        const draft = this._draftKvaPrices;
        const singleDraft = this._draftVariantPrice;

        if (Object.keys(draft).length > 0) {
            // Multi-currency: save each changed currency
            const CCYS = ['USD', 'JPY', 'SGD', 'HKD', 'IDR', 'KRW', 'CNY', 'PHP', 'INR', 'THB', 'MYR'];
            for (const ccy of CCYS) {
                const newVal = parseFloat(draft[ccy]);
                const oldVal = tier['raw' + ccy] || 0;
                const devName = tier['dev_' + ccy];
                if (!isNaN(newVal) && newVal !== oldVal && devName) {
                    promises.push(updatePricingTier({ developerName: devName, newPrice: newVal }));
                }
            }
        } else if (singleDraft !== '' && tier.developerName) {
            // Single-currency: save the one price
            const newVal = parseFloat(singleDraft);
            if (!isNaN(newVal) && newVal !== tier.price) {
                promises.push(updatePricingTier({ developerName: tier.developerName, newPrice: newVal }));
            }
        }
        if (promises.length === 0) {
            this._editingVariantKey = null; this._draftKvaPrices = {}; this._draftVariantPrice = '';
            this._savingVariant = false;
            this._computeDisplay();
            return;
        }
        Promise.all(promises)
            .then(() => {
                // Optimistic UI: update pricing tiers in memory
                const updatedTiers = this._pricingTiers.map(t => {
                    for (const ccy of CCYS) {
                        if (t.developerName === tier['dev_' + ccy]) {
                            const newVal = parseFloat(draft[ccy]);
                            if (!isNaN(newVal)) return { ...t, price: newVal };
                        }
                    }
                    return t;
                });
                this._pricingTiers = updatedTiers;
                this._editingVariantKey = null; this._draftKvaPrices = {};
                this._computeDisplay();
                this._toast('Queued', `${promises.length} price update(s) deploying.`, 'success');
            })
            .catch(err => this._toast('Error', err?.body?.message || 'Failed.', 'error'))
            .finally(() => { this._savingVariant = false; });
    }

    // ─── Delete Pricing Tier (soft delete - set price to 0) ──────────────────
    handleDeleteTier(event) {
        event.stopPropagation();
        const devName = event.currentTarget.dataset.devname;
        if (!devName) return;
        deletePricingTier({ developerName: devName })
            .then(() => {
                this._toast('Tier Removed', 'Price set to 0. Refresh to see changes.', 'success');
                this._scheduleRefreshTiers();
            })
            .catch(err => this._toast('Error', err?.body?.message || 'Failed to remove tier.', 'error'));
    }

    _scheduleRefreshTiers() {
        // Retry loading tiers after CMT deployment (typically 5-15s)
        const tryRefresh = (attempt) => {
            if (attempt > 3) return;
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => {
                this._tiersLoaded = false;
                this._loadPricingTiers();
                // eslint-disable-next-line @lwc/lwc/no-async-operation
                setTimeout(() => {
                    this._enrichedEntries = null;
                    this._computeDisplay();
                }, 1500);
            }, attempt === 1 ? 8000 : 5000);
        };
        tryRefresh(1);
        tryRefresh(2);
    }

    // ─── Create Pricing Tier ──────────────────────────────────────────────────
    @track _showCreateTier = false;
    @track _createTierData = { productCode: '', attributeValue: '', siteCode: '', currencyCode: 'USD', price: '', odooComboId: '' };

    handleOpenCreateTier(event) {
        event.stopPropagation();
        const productCode = event.currentTarget.dataset.code;
        // Derive site code from pricebook - use linkedTo for site-specific, or parse from name
        let site = this.selectedPricebook?.linkedTo || '';
        if (!site && this.selectedPricebook?.name) {
            const m = this.selectedPricebook.name.match(/[A-Z]{3}\d/);
            if (m) site = m[0];
        }
        // If linkedTo looks like an account name (contains spaces), clear it
        if (site && site.includes(' ')) site = '';
        this._createTierData = { productCode, attributeValue: '', siteCode: site, currencyCode: 'USD', price: '', odooComboId: '' };
        this._showCreateTier = true;
    }
    handleCreateTierFieldChange(event) {
        const field = event.currentTarget.dataset.field;
        const val = event.detail ? event.detail.value : event.target.value;
        this._createTierData = { ...this._createTierData, [field]: val };
    }

    get createTierAttributeOptions() {
        const entry = this._rawEntries.find(e => e.productCode === this._createTierData.productCode);
        const vals = (entry?.attributeValues || '').split(',').map(v => v.trim()).filter(Boolean);
        return [{ label: '-- Select --', value: '' }, ...vals.map(v => ({ label: v, value: v }))];
    }

    get createTierNoAttributes() {
        return this.createTierAttributeOptions.length <= 1; // only "-- Select --"
    }

    get createTierSiteOptions() {
        return [
            { label: '-- Global (no site) --', value: '' },
            { label: 'JKT1', value: 'JKT1' }, { label: 'JKT2', value: 'JKT2' },
            { label: 'MNL1', value: 'MNL1' },
            { label: 'OSA1', value: 'OSA1' }, { label: 'OSA2', value: 'OSA2' },
            { label: 'PEK1', value: 'PEK1' }, { label: 'PUS1', value: 'PUS1' },
            { label: 'SEL1', value: 'SEL1' }, { label: 'SEL2', value: 'SEL2' },
            { label: 'TYO1', value: 'TYO1' }, { label: 'TYO2', value: 'TYO2' },
            { label: 'TYO3', value: 'TYO3' }, { label: 'TYO4', value: 'TYO4' },
            { label: 'TYO5', value: 'TYO5' }, { label: 'TYO6', value: 'TYO6' },
            { label: 'TYO7', value: 'TYO7' },
        ];
    }

    get createTierCurrencyOptions() {
        return [
            { label: 'USD', value: 'USD' }, { label: 'JPY', value: 'JPY' },
            { label: 'SGD', value: 'SGD' }, { label: 'HKD', value: 'HKD' },
            { label: 'IDR', value: 'IDR' }, { label: 'KRW', value: 'KRW' },
            { label: 'CNY', value: 'CNY' }, { label: 'PHP', value: 'PHP' },
            { label: 'INR', value: 'INR' }, { label: 'THB', value: 'THB' },
            { label: 'MYR', value: 'MYR' },
        ];
    }
    handleCancelCreateTier() { this._showCreateTier = false; }
    handleConfirmCreateTier() {
        const d = this._createTierData;
        if (!d.attributeValue || !d.currencyCode) { this._toast('Missing', 'Attribute Value and Currency are required.', 'error'); return; }
        const price = parseFloat(d.price);
        if (isNaN(price) || price < 0) { this._toast('Invalid', 'Enter a valid price.', 'error'); return; }
        createPricingTier({
            productCode: d.productCode, attributeValue: d.attributeValue,
            siteCode: d.siteCode || null, currencyCode: d.currencyCode,
            price, odooComboId: d.odooComboId ? parseFloat(d.odooComboId) : null,
        })
            .then(() => {
                this._showCreateTier = false;
                this._toast('Queued', 'Pricing tier deploying. Will auto-refresh shortly.', 'success');
                this._scheduleRefreshTiers();
            })
            .catch(err => this._toast('Error', err?.body?.message || 'Failed to create tier.', 'error'));
    }

    // ─── Add Currency Entry ──────────────────────────────────────────────────
    @track _showAddCurrency = false;
    @track _addCurrencyData = { productId: '', currencyCode: '', price: '0' };

    handleOpenAddCurrency(event) {
        event.stopPropagation();
        const id = event.currentTarget.dataset.id;
        this._addCurrencyData = { productId: id, currencyCode: '', price: '0' };
        this._showAddCurrency = true;
    }
    handleAddCurrencyFieldChange(event) {
        const field = event.currentTarget.dataset.field;
        const val = event.detail ? event.detail.value : event.target.value;
        this._addCurrencyData = { ...this._addCurrencyData, [field]: val };
    }
    handleCancelAddCurrency() { this._showAddCurrency = false; }
    handleConfirmAddCurrency() {
        const d = this._addCurrencyData;
        if (!d.currencyCode) { this._toast('Missing', 'Select a currency.', 'error'); return; }
        const price = parseFloat(d.price) || 0;
        addCurrencyEntry({
            pricebookId: this.selectedPricebook.id,
            productId: d.productId,
            currencyCode: d.currencyCode,
            unitPrice: price,
        })
        .then(() => {
            this._showAddCurrency = false;
            this._toast('Currency Added', d.currencyCode + ' entry created.', 'success');
            this._loadEntries(this.selectedPricebook.id);
        })
        .catch(err => this._toast('Error', err?.body?.message || 'Failed to add currency entry.', 'error'));
    }

    get addCurrencyOptions() {
        return [
            { label: '-- Select Currency --', value: '' },
            { label: 'USD', value: 'USD' }, { label: 'JPY', value: 'JPY' },
            { label: 'SGD', value: 'SGD' }, { label: 'HKD', value: 'HKD' },
            { label: 'IDR', value: 'IDR' }, { label: 'KRW', value: 'KRW' },
            { label: 'CNY', value: 'CNY' }, { label: 'PHP', value: 'PHP' },
            { label: 'INR', value: 'INR' }, { label: 'THB', value: 'THB' },
            { label: 'MYR', value: 'MYR' },
        ];
    }

    // ─── Import Pricing Tiers ─────────────────────────────────────────────────
    @track _showImportModal = false;
    @track _importStep = 'upload';
    @track _importPreview = [];
    @track _importErrors = [];

    handleOpenImport() { this._showImportModal = true; this._importStep = 'upload'; this._importPreview = []; this._importErrors = []; }
    handleCloseImport() { this._showImportModal = false; }

    handleDownloadTierTemplate() {
        this._downloadCsv('pricing_tier_template.csv', [
            { productCode: 'CAB001.RC', attributeValue: '2kVA', siteCode: 'TYO7', currencyCode: 'USD', price: '1270', odooComboId: '44' },
            { productCode: 'CAB001.RC', attributeValue: '2kVA', siteCode: 'TYO7', currencyCode: 'JPY', price: '195700', odooComboId: '44' },
        ], [
            { label: 'Product Code', key: 'productCode' },
            { label: 'Attribute Value', key: 'attributeValue' },
            { label: 'Site Code', key: 'siteCode' },
            { label: 'Currency Code', key: 'currencyCode' },
            { label: 'Price', key: 'price' },
            { label: 'Odoo Combo ID', key: 'odooComboId' },
        ]);
    }

    handleImportFileChange(event) {
        const file = event.target.files[0];
        if (!file) return;
        const reader = new FileReader();
        reader.onload = (e) => {
            const text = e.target.result;
            const lines = text.split('\n').filter(l => l.trim());
            if (lines.length < 2) { this._toast('Empty', 'CSV has no data rows.', 'error'); return; }
            const headers = lines[0].split(',').map(h => h.trim().replace(/"/g, ''));
            const rows = [];
            const errors = [];
            for (let i = 1; i < lines.length; i++) {
                const vals = lines[i].split(',').map(v => v.trim().replace(/"/g, ''));
                const row = {};
                headers.forEach((h, j) => { row[h] = vals[j] || ''; });
                // Map header labels to API keys
                const mapped = {
                    productCode: row['Product Code'] || row['productCode'] || '',
                    attributeValue: row['Attribute Value'] || row['attributeValue'] || '',
                    siteCode: row['Site Code'] || row['siteCode'] || '',
                    currencyCode: row['Currency Code'] || row['currencyCode'] || '',
                    price: row['Price'] || row['price'] || '0',
                    odooComboId: row['Odoo Combo ID'] || row['odooComboId'] || '',
                };
                if (!mapped.attributeValue) errors.push(`Row ${i}: Missing Attribute Value`);
                if (!mapped.currencyCode) errors.push(`Row ${i}: Missing Currency Code`);
                mapped.rowNum = i;
                mapped.key = 'imp_' + i;
                rows.push(mapped);
            }
            this._importPreview = rows;
            this._importErrors = errors;
            this._importStep = 'preview';
        };
        reader.readAsText(file);
    }

    handleImportConfirm() {
        if (this._importErrors.length > 0) { this._toast('Errors', 'Fix validation errors before importing.', 'error'); return; }
        if (this._importPreview.length > 200) { this._toast('Limit', 'Maximum 200 records per import.', 'error'); return; }
        const rowsJson = JSON.stringify(this._importPreview.map(r => ({
            productCode: r.productCode, attributeValue: r.attributeValue,
            siteCode: r.siteCode, currencyCode: r.currencyCode,
            price: parseFloat(r.price) || 0, odooComboId: r.odooComboId ? parseFloat(r.odooComboId) : null,
        })));
        importPricingTiers({ rowsJson })
            .then(() => {
                this._showImportModal = false;
                this._toast('Queued', `${this._importPreview.length} pricing tier(s) deploying. Refresh in a few seconds.`, 'success');
            })
            .catch(err => this._toast('Error', err?.body?.message || 'Import failed.', 'error'));
    }

    get _importStepIsUpload() { return this._importStep === 'upload'; }
    get _importStepIsPreview() { return this._importStep === 'preview'; }
    get _importHasErrors() { return this._importErrors.length > 0; }
    handleEntrySearch(event) {
        this.entrySearch = event.target.value || '';
        this._computeDisplay();
    }
    handleToggleGroup(event) {
        const group = event.currentTarget.dataset.group;
        const next = new Set(this._expandedGroups);
        if (next.has(group)) next.delete(group); else next.add(group);
        this._expandedGroups = next;
        this._computeDisplay();
    }
    handleClearEntrySearch() {
        this.entrySearch = '';
        const inp = this.refs.entrySearchInput;
        if (inp) inp.value = '';
        this._computeDisplay();
    }
    handlePriceKeydown(event) {
        if (event.key === 'Enter')  { event.stopPropagation(); this.handleSaveEntryPrice(event); }
        else if (event.key === 'Escape') { event.stopPropagation(); this.handleCancelEntryEdit(); }
    }
    handleOpenPricebook(event) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: event.currentTarget.dataset.id, actionName: 'view' },
        });
    }

    // ─── Account/Site linking on pricebook ───────────────────────────────────
    @track _showLinkSearch = false;
    @track _linkSearchTerm = '';
    @track _linkSearchResults = [];

    get selectedPricebookCanLink() {
        if (!this.selectedPricebook) return false;
        if (this.selectedPricebook.isStandard) return false;
        return true;
    }

    get linkSearchPlaceholder() {
        const t = this.selectedPricebook?.pricebookType;
        return t === 'Site' ? 'Search sites...' : 'Search accounts...';
    }

    get linkButtonLabel() {
        if (this.selectedPricebook?.linkedTo) return 'Change Association';
        const t = this.selectedPricebook?.pricebookType;
        return t === 'Site' ? 'Link Site' : 'Link Account';
    }

    get hasLinkSearchResults() { return this._linkSearchResults.length > 0; }
    get linkSearchResults() { return this._linkSearchResults; }

    handleShowLinkSearch() { this._showLinkSearch = true; this._linkSearchTerm = ''; this._linkSearchResults = []; }
    handleLinkCancel() { this._showLinkSearch = false; this._linkSearchTerm = ''; this._linkSearchResults = []; }

    handleLinkSearchInput(event) {
        this._linkSearchTerm = event.target.value || event.detail?.value || '';
        if (this._linkSearchTerm.length < 2) { this._linkSearchResults = []; return; }
        const t = this.selectedPricebook?.pricebookType;
        if (t === 'Site') {
            // Filter from cached sites
            const term = this._linkSearchTerm.toLowerCase();
            this._linkSearchResults = (this._sites || [])
                .filter(s => s.name.toLowerCase().includes(term))
                .slice(0, 8);
        } else {
            // Search accounts via controller
            searchAccounts({ searchTerm: this._linkSearchTerm })
                .then(results => { this._linkSearchResults = results.map(a => ({ id: a.id, name: a.name })); })
                .catch(() => { this._linkSearchResults = []; });
        }
    }

    handleLinkSelect(event) {
        const targetId = event.currentTarget.dataset.id;
        const pb = this.selectedPricebook;
        const t = pb?.pricebookType;

        const pbId = pb.id;
        const linkPromise = t === 'Site'
            ? linkPricebookToSite({ pricebookId: pbId, siteId: targetId })
            : linkPricebookToAccount({ pricebookId: pbId, accountId: targetId });

        linkPromise
            .then(() => {
                this._toast('Linked', `Pricebook linked to ${t === 'Site' ? 'site' : 'account'}.`, 'success');
                this._showLinkSearch = false;
                return this._loadPricebooks();
            })
            .then(() => {
                this.selectedPricebook = this._pricebooks.find(p => p.id === pbId) || null;
            })
            .catch(err => this._toast('Error', err?.body?.message || 'Failed to link.', 'error'));
    }

    handleUnlink() {
        const pb = this.selectedPricebook;
        if (!pb) return;
        const pbId = pb.id;
        unlinkPricebook({ pricebookId: pbId })
            .then(() => {
                this._toast('Unlinked', 'Association removed.', 'success');
                this._showLinkSearch = false;
                return this._loadPricebooks();
            })
            .then(() => {
                this.selectedPricebook = this._pricebooks.find(p => p.id === pbId) || null;
            })
            .catch(err => this._toast('Error', err?.body?.message || 'Failed to unlink.', 'error'));
    }

    // ─── Export ───────────────────────────────────────────────────────────────
    _downloadCsv(filename, rows, columns) {
        const header = columns.map(c => c.label).join(',');
        const body = rows.map(r => columns.map(c => {
            let v = c.fn ? c.fn(r) : (r[c.key] != null ? String(r[c.key]) : '');
            if (v.includes(',') || v.includes('"') || v.includes('\n')) v = '"' + v.replace(/"/g, '""') + '"';
            return v;
        }).join(',')).join('\n');
        const csv = header + '\n' + body;
        const blob = new Blob([csv], { type: 'text/plain' });
        const a = document.createElement('a');
        a.href = URL.createObjectURL(blob);
        a.download = filename;
        a.click();
    }

    handleExportCatalog() {
        const products = this.filteredProductList;
        if (!products.length) { this._toast('No Data', 'No products to export.', 'warning'); return; }
        const rows = products.map(p => ({
            productCode: p.productCode || '',
            name: p.name || '',
            family: p.family || '',
            chargeType: p.chargeType || '',
            active: p.isActive ? 'Yes' : 'No',
            availableSites: p.availableSites || '',
            availableCountries: p.availableCountries || '',
            productAttribute: p.attributeType || '',
            attributeValues: p.attributeValues || '',
            showCustomValue: p.showCustomValue ? 'Yes' : 'No',
            capacityAssignment: p.capacityAssignment || '',
            uom: p.uom || '',
            pairedProduct: p.pairedProductCode || '',
            additionalChargeOf: p.additionalChargeOfCode || '',
            odooProductId: p.odooProductId || '',
            pricebookCount: p.entryCount || 0,
            description: p.description || '',
        }));
        this._downloadCsv(
            'product_catalog.csv',
            rows,
            [
                { label: 'Product Code', key: 'productCode' },
                { label: 'Name', key: 'name' },
                { label: 'Family', key: 'family' },
                { label: 'Charge Type', key: 'chargeType' },
                { label: 'Active', key: 'active' },
                { label: 'Available Sites', key: 'availableSites' },
                { label: 'Available Countries', key: 'availableCountries' },
                { label: 'Product Attribute', key: 'productAttribute' },
                { label: 'Attribute Values', key: 'attributeValues' },
                { label: 'Show Custom Value', key: 'showCustomValue' },
                { label: 'Capacity Assignment', key: 'capacityAssignment' },
                { label: 'UoM', key: 'uom' },
                { label: 'Paired Product', key: 'pairedProduct' },
                { label: 'Additional Charge Of', key: 'additionalChargeOf' },
                { label: 'Odoo Product ID', key: 'odooProductId' },
                { label: 'Pricebooks', key: 'pricebookCount' },
                { label: 'Description', key: 'description' },
            ]
        );
        this._toast('Exported', rows.length + ' products downloaded.', 'success');
    }

    handleExportPricebooks() {
        const type = this.selectedPricebookType;
        const books = type
            ? this._pricebooks.filter(pb => pb.pricebookType === type)
            : this._pricebooks;
        if (!books.length) { this._toast('No Data', 'No pricebooks to export.', 'warning'); return; }

        // Load ALL entries for each pricebook then export as one CSV
        this._toast('Exporting...', 'Loading product data for ' + books.length + ' pricebooks.', 'info');
        const promises = books.map(pb =>
            getPricebookEntries({ pricebookId: pb.id })
                .then(entries => entries.map(e => ({
                    pricebookName: pb.name,
                    pricebookType: pb.pricebookType,
                    linkedTo: pb.linkedTo || '',
                    productName: e.productName,
                    productCode: e.productCode,
                    family: e.family || '',
                    chargeType: e.chargeType || '',
                    unitPrice: e.unitPrice,
                    currency: e.currencyIsoCode || '',
                    active: e.isActive ? 'Yes' : 'No',
                    availableCountries: e.availableCountries || '',
                    availableSites: e.availableSites || '',
                    productAttribute: e.productAttribute || '',
                    attributeValues: e.attributeValues || '',
                })))
                .catch(() => [])
        );
        Promise.all(promises).then(results => {
            const allRows = results.flat();
            if (!allRows.length) {
                this._toast('No Data', 'No products found across selected pricebooks.', 'warning');
                return;
            }
            this._downloadCsv(
                'pricebooks' + (type ? '_' + type : '') + '_full.csv',
                allRows,
                [
                    { label: 'Pricebook', key: 'pricebookName' },
                    { label: 'Type', key: 'pricebookType' },
                    { label: 'Linked To', key: 'linkedTo' },
                    { label: 'Product Name', key: 'productName' },
                    { label: 'Product Code', key: 'productCode' },
                    { label: 'Family', key: 'family' },
                    { label: 'Charge Type', key: 'chargeType' },
                    { label: 'Unit Price', key: 'unitPrice' },
                    { label: 'Currency', key: 'currency' },
                    { label: 'Active', key: 'active' },
                    { label: 'Available Countries', key: 'availableCountries' },
                    { label: 'Available Sites', key: 'availableSites' },
                    { label: 'Product Attribute', key: 'productAttribute' },
                    { label: 'Attribute Values', key: 'attributeValues' },
                ]
            );
            this._toast('Exported', allRows.length + ' product entries across ' + books.length + ' pricebooks.', 'success');
        });
    }

    handleExportEntries() {
        // Export only what's currently displayed (filtered/grouped)
        const pbeRows = (this._displayList || []).map(e => ({
            productName: e.productName,
            productCode: e.productCode,
            attribute: '-',
            family: e.family || '',
            chargeType: e.chargeType || '',
            unitPrice: e.unitPrice,
            currency: e.currencyIsoCode || '',
            source: 'Pricebook Entry',
            active: e.isActive ? 'Yes' : 'No',
            availableCountries: e.availableCountries || '',
            availableSites: e.availableSites || '',
            productAttribute: e.productAttribute || '',
        }));
        const variantRows = (this._variantLines || []).map(v => ({
            productName: v.productName,
            productCode: v.productCode || '',
            attribute: v.attributeValue || '',
            family: v.family || '',
            chargeType: '',
            unitPrice: v.unitPrice,
            currency: '',
            source: 'Variant Override',
            active: '-',
        }));
        // Add pricing tier rows from consolidated CMT
        const productCodesInPb = new Set((this._rawEntries || []).map(e => e.productCode).filter(Boolean));
        const tierRows = (this._pricingTiers || [])
            .filter(t => t.productCode && productCodesInPb.has(t.productCode) && t.price > 0)
            .map(t => ({
                productName: (this._rawEntries.find(e => e.productCode === t.productCode) || {}).productName || t.productCode,
                productCode: t.productCode,
                attribute: t.attributeValue || '',
                family: '',
                chargeType: '',
                unitPrice: t.price,
                currency: t.currencyCode || '',
                source: 'Attribute Tier',
                active: '-',
                siteCode: t.siteCode || '',
                odooComboId: t.odooComboId || '',
            }));
        const allRows = [...pbeRows, ...variantRows, ...tierRows];
        if (!allRows.length) {
            this._toast('No Data', 'No entries to export.', 'warning');
            return;
        }
        const pbName = this.selectedPricebook?.name || 'pricebook';
        this._downloadCsv(
            pbName.replace(/[^a-zA-Z0-9]/g, '_') + '_pricing.csv',
            allRows,
            [
                { label: 'Product Name', key: 'productName' },
                { label: 'Product Code', key: 'productCode' },
                { label: 'Attribute', key: 'attribute' },
                { label: 'Site Code', key: 'siteCode' },
                { label: 'Family', key: 'family' },
                { label: 'Charge Type', key: 'chargeType' },
                { label: 'Unit Price', key: 'unitPrice' },
                { label: 'Currency', key: 'currency' },
                { label: 'Source', key: 'source' },
                { label: 'Active', key: 'active' },
                { label: 'Available Countries', key: 'availableCountries' },
                { label: 'Available Sites', key: 'availableSites' },
                { label: 'Product Attribute', key: 'productAttribute' },
                { label: 'Odoo Combo ID', key: 'odooComboId' },
            ]
        );
        this._toast('Exported', allRows.length + ' rows downloaded.', 'success');
    }

    // ─── Mass price update ────────────────────────────────────────────────────
    handleEntryToggleSelect(event) {
        const id   = event.currentTarget.dataset.id;
        const next = new Set(this.selectedEntryIds);
        if (next.has(id)) next.delete(id); else next.add(id);
        this.selectedEntryIds = next;
        this._computeDisplay();
    }
    handleSelectAllEntries() {
        if (this.allEntriesSelected) {
            this.selectedEntryIds = new Set();
        } else {
            this.selectedEntryIds = new Set(this._displayList.map(e => e.id));
        }
        this._computeDisplay();
    }
    handleMassUpdatePriceChange(event) { this.massUpdatePrice = event.target.value; }
    handleCancelMassUpdate() {
        this.selectedEntryIds = new Set();
        this.massUpdatePrice  = '';
        this._computeDisplay();
    }
    handleConfirmMassUpdate() {
        const price = parseFloat(this.massUpdatePrice);
        if (isNaN(price) || price < 0) { this._toast('Invalid Price', 'Enter 0 or greater.', 'error'); return; }
        const ids = [...this.selectedEntryIds];
        this._massUpdating = true;
        massUpdatePricebookEntries({ entryIds: ids, unitPrice: price })
            .then(() => {
                this._setEntries(this._rawEntries.map(e =>
                    ids.includes(e.id)
                        ? { ...e, unitPrice: price, unitPriceFormatted: fmtCurrency(price, e.currencyIsoCode) }
                        : e
                ));
                this.selectedEntryIds = new Set();
                this.massUpdatePrice  = '';
                this._computeDisplay();
                this._toast('Prices Updated', `${ids.length} entr${ids.length !== 1 ? 'ies' : 'y'} updated.`, 'success');
            })
            .catch(err => this._toast('Error', err?.body?.message || 'Failed to update prices.', 'error'))
            .finally(() => { this._massUpdating = false; });
    }

    // ─── Entry row actions ────────────────────────────────────────────────────
    handleEntryEye(event) {
        const id    = event.currentTarget.dataset.id;
        const entry = this._rawEntries.find(e => e.id === id);
        if (!entry || !entry.productId) return;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: entry.productId, actionName: 'view' }
        });
    }
    _enrichEntryDetail(entry) {
        return {
            ...entry,
            familyLabel:   entry.family || '—',
            activeClass:   entry.isActive ? 'dpm-status-pill dpm-status-active' : 'dpm-status-pill dpm-status-inactive',
            activeLabel:   entry.isActive ? 'Active' : 'Inactive',
            toggleTitle:   entry.isActive ? 'Deactivate' : 'Activate',
            pricebookName: this.selectedPricebook?.name || '',
        };
    }

    handleEntryEditPrice(event) {
        const id    = event.currentTarget.dataset.id;
        const entry = this._rawEntries.find(e => e.id === id);
        if (!entry) return;
        this._editingEntryId       = id;
        this._draftPrice           = entry.unitPrice != null ? String(entry.unitPrice) : '0';
        this._confirmDeleteEntryId = null;
        this._computeDisplay();
    }
    handleDraftPriceChange(event) { this._draftPrice = event.target.value; }
    handleCancelEntryEdit()        { this._editingEntryId = null; this._draftPrice = ''; this._computeDisplay(); }
    handleSaveEntryPrice(event) {
        const id    = event.currentTarget.dataset.id;
        const price = parseFloat(this._draftPrice);
        if (isNaN(price) || price < 0) {
            this._toast('Invalid Price', 'Enter a valid price (0 or greater).', 'error');
            return;
        }
        this._savingEntry = true;
        this._computeDisplay();
        updatePricebookEntry({ entryId: id, unitPrice: price })
            .then(() => {
                this._setEntries(this._rawEntries.map(e =>
                    e.id === id ? { ...e, unitPrice: price, unitPriceFormatted: fmtCurrency(price, e.currencyIsoCode) } : e
                ));
                this._editingEntryId = null;
                this._draftPrice     = '';
                if (this._detailPanel?.type === 'entry' && this._detailPanel.data.id === id) {
                    const updated = this._rawEntries.find(e => e.id === id);
                    if (updated) this._detailPanel = { ...this._detailPanel, data: this._enrichEntryDetail(updated) };
                }
                this._toast('Price Updated', '', 'success');
            })
            .catch(err => this._toast('Error', err?.body?.message || 'Failed to update price.', 'error'))
            .finally(() => { this._savingEntry = false; this._computeDisplay(); });
    }

    handleToggleEntryActive(event) {
        const id       = event.currentTarget.dataset.id;
        const newActive = event.currentTarget.dataset.active === 'true' ? false : true;
        this._togglingEntry = id;
        this._computeDisplay();
        toggleEntryActive({ entryId: id, isActive: newActive })
            .then(() => {
                this._setEntries(this._rawEntries.map(e =>
                    e.id === id ? { ...e, isActive: newActive } : e
                ));
                if (this._detailPanel?.type === 'entry' && this._detailPanel.data.id === id) {
                    const updated = this._rawEntries.find(e => e.id === id);
                    if (updated) this._detailPanel = { ...this._detailPanel, data: this._enrichEntryDetail(updated) };
                }
                this._toast(newActive ? 'Entry Activated' : 'Entry Deactivated', '', 'success');
            })
            .catch(err => this._toast('Error', err?.body?.message || 'Failed to update entry.', 'error'))
            .finally(() => { this._togglingEntry = null; this._computeDisplay(); });
    }
    handleDeleteEntry(event) {
        this._confirmDeleteEntryId = event.currentTarget.dataset.id;
        this._editingEntryId = null;
        this._computeDisplay();
    }
    handleCancelDeleteEntry()    { this._confirmDeleteEntryId = null; this._computeDisplay(); }
    handleConfirmDeleteEntry(event) {
        const id = event.currentTarget.dataset.id;
        this._deletingEntry        = id;
        this._confirmDeleteEntryId = null;
        this._computeDisplay();
        deletePricebookEntry({ entryId: id })
            .then(() => {
                this._setEntries(this._rawEntries.filter(e => e.id !== id));
                if (this._detailPanel?.type === 'entry' && this._detailPanel.data.id === id) {
                    this._detailPanel = null;
                }
                const next = new Set(this.selectedEntryIds);
                next.delete(id);
                this.selectedEntryIds = next;
                this._toast('Entry Removed', '', 'success');
            })
            .catch(err => this._toast('Error', err?.body?.message || 'Failed to delete entry.', 'error'))
            .finally(() => { this._deletingEntry = null; this._computeDisplay(); });
    }

    // ─── New Pricebook modal ──────────────────────────────────────────────────
    @track showNewPricebookModal = false;
    @track newPricebookName      = '';
    @track newPricebookDesc      = '';
    @track newPricebookActive    = true;
    @track newPricebookSiteId    = '';
    @track isCreatingPricebook   = false;
    @track modalError            = '';
    _sites = [];

    // Site lookup state
    @track siteSearchTerm    = '';
    @track siteSearchResults = [];
    @track showSiteResults   = false;
    get hasSiteResults() { return this.showSiteResults && this.siteSearchResults.length > 0; }

    // Account lookup state
    @track accountSearchTerm    = '';
    @track accountSearchResults = [];
    @track showAccountResults   = false;
    @track newPricebookAccountId = '';
    get hasAccountResults() { return this.showAccountResults && this.accountSearchResults.length > 0; }

    // New pricebook products
    @track newPbProductSearch      = '';
    @track newPbProductResults     = [];
    @track showNewPbProductResults = false;
    @track newPbProducts           = [];
    get hasNewPbProducts()      { return this.newPbProducts.length > 0; }
    get showNewPbProductDrop()  { return this.showNewPbProductResults && this.newPbProductResults.length > 0; }

    async handleSyncSitePricebooks() {
        try {
            const jobId = await syncSitePricebooks();
            this._toast('Sync Started', 'Pricebook sync job queued (Job ID: ' + jobId + '). This runs in the background — refresh in 30 seconds to see results.', 'success');
        } catch (err) {
            this._toast('Sync Error', err?.body?.message || 'Failed to start sync.', 'error');
        }
    }

    handleNewPricebook() {
        this.newPricebookName        = '';
        this.newPricebookDesc        = '';
        this.newPricebookActive      = true;
        this.newPricebookSiteId      = '';
        this.newPricebookAccountId   = '';
        this.modalError              = '';
        this.siteSearchTerm          = '';
        this.siteSearchResults       = [];
        this.showSiteResults         = false;
        this.accountSearchTerm       = '';
        this.accountSearchResults    = [];
        this.showAccountResults      = false;
        this.newPbProductSearch      = '';
        this.newPbProductResults     = [];
        this.showNewPbProductResults = false;
        this.newPbProducts           = [];
        getSites()
            .then(data => { this._sites = data; })
            .catch(err => { this._sites = []; this.modalError = err.body?.message ?? 'Could not load sites.'; });
        this.showNewPricebookModal = true;
    }

    handleModalClose() {
        this.showNewPricebookModal   = false;
        this.newPbProducts           = [];
        this.siteSearchTerm          = '';
        this.siteSearchResults       = [];
        this.showSiteResults         = false;
        this.accountSearchTerm       = '';
        this.accountSearchResults    = [];
        this.showAccountResults      = false;
        this.newPbProductSearch      = '';
        this.newPbProductResults     = [];
        this.showNewPbProductResults = false;
    }
    handleNewPricebookName(e)   { this.newPricebookName   = e.target.value; }
    handleNewPricebookDesc(e)   { this.newPricebookDesc   = e.target.value; }
    handleNewPricebookActive(e) { this.newPricebookActive = e.target.checked; }

    // Site lookup handlers
    handleSiteSearchInput(event) {
        const val = event.target.value;
        this.siteSearchTerm = val;
        if (!val) {
            this.newPricebookSiteId = '';
            this.siteSearchResults  = [];
            this.showSiteResults    = false;
            return;
        }
        const t = val.toLowerCase();
        this.siteSearchResults = this._sites
            .filter(s => s.name.toLowerCase().includes(t) || (s.currentPricebookName || '').toLowerCase().includes(t))
            .slice(0, 10);
        this.showSiteResults = this.siteSearchResults.length > 0;
    }
    handleSiteResultSelect(event) {
        const id   = event.currentTarget.dataset.id;
        const site = this._sites.find(s => s.id === id);
        if (site) {
            this.newPricebookSiteId = site.id;
            this.siteSearchTerm     = site.currentPricebookName
                ? `${site.name} (current: ${site.currentPricebookName})`
                : site.name;
            // Auto-set name in DE format if the name field is still empty
            if (!this.newPricebookName) {
                const siteCode = this._extractSiteCode(site.name);
                const year     = new Date().getFullYear();
                this.newPricebookName = siteCode
                    ? `DE ${siteCode} Price Book ${year}`
                    : `DE ${site.name} Price Book ${year}`;
            }
        }
        this.showSiteResults = false;
    }
    _extractSiteCode(siteName) {
        if (!siteName) return '';
        // Match 2–5 uppercase letters optionally followed by 1–2 digits at word boundary
        // e.g. "TYO1 - Tokyo" → "TYO1", "SIN2" → "SIN2", "Singapore" → ""
        const m = siteName.match(/\b([A-Z]{2,5}\d{0,2})\b/);
        return m ? m[1] : '';
    }
    handleSiteClear() {
        this.newPricebookSiteId = '';
        this.siteSearchTerm     = '';
        this.siteSearchResults  = [];
        this.showSiteResults    = false;
    }

    // Account lookup handlers
    handleAccountSearchInput(event) {
        const val = event.target.value;
        this.accountSearchTerm = val;
        if (!val || val.length < 2) {
            this.newPricebookAccountId = '';
            this.accountSearchResults  = [];
            this.showAccountResults    = false;
            return;
        }
        searchAccounts({ searchTerm: val })
            .then(data => {
                this.accountSearchResults = data || [];
                this.showAccountResults   = this.accountSearchResults.length > 0;
            })
            .catch(() => { this.accountSearchResults = []; this.showAccountResults = false; });
    }
    handleAccountResultSelect(event) {
        const id  = event.currentTarget.dataset.id;
        const row = this.accountSearchResults.find(a => a.id === id);
        if (row) {
            this.newPricebookAccountId = row.id;
            this.accountSearchTerm     = row.name;
        }
        this.showAccountResults = false;
    }
    handleAccountClear() {
        this.newPricebookAccountId = '';
        this.accountSearchTerm     = '';
        this.accountSearchResults  = [];
        this.showAccountResults    = false;
    }

    // New pricebook product handlers
    handleNewPbProductSearch(event) {
        const val = event.target.value;
        this.newPbProductSearch = val;
        if (val.length < 2) { this.newPbProductResults = []; this.showNewPbProductResults = false; return; }
        const t     = val.toLowerCase();
        const added = new Set(this.newPbProducts.map(p => p.id));
        this.newPbProductResults = this._products
            .filter(p => p.isActive && !added.has(p.id) &&
                (p.name.toLowerCase().includes(t) || (p.productCode || '').toLowerCase().includes(t)))
            .slice(0, 8);
        this.showNewPbProductResults = this.newPbProductResults.length > 0;
    }
    handleAddNewPbProduct(event) {
        const id   = event.currentTarget.dataset.id;
        const prod = this._products.find(p => p.id === id);
        if (!prod) return;
        this.newPbProducts           = [...this.newPbProducts, { id: prod.id, name: prod.name, code: prod.productCode, unitPrice: 0 }];
        this.newPbProductSearch      = '';
        this.newPbProductResults     = [];
        this.showNewPbProductResults = false;
    }
    handleNewPbProductPriceChange(event) {
        const id    = event.currentTarget.dataset.id;
        const price = parseFloat(event.target.value);
        this.newPbProducts = this.newPbProducts.map(p =>
            p.id === id ? { ...p, unitPrice: isNaN(price) ? 0 : price } : p
        );
    }
    handleRemoveNewPbProduct(event) {
        const id = event.currentTarget.dataset.id;
        this.newPbProducts = this.newPbProducts.filter(p => p.id !== id);
    }

    // ─── Add Products to Existing Pricebook handlers ──────────────────────────
    handleToggleAddProducts() {
        this.showAddProductsPanel = !this.showAddProductsPanel;
        if (!this.showAddProductsPanel) {
            this.addProdSearch = ''; this.addProdResults = []; this.addProdSelections = [];
            this._addProdCurrencyOverride = null;
        }
    }
    handleAddProdSearch(event) {
        const val = event.target.value;
        this.addProdSearch = val;
        if (val.length < 2) { this.addProdResults = []; return; }
        const t = val.toLowerCase();
        const added = new Set(this.addProdSelections.map(p => p.id));
        const existing = new Set((this._rawEntries || []).map(e => e.productId));
        this.addProdResults = this._products
            .filter(p => p.isActive && !added.has(p.id) && !existing.has(p.id) &&
                (p.name.toLowerCase().includes(t) || (p.productCode || '').toLowerCase().includes(t)))
            .slice(0, 8);
    }
    handleAddProdSelect(event) {
        const id = event.currentTarget.dataset.id;
        const prod = this._products.find(p => p.id === id);
        if (!prod) return;
        this.addProdSelections = [...this.addProdSelections, { id: prod.id, name: prod.name, code: prod.productCode, unitPrice: 0 }];
        this.addProdSearch = ''; this.addProdResults = [];
    }
    handleAddProdPriceChange(event) {
        const id = event.currentTarget.dataset.id;
        const price = parseFloat(event.target.value);
        this.addProdSelections = this.addProdSelections.map(p =>
            p.id === id ? { ...p, unitPrice: isNaN(price) ? 0 : price } : p);
    }
    handleRemoveAddProd(event) {
        const id = event.currentTarget.dataset.id;
        this.addProdSelections = this.addProdSelections.filter(p => p.id !== id);
    }
    handleNewProductFromAddPanel() {
        this._newProductFromAddPanel = true;
        this.handleNewProduct();
    }
    handleCommitAddProducts() {
        if (!this.addProdSelections.length || !this.selectedPricebook) return;
        this._addingProducts = true;
        addProductsToPricebook({
            pricebookId: this.selectedPricebook.id,
            productsJson: JSON.stringify(this.addProdSelections.map(p => ({ productId: p.id, unitPrice: p.unitPrice, currencyIsoCode: this.addProdCurrency }))),
        })
        .then(() => {
            const n = this.addProdSelections.length;
            this._toast('Products Added', n + ' product' + (n !== 1 ? 's' : '') + ' added to pricebook.', 'success');
            this.showAddProductsPanel = false;
            this.addProdSearch = ''; this.addProdResults = []; this.addProdSelections = [];
            this._loadEntries(this.selectedPricebook.id);
            this._loadPricebooks();
        })
        .catch(err => this._toast('Error', err?.body?.message || 'Failed to add products.', 'error'))
        .finally(() => { this._addingProducts = false; });
    }

    handleCreatePricebook() {
        if (!this.newPricebookName?.trim()) { this.modalError = 'Pricebook name is required.'; return; }
        this.modalError          = '';
        this.isCreatingPricebook = true;
        const pbName     = this.newPricebookName.trim();
        const hasSite    = !!this.newPricebookSiteId;
        const hasAccount = !!this.newPricebookAccountId;
        const hasProds   = this.newPbProducts.length > 0;
        const prodCount  = hasProds ? this.newPbProducts.length : 0;
        // The pricebook is committed by createPricebook in its own transaction; a later
        // failure adding products does NOT roll it back. Track the id so the catch below
        // can tell "nothing was created" from "created, products failed".
        let createdPbId = null;
        createPricebook({
            name:        pbName,
            description: this.newPricebookDesc,
            isActive:    this.newPricebookActive,
            siteId:      this.newPricebookSiteId || null,
            accountId:   this.newPricebookAccountId || null,
        })
        .then(pbId => {
            createdPbId = pbId;
            if (hasProds) {
                return addProductsToPricebook({
                    pricebookId:  pbId,
                    productsJson: JSON.stringify(this.newPbProducts.map(p => ({ productId: p.id, unitPrice: p.unitPrice }))),
                });
            }
            return Promise.resolve();
        })
        .then(() => {
            this._closeNewPricebookModal();
            const siteMsg    = hasSite    ? ', assigned to site'    : '';
            const acctMsg    = hasAccount ? ', linked to account'   : '';
            const finalMsg   = hasSite || hasAccount || prodCount > 0
                ? `"${pbName}" created${siteMsg}${acctMsg}${prodCount > 0 ? `, ${prodCount} product(s) added` : ''}.`
                : `"${pbName}" created.`;
            this._toast('Pricebook Created', finalMsg, 'success');
            return this._loadPricebooks();
        })
        .catch(err => {
            const msg = err?.body?.message || 'Failed to create pricebook.';
            if (!createdPbId) { this.modalError = msg; return null; }
            // Pricebook exists. Keeping the modal open invites a second Create click and a
            // duplicate pricebook, so close it and say plainly what did and did not happen.
            this._closeNewPricebookModal();
            this._toast('Products Not Added', `"${pbName}" was created, but its products could not be added: ${msg}`, 'warning');
            return this._loadPricebooks();
        })
        .finally(() => { this.isCreatingPricebook = false; });
    }

    _closeNewPricebookModal() {
        this.showNewPricebookModal   = false;
        this.modalError              = '';
        this.newPbProducts           = [];
        this.newPricebookSiteId      = '';
        this.newPricebookAccountId   = '';
        this.siteSearchTerm          = '';
        this.accountSearchTerm       = '';
    }

    // ─── Pricebook Requests ───────────────────────────────────────────────────
    @track activeRequestStatus = 'All';
    @track requestsLoading     = false;
    @track requestsError       = '';
    _requests = [];

    _clickOutsideHandler = (event) => {
        // Close any open column menu when clicking outside
        if (this.showColumnMenu || this.showProductColumnMenu) {
            const path = event.composedPath();
            const isInside = path.some(el => el.classList && el.classList.contains('dpm-col-toggle-wrap'));
            if (!isInside) {
                this.showColumnMenu        = false;
                this.showProductColumnMenu = false;
                this._removeClickOutsideListener();
            }
        }
    };

    _addClickOutsideListener() {
        // Use setTimeout so the current click event doesn't immediately close
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => { document.addEventListener('click', this._clickOutsideHandler, true); }, 0);
    }
    _removeClickOutsideListener() {
        document.removeEventListener('click', this._clickOutsideHandler, true);
    }

    connectedCallback() {
        this._loadCategoryMappings();
        this._loadRequests();
        this._loadPricebooks();
        this._loadPricingTiers();
    }

    handleRefreshAll() {
        refreshApex(this._wiredProducts);
        this._loadRequests();
        this._loadPricebooks();
        this._tiersLoaded = false;
        this._loadPricingTiers();
        if (this.selectedPricebook) {
            this._loadEntries(this.selectedPricebook.id);
        }
        this._toast('Refreshed', 'All data reloaded.', 'success');
    }

    disconnectedCallback() {
        this._removeClickOutsideListener();
    }

    _loadRequests() {
        this.requestsLoading = true;
        getPricebookRequests({ statusFilter: this.activeRequestStatus || 'All' })
            .then(data => { this._requests = data; this.requestsError = ''; })
            .catch(err  => { this.requestsError = err?.body?.message || 'Failed to load requests.'; })
            .finally(() => { this.requestsLoading = false; });
    }

    get requestStatusFilters() {
        const counts = {};
        this._requests.forEach(r => { counts[r.Status__c] = (counts[r.Status__c] || 0) + 1; });
        return REQUEST_STATUSES.map(s => ({
            value:    s.value,
            label:    s.label,
            count:    s.value !== 'All' ? (counts[s.value] || null) : null,
            cssClass: 'cat-pill' + (this.activeRequestStatus === s.value ? ' cat-pill_active' : ''),
        }));
    }
    get displayedRequests() {
        let list = this._requests;
        if (this.activeRequestStatus && this.activeRequestStatus !== 'All') {
            list = list.filter(r => r.Status__c === this.activeRequestStatus);
        }
        return list.map((r, idx) => ({
            ...r,
            rowNum:               idx + 1,
            accountName:          r.Account__r?.Name || '—',
            quoteName:            r.Quote__r?.Name   || '—',
            pricebookName:        r.Pricebook2__r?.Name || '—',
            requestedByName:      r.CreatedBy?.Name  || '—',
            createdDateFormatted: fmtDate(r.CreatedDate),
            statusClass:          STATUS_CLASS[r.Status__c] || 'dpm-status-pill',
            statusDotClass:       STATUS_DOT[r.Status__c]   || 'dpm-dot',
            statusShort:          STATUS_SHORT[r.Status__c] || r.Status__c,
            statusBarClass:       STATUS_BAR[r.Status__c]   || 'dpm-req-card-bar',
            hasQuote:             !!r.Quote__r?.Name,
            hasPricebook:         !!r.Pricebook2__r?.Name,
        }));
    }
    get hasRequests()         { return this.displayedRequests.length > 0; }
    get pendingRequestCount() { return this._requests.filter(r => r.Status__c === 'Pending Approval').length; }
    get hasPendingRequests()  { return this.pendingRequestCount > 0; }

    // ─── Queue view getters ──────────────────────────────────────────────────
    _enrichQueueRequest(r, idx) {
        return {
            ...r,
            rowNum:               idx + 1,
            accountName:          r.Account__r?.Name || '—',
            quoteName:            r.Quote__r?.Name   || '',
            requestedByName:      r.CreatedBy?.Name  || '—',
            createdDateFormatted: fmtDate(r.CreatedDate),
            statusDotClass:       STATUS_DOT[r.Status__c]   || 'dpm-dot',
            statusShort:          STATUS_SHORT[r.Status__c] || r.Status__c,
            statusClass:          STATUS_CLASS[r.Status__c] || 'dpm-status-pill',
            currencyCode:         r.Currency__c || 'USD',
            hasQuote:             !!r.Quote__r?.Name,
        };
    }
    get pendingRequests() {
        return this._requests
            .filter(r => r.Status__c === 'Pending Approval')
            .map((r, idx) => this._enrichQueueRequest(r, idx));
    }
    get processedRequests() {
        return this._requests
            .filter(r => r.Status__c === 'Approved' || r.Status__c === 'Rejected')
            .sort((a, b) => new Date(b.CreatedDate) - new Date(a.CreatedDate))
            .slice(0, 15)
            .map((r, idx) => this._enrichQueueRequest(r, idx));
    }
    get hasPendingQueue()       { return this.pendingRequests.length > 0; }
    get hasProcessedRequests()  { return this.processedRequests.length > 0; }
    get isQueueClear()          { return !this.requestsLoading && !this.hasPendingQueue; }

    handleRequestStatusClick(event) {
        this.activeRequestStatus = event.currentTarget.dataset.value;
        this._loadRequests();
    }
    handleOpenRequest(event) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: event.currentTarget.dataset.id, actionName: 'view' },
        });
    }
    handleRequestEye(event) {
        const id = event.currentTarget.dataset.id;
        this._detailLoading     = true;
        this._detailPanel       = null;
        this._requestLineSearch = '';
        getRequestDetail({ requestId: id })
            .then(data => {
                this._detailPanel = {
                    type: 'request',
                    data: this._enrichRequestDetail(data),
                };
            })
            .catch(err => this._toast('Error', err?.body?.message || 'Failed to load request.', 'error'))
            .finally(() => { this._detailLoading = false; });
    }
    _enrichRequestDetail(data) {
        return {
            ...data,
            statusClass:       STATUS_CLASS[data.status] || 'dpm-status-pill',
            statusDotClass:    STATUS_DOT[data.status]   || 'dpm-dot',
            statusShort:       STATUS_SHORT[data.status] || data.status,
            isPendingApproval: data.status === 'Pending Approval',
            createdDateFmt:    fmtDate(data.createdDate),
            lines: (data.lines || []).map(ln => ({
                ...ln,
                familyLabel:        ln.family || '—',
                unitPriceFormatted: fmtCurrency(ln.unitPrice, data.currencyCode),
                displayName:        ln.productName ? (ln.productName + (ln.attributeValue ? ' [' + ln.attributeValue + ']' : '')) : '',
                isUnlinked:         !ln.productName,
            })),
        };
    }

    // ─── Request line price editing ───────────────────────────────────────────
    @track _editingLineId  = null;
    @track _draftLinePrice = '';
    _savingLine = null;

    get requestPanelLines() {
        if (!this._detailPanel?.data?.lines) return [];
        const editId = this._editingLineId;
        const draft  = this._draftLinePrice;
        return this._detailPanel.data.lines.map(ln => ({
            ...ln,
            isEditingPrice: ln.id === editId,
            draftPrice:     ln.id === editId ? draft : (ln.unitPrice != null ? String(ln.unitPrice) : '0'),
            priceTextClass: (ln.unitPrice == null || ln.unitPrice === 0) ? 'dpm-price-text dpm-price-zero' : 'dpm-price-text',
        }));
    }

    handleRequestLinePriceClick(event) {
        if (this._editingLineId) return;          // already editing another line
        const id   = event.currentTarget.dataset.id;
        const line = this._detailPanel?.data?.lines?.find(ln => ln.id === id);
        if (!line) return;
        this._editingLineId  = id;
        this._draftLinePrice = line.unitPrice != null ? String(line.unitPrice) : '0';
    }
    handleRequestLineDraftChange(event) { this._draftLinePrice = event.target.value; }
    handleCancelRequestLinePrice() { this._editingLineId = null; this._draftLinePrice = ''; }
    handleRequestLinePriceKeydown(event) {
        if (event.key === 'Enter')  { event.stopPropagation(); this._saveRequestLinePrice(event.currentTarget.dataset.id); }
        else if (event.key === 'Escape') { event.stopPropagation(); this.handleCancelRequestLinePrice(); }
    }
    handleSaveRequestLinePrice(event) { this._saveRequestLinePrice(event.currentTarget.dataset.id); }
    _saveRequestLinePrice(lineId) {
        const price = parseFloat(this._draftLinePrice);
        if (isNaN(price) || price < 0) {
            this._toast('Invalid Price', 'Enter a valid price (0 or greater).', 'error');
            return;
        }
        const panelData = this._detailPanel?.data;
        const line      = panelData?.lines?.find(ln => ln.id === lineId);
        if (!line || !panelData?.id) return;
        this._savingLine = lineId;
        upsertRequestLine({ requestId: panelData.id, productId: line.productId, productName: line.productName, unitPrice: price })
            .then(() => {
                const updatedLines = panelData.lines.map(ln =>
                    ln.id === lineId
                        ? { ...ln, unitPrice: price, unitPriceFormatted: fmtCurrency(price, panelData.currencyCode) }
                        : ln
                );
                this._detailPanel = { ...this._detailPanel, data: { ...panelData, lines: updatedLines } };
                this._editingLineId  = null;
                this._draftLinePrice = '';
                this._toast('Price Updated', '', 'success');
            })
            .catch(err => this._toast('Error', err?.body?.message || 'Failed to update price.', 'error'))
            .finally(() => { this._savingLine = null; });
    }

    // ─── Detail panel (shared across all 3 tabs) ──────────────────────────────
    @track _detailPanel     = null;
    @track _detailLoading   = false;
    @track _panelEditPrice  = false;
    @track _panelDraftPrice = '';
    _panelSaving = false;

    // Request-specific panel state
    @track _requestLineSearch   = '';
    @track _requestApproveInput = false;
    @track _requestRejectInput  = false;
    @track _requestNotes        = '';
    _processingApproval    = false;
    _addingRequestLine     = false;
    _deletingRequestLineId = null;

    get showDetailPanel()  { return this._detailPanel != null || this._detailLoading; }
    get isProductDetail()  { return this._detailPanel?.type === 'product'; }
    get isEntryDetail()    { return this._detailPanel?.type === 'entry'; }
    get isRequestDetail()  { return this._detailPanel?.type === 'request'; }
    get detailData()       { return this._detailPanel?.data || {}; }
    get detailTitle()      {
        if (!this._detailPanel) return '';
        const d = this._detailPanel.data;
        if (this._detailPanel.type === 'entry')   return d.productName || '';
        if (this._detailPanel.type === 'request') return d.name || '';
        return d.name || '';
    }

    get requestLineSearchResults() {
        if (!this._requestLineSearch || this._requestLineSearch.length < 2) return [];
        const t = this._requestLineSearch.toLowerCase();
        return this._products
            .filter(p => p.name.toLowerCase().includes(t) || (p.productCode || '').toLowerCase().includes(t))
            .slice(0, 10)
            .map(p => ({ ...p, label: `${p.name} (${p.productCode || '—'})` }));
    }
    get hasRequestLineSearchResults() { return this.requestLineSearchResults.length > 0; }

    handleDetailClose() {
        this._detailPanel          = null;
        this._panelEditPrice       = false;
        this._panelDraftPrice      = '';
        this._requestApproveInput  = false;
        this._requestRejectInput   = false;
        this._requestNotes         = '';
        this._requestLineSearch    = '';
        // Clear pairing search state
        this._pairingSearch        = '';
        this._pairingSearchResults = [];
        this._showPairingResults   = false;
    }

    handleMainRowClick(event) {
        if (!this._detailPanel && !this._detailLoading) return;
        const path = event.composedPath();
        const isPanel = path.some(el => el.classList && el.classList.contains('dpm-detail-panel'));
        const isOpener = path.some(el => el.classList && (
            el.classList.contains('dpm-row-num-cell') ||
            el.classList.contains('dpm-queue-card') ||
            el.classList.contains('dpm-queue-recent-row')
        ));
        if (!isPanel && !isOpener) {
            this.handleDetailClose();
        }
    }

    // ─── Entry detail panel actions ───────────────────────────────────────────
    handlePanelStartEdit() {
        this._panelDraftPrice = this.detailData.unitPrice != null ? String(this.detailData.unitPrice) : '0';
        this._panelEditPrice  = true;
    }
    handlePanelCancelEdit() { this._panelEditPrice = false; this._panelDraftPrice = ''; }
    handlePanelDraftChange(event) { this._panelDraftPrice = event.target.value; }
    handlePanelSavePrice() {
        const price = parseFloat(this._panelDraftPrice);
        if (isNaN(price) || price < 0) { this._toast('Invalid Price', 'Enter 0 or greater.', 'error'); return; }
        const id = this.detailData.id;
        this._panelSaving = true;
        updatePricebookEntry({ entryId: id, unitPrice: price })
            .then(() => {
                this._setEntries(this._rawEntries.map(e =>
                    e.id === id ? { ...e, unitPrice: price, unitPriceFormatted: fmtCurrency(price, e.currencyIsoCode) } : e
                ));
                const updated = this._rawEntries.find(e => e.id === id);
                if (updated) this._detailPanel = { ...this._detailPanel, data: this._enrichEntryDetail(updated) };
                this._panelEditPrice  = false;
                this._panelDraftPrice = '';
                this._toast('Price Updated', '', 'success');
            })
            .catch(err => this._toast('Error', err?.body?.message || 'Failed to update price.', 'error'))
            .finally(() => { this._panelSaving = false; });
    }
    handlePanelToggleEntry() {
        const id       = this.detailData.id;
        const newActive = !this.detailData.isActive;
        this._togglingEntry = id;
        this._computeDisplay();
        toggleEntryActive({ entryId: id, isActive: newActive })
            .then(() => {
                this._setEntries(this._rawEntries.map(e =>
                    e.id === id ? { ...e, isActive: newActive } : e
                ));
                const updated = this._rawEntries.find(e => e.id === id);
                if (updated) this._detailPanel = { ...this._detailPanel, data: this._enrichEntryDetail(updated) };
                this._toast(newActive ? 'Entry Activated' : 'Entry Deactivated', '', 'success');
            })
            .catch(err => this._toast('Error', err?.body?.message || 'Failed to update entry.', 'error'))
            .finally(() => { this._togglingEntry = null; this._computeDisplay(); });
    }
    handlePanelDeleteEntry() {
        const id = this.detailData.id;
        this._deletingEntry = id;
        this._computeDisplay();
        deletePricebookEntry({ entryId: id })
            .then(() => {
                this._setEntries(this._rawEntries.filter(e => e.id !== id));
                this._detailPanel = null;
                this._toast('Entry Removed', '', 'success');
            })
            .catch(err => this._toast('Error', err?.body?.message || 'Failed to delete entry.', 'error'))
            .finally(() => { this._deletingEntry = null; this._computeDisplay(); });
    }

    // ─── Product detail panel actions ─────────────────────────────────────────
    handlePanelToggleProduct() {
        const id       = this.detailData.id;
        const newActive = !this.detailData.isActive;
        toggleProductActive({ productId: id, isActive: newActive })
            .then(() => {
                this._products = this._products.map(p =>
                    p.id === id ? { ...p, isActive: newActive } : p
                );
                this._detailPanel = {
                    ...this._detailPanel,
                    data: this._enrichProductDetail({ ...this.detailData, isActive: newActive }),
                };
                this._toast(`Product ${newActive ? 'activated' : 'deactivated'}.`, '', 'success');
            })
            .catch(err => this._toast('Error', err?.body?.message || 'Failed to update product.', 'error'));
    }

    // ─── Request detail panel actions ─────────────────────────────────────────
    handleRequestNotesChange(event) { this._requestNotes = event.target.value; }
    handleShowApproveInput(event)  { event.stopPropagation(); this._requestApproveInput = true;  this._requestRejectInput = false; }
    handleShowRejectInput(event)   { event.stopPropagation(); this._requestRejectInput  = true;  this._requestApproveInput = false; }
    handleCancelApprovalInput(event) {
        event.stopPropagation();
        this._requestApproveInput = false;
        this._requestRejectInput  = false;
        this._requestNotes        = '';
    }
    handleConfirmApprove(event) {
        event.stopPropagation();
        const id = this.detailData?.id;
        if (!id) { this._toast('Error', 'No request selected.', 'error'); return; }
        this._processingApproval = true;
        approveRequest({ requestId: id, notes: this._requestNotes || '' })
            .then(() => {
                this._toast('Request Approved', 'Pricebook request approved and materialized.', 'success');
                this._requestApproveInput = false;
                this._requestNotes        = '';
                this._loadRequests();
                return getRequestDetail({ requestId: id })
                    .then(data => {
                        this._detailPanel = { type: 'request', data: this._enrichRequestDetail(data) };
                    })
                    .catch(() => {
                        this._refreshRequestInPanel(id, 'Approved');
                    });
            })
            .then(() => this._loadPricebooks())
            .catch(err => {
                const msg = err?.body?.message || err?.message || 'Approval failed. Check the approval process configuration.';
                this._toast('Approval Error', msg, 'error');
                console.error('Approve error:', JSON.stringify(err));
            })
            .finally(() => { this._processingApproval = false; });
    }
    handleConfirmReject(event) {
        event.stopPropagation();
        const id = this.detailData.id;
        this._processingApproval = true;
        rejectRequest({ requestId: id, notes: this._requestNotes })
            .then(() => {
                this._loadRequests();
                this._toast('Request Rejected', '', 'success');
                this._requestRejectInput = false;
                this._requestNotes       = '';
                // Reload detail from server to refresh all UI elements
                return getRequestDetail({ requestId: id });
            })
            .then(detail => {
                if (detail && this._detailPanel?.type === 'request') {
                    this._detailPanel = { type: 'request', data: this._enrichRequestDetail(detail) };
                }
            })
            .catch(err => {
                // If detail reload fails, fall back to local refresh
                this._refreshRequestInPanel(id, 'Rejected');
                if (err?.body?.message) this._toast('Error', err.body.message, 'error');
            })
            .finally(() => { this._processingApproval = false; });
    }
    _refreshRequestInPanel(id, newStatus) {
        if (this._detailPanel?.type === 'request' && this._detailPanel.data.id === id) {
            const updated = { ...this._detailPanel.data, status: newStatus };
            this._detailPanel = { ...this._detailPanel, data: this._enrichRequestDetail(updated) };
        }
    }

    handleRequestLineSearch(event) { this._requestLineSearch = event.target.value; }
    handleAddRequestLine(event) {
        const productId   = event.currentTarget.dataset.id;
        const productName = event.currentTarget.dataset.name;
        const requestId   = this.detailData.id;
        this._addingRequestLine = true;
        this._requestLineSearch = '';
        upsertRequestLine({ requestId, productId, productName, unitPrice: 0 })
            .then(() => getRequestDetail({ requestId }))
            .then(data => {
                this._detailPanel = { ...this._detailPanel, data: this._enrichRequestDetail(data) };
            })
            .catch(err => this._toast('Error', err?.body?.message || 'Failed to add product.', 'error'))
            .finally(() => { this._addingRequestLine = false; });
    }
    handleDeleteRequestLine(event) {
        const lineId    = event.currentTarget.dataset.id;
        const requestId = this.detailData.id;
        this._deletingRequestLineId = lineId;
        deleteRequestLine({ lineId })
            .then(() => getRequestDetail({ requestId }))
            .then(data => {
                this._detailPanel = { ...this._detailPanel, data: this._enrichRequestDetail(data) };
            })
            .catch(err => this._toast('Error', err?.body?.message || 'Failed to remove product.', 'error'))
            .finally(() => { this._deletingRequestLineId = null; });
    }

    // ─── Utility ─────────────────────────────────────────────────────────────
    _toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}