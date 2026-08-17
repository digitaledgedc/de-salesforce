/* ─────────────────────────────────────────────────────────────────────────
 * CHANGE 2026-07-10 — Attribute dropdown overlap/click fix (REVERTABLE)
 * Replaced the inline <lightning-combobox> attribute picker with a custom
 * dropdown (button + <ul> menu) so an open menu reliably stacks above the
 * next selected row and its option clicks are not retargeted to the combobox
 * underneath. Search this file for the "CHANGE 2026-07-10" tag to find every
 * touched block. Original bundle backed up in scratchpad (see memory
 * [[fb-productselector-attr-dropdown-fix]]).
 *   Added:   _openAttrId state, connectedCallback/disconnectedCallback,
 *            handleAttrToggle, handleAttrSelect, custom attr* props in
 *            groupedProducts.
 *   Removed: handleAttrChange, attrPlaceholder/attrCheckboxOptions,
 *            lightning-combobox usage in the template + its CSS.
 * ───────────────────────────────────────────────────────────────────────── */
import { LightningElement, api, track, wire } from 'lwc';
import { FlowNavigationNextEvent, FlowAttributeChangeEvent } from 'lightning/flowSupport';
import getProductsForPricebook   from '@salesforce/apex/ProductSelectorController.getProductsForPricebook';
import getPricebooksForQuote     from '@salesforce/apex/ProductSelectorController.getPricebooksForQuote';
import updateQuotePricebook      from '@salesforce/apex/ProductSelectorController.updateQuotePricebook';

const PREFIX_TO_CATEGORY = {
    CAB: 'Space',  CAG: 'Space',  HYS: 'Space',  SPC: 'Space',
    POW: 'Power',  PCM: 'Power',
    CCL: 'Cross Connect', CCX: 'Cross Connect', DPP: 'Cross Connect', RIS: 'Cross Connect',
    IPT: 'IP & Internet', IXP: 'IP & Internet',
    MCS: 'Managed Connectivity', NMS: 'Managed Connectivity',
    RMH: 'Remote Hands',
    EMS: 'Managed Services', VAS: 'Managed Services',
    OFC: 'Office Services',
    CTM: 'Professional Services', PRO: 'Professional Services',
    RPT: 'Reports', STR: 'Storage', TER: 'Other',
    CUS: 'Professional Services', HEM: 'Managed Services',
};
// Map Family values that don't match display categories
const FAMILY_TO_CATEGORY = {
    'Interconnect': 'Cross Connect',
    'Network Services': 'IP & Internet',
};
function categoryFromFamily(family) {
    if (!family) return null;
    return FAMILY_TO_CATEGORY[family] || family;
}
function categoryFromCode(code) {
    if (!code) return 'Other';
    return PREFIX_TO_CATEGORY[(code.substring(0, 3) || '').toUpperCase()] || 'Other';
}
const CATEGORY_ORDER = [
    'All', 'Space', 'Power', 'Cross Connect', 'IP & Internet',
    'Managed Connectivity', 'Remote Hands', 'Managed Services',
    'Office Services', 'Professional Services', 'Reports', 'Storage', 'Other',
];

export default class ProductSelectorComponent extends LightningElement {

    @track _accountId = null;
    @track _wireAccountId = '';
    @api get accountId() { return this._accountId; }
    set accountId(val) { this._accountId = val; this._wireAccountId = val || ''; }
    @api quoteId;
    @api invoiceFrequency = '';
    @api mode = '';
    @track _activePricebookId = null;
    @api get pricebookId() { return this._activePricebookId; }
    set pricebookId(val) { this._activePricebookId = val || null; }
    @track _wireCurrencyIsoCode = '';
    @api get currencyIsoCode() { return this._wireCurrencyIsoCode; }
    set currencyIsoCode(val) { this._wireCurrencyIsoCode = val || ''; }

