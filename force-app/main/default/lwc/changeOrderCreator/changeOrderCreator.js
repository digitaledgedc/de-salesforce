import { LightningElement, api, track, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CloseActionScreenEvent } from 'lightning/actions';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import ORIGINAL_ORDER_FIELD from '@salesforce/schema/Order.Original_Order__c';
import ORDER_SITE_FIELD from '@salesforce/schema/Order.Operation_Site__c';
import ORDER_DATE_FIELD from '@salesforce/schema/Order.EffectiveDate';
import ORDER_TERM_FIELD from '@salesforce/schema/Order.Contract_Term_Months__c';
import ORDER_NUMBER_FIELD from '@salesforce/schema/Order.Order_Number__c';
import getActiveOrderItems    from '@salesforce/apex/ChangeOrderController.getActiveOrderItems';
import createChangeOrder      from '@salesforce/apex/ChangeOrderController.createChangeOrder';
import searchAvailableProducts from '@salesforce/apex/ChangeOrderController.searchAvailableProducts';
import hasUnlinkedAssets       from '@salesforce/apex/ChangeOrderController.hasUnlinkedAssets';

function isCrossConnect(productCode) {
    if (!productCode) return false;
    const p = productCode.toUpperCase();
    return p.startsWith('CCL') || p.startsWith('CCX') || p.startsWith('DPP') || p.startsWith('RIS');
}

function isNrc(chargeType, billingMode) {
    for (const bm of [chargeType, billingMode]) {
        if (!bm) continue;
        const v = bm.toLowerCase().replace(/_/g, ' ');
        if (v === 'one time' || v === 'nrc' || v.includes('one time') || v.includes('one-time')) return true;
    }
    return false;
}

let _newRowSeq = 1;

function buildAttributeOptions(attrValues, currentVal) {
    const raw = (attrValues || '').split(',').map(v => v.trim()).filter(Boolean);
    const opts = [{ label: '--None--', value: '' }];
    raw.forEach(v => opts.push({ label: v, value: v }));
    if (currentVal && !raw.includes(currentVal)) opts.push({ label: currentVal, value: currentVal });
    return opts;
}

const RENEWAL_TYPE_OPTIONS = [
    { label: 'Negotiated', value: 'Negotiated' },
    { label: 'Auto', value: 'Auto' },
    { label: 'At-Risk', value: 'At-Risk' },
    { label: 'Early Renewal', value: 'Early Renewal' },
];

export default class ChangeOrderCreator extends NavigationMixin(LightningElement) {

    @api recordId;
    @api mode = '';  // 'change' | 'renew-term' | '' 

    @track isLoading       = true;
    @track isReady         = false;
    @track _isChangeOrder  = false;
    @track isSaving        = false;
    @track loadError       = '';
    @track validationError = '';
    @track rows            = [];
    @track searchTerm      = '';
    @track _expandedGroups = {};
    @track currencyCode    = 'USD';
    @track showModal       = false;

    // ── Step management ────────────────────────────────────────────────
    @track step            = 0;       // 0=intent, 1=scope, 2=grid
    @track intent          = '';      // 'upsell' | 'renewal' | 'termination'
    @track scope           = '';      // 'all' | 'select'

    // ── Renewal-specific ───────────────────────────────────────────────
    @track renewalTerm     = 12;
    @track renewalType     = 'Negotiated';
    @track bulkPriceIncrease = 0;
    get renewalTypeOptions() { return RENEWAL_TYPE_OPTIONS; }

    // ── CO date ────────────────────────────────────────────────────────
    @track coDate          = '';

    // ── Add new service state ──────────────────────────────────────────
    @track addSearchTerm   = '';
    @track addSearchResults = [];
    @track showAddDropdown = false;
    @track isAddSearching  = false;
    _addSearchTimer;

    @track orderSite = '';
    @track orderDate = '';
    @track orderTerm = '';
    @track orderNumber = '';

