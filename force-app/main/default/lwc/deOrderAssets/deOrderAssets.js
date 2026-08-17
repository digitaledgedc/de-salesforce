import { LightningElement, api, wire, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import ORIGINAL_ORDER_FIELD from '@salesforce/schema/Order.Original_Order__c';
import CURRENCY_FIELD from '@salesforce/schema/Order.CurrencyIsoCode';
import getByOrder from '@salesforce/apex/OrderAssetsController.getByOrder';
import getLinkedChangeOrderQuote from '@salesforce/apex/OrderAssetsController.getLinkedChangeOrderQuote';

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

function catFromCode(code) {
    if (!code || code.length < 3) return 'Other';
    return PREFIX_TO_CATEGORY[code.substring(0, 3).toUpperCase()] || 'Other';
}

function isCrossConnect(productCode) {
    if (!productCode) return false;
    const p = productCode.toUpperCase();
    return p.startsWith('CCL') || p.startsWith('CCX') || p.startsWith('DPP') || p.startsWith('RIS');
}

const ALL_CATEGORIES = ['All', 'Space', 'Power', 'Cross Connect', 'IP & Internet', 'Remote Hands', 'Managed Services', 'Other'];

export default class DeOrderAssets extends NavigationMixin(LightningElement) {

    @api recordId;

    @track assets           = [];
    @track isLoading        = true;
    @track _isChangeOrder   = false;
    @track error;
    @track searchTerm       = '';
    @track activeCategory   = 'All';
    @track activeStatus     = 'All';
    @track expandedGroups   = {};
    @track showSmallLines   = false;
    @track selectedAssetId;
    @track selectedAssetName;
    @track showDetailPanel  = false;
    @track currencyCode     = 'USD';
    @track linkedQuoteId;
    @track linkedQuoteName;

    // ── Change Order guard ───────────────────────────────────────────────────

    @wire(getRecord, { recordId: '$recordId', fields: [ORIGINAL_ORDER_FIELD, CURRENCY_FIELD] })
    wiredOrder({ data }) {
        if (data) {
            this._isChangeOrder = !!getFieldValue(data, ORIGINAL_ORDER_FIELD);
            this.currencyCode = getFieldValue(data, CURRENCY_FIELD) || 'USD';
        }
    }

    get isChangeOrder()         { return this._isChangeOrder === true; }
    get showChangeOrderButton() { return !this._isChangeOrder; }

    // ── Data ─────────────────────────────────────────────────────────────────

    @wire(getByOrder, { orderId: '$recordId' })
    wiredAssets({ data, error }) {
        this.isLoading = false;
        if (data) {
            this.assets = data
                .filter(a => !(a.Product2?.ProductCode || '').toUpperCase().endsWith('.NR'))
                .map(a => ({
                    ...a,
                    productName: a.Product2 ? a.Product2.Name : a.Name,
                    productCode: a.Product2 ? a.Product2.ProductCode : '',
                    category:    catFromCode(a.Product2 ? a.Product2.ProductCode : ''),
                    attribute:   a.Product_Attribute__c || a.Source_OrderItem__r?.QuoteLineItem?.Product_Attribute_Value__c || '',
                    spaceName:   a.Space__r ? a.Space__r.Name : null,
                    inventoryName: a.Inventory__r ? a.Inventory__r.Name : null,
                    subscriptionId: a.Odoo_Subscription_ID__c || null,
                    aSideAsset:  a.A_Side_Asset__c || null,
                    zSideAsset:  a.Z_Side_Asset__c || null,
                    quantity:    a.Quantity || 1,
                }));
            this.error = undefined;
        } else if (error) {
            this.error = error;
            this.assets = [];
        }
    }

    // ── Stats ────────────────────────────────────────────────────────────────

    get mrcAssets() {
        return this.assets;
    }

    get statServices() { return this.mrcAssets.length; }

    get totalMRCRaw() {
        return this.mrcAssets.reduce((s, a) => s + (a.MRC__c || 0), 0);
    }

    get statTotalMRC() { return this._fmt(this.totalMRCRaw); }

    get lifecycleSummary() {
        const counts = {};
        this.mrcAssets.forEach(a => {
            const s = a.Status || 'Unknown';
            counts[s] = (counts[s] || 0) + 1;
        });
        const items = [];
        if (counts['In Service'])  items.push({ label: counts['In Service'] + ' in service',  cssClass: 'oa-life oa-life_green' });
        if (counts['Active'])      items.push({ label: counts['Active'] + ' active',         cssClass: 'oa-life oa-life_green' });
        if (counts['Pending'])     items.push({ label: counts['Pending'] + ' pending',       cssClass: 'oa-life oa-life_amber' });
        if (counts['In Progress']) items.push({ label: counts['In Progress'] + ' in progress', cssClass: 'oa-life oa-life_amber' });
        if (counts['Inactive'])    items.push({ label: counts['Inactive'] + ' inactive',     cssClass: 'oa-life oa-life_muted' });
        return items;
    }

    get hasLifecycleSummary() { return this.lifecycleSummary.length > 0; }

    // ── Filtering ────────────────────────────────────────────────────────────

    get filteredAssets() {
        let list = this.mrcAssets;
        if (this.activeCategory !== 'All') {
            list = list.filter(a => a.category === this.activeCategory);
        }
        if (this.activeStatus !== 'All') {
            list = list.filter(a => a.Status === this.activeStatus);
        }
        if (this.searchTerm) {
            const t = this.searchTerm.toLowerCase();
            list = list.filter(a =>
                (a.productName            || '').toLowerCase().includes(t) ||
                (a.Name                   || '').toLowerCase().includes(t) ||
                (a.productCode            || '').toLowerCase().includes(t) ||
                (a.Odoo_IB_ID__c          || '').toLowerCase().includes(t) ||
                (a.Odoo_Subscription_ID__c || '').toLowerCase().includes(t)
            );
        }
        return list;
    }

    // ── Grouped (sorted MRC desc) ────────────────────────────────────────────

    get groupedAssets() {
        const items = this.filteredAssets;
        const total = items.reduce((s, a) => s + (a.MRC__c || 0), 0);
        const groupMap = new Map();
        items.forEach(a => {
            const key = (a.Product2 ? a.Product2.Id : '_ungrouped') + '||' + (a.attribute || '');
            if (!groupMap.has(key)) groupMap.set(key, []);
            groupMap.get(key).push(a);
        });

        const allGroups = [];
        for (const [key, groupItems] of groupMap) {
            const mrc = groupItems.reduce((sum, a) => sum + (a.MRC__c || 0), 0);
            const pct = total > 0 ? (mrc / total * 100) : 0;
            const expanded = !!this.expandedGroups[key];

            // Status summary
            const statusCounts = {};
            groupItems.forEach(a => { statusCounts[a.Status || 'Unknown'] = (statusCounts[a.Status || 'Unknown'] || 0) + 1; });
            const statusKeys = Object.keys(statusCounts);
            let statusLabel, statusChipClass;
            if (statusKeys.length === 1) {
                const s = statusKeys[0];
                statusLabel = s;
                statusChipClass = 'oa-chip ' + ((s === 'In Service' || s === 'Active') ? 'oa-chip_green' : (s === 'Pending Change' || s === 'Pending' || s === 'In Progress') ? 'oa-chip_amber' : 'oa-chip_quiet');
            } else {
                const parts = [];
                if (statusCounts['In Service'])  parts.push(statusCounts['In Service'] + ' in service');
                if (statusCounts['Active'])      parts.push(statusCounts['Active'] + ' active');
                if (statusCounts['Pending'])     parts.push(statusCounts['Pending'] + ' pending');
                if (statusCounts['In Progress']) parts.push(statusCounts['In Progress'] + ' in progress');
                statusLabel = parts.join(' · ') || 'Mixed';
                statusChipClass = 'oa-chip oa-chip_mixed';
            }

            // MRC share class for gradient
            let shareClass = 'oa-share-tiny';
            if (pct >= 50) shareClass = 'oa-share-large';
            else if (pct >= 10) shareClass = 'oa-share-mid';
            else if (pct >= 2) shareClass = 'oa-share-small';

            const firstItem = groupItems[0];
            const pName = firstItem.productName || '';
            const hasProduct2 = !!firstItem.Product2;
            const attrSuffix = firstItem.attribute ? ' – ' + firstItem.attribute : '';
            const children = expanded ? groupItems.map(a => {
                let displayName = a.Name || '';
                if (hasProduct2 && pName && displayName.includes(': ' + pName)) {
                    displayName = displayName.split(': ' + pName)[0];
                } else if (hasProduct2 && pName && displayName.endsWith(pName)) {
                    displayName = displayName.slice(0, -pName.length).replace(/[:\s-]+$/, '');
                }
                
                // Build metadata label like in Change Order
                const metaParts = [];
                if (a.spaceName) metaParts.push('Space: ' + a.spaceName);
                if (a.inventoryName) metaParts.push('Breaker: ' + a.inventoryName);
                if (a.subscriptionId) metaParts.push('SID: ' + a.subscriptionId);
                if (a.attribute) metaParts.push(a.attribute);
                if (isCrossConnect(a.productCode) && a.aSideAsset) metaParts.push('A-Side: ' + a.aSideAsset);
                if (isCrossConnect(a.productCode) && a.zSideAsset) metaParts.push('Z-Side: ' + a.zSideAsset);
                const metaLabel = metaParts.join('  -  ');
                
                return {
                    ...a,
                    displayName,
                    metaLabel,
                    mrcFmt:       this._fmt(a.MRC__c),
                    pctFmt:       total > 0 ? ((a.MRC__c || 0) / total * 100).toFixed(1) + '%' : '—',
                    childChipCls: 'oa-chip ' + ((a.Status === 'In Service' || a.Status === 'Active') ? 'oa-chip_indigo' : (a.Status === 'Pending Change' || a.Status === 'Pending' || a.Status === 'In Progress') ? 'oa-chip_amber' : 'oa-chip_quiet'),
                };
            }) : [];

            allGroups.push({
                groupKey:    key,
                groupLabel:  key.startsWith('_ungrouped') ? 'Other' : pName + attrSuffix,
                count:       groupItems.length,
                mrc,
                mrcFmt:      this._fmt(mrc),
                pctRaw:      pct,
                pctFmt:      pct >= 1 ? pct.toFixed(1) + '%' : pct.toFixed(2) + '%',
                pctColor:    pct >= 10 ? 'oa-pct_strong' : 'oa-pct_soft',
                shareClass,
                statusLabel,
                statusChipClass,
                isExpanded:   expanded,
                hasChildren:  expanded,
                chevronClass: 'oa-chev' + (expanded ? ' oa-chev_open' : ''),
                rowClass:     'oa-parent ' + shareClass + (expanded ? ' oa-parent_expanded' : ''),
                children,
            });
        }

        allGroups.sort((a, b) => b.mrc - a.mrc);
        return allGroups;
    }

    get displayGroups() {
        const all = this.groupedAssets;
        if (all.length <= 10 || this.showSmallLines || this.searchTerm || this.activeCategory !== 'All' || this.activeStatus !== 'All') {
            return all;
        }
        return all.slice(0, 10);
    }

    get smallGroups() {
        const all = this.groupedAssets;
        if (all.length <= 10 || this.showSmallLines || this.searchTerm || this.activeCategory !== 'All' || this.activeStatus !== 'All') {
            return [];
        }
        return all.slice(10);
    }

    get hasSmallGroups() { return this.smallGroups.length > 0; }

    get smallGroupsSummary() {
        const sg = this.smallGroups;
        const mrc = sg.reduce((s, g) => s + g.mrc, 0);
        return {
            label: sg.length + ' smaller line' + (sg.length > 1 ? 's' : ''),
            ids:   sg.map(g => g.groupLabel).join(' · '),
            mrcFmt: this._fmt(mrc) + ' combined',
        };
    }

    get hasFilteredAssets() { return this.filteredAssets.length > 0; }
    get isEmpty()          { return !this.isLoading && !this.hasError && this.filteredAssets.length === 0; }
    get hasError()         { return !!this.error; }
    get errorMessage()     { return this.error && (this.error.body ? this.error.body.message : JSON.stringify(this.error)); }

    // ── Pills ────────────────────────────────────────────────────────────────

    get categoryPills() {
        const mrc = this.mrcAssets;
        const counts = {};
        mrc.forEach(a => { counts[a.category] = (counts[a.category] || 0) + 1; });
        return ALL_CATEGORIES
            .filter(c => c === 'All' || counts[c])
            .map(c => ({
                value:    c,
                label:    c,
                count:    c === 'All' ? mrc.length : (counts[c] || 0),
                cssClass: 'oa-pill' + (this.activeCategory === c ? ' oa-pill_active' : ''),
            }));
    }

    get hasCategoryPills() { return this.categoryPills.filter(p => p.value !== 'All').length > 1; }

    get statusPills() {
        const counts = {};
        this.mrcAssets.forEach(a => { counts[a.Status || 'Unknown'] = (counts[a.Status || 'Unknown'] || 0) + 1; });
        const pills = [];
        ['In Service', 'Pending Change', 'Active', 'Closed', 'Pending', 'In Progress', 'Inactive'].forEach(s => {
            if (counts[s]) {
                pills.push({
                    value: s, label: s, count: counts[s],
                    cssClass: 'oa-pill oa-pill-status' + (this.activeStatus === s ? ' oa-pill_active' : ''),
                    dotClass: 'oa-pill-dot' + ((s === 'In Service' || s === 'Active') ? ' oa-pill-dot_green' : (s === 'Pending Change' || s === 'Pending' || s === 'In Progress') ? ' oa-pill-dot_amber' : ''),
                });
            }
        });
        return pills;
    }

    get hasStatusPills() { return this.statusPills.length > 0; }

    get filteredCountLabel() {
        const shown = this.filteredAssets.length;
        const groups = this.groupedAssets.length;
        return `${shown} services across ${groups} product lines`;
    }

    get selectedAssetUrl() { return '/lightning/r/Asset/' + this.selectedAssetId + '/view'; }

    get hasLinkedQuote()  { return !!this.linkedQuoteId; }
    get linkedQuoteUrl()  { return this.linkedQuoteId ? '/lightning/r/Quote/' + this.linkedQuoteId + '/view' : null; }

    // ── Event handlers ───────────────────────────────────────────────────────

    handleSearch(event)         { this.searchTerm = event.target.value; }
    handleCategoryFilter(event) { this.activeCategory = event.currentTarget.dataset.value; }
    handleStatusFilter(event) {
        const val = event.currentTarget.dataset.value;
        this.activeStatus = this.activeStatus === val ? 'All' : val;
    }

    handleGroupToggle(event) {
        event.stopPropagation();
        const key = event.currentTarget.dataset.groupKey;
        this.expandedGroups = { ...this.expandedGroups, [key]: !this.expandedGroups[key] };
    }

    handleShowSmallLines() { this.showSmallLines = true; }

    handleRowClick(event) {
        event.stopPropagation();
        const assetId = event.currentTarget.dataset.id;
        this.selectedAssetId   = assetId;
        this.selectedAssetName = event.currentTarget.dataset.name;
        this.showDetailPanel   = true;

        this.linkedQuoteId   = null;
        this.linkedQuoteName = null;
        const asset = this.assets.find(a => a.Id === assetId);
        if (asset && asset.Status === 'Pending Change') {
            getLinkedChangeOrderQuote({ assetId })
                .then(result => {
                    if (result) {
                        this.linkedQuoteId   = result.quoteId;
                        this.linkedQuoteName = result.quoteName;
                    }
                })
                .catch(() => { /* non-critical enrichment — panel still works without it */ });
        }
    }

    closeDetailPanel() {
        this.showDetailPanel = false;
        this.selectedAssetId = null;
        this.linkedQuoteId   = null;
        this.linkedQuoteName = null;
    }

    handleCreateCO() {
        this._openOrderAction('Order.Create_Change_Order');
    }

    handleRenewTerm() {
        this._openOrderAction('Order.Renewal_Termination');
    }

    _openOrderAction(actionName) {
        const orderId = this.recordId;
        const bg = encodeURIComponent('/lightning/r/Order/' + orderId + '/view');
        this[NavigationMixin.Navigate]({
            type: 'standard__webPage',
            attributes: {
                url: `/lightning/action/quick/${actionName}?backgroundContext=${bg}&objectApiName=Order&recordId=${orderId}`,
            },
        });
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    _fmt(val, currency) {
        return new Intl.NumberFormat('en-US', {
            style: 'currency', currency: currency || this.currencyCode || 'USD',
            minimumFractionDigits: 0, maximumFractionDigits: 0,
        }).format(val || 0);
    }
}