    @track allProducts      = [];
    @track _selectedMap     = {};  // productId -> [attrVal1, attrVal2] or [''] for no-attr products
    @track searchTerm       = '';
    @track activeCategory   = 'All';
    @track openCategories   = new Set();
    @track isLoading        = true;
    @track isLoaded         = false;
    @track loadError        = '';
    @track validationError  = '';
    @track showPricebookPicker  = false;
    @track availablePricebooks  = [];
    @track pricebookChangeError = '';
    @track isChangingPricebook  = false;
    @track _openAttrId          = null;  // CHANGE 2026-07-10 — product id whose attribute dropdown is open

    // ── Wire ──────────────────────────────────────────────────────────────────

    @wire(getProductsForPricebook, { pricebookId: '$_activePricebookId', currencyIsoCode: '$_wireCurrencyIsoCode', accountId: '$_accountId' })
    wiredProducts({ data, error }) {
        this.isLoading = false;
        this.isLoaded  = true;
        if (data) {
            this.allProducts = data.map(p => {
                const code = (p.Product2 && p.Product2.ProductCode) || '-';
                const attrType = (p.Product2 && p.Product2.Attribute_Type__c) || null;
                const attrVals = (p.Product2 && p.Product2.Attribute_Values__c) || null;
                let options = null;
                if (attrType && attrVals) {
                    options = attrVals.split(',').map(v => v.trim()).filter(Boolean);
                    options.sort((a, b) => (parseFloat(a) || 0) - (parseFloat(b) || 0));
                }
                return {
                    id: p.Product2Id,
                    name: p.Name,
                    code,
                    category: categoryFromCode(code) !== 'Other' ? categoryFromCode(code) : (categoryFromFamily(p.Product2?.Family) || 'Other'),
                    invoiceFrequency: (p.Product2 && p.Product2.Invoice_Frequency__c) || '',
                    hasAttr: !!options,
                    attrType: attrType || '',
                    attrOptions: options || [],
                };
            });
        } else if (error) {
            this.loadError = (error.body && error.body.message) || 'Failed to load products.';
        }
    }

    @wire(getPricebooksForQuote, { accountId: '$_wireAccountId', currentPricebookId: '$_activePricebookId' })
    wiredPricebooks({ data, error }) {
        if (data) {
            this.availablePricebooks = data.map(pb => ({
                ...pb,
                cssClass: 'pb-option' + (pb.id === this._activePricebookId ? ' pb-option_active' : ''),
            }));
        } else if (error) {
            this.pricebookChangeError = (error.body && error.body.message) || 'Could not load pricebooks.';
        }
    }

    // ── Computed ───────────────────────────────────────────────────────────────

    get categories() {
        const presentCats = new Set(this.allProducts.map(p => p.category));
        return CATEGORY_ORDER.filter(c => c === 'All' || presentCats.has(c))
            .map(c => ({ value: c, label: c, cssClass: 'cat-pill' + (this.activeCategory === c ? ' cat-pill_active' : '') }));
    }

    get filteredProducts() {
        let products = this.allProducts;
        // Filter by quote's invoice frequency — product must include the quote's frequency
        // "Half Yearly" (quote) matches "Half-Yearly" (product) via normalization
        if (this.invoiceFrequency) {
            const qf = this.invoiceFrequency.replace(/\s+/g, '-').toLowerCase();
            products = products.filter(p => {
                if (!p.invoiceFrequency) return true; // no restriction if product has no frequency set
                return p.invoiceFrequency.toLowerCase().split(';').some(v => v.trim().replace(/\s+/g, '-') === qf);
            });
        }
        if (this.activeCategory !== 'All') products = products.filter(p => p.category === this.activeCategory);
        if (this.searchTerm) {
            const t = this.searchTerm.toLowerCase();
            products = products.filter(p => p.name.toLowerCase().includes(t) || p.code.toLowerCase().includes(t));
        }
        return products;
    }