    @wire(getRecord, { recordId: '$recordId', fields: [ORIGINAL_ORDER_FIELD, ORDER_SITE_FIELD, ORDER_DATE_FIELD, ORDER_TERM_FIELD, ORDER_NUMBER_FIELD] })
    wiredOrder({ data }) {
        if (data) {
            if (getFieldValue(data, ORIGINAL_ORDER_FIELD)) {
                this._isChangeOrder = true;
                this.isLoading = false;
            } else {
                this.isLoading = false;
                this.isReady = true;
                
                // If mode is 'change', go directly to step 2 with upsell intent
                if (this.mode === 'change') {
                    this.intent = 'upsell';
                    this.step = 2;
                }
            }
            this.orderSite = getFieldValue(data, ORDER_SITE_FIELD) || '';
            this.orderDate = getFieldValue(data, ORDER_DATE_FIELD) || '';
            this.orderTerm = getFieldValue(data, ORDER_TERM_FIELD) || '';
            this.orderNumber = getFieldValue(data, ORDER_NUMBER_FIELD) || '';
        }
    }

    get isChangeOrder() { return this._isChangeOrder; }

    // ── Data ────────────────────────────────────────────────────────────

    @wire(getActiveOrderItems, { orderId: '$recordId' })
    wiredItems({ data, error }) {
        this.isLoading = false;
        if (data) {
            if (data.length) this.currencyCode = data[0].currencyIsoCode || 'USD';
            this.rows = data.map(d => ({
                rowId:            d.assetId + '_0',
                assetId:          d.assetId,
                itemId:           d.itemId,
                productId:        d.productId,
                pricebookEntryId: d.pricebookEntryId,
                productName:      d.productName,
                productCode:      d.productCode,
                assetName:        d.assetName || '',
                description:      d.description || '',
                status:           d.status || '',
                quantity:         d.quantity,
                unitPrice:        d.unitPrice,
                billingMode:      d.billingMode,
                chargeType:       d.chargeType,
                odooProductId:    d.odooProductId,
                odooIbId:         d.odooIbId || null,
                attribute:        d.attribute || '',
                newAttribute:     d.attribute || '',
                attributeValues:  d.attributeValues || '',
                hasAttribute:     d.hasAttribute || false,
                attributeOptions: buildAttributeOptions(d.attributeValues, d.attribute),
                subscriptionId:   d.subscriptionId || null,
                spaceName:        d.spaceName || null,
                inventoryName:    d.inventoryName || null,
                aSideAsset:       d.aSideAsset || null,
                zSideAsset:       d.zSideAsset || null,
                changeType:       'NO_CHANGE',
                newQuantity:      d.quantity,
                newUnitPrice:     d.unitPrice,
                isNew:            false,
            }));
            if (data.length === 0) {
                this._checkUnlinkedAssets();
            } else {
                this.isReady = true;
            }
        } else if (error) {
            this.loadError = (error.body && error.body.message)
                ? error.body.message : 'Failed to load services.';
        }
    }

    _checkUnlinkedAssets() {
        hasUnlinkedAssets({ orderId: this.recordId })
            .then(result => {
                if (result) {
                    this.loadError = 'This order has services that were imported without asset linkage. Change orders, renewals, and terminations are not available for imported orders.';
                } else {
                    this.isReady = true;
                }
            })
            .catch(() => {
                this.isReady = true;
            });
    }

    // ── Step getters ────────────────────────────────────────────────────

    get isStep0() { return this.step === 0; }
    get isStep1() { return this.step === 1; }
    get isStep2() { return this.step === 2; }

    get currentTotalMrc() {
        const total = this.mrcRows.reduce((s, r) => s + ((r.quantity || 0) * (r.unitPrice || 0)), 0);
        return this._fmt(total);
    }

    get uniqueProductCount() {
        const products = new Set();
        this.mrcRows.forEach(r => { if (r.productId) products.add(r.productId); });
        return products.size;
    }

    get isUpsellIntent()      { return this.intent === 'upsell'; }
    get isRenewalIntent()     { return this.intent === 'renewal'; }
    get isTerminationIntent() { return this.intent === 'termination'; }
    get showRenewalFields()   { return this.intent === 'renewal'; }

    get intentLabel() {
        if (this.intent === 'upsell') return 'Change Order';
        if (this.intent === 'renewal') return 'Renewal';
        if (this.intent === 'termination') return 'Termination';
        return 'Change Order';
    }

    get scopeQuestion() {
        if (this.intent === 'renewal') return 'Which services are you renewing?';
        return 'Which services are you terminating?';
    }

    get allItemsDesc() {
        if (this.intent === 'renewal') return 'Renew all services on this order with updated pricing';
        return 'Terminate all services on this order';
    }