    get groupedProducts() {
        const groups = {};
        this.filteredProducts.forEach(p => {
            if (!groups[p.category]) groups[p.category] = [];
            const isSelected = this._selectedMap[p.id] !== undefined;
            const selectedAttrs = isSelected ? (this._selectedMap[p.id] || []) : [];
            const selAttr = selectedAttrs.length > 0 ? selectedAttrs[0] : '';
            const menuOpen = this._openAttrId === p.id;
            groups[p.category].push({
                ...p,
                isSelected,
                selectedAttrs,
                selectedAttr: selAttr,
                // CHANGE 2026-07-10 — custom attribute dropdown state (replaces
                // attrPicklistOptions/attrPlaceholder/attrCheckboxOptions used
                // by the old <lightning-combobox>)
                attrMenuOpen: menuOpen,
                attrDisplay: selAttr || '-- Select --',
                attrValClass: 'psc-select-val' + (selAttr ? '' : ' psc-select-val_placeholder'),
                attrRowClass: 'psc-attr-row' + (menuOpen ? ' psc-attr-row_open' : ''),
                attrBtnClass: 'psc-select-btn' + (menuOpen ? ' psc-select-btn_open' : ''),
                attrPicklistOptions: p.hasAttr
                    ? [{ label: '-- Select --', value: '' }, ...p.attrOptions.map(o => ({ label: o, value: o }))]
                        .map(opt => ({
                            ...opt,
                            itemClass: 'psc-select-opt' + (opt.value === selAttr ? ' psc-select-opt_sel' : ''),
                        }))
                    : [],
                rowClass: 'psc-row' + (isSelected ? ' psc-row-sel' : ''),
            });
        });
        return CATEGORY_ORDER.filter(c => c !== 'All' && groups[c])
            .map(c => {
                // CHANGE 2026-07-16 — dropdown-clip fix: relax this section's
                // overflow:hidden while one of its rows has an open attribute
                // menu, so the popup isn't cut off when the section is short.
                const hasOpenMenu = this._openAttrId !== null
                    && groups[c].some(p => p.id === this._openAttrId);
                return {
                    category: c,
                    products: groups[c],
                    count: groups[c].length,
                    isOpen: this.openCategories.has(c),
                    sectionClass: 'psc-section'
                        + (this.openCategories.has(c) ? ' psc-section-open' : '')
                        + (hasOpenMenu ? ' psc-section_menu-open' : ''),
                };
            });
    }

    get hasFilteredProducts() { return !this.isLoading && !this.loadError && this.filteredProducts.length > 0; }
    get selectedCount() { return Object.keys(this._selectedMap).length; }
    get hasSelection() { return this.selectedCount > 0; }

    get statusLabel() {
        if (this.isLoading) return 'Loading products...';
        const total = this.filteredProducts.length;
        if (this.searchTerm) return total + ' products match "' + this.searchTerm + '"';
        return total + ' products in this pricebook';
    }

    // ── Handlers ──────────────────────────────────────────────────────────────

    handleCategoryClick(e)  { this.activeCategory = e.currentTarget.dataset.value; this.validationError = ''; }
    handleSearchChange(e)   { this.searchTerm = e.target.value; this.validationError = ''; }

    handleSectionToggle(e) {
        const cat = e.currentTarget.dataset.category;
        const next = new Set(this.openCategories);
        if (next.has(cat)) next.delete(cat); else next.add(cat);
        this.openCategories = next;
    }

    // CHANGE 2026-07-10 — lifecycle + handlers for custom attribute dropdown
    connectedCallback() {
        // Close any open attribute dropdown when clicking outside of it.
        this._onOutsideClick = () => { if (this._openAttrId !== null) this._openAttrId = null; };
        window.addEventListener('click', this._onOutsideClick);
    }

    disconnectedCallback() {
        window.removeEventListener('click', this._onOutsideClick);
    }