    get selectItemsDesc() {
        if (this.intent === 'renewal') return 'Choose which services to renew. Services not selected will continue as-is.';
        return 'Choose which services to terminate. Services not selected will continue as-is.';
    }

    get gridTitle() {
        if (this.intent === 'upsell') return 'Select services to change or remove';
        if (this.intent === 'renewal') return 'Set renewal pricing for each service';
        return 'Confirm services to terminate';
    }

    get submitLabel() {
        if (this.intent === 'renewal') return 'Create Renewal';
        if (this.intent === 'termination') return 'Create Termination';
        return 'Create Change Order';
    }

    get savingLabel() {
        if (this.intent === 'renewal') return 'Creating Renewal...';
        if (this.intent === 'termination') return 'Creating Termination Order...';
        return 'Creating Change Order...';
    }

    // ── Step handlers ──────────────────────────────────────────────────

    handleIntentSelect(event) {
        const selected = event.currentTarget.dataset.intent;
        this.validationError = '';
        this.intent = selected;
        if (this.intent === 'termination') {
            // Skip the scope picker — go straight to the grid with every
            // line pre-marked for termination (matches "All Items" scope).
            this.scope = 'all';
            this.rows = this.rows.map(r => r.isNew ? r : { ...r, changeType: 'DELETE' });
            this.step = 2;
        } else {
            // For renewal, go to scope selector (step 1)
            this.step = 1;
        }
    }

    handleScopeSelect(event) {
        this.scope = event.currentTarget.dataset.scope;
        if (this.intent === 'renewal') {
            if (this.scope === 'all') {
                this.rows = this.rows.map(r => r.isNew ? r : { ...r, changeType: 'RENEW' });
            } else {
                // Select mode: user picks what to renew. Start unchecked.
                this.rows = this.rows.map(r => r.isNew ? r : { ...r, changeType: 'NO_CHANGE' });
            }
        } else if (this.intent === 'termination') {
            if (this.scope === 'all') {
                this.rows = this.rows.map(r => r.isNew ? r : { ...r, changeType: 'DELETE' });
            } else {
                // Select mode: user picks what to terminate. Start unchecked.
                this.rows = this.rows.map(r => r.isNew ? r : { ...r, changeType: 'NO_CHANGE' });
            }
        }
        this.step = 2;
    }

    handleBackToStep0() {
        this.step = 0;
        this.intent = '';
        this.scope = '';
        this._setAllRowsToDefault();
    }

    handleBackFromGrid() {
        if (this.intent === 'upsell') {
            // For upsell (change mode), going back means cancel/close
            this.handleCancel();
        } else if (this.intent === 'termination') {
            // Termination skips the scope picker entirely — back goes to intent picker
            this.handleBackToStep0();
        } else {
            this.step = 1;
        }
    }

    _setAllRowsToDefault() {
        this.rows = this.rows
            .filter(r => !r.isNew)
            .map(r => ({ ...r, changeType: 'NO_CHANGE', newQuantity: r.quantity, newUnitPrice: r.unitPrice, newAttribute: r.attribute }));
    }

    handleTermChange(event) {
        this.renewalTerm = parseInt(event.detail.value, 10) || 12;
    }

    handleRenewalTypeChange(event) {
        this.renewalType = event.detail.value;
    }

    handleBulkPriceApply(event) {
        const pct = parseFloat(event.detail.value) || 0;
        this.bulkPriceIncrease = pct;
        const factor = 1 + (pct / 100);
        this.rows = this.rows.map(r => {
            if (r.changeType === 'RENEW' && !r.isNew) {
                return { ...r, newUnitPrice: Math.round(r.unitPrice * factor * 100) / 100 };
            }
            return r;
        });
    }

    // ── Computed ─────────────────────────────────────────────────────────

    get mrcRows()      { return this.rows.filter(r => !isNrc(r.chargeType, r.billingMode)); }
    get totalRows()    { return this.mrcRows.length; }
    get changedCount() { return this.rows.filter(r => r.changeType !== 'NO_CHANGE').length; }
    get newRows()      { return this.rows.filter(r => r.isNew); }
    get hasNewRows()   { return this.newRows.length > 0; }

    get filteredRows() {
        let list = this.mrcRows;
        if (this.searchTerm) {
            const t = this.searchTerm.toLowerCase();
            list = list.filter(r =>
                r.productName.toLowerCase().includes(t) ||
                (r.assetName      || '').toLowerCase().includes(t) ||
                (r.description    || '').toLowerCase().includes(t) ||
                (r.subscriptionId || '').toLowerCase().includes(t) ||
                (r.spaceName      || '').toLowerCase().includes(t) ||
                (r.inventoryName  || '').toLowerCase().includes(t)
            );
        }
        return list;
    }

    get groupedRows() {
        const items = this.filteredRows;
        const groupMap = new Map();
        items.forEach(r => {
            const key = (r.productId || '_ungrouped') + '||' + (r.attribute || '');
            if (!groupMap.has(key)) groupMap.set(key, []);
            groupMap.get(key).push(r);
        });

        const groups = [];
        for (const [key, groupItems] of groupMap) {
            const mrc = groupItems.reduce((s, r) => s + (r.quantity || 0) * (r.unitPrice || 0), 0);
            const renewCount = groupItems.filter(r => r.changeType === 'RENEW').length;
            const deleteCount = groupItems.filter(r => r.changeType === 'DELETE').length;
            const changed = groupItems.filter(r => r.changeType !== 'NO_CHANGE').length;
            const isExpanded = this.searchTerm
                ? true
                : (this._expandedGroups[key] || false);
            const firstRow = groupItems[0];
            const isRenTerm = this.intent === 'renewal' || this.intent === 'termination';
            const changedLabel = isRenTerm
                ? (renewCount > 0 ? renewCount + ' renew' : '') + (renewCount > 0 && deleteCount > 0 ? ', ' : '') + (deleteCount > 0 ? deleteCount + ' end' : '')
                : changed + ' changed';
            groups.push({
                groupKey:   key,
                groupLabel: key.startsWith('_ungrouped') ? 'Other' : firstRow.productName,
                count:      groupItems.length,
                mrcFmt:     this._fmt(mrc),
                changed:    changedLabel,
                hasChanges: changed > 0,
                isExpanded,
                chevron:    isExpanded ? '▾' : '▸',
                items:      groupItems.map(r => this._enrich(r)),
            });
        }
        groups.sort((a, b) => {
            const ma = a.items.reduce((s, r) => s + (r.quantity || 0) * (r.unitPrice || 0), 0);
            const mb = b.items.reduce((s, r) => s + (r.quantity || 0) * (r.unitPrice || 0), 0);
            return mb - ma;
        });
        return groups;
    }

    get noFilteredRows() { return this.isReady && this.filteredRows.length === 0; }
    get noAddResults()   { return !this.isAddSearching && this.addSearchResults.length === 0; }

    get addSearchComboClass() {
        return 'co-add-combobox' + (this.showAddDropdown ? ' co-add-combobox_open' : '');
    }

    get statsLabel() {
        const c = this.changedCount;
        const renew = this.rows.filter(r => r.changeType === 'RENEW').length;
        const del = this.rows.filter(r => r.changeType === 'DELETE').length;

        if (this.intent === 'renewal' || this.intent === 'termination') {
            return `${this.totalRows} services - ${renew} renew - ${del} terminate`;
        }

        let label = this.totalRows + ' services';
        if (c > 0) label += ' - ' + c + ' changed';
        if (this.newRows.length > 0) label += ' - ' + this.newRows.length + ' new';
        return label;
    }

    // ── Net impact ──────────────────────────────────────────────────────

    get netImpact() {
        let total = 0;
        this.rows.forEach(r => {
            if (r.changeType === 'NO_CHANGE') return;
            if (r.changeType === 'RENEW') {
                // Renewal: net impact = new price - old price (per unit * qty)
                total += ((r.newUnitPrice || 0) - (r.unitPrice || 0)) * (r.quantity || 1);
                return;
            }
            const cur = r.isNew ? 0 : (r.quantity || 0) * (r.unitPrice || 0);
            const nxt = r.changeType === 'DELETE' ? 0
                : (r.newQuantity || 0) * (r.newUnitPrice || 0);
            total += nxt - cur;
        });
        return total;
    }

    get netImpactFormatted() {
        const v = this.netImpact;
        const sign = v >= 0 ? '+ ' : '- ';
        return sign + this._fmt(Math.abs(v)) + ' / mo';
    }

    get netImpactIsPositive() { return this.netImpact > 0; }
    get netImpactIsNegative() { return this.netImpact < 0; }