    handleProductCheck(e) {
        const id = e.currentTarget.dataset.id;
        const checked = e.currentTarget.checked;
        const next = { ...this._selectedMap };
        if (checked) {
            next[id] = [];  // selected, no attributes yet
        } else {
            delete next[id];
            if (this._openAttrId === id) this._openAttrId = null;
        }
        this._selectedMap = next;
        this.validationError = '';
    }

    // Toggle the custom attribute dropdown for a product. stopPropagation keeps
    // the window outside-click handler from immediately closing it.
    handleAttrToggle(e) {
        e.stopPropagation();
        const id = e.currentTarget.dataset.id;
        this._openAttrId = (this._openAttrId === id) ? null : id;
    }

    // Select an attribute value from the custom dropdown.
    handleAttrSelect(e) {
        e.stopPropagation();
        const id = e.currentTarget.dataset.id;
        const val = e.currentTarget.dataset.value; // '' for -- Select --
        this._selectedMap = { ...this._selectedMap, [id]: val ? [val] : [] };
        this._openAttrId = null;
        this.validationError = '';
    }

    // ── Pricebook ─────────────────────────────────────────────────────────────

    togglePricebookPicker() { this.showPricebookPicker = !this.showPricebookPicker; this.pricebookChangeError = ''; }

    handlePricebookSelect(e) {
        const newId = e.currentTarget.dataset.id;
        if (newId === this._activePricebookId) { this.showPricebookPicker = false; return; }
        this.isChangingPricebook = true;
        this.pricebookChangeError = '';
        updateQuotePricebook({ quoteId: this.quoteId, newPricebookId: newId })
            .then(() => {
                this._activePricebookId = newId;
                this._selectedMap = {};
                this.isLoading = true;
                this.isLoaded = false;
                this.showPricebookPicker = false;
                this.dispatchEvent(new FlowAttributeChangeEvent('pricebookId', newId));
            })
            .catch(err => { this.pricebookChangeError = err?.body?.message || 'Cannot change pricebook.'; })
            .finally(() => { this.isChangingPricebook = false; });
    }

    // ── Actions ───────────────────────────────────────────────────────────────

    handleAddToQuote() {
        for (const [id, attrs] of Object.entries(this._selectedMap)) {
            const prod = this.allProducts.find(p => p.id === id);
            if (prod && prod.hasAttr && (!attrs || attrs.length === 0)) {
                this.validationError = 'Select at least one ' + prod.attrType + ' for ' + prod.name + '.';
                return;
            }
        }
        this.dispatchEvent(new FlowNavigationNextEvent());
    }

    handleAddToCustomPricebook() {
        this.mode = 'customPricebook';
        this.dispatchEvent(new FlowAttributeChangeEvent('mode', 'customPricebook'));
        this.dispatchEvent(new FlowNavigationNextEvent());
    }

    // ── Flow interface ────────────────────────────────────────────────────────

    @api attributeMap = '';

    @api
    get value() {
        const ids = [];
        for (const [id, attrs] of Object.entries(this._selectedMap)) {
            if (Array.isArray(attrs) && attrs.length > 0) {
                for (const av of attrs) {
                    ids.push(id + '::' + av);
                }
            } else {
                ids.push(id);
            }
        }
        return ids.join(';');
    }

    set value(val) {
        if (!val) { this._selectedMap = {}; return; }
        const map = {};
        for (const entry of val.split(';').filter(Boolean)) {
            if (entry.includes('::')) {
                const sep = entry.indexOf('::');
                const pid = entry.substring(0, sep);
                const av  = entry.substring(sep + 2);
                if (!map[pid]) map[pid] = [];
                map[pid].push(av);
            } else {
                map[entry] = [];
            }
        }
        this._selectedMap = map;
    }

    @api validate() {
        const valid = Object.keys(this._selectedMap).length > 0;
        if (!valid) this.validationError = 'Select at least one product to add.';
        return { isValid: valid, errorMessage: valid ? '' : 'Select at least one product to add.' };
    }
}