    // ── Row enrichment ──────────────────────────────────────────────────

    _enrich(r) {
        const isChange = r.changeType === 'CHANGE';
        const isDelete = r.changeType === 'DELETE';
        const isRenew  = r.changeType === 'RENEW';
        const isNew    = r.isNew === true;
        const curMrc   = isNew ? 0 : (r.quantity || 0) * (r.unitPrice || 0);
        const newMrc   = isDelete ? 0
            : (isChange || isNew) ? (r.newQuantity || 0) * (r.newUnitPrice || 0)
            : isRenew ? (r.quantity || 0) * (r.newUnitPrice || 0)
            : curMrc;
        const delta    = newMrc - curMrc;

        let code = '';
        if (r.assetName && r.productName && r.assetName.includes(': ')) {
            code = r.assetName.split(': ')[0];
        } else {
            code = r.odooIbId ? ('IB-' + r.odooIbId) : (r.subscriptionId || r.productCode || '');
        }

        const renewPriceChanged = isRenew && r.newUnitPrice !== r.unitPrice;

        return {
            ...r,
            curMrcFmt:    isNew ? 'NEW' : this._fmt(curMrc),
            codeLabel:    code,
            displayName:  r.productName,
            metaLabel:    [
                r.spaceName      ? 'Space: '   + r.spaceName      : null,
                r.inventoryName  ? 'Breaker: ' + r.inventoryName  : null,
                r.subscriptionId ? 'SID: '     + r.subscriptionId : null,
                r.attribute      ? r.attribute                    : null,
                isCrossConnect(r.productCode) && r.aSideAsset ? 'A-Side: ' + r.aSideAsset : null,
                isCrossConnect(r.productCode) && r.zSideAsset ? 'Z-Side: ' + r.zSideAsset : null,
            ].filter(Boolean).join('  -  '),
            isChange,
            isDelete,
            isNew,
            isRenew,
            isRenewUnchanged: isRenew && !renewPriceChanged,
            showRemoveLabel: isDelete && this.intent === 'upsell',
            showEdit:     isChange || isNew || (isRenew && this.intent === 'renewal'),
            rowClass:     'co-row'
                + (isChange ? ' co-row_change' : '')
                + (isDelete ? ' co-row_remove' : '')
                + (isNew    ? ' co-row_new'    : '')
                + (isRenew  ? ' co-row_renew'  : '')
                ,
            changeClass:  'co-act co-act_change' + (isChange ? ' co-act_on' : ''),
            renewClass:   'co-act co-act_renew'  + (isRenew  ? ' co-act_on' : ''),
            removeClass:  'co-act co-act_remove' + (isDelete ? ' co-act_on' : ''),
            showChange:   !isNew,
            removeLabel:  this.intent === 'termination' || this.intent === 'renewal'
                ? 'This service will be terminated.' : 'This service will be removed from the order.',
            newMrcFmt:    this._fmt(newMrc),
            deltaFmt:     delta !== 0 ? ((delta > 0 ? '+' : '') + this._fmt(delta)) : '',
            deltaClass:   'co-delta' + (delta > 0 ? ' co-delta_up' : delta < 0 ? ' co-delta_down' : ''),
        };
    }

    // ── Handlers ────────────────────────────────────────────────────────

    handleSearch(event)  { this.searchTerm = event.target.value; }

    handleDateChange(event) {
        this.coDate = event.detail.value || '';
        this.validationError = '';
    }

    handleGroupToggle(event) {
        const key = event.currentTarget.dataset.groupKey;
        this._expandedGroups = { ...this._expandedGroups, [key]: !this._expandedGroups[key] };
    }

    handleActionClick(event) {
        const rowId  = event.currentTarget.dataset.rowId;
        const action = event.currentTarget.dataset.value;
        const row    = this.rows.find(r => r.rowId === rowId);
        if (!row) return;

        let changeType;
        if (this.intent === 'termination') {
            // Termination: toggle between DELETE and NO_CHANGE (continue as-is)
            changeType = (row.changeType === 'DELETE') ? 'NO_CHANGE' : 'DELETE';
        } else if (this.intent === 'renewal') {
            // Renewal: toggle between RENEW and DELETE
            changeType = (row.changeType === action) ? (action === 'RENEW' ? 'DELETE' : 'RENEW') : action;
        } else {
            changeType = (row.changeType === action) ? 'NO_CHANGE' : action;
        }

        if (changeType === 'NO_CHANGE' || changeType === 'DELETE') {
            this.rows = this.rows.map(r => r.rowId === rowId
                ? { ...r, changeType, newQuantity: r.quantity, newUnitPrice: r.unitPrice, newAttribute: r.attribute }
                : r);
        } else if (changeType === 'RENEW') {
            // RENEW: keep current values, user can edit price
            this.rows = this.rows.map(r =>
                r.rowId === rowId ? { ...r, changeType, newQuantity: r.quantity, newUnitPrice: r.unitPrice } : r
            );
        } else {
            this.rows = this.rows.map(r =>
                r.rowId === rowId ? { ...r, changeType } : r
            );
        }
        this.validationError = '';
    }

    handleRemoveNew(event) {
        const rowId = event.currentTarget.dataset.rowId;
        this.rows = this.rows.filter(r => r.rowId !== rowId);
    }

    handleLineFieldChange(event) {
        const rowId = event.currentTarget.dataset.rowId;
        const field = event.currentTarget.dataset.field;
        const val   = field === 'newAttribute'
            ? (event.detail.value || '')
            : (parseFloat(event.detail.value) || 0);
        this.rows = this.rows.map(r =>
            r.rowId === rowId ? { ...r, [field]: val } : r
        );
    }

    handleCancel() {
    this.dispatchEvent(new CloseActionScreenEvent());
    //if CloseActionScreenEvent doesn't close the screen, navigate back to the Order record page
    this[NavigationMixin.Navigate]({
        type: 'standard__recordPage',
        attributes: {
            recordId: this.recordId,
            actionName: 'view',
        },
    });
}
    // ── Modal handlers ───────────────────────────────────────────────────

    handleModalCancel() {
        this.showModal = false;
    }

    async handleModalConfirm() {
        this.showModal = false;
        await this._createChangeOrder();
    }

    // ── Add new service search ──────────────────────────────────────────

    handleAddSearchInput(event) {
        this.addSearchTerm = event.target.value;
        clearTimeout(this._addSearchTimer);
        if (this.addSearchTerm.length < 2) {
            this.addSearchResults = [];
            this.showAddDropdown = false;
            return;
        }
        this.showAddDropdown = true;
        this.isAddSearching  = true;
        this._addSearchTimer = setTimeout(() => this._runAddSearch(), 300);
    }

    handleAddSearchFocus() {
        if (this.addSearchTerm.length >= 2 && this.addSearchResults.length > 0) {
            this.showAddDropdown = true;
        }
    }

    handleAddSearchBlur() {
        setTimeout(() => { this.showAddDropdown = false; }, 200);
    }

    _runAddSearch() {
        searchAvailableProducts({ orderId: this.recordId, searchTerm: this.addSearchTerm })
            .then(results => {
                this.addSearchResults = results.map(r => ({
                    ...r,
                    label: r.productName + ' (' + r.productCode + ')',
                    priceFmt: this._fmt(r.unitPrice),
                }));
                this.showAddDropdown = true;
            })
            .catch(() => { this.addSearchResults = []; })
            .finally(() => { this.isAddSearching = false; });
    }

    handleAddProductSelect(event) {
        const pbeId = event.currentTarget.dataset.id;
        const result = this.addSearchResults.find(r => r.pbeId === pbeId);
        if (!result) return;

        this.addSearchTerm    = '';
        this.addSearchResults = [];
        this.showAddDropdown  = false;

        const rowId = 'new_' + (_newRowSeq++);
        const attrValues = result.attributeValues || '';
        this.rows = [...this.rows, {
            rowId,
            assetId:          null,
            itemId:           null,
            productId:        result.productId,
            pricebookEntryId: result.pbeId,
            productName:      result.productName,
            productCode:      result.productCode,
            assetName:        '',
            description:      '',
            status:           'New',
            quantity:         0,
            unitPrice:        result.unitPrice,
            billingMode:      result.billingMode || null,
            odooProductId:    result.odooProductId || null,
            subscriptionId:   null,
            spaceName:        null,
            inventoryName:    null,
            changeType:       'NEW',
            newQuantity:      1,
            newUnitPrice:     result.unitPrice,
            isNew:            true,
            attribute:        '',
            newAttribute:     '',
            attributeValues:  attrValues,
            hasAttribute:     !!(result.attributeType),
            attributeOptions: buildAttributeOptions(attrValues, ''),
        }];
    }

    // ── Submit ──────────────────────────────────────────────────────────

    async handleSubmit() {
        this.validationError = '';

        if (!this.coDate) {
            this.validationError = 'Requested Delivery Date is required.';
            return;
        }

        // For renewal/termination: every line must have RENEW or DELETE
        if (this.intent === 'renewal' || this.intent === 'termination') {
            const undecided = this.mrcRows.filter(r => !r.isNew && r.changeType === 'NO_CHANGE');
            if (undecided.length > 0) {
                this.validationError = `${undecided.length} service(s) have no action assigned. Every line must be either renewed or terminated.`;
                return;
            }
        }

        const changedRows = this.rows.filter(r => r.changeType !== 'NO_CHANGE');

        // If no changes, show confirmation modal
        if (changedRows.length === 0) {
            this.showModal = true;
            return;
        }

        // Validate renewal term
        if (this.intent === 'renewal' && (!this.renewalTerm || this.renewalTerm < 1)) {
            this.validationError = 'Contract term must be at least 1 month.';
            return;
        }

        // Validate required attributes
        const missingAttr = changedRows.find(r => r.hasAttribute && r.changeType !== 'DELETE' && !(r.newAttribute || '').trim());
        if (missingAttr) {
            this.validationError = `Attribute is required for "${missingAttr.productName}". Please select a value before submitting.`;
            return;
        }

        await this._createChangeOrder();
    }

    async _createChangeOrder() {
        const changedRows = this.rows.filter(r => r.changeType !== 'NO_CHANGE');

        // Determine order type and amendment reason
        let coType, amendmentReason;
        if (this.intent === 'renewal') {
            coType = 'Renewal';
            amendmentReason = 'Renewal';
        } else if (this.intent === 'termination') {
            coType = this._deriveCoType(changedRows, true);
            amendmentReason = this._deriveAmendmentReason(coType, changedRows);
        } else {
            // Change Order (upsell) intent: never classify as Churn/Partial Churn
            // even if every line was removed — that only happens via the dedicated
            // Termination flow. Removing everything through a Change Order is
            // still an Amendment, not a Termination.
            coType = this._deriveCoType(changedRows, false);
            amendmentReason = this._deriveAmendmentReason(coType, changedRows);
        }

        this.isSaving = true;
        try {
            const linesJson = JSON.stringify(this.rows.map(r => {
                let effectiveChangeType = r.changeType;
                if (r.changeType === 'CHANGE') {
                    const priceChanged = r.newUnitPrice !== r.unitPrice;
                    const qtyChanged   = r.newQuantity  !== r.quantity;
                    const attrChanged  = (r.newAttribute || '') !== (r.attribute || '');
                    if (priceChanged && !qtyChanged && !attrChanged) effectiveChangeType = 'CHANGE_PRICE';
                } else if (r.changeType === 'RENEW') {
                    // Change_Type__c has no RENEW value (restricted picklist) — translate
                    // renewed lines into the same NO_CHANGE/CHANGE/CHANGE_PRICE vocabulary
                    // used by Change Orders, based on what actually changed on renewal.
                    const priceChanged = r.newUnitPrice !== r.unitPrice;
                    const qtyChanged   = r.newQuantity  !== r.quantity;
                    const attrChanged  = (r.newAttribute || '') !== (r.attribute || '');
                    if (!priceChanged && !qtyChanged && !attrChanged) {
                        effectiveChangeType = 'NO_CHANGE';
                    } else if (priceChanged && !qtyChanged && !attrChanged) {
                        effectiveChangeType = 'CHANGE_PRICE';
                    } else {
                        effectiveChangeType = 'CHANGE';
                    }
                }
                return {
                    itemId:           r.itemId,
                    assetId:          r.assetId,
                    productId:        r.productId,
                    pricebookEntryId: r.pricebookEntryId,
                    productCode:      r.productCode || '',
                    changeType:       effectiveChangeType,
                    quantity:         r.quantity,
                    unitPrice:        r.unitPrice,
                    newQuantity:      r.changeType === 'RENEW' ? r.quantity : r.newQuantity,
                    newUnitPrice:     r.newUnitPrice,
                    billingMode:      r.billingMode,
                    odooProductId:    r.odooProductId,
                    odooIbId:         r.odooIbId,
                    description:      r.description,
                    attribute:        r.newAttribute || null,
                };
            }));

            const quoteId = await createChangeOrder({
                originalOrderId:    this.recordId,
                orderType:          coType,
                amendmentReason:    amendmentReason,
                rddStr:             this.coDate,
                poReference:        null,
                linesJson,
                newBillingAccountId: null,
            });

            this.dispatchEvent(new ShowToastEvent({
                title: this.intentLabel + ' Created',
                message: 'Draft Quote created for review.',
                variant: 'success',
            }));

            this.dispatchEvent(new CloseActionScreenEvent());
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: { recordId: quoteId, actionName: 'view' },
            });

        } catch (err) {
            const msg = (err.body && err.body.message) ? err.body.message : 'Failed to create order.';
            this.validationError = msg;
            this.dispatchEvent(new ShowToastEvent({ title: 'Error', message: msg, variant: 'error' }));
        } finally {
            this.isSaving = false;
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    // allowChurn: only true for the dedicated Termination flow. When false
    // (Change Order / upsell intent), removing lines never classifies the
    // quote as Churn/Partial Churn — it stays an Amendment regardless of
    // how many lines were deleted.
    _deriveCoType(changedRows, allowChurn) {
        const hasDeletes  = changedRows.some(r => r.changeType === 'DELETE');
        const hasChanges  = changedRows.some(r => r.changeType !== 'DELETE' && r.changeType !== 'NEW' && r.changeType !== 'RENEW');
        const hasNew      = changedRows.some(r => r.changeType === 'NEW');
        const hasRenew    = changedRows.some(r => r.changeType === 'RENEW');
        const totalRows   = this.mrcRows.filter(r => !r.isNew).length;

        if (allowChurn) {
            if (hasDeletes && !hasChanges && !hasNew && !hasRenew
                && changedRows.filter(r => r.changeType === 'DELETE').length === totalRows) return 'Churn';
            if (hasDeletes && !hasNew && !hasRenew) return 'Partial Churn';
        }
        return 'Change/Upsell';
    }

    _deriveAmendmentReason(coType, changedRows) {
        if (coType === 'Churn')         return 'End_of_Term';
        if (coType === 'Partial Churn') return 'Capacity_Reduction';
        const hasNew = changedRows.some(r => r.changeType === 'NEW');
        if (hasNew) return 'Upsell_New_Add';
        const changes = changedRows.filter(r => r.changeType === 'CHANGE');
        const hasPrice = changes.some(r => r.newUnitPrice !== r.unitPrice);
        const hasQty   = changes.some(r => r.newQuantity !== r.quantity);
        const hasAttr  = changes.some(r => (r.newAttribute || '') !== (r.attribute || ''));
        if (hasPrice && !hasQty && !hasAttr) return 'Price_Change';
        if (hasQty   && !hasPrice && !hasAttr) return 'Quantity_Change';
        if (hasAttr) return 'Product_Change';
        return 'Product_Change';
    }

    _fmt(val, currency) {
        return new Intl.NumberFormat('en-US', {
            style: 'currency', currency: currency || this.currencyCode || 'USD',
            minimumFractionDigits: 0, maximumFractionDigits: 0,
        }).format(val || 0);
    }
    get currencySymbol() {
        const cur = this.currencyCode || 'USD';
        const symbols = {
            'USD': '$',
            'PHP': '₱',
            'EUR': '€',
            'GBP': '£',
            'JPY': '¥',
            'SGD': 'S$',
            'MYR': 'RM',
            'IDR': 'Rp',
            'AUD': 'A$',
            'CAD': 'C$',
            'CNY': '¥',
            'KRW': '₩',
            'INR': '₹',
            'BRL': 'R$',
            'MXN': '$',
            'NZD': 'NZ$',
            'CHF': 'Fr',
            'SEK': 'kr',
            'NOK': 'kr',
            'DKK': 'kr',
            'ZAR': 'R',
            'ILS': '₪',
            'AED': 'د.إ',
            'SAR': '﷼',
            'TRY': '₺',
            'RUB': '₽',
            'PLN': 'zł',
            'THB': '฿',
            'VND': '₫',
            'TWD': 'NT$',
            'HKD': 'HK$',
        };
        return symbols[cur] || cur;
    }
}