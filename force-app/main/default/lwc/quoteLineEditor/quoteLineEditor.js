/* quoteLineEditor v2 — 2026-06-23 */
import { LightningElement, api, wire, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import { getRecord, getFieldValue, updateRecord, getRecordNotifyChange } from 'lightning/uiRecordApi';
import { registerRefreshHandler, unregisterRefreshHandler } from 'lightning/refresh';
import PRICEBOOK2_FIELD      from '@salesforce/schema/Quote.Pricebook2Id';
import CURRENCY_FIELD        from '@salesforce/schema/Quote.CurrencyIsoCode';
import IS_BINDING_FIELD      from '@salesforce/schema/Quote.Is_Binding__c';
import STATUS_FIELD          from '@salesforce/schema/Quote.Status';
import ORIGINAL_ORDER_FIELD  from '@salesforce/schema/Quote.Original_Order__c';
import CONTRACT_END_DATE_FIELD from '@salesforce/schema/Quote.Contract_End_Date__c';
import RDD_FIELD               from '@salesforce/schema/Quote.RDD__c';
import getQuoteLineItems      from '@salesforce/apex/QuoteLineEditorController.getQuoteLineItems';
import getQuotePricebookInfo  from '@salesforce/apex/QuoteLineEditorController.getQuotePricebookInfo';
// searchProducts import removed — inline search disabled, products added via Add Product action
import addProductToQuote      from '@salesforce/apex/QuoteLineEditorController.addProductToQuote';
import deleteQuoteLineItems   from '@salesforce/apex/QuoteLineEditorController.deleteQuoteLineItems';
import updateQuoteLineItems   from '@salesforce/apex/QuoteLineEditorController.updateQuoteLineItems';
import reorderQuoteLineItem   from '@salesforce/apex/QuoteLineEditorController.reorderQuoteLineItem';
import getLineInventory       from '@salesforce/apex/InventoryController.getLineInventory';
import assignInventoryToLine  from '@salesforce/apex/InventoryController.assignInventoryToLine';
import releaseInventoryFromLine from '@salesforce/apex/InventoryController.releaseInventoryFromLine';
import splitRampLines          from '@salesforce/apex/QuoteLineEditorController.splitRampLines';
import splitRampLinesBulk      from '@salesforce/apex/QuoteLineEditorController.splitRampLinesBulk';
import aggregateRampNrcQty     from '@salesforce/apex/QuoteLineEditorController.aggregateRampNrcQty';
import getRampSiblings         from '@salesforce/apex/QuoteLineEditorController.getRampSiblings';
import deleteRampPhases        from '@salesforce/apex/QuoteLineEditorController.deleteRampPhases';
import addRampPhase            from '@salesforce/apex/QuoteLineEditorController.addRampPhase';
import getColumnPreferences    from '@salesforce/apex/QuoteLineEditorController.getColumnPreferences';
import saveColumnPreferences   from '@salesforce/apex/QuoteLineEditorController.saveColumnPreferences';
import saveAutoSavePreference  from '@salesforce/apex/QuoteLineEditorController.saveAutoSavePreference';
import getQuoteSiteInfo        from '@salesforce/apex/InventoryController.getQuoteSiteInfo';
import createInventoryRecords  from '@salesforce/apex/DeInventoryManagerController.createInventoryRecords';
import getFloorsBySite         from '@salesforce/apex/DeInventoryManagerController.getFloorsBySite';
import getHallsByFloor         from '@salesforce/apex/DeInventoryManagerController.getHallsByFloor';
import updateCrossId         from '@salesforce/apex/DeInventoryManagerController.updateCrossId';
import getActiveApprovals        from '@salesforce/apex/QuoteLineEditorController.getActiveApprovals';
import getBillingAccountOptions  from '@salesforce/apex/QuoteLineEditorController.getBillingAccountOptions';

// Column definition registry — keyed by column ID
const ALL_COLS = {
    // Preview icon — opens the right-side detail panel
    view_btn: {
        type: 'button-icon', fixedWidth: 30,
        typeAttributes: { iconName: { fieldName: '_viewIcon' }, name: 'view', title: { fieldName: '_viewTitle' }, variant: 'bare' }
    },
    // Product name as URL (truncates cleanly)
    productName: {
        label: 'Product', fieldName: 'lineUrl', type: 'url', initialWidth: 220,
        typeAttributes: { label: { fieldName: 'productName' }, target: '_top' },
        editable: false, wrapText: false
    },
    productCode:    { label: 'Code',          fieldName: 'productCode',         type: 'text',       initialWidth: 100, editable: false, wrapText: false },
    Product_Attribute_Value__c: {
        label: 'Attribute', fieldName: 'Product_Attribute_Value__c',
        type: 'attributePicklist', initialWidth: 140,
        typeAttributes: {
            options: { fieldName: '_attributeOptions' },
            rowId: { fieldName: 'Id' },
            hasAttribute: { fieldName: '_hasAttribute' },
            disabled: { fieldName: '_attrDisabled' },
            // FB-455/FB-960: Custom_Attribute_Value__c is Text on the object, but must only
            // ever hold a number — restrict the fallback custom-value input accordingly.
            customValueInputType: 'number'
        }
    },
    attributeType: { label: 'Attr Type', fieldName: '_attributeType', type: 'text', initialWidth: 130, editable: false, wrapText: false },
    productFamily:  { label: 'Family',        fieldName: 'productFamily',        type: 'text',       initialWidth: 110, editable: false, wrapText: false },
    // SFDC-366: UoM is now a per-line value, chosen from the product's default plus
    // Product2.Allowed_UoM__c. The ALL_COLS key stays 'productUnit' — INITIAL_COL_DEFS
    // and the saved column-preference bitstring index on it positionally, so renaming
    // or moving it would silently discard every user's saved layout.
    // editable stays false: the editOptions render path never consults it, and false
    // keeps handleCellClick from opening a text input over the visible <select>.
    productUnit:    { label: 'UoM',           fieldName: 'UoM__c',               type: 'text',       initialWidth:  95, editable: false, wrapText: false,
                      editOptionsField: '_uomOptions' },
    Quantity: {
        label: 'Qty', fieldName: 'Quantity', type: 'number', initialWidth: 75, editable: true,
        typeAttributes: { minimumFractionDigits: 0, maximumFractionDigits: 4 },
        cellAttributes: { alignment: 'left' }
    },
    ListPrice: {
        label: 'List Price', fieldName: 'List_Price__c', type: 'currency', initialWidth: 115, editable: false,
        typeAttributes: { currencyCode: { fieldName: 'CurrencyIsoCode' }, minimumFractionDigits: 2 }
    },
    UnitPrice: {
        label: 'Sales Price', fieldName: 'UnitPrice', type: 'currency', initialWidth: 120, editable: true,
        typeAttributes: { currencyCode: { fieldName: 'CurrencyIsoCode' }, minimumFractionDigits: 2 }
    },
    Discount: {
        label: 'Discount (%)', fieldName: 'Discount', type: 'number', initialWidth: 100, editable: true,
        typeAttributes: { minimumFractionDigits: 0, maximumFractionDigits: 2 },
        cellAttributes: { alignment: 'left' }
    },
    TotalPrice: {
        label: 'Total Price', fieldName: 'TotalPrice', type: 'currency', initialWidth: 120, editable: false,
        typeAttributes: { currencyCode: { fieldName: 'CurrencyIsoCode' }, minimumFractionDigits: 2 }
    },
    BillingFrequency: { label: 'Billing',    fieldName: 'BillingFrequency',    type: 'text',       initialWidth: 90,  editable: false, wrapText: false },
    StartDate:        { label: 'Start',       fieldName: 'StartDate',           type: 'date-local', initialWidth: 110, editable: true   },
    EndDate:          { label: 'End',         fieldName: 'EndDate',             type: 'date-local', initialWidth: 110, editable: true   },
    Ramp_Phase__c: {
        label: 'Ramp Phase', fieldName: 'Ramp_Phase__c', type: 'text', initialWidth: 100, editable: false,
    },
    Ramp_Start_Date__c: { label: 'Ramp Start', fieldName: 'Ramp_Start_Date__c', type: 'date-local', initialWidth: 110, editable: false },
    Reserved__c: {
        label: 'Reserved', fieldName: 'Reserved__c', type: 'text', initialWidth: 110, editable: true, wrapText: false,
        editOptions: [
            { label: 'Reserved', value: 'Reserved' },
            { label: 'Not Reserved', value: 'Not Reserved' },
            { label: 'N/A', value: 'N/A' }
        ]
    },
    Charge_Type__c: { label: 'Charge Type', fieldName: 'Charge_Type__c', type: 'text', initialWidth: 100, editable: false, wrapText: false },
    Charge_Frequency__c: { label: 'Frequency', fieldName: 'Charge_Frequency__c', type: 'text', initialWidth: 100, editable: false, wrapText: false },
    Billing_Mode__c: {
        label: 'Billing Mode', fieldName: 'Billing_Mode__c', type: 'text', initialWidth: 110, editable: true, wrapText: false,
        editOptions: [
            { label: 'Advance', value: 'Advance' },
            { label: 'Arrear', value: 'Arrear' }
        ]
    },
    Line_Remarks__c: { label: 'Line Remarks', fieldName: 'Line_Remarks__c', type: 'text', initialWidth: 200, editable: true, wrapText: true },
    Line_Origin__c:  { label: 'Origin',      fieldName: 'Line_Origin__c',  type: 'text', initialWidth: 100, editable: false, wrapText: false },
    Change_Type__c:  { label: 'Change Type', fieldName: 'Change_Type__c',  type: 'text', initialWidth: 120, editable: false, wrapText: false },
    serviceName:     { label: 'Service Name', fieldName: '_serviceName',   type: 'text', initialWidth: 160, editable: false, wrapText: false },
    originalPrice:   { label: 'Original Price', fieldName: '_originalPrice', type: 'currency', initialWidth: 130, editable: false,
        typeAttributes: { currencyCode: { fieldName: 'CurrencyIsoCode' }, minimumFractionDigits: 2 } },
    originalAttribute: { label: 'Original Attr', fieldName: '_originalAttribute', type: 'text', initialWidth: 130, editable: false, wrapText: false },
    Target_BAN__c:   { label: 'Target BAN',  fieldName: 'Target_BAN__c',   type: 'text', initialWidth: 200, editable: true,  wrapText: false }
};

// Initial column visibility — Family, Unit, Ramp fields hidden by default
const INITIAL_COL_DEFS = [
    { key: 'view_btn',           label: 'Details',      required: true,  visible: true  },
    { key: 'productName',        label: 'Product',      required: true,  visible: true  },
    { key: 'productCode',        label: 'Code',         required: false, visible: true  },
    { key: 'Product_Attribute_Value__c', label: 'Attribute', required: false, visible: true  },
    { key: 'attributeType',      label: 'Attr Type',    required: false, visible: false },
    { key: 'productFamily',      label: 'Family',       required: false, visible: false },
    { key: 'productUnit',        label: 'UoM',          required: false, visible: true  },
    { key: 'Quantity',           label: 'Qty',          required: false, visible: true  },
    { key: 'ListPrice',          label: 'List Price',   required: false, visible: true  },
    { key: 'UnitPrice',          label: 'Sales Price',  required: false, visible: true  },
    { key: 'Discount',           label: 'Discount (%)', required: false, visible: true },
    { key: 'TotalPrice',         label: 'Total Price',  required: false, visible: true  },
    { key: 'BillingFrequency',   label: 'Billing',      required: false, visible: false },
    { key: 'StartDate',          label: 'Start',        required: false, visible: false },
    { key: 'EndDate',            label: 'End',          required: false, visible: false },
    { key: 'Reserved__c',         label: 'Reserved',     required: false, visible: true  },
    { key: 'Charge_Type__c',     label: 'Charge Type',  required: false, visible: true  },
    { key: 'Charge_Frequency__c', label: 'Frequency',   required: false, visible: false, hidden: true },
    { key: 'Billing_Mode__c',    label: 'Billing Mode', required: false, visible: true  },
    { key: 'Line_Remarks__c',    label: 'Line Remarks', required: false, visible: true  },
    { key: 'Ramp_Phase__c',      label: 'Ramp #',       required: false, visible: false },
    { key: 'Ramp_Start_Date__c', label: 'Ramp Start',   required: false, visible: false },
    { key: 'Line_Origin__c',    label: 'Origin',       required: false, visible: false },
    { key: 'Change_Type__c',    label: 'Change Type',  required: false, visible: false },
    { key: 'serviceName',       label: 'Service Name', required: false, visible: false },
    { key: 'Target_BAN__c',     label: 'Target BAN',   required: false, visible: true  },
];

// NRC/MRC grouping constants
const GROUP_ORDER = ['Monthly', 'Quarterly', 'Annual', 'MRC', 'NRC'];
const CREATE_RT_OPTIONS = [
    { label: 'Space', value: 'Inventory_Space' },
    { label: 'Breaker', value: 'Inventory_Breaker' }
];
const SPACE_TYPE_CREATE_OPTIONS = [
    { label: 'Cabinet', value: 'Cabinet' },
    { label: 'Cage', value: 'Cage' },
    { label: 'Data Hall', value: 'Data Hall' }
];
const CAPACITY_TYPE_OPTIONS = [
    { label: 'Power Circuit', value: 'Power Circuit' },
    { label: 'Cross Connect Port', value: 'Cross Connect Port' }
];
const INV_TYPE_FILTERS = ['All', 'Space', 'Breaker'];

const GROUP_LABELS = {
    NRC:       'Non-Recurring Charges (NRC)',
    Monthly:   'Monthly Recurring Charges (MRC)',
    Quarterly: 'Quarterly Recurring Charges',
    Annual:    'Annual Recurring Charges (ARC)',
    MRC:       'Monthly Recurring Charges (MRC)',
};

// Ramp phase count bounds (SFDC-208). PHASE_PICK_MAX is a UI limit only — the row of
// quick-pick buttons stops there and the stepper carries on to RAMP_PHASE_MAX.
const RAMP_PHASE_MIN = 2;
const RAMP_PHASE_MAX = 30;
const PHASE_PICK_MAX = 12;

// Quantities are decimal (SFDC-208 #2: pyeong converted to sqm gives 132.23), so totals
// must never be compared with ===. Summing 0.1-style values drifts in the last bits and an
// exact test then rejects a split that is correct, with no way for the user to clear it.
const QTY_EPSILON = 0.0001;
const qtyEquals = (a, b) => Math.abs((Number(a) || 0) - (Number(b) || 0)) < QTY_EPSILON;
const isBlankQty = (v) => v === '' || v === null || v === undefined;

export default class QuoteLineEditor extends LightningElement {
    @api recordId;
    @api quoteId;

    @track selectedRowIds     = [];
    @track searchTerm         = '';
    @track searchResults      = [];
    @track isSearching        = false;
    @track showDropdown       = false;
    @track isLoading          = false;
    @track _draftValues       = null;
    @track hasPendingDrafts   = false;
    @track _autoSave          = true;
    @track showSbiWarning     = false;
    @track showDetailPanel    = false;
    @track showColumnPicker   = false;
    @track showFamilyGroups   = false;
    @track _editSection       = null;
    @track _columnDefs        = INITIAL_COL_DEFS.map(c => ({ ...c }));
    @track _collapsedGroups   = {};
    @track _collapsedSubGroups = {};
    @track _panelSection       = 'details';
    @track _mainTab            = 'lines'; // 'lines' or 'rampSchedule'

    selectedLineId   = null;
    selectedLineName = null;
    selectedLineCode = null;
    _selectedCapAssign = '';
    _wiredResult;
    _lines       = [];
    _pendingSbiDrafts = null;
    _sbiChangeDetails = [];
    _error;
    _pricebook2Id;
    _currencyCode = 'USD';
    _searchTimer;
    @track _activeApprovals    = [];
    @track _banOptions         = [];
    _defaultBanId              = null;
    _isChangeOrderQuote        = false;
    _contractEndDate           = null; // Quote.Contract_End_Date__c — ramp must stay within this
    _quoteRdd                  = null; // Quote.RDD__c — Ramp Phase 1 start (locked)

    // ─── Pricebook context ────────────────────────────────────────────
    @track _sitePricebookName    = '';
    @track _accountPricebookId   = null;
    @track _accountPricebookName = '';
    get hasPricebookName()       { return !!this._sitePricebookName; }
    get hasAccountPricebook()    { return !!this._accountPricebookId; }
    get pricebookLabel() {
        let label = this._sitePricebookName || '';
        if (this._accountPricebookName) {
            label += '  +  ' + this._accountPricebookName;
        }
        return label;
    }

    // ─── Inventory tab state ──────────────────────────────────────────
    @track _assignedInventory = [];
    @track _availableInventory = [];
    @track isInventoryLoading = false;
    @track isInventoryBusy = false;
    @track inventoryLoaded = false;
    _invSearchTerm = '';

    // ─── Ramp builder state ──────────────────────────────────────────────
    @track showRampBuilder = false;
    @track rampPhases      = [];
    @track rampType        = 'quantity';
    _rampSourceQty       = 0;
    _rampSourcePrice     = 0;
    _rampSourceStartDate = null;
    _rampSourceEndDate   = null;
    _rampSourceAttributeOptions = [];
    _rampSourceAttributeValue   = '';
    _rampSourceAttributeType    = '';
    _rampNextId          = 1;

    // ─── Create inventory state ──────────────────────────────────
    @track showCreateModal  = false;
    @track creating         = false;
    @track createRT         = 'Inventory_Space';
    @track createFloorId;
    @track createHallId;
    @track createSpaceType  = 'Cabinet';
    @track createCapType    = 'Power Circuit';
    @track createPowerKva;
    @track createTotalCapKva;
    @track createPanel      = '';
    @track createNotes      = '';
    @track createQty        = 1;
    @track _floors          = [];
    @track _halls           = [];
    _siteId                 = null;
    _siteLoaded             = false;

    // ─── Inventory filter state ──────────────────────────────────
    @track _invTypeFilter   = 'All';

    // SFDC-472: Floor / Data Hall scope for the available list. The Apex query is
    // row-capped and ordered by Floor name, so at a site whose first floor fills the
    // cap the later floors never reach the browser. These two send the filter to the
    // server instead of filtering what already arrived.
    @track _invFloorId        = '';
    @track _invHallId         = '';
    @track _invFloors         = [];
    @track _invHalls          = [];
    @track _invAvailableTotal = 0;
    @track _invAvailableLimit = 0;
    @track _selectedInvIds  = new Set();

    // ─── Multi-product ramp modal state ──────────────────────────────
    @track showRampModal        = false;
    @track _rampMrcLines        = [];
    @track _rampNrcLines        = [];
    @track _rampModalPhaseCount = 2;
    @track _rampModalType       = 'quantity';
    @track _rampModalPhases     = [];
    @track _showRampAddPopover  = false;
    @track _isEditingRamp       = false;
    @track _rampCellLinks       = {}; // { "lineId_phaseId": [linkedToPhaseId, ...] } — a phase can supersede several earlier ones; key absent when unlinked
    @track _openPillKey         = null; // which pill menu is open: "lineId_phaseId"
    _rampPreLinkQty             = {}; // { "lineId_phaseId": qty before linking } — captured on the 0→N links transition, restored on N→0; a partial unlink just re-sums
    @track _rampExcludedCells   = {}; // { "lineId_phaseId": true } — product excluded from this phase

    // ─── Existing ramp view/edit state ───────────────────────────────
    @track _existingRampPhases    = [];
    @track _existingRampProducts  = [];
    @track _existingRampRaw       = [];
    @track _isViewingExistingRamp = false;
    @track _isEditingExistingRamp = false;
    @track _rampInvoiceDisplay    = '';

    // ─── Currency-aware formatter (cached) ─────────────────────────────────

    _fmtCache = null;
    _fmtCacheCode = null;

    _fmt(v) {
        if (v == null) return '-';
        const cc = this._currencyCode || 'USD';
        if (!this._fmtCache || this._fmtCacheCode !== cc) {
            this._fmtCacheCode = cc;
            // No minimumFractionDigits: with style 'currency' Intl uses each
            // currency's own minor-unit count — JPY/KRW 0, USD/SGD 2. Forcing 2
            // rendered JPY totals as ¥230,250.72 where BOSS shows ¥230,251
            // (ITCJP-OR-020349).
            this._fmtCache = new Intl.NumberFormat('en-US', {
                style: 'currency', currency: cc
            });
        }
        return this._fmtCache.format(v);
    }

    // ─── Derived ──────────────────────────────────────────────────────────

    get resolvedId()          { return this.recordId || this.quoteId; }
    get lineCount()           { return this._lines.length || null; }
    get hasLines()            { return this._lines.length > 0; }
    get isEmpty()             { return !this.isLoading && !this._error && this._lines.length === 0; }
    get hasError()            { return !!this._error; }
    get errorMessage()        { return this._error?.body?.message || this._error?.message || 'An unexpected error occurred.'; }
    get hasSelectedRows()     { return this.selectedRowIds.length > 0; }
    get hasSearchResults()    { return this.searchResults.length > 0; }
    get noSearchResults()     { return !this.isSearching && this.showDropdown && this.searchResults.length === 0 && this.searchTerm.length >= 2; }
    get selectedLineUrl()     { return this.selectedLineId ? `/lightning/r/QuoteLineItem/${this.selectedLineId}/view` : null; }
    get showInitialSpinner()  { return this.isLoading && this._lines.length === 0; }
    get showLoadingOverlay()  { return this.isLoading && this._lines.length > 0; }
    get isEditingPricing()    { return this._editSection === 'pricing'; }
    get isEditingSchedule()   { return this._editSection === 'schedule'; }
    get draftValues()         { return this._draftValues; }

    // ─── Approval lockdown ───────────────────────────────────────────────

    // Lockdown based on actual ProcessInstance records — not boolean flags.
    // Only shows bar and locks QLE when an approval is genuinely in progress.

    get _hasQuoteApproval() {
        return this._activeApprovals.some(a => a.targetType === 'Quote');
    }

    get _hasBanApproval() {
        return this._activeApprovals.some(a => a.targetType === 'BAN');
    }

    get isQuoteLocked() {
        return this._hasQuoteApproval;
    }

    get _isQuoteDraft() {
        return this._quoteStatus === 'Draft';
    }

    get isSearchDisabled() {
        return this.isQuoteLocked || this.isLoading || this.hasRampSchedule;
    }

    get showDeleteButton() {
        return this.hasSelectedRows && !this.isQuoteLocked && !this.hasRampSchedule;
    }

    get showCreateRampButton() {
        return this.hasSelectedRows && !this.isQuoteLocked && this.isLinesTab && !this.hasRampSchedule;
    }

     get allowLineReorder() {
        return !this.isQuoteLocked && this._isQuoteDraft && this.isLinesTab;
    }

    get showApprovalBar() {
        return this._activeApprovals.length > 0;
    }

    get approvalBadges() {
        const badges = [];
        let quoteIdx = 0;
        for (const a of this._activeApprovals) {
            if (a.targetType === 'Quote') {
                quoteIdx++;
                const label = a.approver ? `Pending: ${a.approver}` : 'Pending Approval';
                badges.push({
                    key: `quote-${quoteIdx}`,
                    label,
                    cls: 'qle-badge qle-badge_pending'
                });
            } else if (a.targetType === 'BAN') {
                badges.push({
                    key: `ban-${a.banName}`,
                    label: `BAN: ${a.banName}`,
                    cls: 'qle-badge qle-badge_info'
                });
            }
        }
        return badges;
    }

    _loadActiveApprovals() {
        getActiveApprovals({ quoteId: this.resolvedId })
            .then(result => { this._activeApprovals = result || []; })
            .catch(() => { this._activeApprovals = []; });
    }

    // ─── Panel navigation ──────────────────────────────────────────────
    get isPanelDetails()   { return this._panelSection === 'details'; }
    get isPanelInventory() { return this._panelSection === 'inventory'; }
    get isPanelRamp()      { return this._panelSection === 'ramp'; }
    get detailsNavCls()    { return 'qle-pn-btn' + (this._panelSection === 'details'   ? ' qle-pn-btn-on' : ''); }
    get inventoryNavCls()  { return 'qle-pn-btn' + (this._panelSection === 'inventory' ? ' qle-pn-btn-on' : ''); }
    get rampNavCls()       { return 'qle-pn-btn' + (this._panelSection === 'ramp'      ? ' qle-pn-btn-on' : ''); }
    get showInventoryTab() { return !!this._selectedCapAssign; }
    // Ramp tab removed from detail panel — use the Ramp Schedule tab instead
    get showRampTab() { return false; }
    get showPanelFooter()  { return this._panelSection === 'inventory' && this.showInventoryTab; }
    get assignedCount()    { return this._assignedInventory.length; }

    // ─── Main tab navigation (Lines | Ramp Schedule) ──────────────────
    get isLinesTab()        { return this._mainTab === 'lines' || !this.showRampScheduleNav; }
    get isRampScheduleTab() { return this._mainTab === 'rampSchedule' && this.showRampScheduleNav; }
    get showRampScheduleNav() {
        return this._lines && this._lines.some(l => l.Line_Origin__c === 'Ramp');
    }
    get linesNavClass()        { return 'qle-main-nav-btn' + (this.isLinesTab ? ' qle-main-nav-active' : ''); }
    get rampScheduleNavClass() { return 'qle-main-nav-btn' + (this.isRampScheduleTab ? ' qle-main-nav-active' : ''); }

    handleMainTabChange(event) {
        this._mainTab = event.currentTarget.dataset.tab;
    }

    // Ramp type CSS class getters (segment pills)
    get qtyRampCls()   { return 'qle-ramp-type-btn' + (this.rampType === 'quantity'  ? ' qle-ramp-type-on' : ''); }
    get priceRampCls() { return 'qle-ramp-type-btn' + (this.rampType === 'price'     ? ' qle-ramp-type-on' : ''); }
    get attrRampCls()  { return 'qle-ramp-type-btn' + (this.rampType === 'attribute' ? ' qle-ramp-type-on' : ''); }

    // Existing ramp view/edit getters
    get isViewingExistingRamp()  { return this._isViewingExistingRamp; }
    get isEditingExistingRamp()  { return this._isEditingExistingRamp; }
    get existingRampPhases()     { return this._existingRampPhases; }
    get existingRampPhaseCount() { return this._existingRampPhases.length; }
    get existingRampProductCount() { return this._existingRampProducts.length; }
    get rampInvoiceDisplay()     { return this._rampInvoiceDisplay || '-'; }
    get hasExistingRampAttribute() {
        return this._existingRampPhases.length > 0 && !!this._existingRampPhases[0].attributeType;
    }
    get existingRampAttributeLabel() {
        return this._existingRampPhases.length > 0 ? (this._existingRampPhases[0].attributeType || 'Attribute') : 'Attribute';
    }
    get existingRampAttributeOptions() {
        if (this._existingRampPhases.length === 0) return [];
        const raw = (this._existingRampPhases[0].attributeValues || '').split(',').map(v => v.trim()).filter(Boolean);
        const opts = [{ label: '--None--', value: '' }];
        raw.forEach(v => opts.push({ label: v, value: v }));
        return opts;
    }

    // ─── Ramp Schedule tab data ──────────────────────────────────────────
    get rampScheduleData() {
        if (this._cachedRampSchedule) return this._cachedRampSchedule;
        const empty = { phases: [], rows: [], mrcTotals: [], nrcTotals: [], gridStyle: '', phaseCount: 0, productCount: 0, invoiceDisplay: '-', hasData: false };
        if (!this._lines) return empty;
        const rampLines = this._lines.filter(l => l.Line_Origin__c === 'Ramp');
        if (rampLines.length === 0) return empty;

        // Separate auto-paired NRCs from everything else (MRC + standalone NRC)
        const autoNrcLines = rampLines.filter(l => l.Charge_Type__c === 'NRC' && l.Is_Auto_NRC__c === true);
        const productLines = rampLines.filter(l => !(l.Charge_Type__c === 'NRC' && l.Is_Auto_NRC__c === true));
        // SFDEV-11: only auto NRCs attach to an MRC row. A standalone NRC is already its own
        // row in productLines; linking it by product code as well printed it twice.
        const nrcLines = autoNrcLines;
        const mrcLines = rampLines.filter(l => l.Charge_Type__c !== 'NRC');

        const phaseNums = [...new Set(productLines.map(l => l.Ramp_Phase__c))].sort((a, b) => a - b);

        // Build unique product lines by QLI identity (Phase 1 QLI Id as group key)
        const seen = new Set();
        const products = [];
        // Pass 1: Phase 1 products (group anchors)
        for (const l of productLines) {
            if (l.Ramp_Phase__c !== phaseNums[0]) continue;
            const groupKey = l.Id; // Phase 1 line IS the anchor
            if (!seen.has(groupKey)) {
                seen.add(groupKey);
                products.push({
                    productId: l.Product2Id,
                    groupKey,
                    lineKey: groupKey,
                    attr: l.Product_Attribute_Value__c || '',
                    code: l.Product2?.ProductCode || l.productCode || '',
                    name: l.Product2?.Name || l.productName || '',
                });
            }
        }
        // Pass 2: products only in later phases — find their group anchor via Ramp_Parent_Line__c
        for (const l of productLines) {
            const groupKey = l.Ramp_Parent_Line__c || l.Id;
            if (!seen.has(groupKey)) {
                seen.add(groupKey);
                products.push({
                    productId: l.Product2Id,
                    groupKey,
                    lineKey: groupKey,
                    attr: l.Product_Attribute_Value__c || '',
                    code: l.Product2?.ProductCode || l.productCode || '',
                    name: l.Product2?.Name || l.productName || '',
                });
            }
        }

        // NRC lookup by MRC Id
        const nrcByMrcId = {};
        for (const nrc of nrcLines) {
            if (nrc.Paired_MRC_Line__c) {
                nrcByMrcId[nrc.Paired_MRC_Line__c] = nrc;
            }
        }
        // Fallback: match by product code convention (.RC -> .NR) + phase
        for (const nrc of nrcLines) {
            if (!nrc.Paired_MRC_Line__c) {
                const nrcCode = nrc.Product2?.ProductCode || nrc.productCode || '';
                for (const mrc of mrcLines) {
                    const mrcCode = mrc.Product2?.ProductCode || mrc.productCode || '';
                    const expectedNrc = mrcCode.replace(/\.RC$/i, '.NR');
                    if (nrcCode === expectedNrc && nrc.Ramp_Phase__c === mrc.Ramp_Phase__c && !nrcByMrcId[mrc.Id]) {
                        nrcByMrcId[mrc.Id] = nrc;
                    }
                }
            }
        }

        const fmt = (v) => this._fmt(v);

        // Build first-phase-per-product map for identifier logic (keyed by group anchor)
        const firstPhaseByProduct = {};
        for (const l of productLines) {
            const gk = l.Ramp_Parent_Line__c || l.Id;
            if (!firstPhaseByProduct[gk] || l.Ramp_Phase__c < firstPhaseByProduct[gk]) {
                firstPhaseByProduct[gk] = l.Ramp_Phase__c;
            }
        }

        // Build phase cards — each card = one phase with all products
        const phaseCards = phaseNums.map(pn => {
            const phaseMrcs = productLines.filter(l => l.Ramp_Phase__c === pn);
            const startDate = phaseMrcs[0]?.Ramp_Start_Date__c || phaseMrcs[0]?.StartDate;
            // FB-815: phase notes live in Ramp_Phase_Notes__c, not Line_Remarks__c
            const notes = phaseMrcs[0]?.Ramp_Phase_Notes__c || '';
            let mrcTotal = 0;
            let nrcTotal = 0;

            // Build lookup by group key for this phase's lines. A repricing phase supersedes
            // each earlier phase with its own line, so one (product, phase) can hold several.
            const phaseMrcsByGroup = {};
            for (const l of phaseMrcs) {
                const gk = l.Ramp_Parent_Line__c || l.Id;
                if (!phaseMrcsByGroup[gk]) phaseMrcsByGroup[gk] = [];
                phaseMrcsByGroup[gk].push(l);
            }

            const items = products.map(prod => {
                const group = phaseMrcsByGroup[prod.groupKey] || null;
                // Skip products with no data in this phase
                if (!group) return null;
                // The bucket is one row: quantities add up, everything else is shared by
                // construction so it comes off the first line.
                const mrc = group[0];
                const qty = group.reduce((sum, l) => sum + (Number(l.Quantity) || 0), 0);
                const price = Number(mrc.UnitPrice) || 0;
                // Siblings reprice the same cell, so they should agree on price. If they don't,
                // the data was edited outside the ramp modal — say so rather than silently
                // showing one price against the combined quantity.
                if (group.some(l => (Number(l.UnitPrice) || 0) !== price)) {
                    console.warn(`Ramp schedule: ${prod.code} phase ${pn} has lines with differing unit prices; using ${price}`);
                }
                const attr = mrc.Product_Attribute_Value__c || '';
                mrcTotal += qty * price;

                // Dedupe by NRC Id — a paired NRC counts once for the whole bucket, not once
                // per line in it. Linked lines carry no NRC, so this is a guard, not a change.
                const nrcs = [];
                const seenNrcIds = new Set();
                for (const l of group) {
                    const n = nrcByMrcId[l.Id];
                    if (n && !seenNrcIds.has(n.Id)) { seenNrcIds.add(n.Id); nrcs.push(n); }
                }
                const nrc = nrcs[0] || null;
                const nrcQty = nrcs.reduce((sum, n) => sum + (Number(n.Quantity) || 0), 0);
                const nrcPrice = nrc ? (Number(nrc.UnitPrice) || 0) : 0;
                nrcTotal += nrcQty * nrcPrice;

                const identifier = mrc.Ramp_Identifier__c || 'Add';
                // Aggregate is a product property — any line in the bucket carries it
                const isAggregate = mrc.Merge_IB_Task__c || mrc.Product2?.Merge_IB_Task__c;

                // Determine display label:
                // - Aggregate products after their first phase → "Existing"
                // - 'Change' → "Change", 'Price_Change' → "Price Change", 'Add' → "New"
                const firstPhase = firstPhaseByProduct[prod.groupKey] || phaseNums[0];
                let identifierLabel, identifierClass;
                if (isAggregate && pn > firstPhase && identifier === 'Add') {
                    identifierLabel = 'Existing';
                    identifierClass = 'qle-rs-item-id qle-rs-item-id_existing';
                } else if (identifier === 'Change') {
                    identifierLabel = 'Change';
                    identifierClass = 'qle-rs-item-id qle-rs-item-id_change';
                } else if (identifier === 'Price_Change') {
                    identifierLabel = 'Price Change';
                    identifierClass = 'qle-rs-item-id qle-rs-item-id_pricechange';
                } else {
                    identifierLabel = 'New';
                    identifierClass = 'qle-rs-item-id qle-rs-item-id_new';
                }

                return {
                    key: 'rsi_' + prod.groupKey + '_' + pn,
                    name: prod.name,
                    code: prod.code,
                    qty: String(qty),
                    price: fmt(price),
                    rawPrice: price,
                    attr: attr,
                    hasAttr: !!attr,
                    isChange: identifier === 'Change',
                    identifierLabel,
                    identifierClass,
                    hasNrc: !!nrc,
                    nrcKey: 'rsn_' + prod.groupKey + '_' + pn,
                    nrcName: nrc ? (nrc.Product2?.Name || nrc.productName || 'NRC') : '',
                    nrcQty: nrc ? String(nrcQty) : '',
                    nrcPrice: nrc ? fmt(nrcPrice) : '',
                    rawNrcPrice: nrcPrice,
                };
            }).filter(Boolean);

            // Default: Phase 1 expanded on first render
            if (!this._rampPhasesInited) {
                this._openRampPhases = new Set([phaseNums[0]]);
                this._rampPhasesInited = true;
            }
            const isOpen = this._openRampPhases.has(pn);
            const productSummary = items.length <= 2
                ? items.map(it => it.name).join(', ')
                : items.slice(0, 2).map(it => it.name).join(', ') + ' +' + (items.length - 2);

            return {
                key: 'rsp_' + pn,
                phaseNumber: pn,
                formattedStart: startDate ? new Date(startDate).toLocaleDateString('en-SG', { day: '2-digit', month: 'short', year: 'numeric' }) : '',
                notes: notes,
                hasNotes: !!notes,
                items: items,
                mrcTotal: fmt(mrcTotal),
                nrcTotal: fmt(nrcTotal),
                productSummary: productSummary,
                productCount: items.length,
                sectionClass: 'qle-rs-section' + (isOpen ? ' qle-rs-section-open' : ''),
            };
        });

        // Build flat table rows — ALL products (MRC + NRC) with cells per phase
        const allProducts = [];
        const seenProducts = new Set();
        // Collect all unique products from ALL ramp lines (MRC and NRC)
        for (const l of rampLines) {
            const gk = l.Ramp_Parent_Line__c || l.Id;
            if (!seenProducts.has(gk)) {
                seenProducts.add(gk);
                allProducts.push({
                    productId: l.Product2Id,
                    groupKey: gk,
                    name: l.Product2?.Name || l.productName || '',
                    isNrc: (l.Charge_Type__c || '').toUpperCase() === 'NRC',
                });
            }
        }
        // Sort: MRC first, NRC second
        allProducts.sort((a, b) => (a.isNrc === b.isNrc ? 0 : a.isNrc ? 1 : -1));

        const tableRows = allProducts.map(prod => {
            const cells = phaseNums.map(pn => {
                // Same fan-out as the phase cards — collapse the bucket into one cell.
                // Price disagreement is already warned about above; don't warn twice.
                const group = rampLines.filter(l => (l.Ramp_Parent_Line__c || l.Id) === prod.groupKey && l.Ramp_Phase__c === pn);
                const line = group[0] || null;
                const qty = group.reduce((sum, l) => sum + (Number(l.Quantity) || 0), 0);
                return {
                    key: 'trc_' + prod.groupKey + '_' + pn,
                    qty: line ? String(qty) : '-',
                    price: line ? fmt(line.UnitPrice || 0) : '-',
                    attr: line ? (line.Product_Attribute_Value__c || '') : '',
                    hasAttr: !!(line && line.Product_Attribute_Value__c),
                };
            });
            return {
                key: 'trr_' + prod.groupKey,
                name: prod.name,
                isNrc: prod.isNrc,
                rowClass: prod.isNrc ? 'qle-rs-row qle-rs-row-nrc' : 'qle-rs-row',
                cells: cells,
            };
        });

        // Grand total across all phases
        let grandMrc = 0;
        let grandNrc = 0;
        for (const pc of phaseCards) {
            for (const it of pc.items) {
                grandMrc += (Number(it.qty) || 0) * (Number(it.rawPrice) || 0);
                const nrcQ = Number(it.nrcQty) || 0;
                const nrcP = Number(it.rawNrcPrice) || 0;
                grandNrc += nrcQ * nrcP;
            }
        }

        return {
            phaseCards,
            tableRows,
            phaseCount: phaseNums.length,
            productCount: products.length,
            hasData: phaseCards.length > 0,
            hasAnyNotes: phaseCards.some(pc => pc.hasNotes),
            grandTotal: fmt(grandMrc + grandNrc),
        };
        this._cachedRampSchedule = result;
        return result;
    }

    get hasRampSchedule() {
        return this.rampScheduleData && this.rampScheduleData.hasData;
    }

    get rampSchedulePhaseCount() {
        return this.rampScheduleData ? `${this.rampScheduleData.phaseCount} Phases` : '';
    }

    // Collapsible ramp phase sections — all open by default
    @track _openRampPhases = new Set();
    _rampPhasesInited = false;

    handleToggleRampPhase(event) {
        const pn = Number(event.currentTarget.dataset.phase);
        const next = new Set(this._openRampPhases);
        if (next.has(pn)) { next.delete(pn); } else { next.add(pn); }
        this._openRampPhases = next;
        this._cachedRampSchedule = null; // phase collapse state changed
    }

    // ─── Ramp Schedule tab actions ───────────────────────────────────────
    handleEditRampFromSchedule() {
        if (this.isQuoteLocked) {
            this._toast('Locked', 'Cannot modify ramp while approvals are in progress.', 'warning');
            return;
        }
        // Find a ramped MRC PARENT line and build the edit modal from it. Not "phase 1" —
        // with phase 1 excludable every parent can start at phase 2+, and the old test then
        // found nothing and returned silently, leaving this button dead with no message.
        const phase1 = this._lines.find(l => l.Line_Origin__c === 'Ramp' && !l.Ramp_Parent_Line__c && l.Charge_Type__c !== 'NRC');
        if (!phase1) return;

        // Simulate the same flow as handleEditExistingRamp by setting up the context
        this.selectedLineId = phase1.Id;
        this.selectedLineName = phase1.productName;
        this.selectedLineCode = phase1.productCode;

        // Load existing ramp data then switch to edit
        this.isLoading = true;
        getRampSiblings({ quoteLineItemId: phase1.Id })
            .then(result => {
                if (result && result.length > 0) {
                    this._existingRampRaw = result;
                    const phaseNums = [...new Set(result.map(r => r.rampPhase))].sort((a, b) => a - b);
                    const productMap = new Map();
                    for (const r of result) {
                        if (!productMap.has(r.productCode)) {
                            productMap.set(r.productCode, { name: r.productName, code: r.productCode });
                        }
                    }
                    this._existingRampPhases = phaseNums.map(pn => {
                        const phaseLines = result.filter(r => r.rampPhase === pn);
                        const firstLine = phaseLines[0];
                        return {
                            key: `phase-${pn}`, phaseNumber: pn,
                            startDate: firstLine.startDate, endDate: firstLine.endDate,
                            formattedStart: this._fmtDate(firstLine.startDate),
                            formattedEnd: this._fmtDate(firstLine.endDate),
                            products: phaseLines.map(r => ({
                                id: r.id, code: r.productCode, name: r.productName,
                                quantity: r.quantity, unitPrice: r.unitPrice,
                                formattedPrice: this._fmt(r.unitPrice),
                                attributeValue: r.attributeValue || '',
                                nrcCode: r.nrcCode || '', nrcPrice: r.nrcPrice != null ? this._fmt(r.nrcPrice) : ''
                            }))
                        };
                    });
                    this._existingRampProducts = [...productMap.values()];
                    this._rampInvoiceDisplay = result[0].invoiceDisplay || '';
                    this._isViewingExistingRamp = true;
                    // Now trigger edit mode like handleEditExistingRamp
                    this.handleEditExistingRamp();
                }
            })
            .catch(err => this._toast('Error', err?.body?.message || 'Could not load ramp.', 'error'))
            .finally(() => { this.isLoading = false; });
    }

    handleRemoveRampFromSchedule() {
        if (!this._isQuoteDraft) {
            this._toast('Quote Not in Draft', 'Ramp can only be removed when the Quote is in Draft status.', 'warning');
            return;
        }
        if (this.isQuoteLocked) {
            this._toast('Locked', 'Cannot modify ramp while approvals are in progress.', 'warning');
            return;
        }
        // eslint-disable-next-line no-alert
        if (!confirm('This will remove ALL ramp phases from ALL products on this quote. Lines will revert to their original quantities. Continue?')) return;
        // Parent line, not phase 1 — see handleEditRampFromSchedule. deleteRampPhases works
        // quote-wide from whichever line it is handed, so any ramp parent will do.
        const phase1 = this._lines.find(l => l.Line_Origin__c === 'Ramp' && !l.Ramp_Parent_Line__c && l.Charge_Type__c !== 'NRC');
        if (!phase1) return;
        this.isLoading = true;
        deleteRampPhases({ quoteLineItemId: phase1.Id })
            .then(() => {
                this._mainTab = 'lines';
                this._toast('Ramp Removed', 'All phases reverted to base lines.', 'success');
                return this._refreshAfterLineChange();
            })
            .catch(err => this._toast('Error', err?.body?.message || 'Failed to remove ramp.', 'error'))
            .finally(() => { this.isLoading = false; });
    }

    get searchComboClass() {
        return 'slds-combobox slds-dropdown-trigger slds-dropdown-trigger_click' + (this.showDropdown ? ' slds-is-open' : '');
    }

    // Visible columns for the picker UI (excludes required/pinned cols)
    get columnDefs() {
        return this._columnDefs.filter(c => !c.required && !c.hidden);
    }

    // Datatable columns — inject live currency code into currency columns
    // When quote is locked (in approval), strip editability from all columns except
    // Reserved__c and Target_BAN__c (both stay editable through approval, like Reservation)
    get columns() {
        const cc = this._currencyCode || 'USD';
        const locked = this.isQuoteLocked;
        const cols = this._columnDefs.filter(c => c.visible).map(c => {
            const col = ALL_COLS[c.key];
            if (!col) return null;
            let result = col;
            if (result.type === 'currency') {
                result = { ...result, typeAttributes: { ...result.typeAttributes, currencyCode: cc } };
            }
            if (locked && result.editable
                && result.fieldName !== 'Reserved__c'
                && result.fieldName !== 'Target_BAN__c') {
                result = { ...result, editable: false };
            }
            if (c.key === 'Target_BAN__c') {
                result = { ...result, editOptions: this._banOptions };
            }
            return result;
        }).filter(Boolean);
        if (this._isChangeOrderQuote) {
            if (!cols.find(c => c.fieldName === 'Change_Type__c')) {
                cols.push({ ...ALL_COLS.Change_Type__c });
            }
            if (!cols.find(c => c.fieldName === '_serviceName')) {
                cols.push({ ...ALL_COLS.serviceName });
            }
            // Original Attr: only when any line has Change_Type = CHANGE with an original attribute value
            const hasAttrChange = this._lines.some(l => l.Change_Type__c === 'CHANGE' && !!l._originalAttribute);
            if (hasAttrChange) {
                const attrIdx = cols.findIndex(c => c.fieldName === 'Product_Attribute_Value__c');
                const attrInsert = attrIdx >= 0 ? attrIdx : cols.length;
                cols.splice(attrInsert, 0, { ...ALL_COLS.originalAttribute });
            }
            // Original Price: only when any line has Change_Type = CHANGE_PRICE
            const hasPriceChange = this._lines.some(l => l.Change_Type__c === 'CHANGE_PRICE');
            if (hasPriceChange) {
                const totalIdx = cols.findIndex(c => c.fieldName === 'TotalPrice');
                const priceInsert = totalIdx >= 0 ? totalIdx : cols.length;
                cols.splice(priceInsert, 0,
                    { ...ALL_COLS.originalPrice, typeAttributes: { ...ALL_COLS.originalPrice.typeAttributes, currencyCode: cc } }
                );
            }
        }
        return cols;
    }

    // ─── Grouping toggle ──────────────────────────────────────────────────

    get groupToggleTitle()   { return this.showFamilyGroups ? 'Group by Family: On' : 'Group by Family'; }
    get groupToggleVariant() { return this.showFamilyGroups ? 'brand' : 'border-filled'; }

    handleGroupToggle() {
        this.showFamilyGroups = !this.showFamilyGroups;
        this._cachedGroupedLines = null;
    }

    // ─── Grouping ─────────────────────────────────────────────────────────

    get groupedLines() {
        if (this._cachedGroupedLines) return this._cachedGroupedLines;
        if (!this._lines.length) return [];

        // Hide the ramp's extra phase rows from the Lines tab (shown in Ramp Schedule tab
        // instead). Test the parent pointer, NOT the phase number: since phase 1 became
        // excludable a product's OWN line can carry phase 2 or 3, and a phase-number test
        // hid it from this tab entirely. Ramp_Parent_Line__c is empty on a product's own
        // line and set on every row the split created — the same switch deleteRampPhases
        // already made in Apex for this reason.
        let displayLines = this._lines;
        if (this.isLinesTab) {
            displayLines = this._lines.filter(l => !(l.Line_Origin__c === 'Ramp' && l.Ramp_Parent_Line__c));
            // For a ramped parent MRC line, roll its phases up into the displayed values
            // (full breakdown on Ramp Schedule tab)
            displayLines = displayLines.map(l => {
                if (l.Line_Origin__c === 'Ramp' && !l.Ramp_Parent_Line__c && l.Charge_Type__c !== 'NRC') {
                    const siblings = this._lines.filter(s =>
                        s.Line_Origin__c === 'Ramp' &&
                        s.Charge_Type__c !== 'NRC' &&
                        (s.Ramp_Parent_Line__c === l.Id || s.Id === l.Id)
                    );
                    const rampMeta = {
                        _rampPhaseCount: Math.max(...siblings.map(s => s.Ramp_Phase__c || 0)),
                        _isRampParent: true,
                        _readOnly: true,
                        _attrDisabled: true,
                    };
                    // Price shown on the Lines tab is the FIRST phase price. Later phases
                    // carry escalations that belong only in the Ramp Schedule tab.
                    const firstSibling = siblings.reduce((min, s) =>
                        (s.Ramp_Phase__c || 0) < (min.Ramp_Phase__c || 0) ? s : min, siblings[0]);
                    // Aggregate products: show LAST phase quantity (running capacity)
                    if (this._isAggregateProduct(l)) {
                        const lastSibling = siblings.reduce((max, s) =>
                            (s.Ramp_Phase__c || 0) > (max.Ramp_Phase__c || 0) ? s : max, siblings[0]);
                        return {
                            ...l,
                            Quantity: lastSibling.Quantity,
                            UnitPrice: firstSibling.UnitPrice,
                            List_Price__c: firstSibling.List_Price__c,
                            TotalPrice: (lastSibling.Quantity || 0) * (firstSibling.UnitPrice || 0) * (1 - ((firstSibling.Discount || 0) / 100)),
                            ...rampMeta,
                        };
                    }
                    // Non-aggregate: show base qty (sum of unlinked phases) and first phase price
                    const baseQty = siblings
                        .filter(s => !s.Ramp_Linked_Phase__c)
                        .reduce((sum, s) => sum + (s.Quantity || 0), 0);
                    return {
                        ...l,
                        Quantity: baseQty,
                        UnitPrice: firstSibling.UnitPrice,
                        List_Price__c: firstSibling.List_Price__c,
                        TotalPrice: (baseQty || 0) * (firstSibling.UnitPrice || 0) * (1 - ((firstSibling.Discount || 0) / 100)),
                        ...rampMeta,
                    };
                }
                // NRC ramp Phase 1 lines - show last phase values for both aggregate and non-aggregate
                if (l.Line_Origin__c === 'Ramp' && l.Charge_Type__c === 'NRC') {
                    const nrcSiblings = this._lines.filter(s =>
                        s.Line_Origin__c === 'Ramp' &&
                        s.Charge_Type__c === 'NRC' &&
                        (s.Ramp_Parent_Line__c === l.Id || s.Id === l.Id)
                    );
                    const lastNrc = nrcSiblings.reduce((max, s) =>
                        (s.Ramp_Phase__c || 0) > (max.Ramp_Phase__c || 0) ? s : max, nrcSiblings[0]);
                    const firstNrc = nrcSiblings.reduce((min, s) =>
                        (s.Ramp_Phase__c || 0) < (min.Ramp_Phase__c || 0) ? s : min, nrcSiblings[0]);
                    if (this._isAggregateProduct(l)) {
                        return {
                            ...l,
                            Quantity: lastNrc.Quantity,
                            UnitPrice: firstNrc.UnitPrice,
                            List_Price__c: firstNrc.List_Price__c,
                            TotalPrice: (lastNrc.Quantity || 0) * (firstNrc.UnitPrice || 0) * (1 - ((firstNrc.Discount || 0) / 100)),
                            _readOnly: true, _attrDisabled: true,
                        };
                    }
                    // Non-aggregate NRC: sum qty across unlinked phases, first phase price
                    const nrcBaseQty = nrcSiblings
                        .filter(s => !s.Ramp_Linked_Phase__c)
                        .reduce((sum, s) => sum + (s.Quantity || 0), 0);
                    return {
                        ...l,
                        Quantity: nrcBaseQty,
                        UnitPrice: firstNrc.UnitPrice,
                        List_Price__c: firstNrc.List_Price__c,
                        TotalPrice: (nrcBaseQty || 0) * (firstNrc.UnitPrice || 0) * (1 - ((firstNrc.Discount || 0) / 100)),
                        _readOnly: true, _attrDisabled: true,
                    };
                }
                return l;
            });
        }

        // Step 1: bucket by billing type
        const billingMap = new Map();
        displayLines.forEach(l => {
            const bKey = this._billingGroup(l);
            if (!billingMap.has(bKey)) billingMap.set(bKey, []);
            billingMap.get(bKey).push(l);
        });

        // Sort: recurring first, NRC last
        const sorted = [...billingMap.entries()].sort(([a], [b]) => {
            if (a === 'NRC') return 1;
            if (b === 'NRC') return -1;
            const ai = GROUP_ORDER.indexOf(a) >= 0 ? GROUP_ORDER.indexOf(a) : 50;
            const bi = GROUP_ORDER.indexOf(b) >= 0 ? GROUP_ORDER.indexOf(b) : 50;
            return ai - bi;
        });

        const result = sorted.map(([bKey, lines]) => {
            const label        = GROUP_LABELS[bKey] || bKey;
            const count        = lines.length;
            const subtotal     = this._fmt(lines.reduce((s, l) => s + (l.TotalPrice || 0), 0));
            const isCollapsed  = !!this._collapsedGroups[bKey];
            const chevronIcon  = isCollapsed ? 'utility:chevronright' : 'utility:chevrondown';
            const contentClass = isCollapsed ? 'qle-group-content slds-hide' : 'qle-group-content';

            if (this.showFamilyGroups) {
                // Sub-group by Product2.Family within each billing group
                const familyMap = new Map();
                lines.forEach(l => {
                    const fKey = l.productFamily || 'Other';
                    if (!familyMap.has(fKey)) familyMap.set(fKey, []);
                    familyMap.get(fKey).push(l);
                });

                const subGroups = [...familyMap.entries()]
                    .sort(([a], [b]) => a.localeCompare(b))
                    .map(([fKey, fLines]) => {
                        const subKey          = `${bKey}|${fKey}`;
                        const subCollapsed    = !!this._collapsedSubGroups[subKey];
                        const subChevronIcon  = subCollapsed ? 'utility:chevronright' : 'utility:chevrondown';
                        const subContentClass = subCollapsed ? 'qle-subgroup-content slds-hide' : 'qle-subgroup-content';
                        return {
                            key:          subKey,
                            label:        fKey,
                            lines:        fLines,
                            count:        fLines.length,
                            subtotal:     this._fmt(fLines.reduce((s, l) => s + (l.TotalPrice || 0), 0)),
                            isCollapsed:  subCollapsed,
                            chevronIcon:  subChevronIcon,
                            contentClass: subContentClass
                        };
                    });

                return { key: bKey, label, count, subtotal, lines: null, subGroups, hasSubGroups: true, isCollapsed, chevronIcon, contentClass, headerCls: 'qle-group-header qle-grp-' + bKey.toLowerCase() };
            }

            return { key: bKey, label, count, subtotal, lines, subGroups: null, hasSubGroups: false, isCollapsed, chevronIcon, contentClass, headerCls: 'qle-group-header qle-grp-' + bKey.toLowerCase() };
        });
        this._cachedGroupedLines = result;
        return result;
    }

    // Show billing group headers when there are 2+ billing groups
    get showBillingGroups() {
        return this.groupedLines.length > 1;
    }

    _billingGroup(line) {
        const ct = (line.Charge_Type__c || '').toUpperCase();
        if (ct === 'NRC') return 'NRC';
        if (ct === 'MRC') return 'Monthly';
        const code = (line.productCode || '').toUpperCase();
        const freq = (line.BillingFrequency || '').toLowerCase();
        if (code.endsWith('.NR') || freq.includes('one') || freq === 'nrc') return 'NRC';
        if (code.endsWith('.RC') || freq === 'monthly' || freq === 'mrc')   return 'Monthly';
        if (freq === 'quarterly') return 'Quarterly';
        if (freq === 'annual')    return 'Annual';
        if (freq)                 return freq;
        return 'NRC';
    }

    // Return all line IDs belonging to a given group key (handles flat + sub-groups)
    _getLineIdsForGroupKey(key) {
        for (const grp of this.groupedLines) {
            if (grp.key === key) return grp.lines ? grp.lines.map(l => l.Id) : [];
            if (grp.subGroups) {
                const sub = grp.subGroups.find(s => s.key === key);
                if (sub) return sub.lines.map(l => l.Id);
            }
        }
        return [];
    }

    // ─── Collapse / expand billing groups ────────────────────────────────

    handleGroupCollapse(event) {
        const key     = event.currentTarget.dataset.key;
        const current = !!this._collapsedGroups[key];
        this._collapsedGroups = { ...this._collapsedGroups, [key]: !current };
        this._cachedGroupedLines = null;
    }

    // ─── Collapse / expand sub-groups (family) ────────────────────────────

    handleSubGroupCollapse(event) {
        event.stopPropagation();
        const key     = event.currentTarget.dataset.key;
        const current = !!this._collapsedSubGroups[key];
        this._collapsedSubGroups = { ...this._collapsedSubGroups, [key]: !current };
        this._cachedGroupedLines = null;
    }

    // ─── Totals ───────────────────────────────────────────────────────────

    get formattedTotal() {
        return this._fmt(this._lines.reduce((s, l) => s + (l.TotalPrice || 0), 0));
    }
    // ─── Lifecycle ────────────────────────────────────────────────────────

    connectedCallback() {
        this._refreshHandlerId = registerRefreshHandler(this, this._handlePageRefresh.bind(this));
        this._loadColumnPrefs();
    }

    _loadColumnPrefs() {
        getColumnPreferences()
            .then(raw => {
                if (!raw) return;
                try {
                    // Check if autosave flag is encoded (last char: A=on, a=off)
                    let colConfig = raw;
                    if (raw.endsWith('A') || raw.endsWith('a')) {
                        this._autoSave = raw.endsWith('A');
                        colConfig = raw.slice(0, -1);
                    }
                    const nonReq = this._columnDefs.filter(c => !c.required);
                    if (/^[01]+$/.test(colConfig) && colConfig.length === nonReq.length) {
                        let idx = 0;
                        this._columnDefs = this._columnDefs.map(c => {
                            if (c.required) return c;
                            return { ...c, visible: colConfig[idx++] === '1' };
                        });
                    }
                } catch (_e) { /* ignore corrupt data — defaults are fine */ }
            })
            .catch(() => { /* silent — defaults are fine */ });
    }

    disconnectedCallback() {
        if (this._refreshHandlerId) {
            unregisterRefreshHandler(this._refreshHandlerId);
        }
        clearTimeout(this._customValueTimer);
    }

    _handlePageRefresh() {
        return refreshApex(this._wiredResult);
    }

    /** Reload QLE lines and invalidate Quote LDS cache so header totals refresh. */
    _refreshAfterLineChange() {
        const quoteId = this.resolvedId;
        if (quoteId) {
            getRecordNotifyChange([{ recordId: quoteId }]);
        }
        return refreshApex(this._wiredResult);
    }

    // ─── Wires ────────────────────────────────────────────────────────────

    @wire(getRecord, { recordId: '$resolvedId', fields: [PRICEBOOK2_FIELD, CURRENCY_FIELD, IS_BINDING_FIELD, STATUS_FIELD, ORIGINAL_ORDER_FIELD, CONTRACT_END_DATE_FIELD, RDD_FIELD] })
    wiredQuote({ data }) {
        if (data) {
            this._pricebook2Id      = getFieldValue(data, PRICEBOOK2_FIELD);
            this._currencyCode      = getFieldValue(data, CURRENCY_FIELD) || 'USD';
            this._isBinding         = getFieldValue(data, IS_BINDING_FIELD);
            this._quoteStatus       = getFieldValue(data, STATUS_FIELD);
            this._isChangeOrderQuote = !!getFieldValue(data, ORIGINAL_ORDER_FIELD);
            this._contractEndDate   = getFieldValue(data, CONTRACT_END_DATE_FIELD) || null;
            this._quoteRdd          = getFieldValue(data, RDD_FIELD) || null;
            this._loadActiveApprovals();
        }
    }

    get isChangeOrderQuote() { return this._isChangeOrderQuote === true; }

    @wire(getBillingAccountOptions, { quoteId: '$resolvedId' })
    wiredBanOptions({ data }) {
        if (data) {
            this._banOptions   = data.options      || [];
            this._defaultBanId = data.defaultBanId || null;
            if (this._defaultBanId && this._lines.length > 0) {
                /*this._lines = this._lines.map(l =>
                    l.Target_BAN__c ? l : { ...l, Target_BAN__c: this._defaultBanId }
                );*/
                this._cachedGroupedLines = null;
            }
        }
    }

    @wire(getQuotePricebookInfo, { quoteId: '$resolvedId' })
    wiredPricebookInfo({ data }) {
        if (data) {
            this._sitePricebookName    = data.sitePricebookName || '';
            this._accountPricebookId   = data.accountPricebookId || null;
            this._accountPricebookName = data.accountPricebookName || '';
        }
    }

    _isNRC(line) {
        const ct = (line.Charge_Type__c || '').toUpperCase();
        if (ct === 'NRC') return true;
        if (ct === 'MRC') return false;
        const code = (line.Product2?.ProductCode || line.productCode || '').toUpperCase();
        const freq = (line.BillingFrequency || '').toLowerCase();
        return code.endsWith('.NR') || freq.includes('one') || freq === 'nrc';
    }

    _isCrossConnectProduct(line) {
        const code = (line.productCode || line.Product2?.ProductCode || '').substring(0, 3).toUpperCase();
        return ['CCL','CCX','DPP','RIS'].includes(code);
    }

    @wire(getQuoteLineItems, { quoteId: '$resolvedId' })
    wiredLines(result) {
        this._wiredResult = result;
        if (result.data) {
            this._lines = result.data.map(l => ({
                ...l,
                productName:        l.Product2?.Name                    ?? '-',
                productCode:        l.Product2?.ProductCode              ?? '',
                productFamily:      l.Product2?.Family                   ?? '',
                productDescription: l.Product2?.Description              ?? '',
                // SFDC-366: the effective unit. A blank UoM__c means "inherit the
                // product default", which is the state of every line created before
                // this ticket — so both of these coalesce, never read UoM__c raw.
                // productUnit is kept because the ramp modal still reads it for the
                // custom-value label/placeholder.
                UoM__c:             l.UoM__c || l.Product2?.QuantityUnitOfMeasure || '',
                productUnit:        l.UoM__c || l.Product2?.QuantityUnitOfMeasure || '',
                Product_Attribute_Value__c: l.Product_Attribute_Value__c
                    || (l.Product2?.Show_Custom_Attribute_Value__c && l.Custom_Attribute_Value__c ? String(l.Custom_Attribute_Value__c) : '')
                    || '',
                _attributeType:     l.Product2?.Attribute_Type__c        ?? '',
                _attributeValues:   l.Product2?.Attribute_Values__c      ?? '',
                _hasAttribute:      !!l.Product2?.Attribute_Type__c,
                _originalPrice:     l.Original_OrderItem__r?.UnitPrice ?? null,
                _originalAttribute: l.Original_OrderItem__r?.Product_Attribute_Value__c ?? '',
                _serviceName:       l.Asset__r?.Name ?? '',
                _attrDisabled:      !this._isQuoteDraft || l.Line_Origin__c === 'Ramp',
                _attributeOptions:  (() => {
                    const raw = (l.Product2?.Attribute_Values__c ?? '').split(',').map(v => v.trim()).filter(Boolean);
                    const opts = [{ label: '--None--', value: '' }];
                    raw.forEach(v => opts.push({ label: v, value: v }));
                    const cur = l.Product_Attribute_Value__c ?? '';
                    if (cur && !raw.includes(cur)) opts.push({ label: cur, value: cur });
                    return opts;
                })(),
                // SFDC-366: the UoM column's per-row choices. An EMPTY array means the
                // cell renders as read-only text — that is how this one field also acts
                // as the enable/disable switch (quoteLineDatatable hasEditOptions).
                //   - Ramp lines are excluded because _executeSave drops every Ramp draft
                //     anyway, and one ramp family must carry one unit: deleteRampPhases
                //     SUMS phase quantities back onto the parent when unramping, which is
                //     meaningless if the phases disagree. Set UoM before ramping.
                //   - Non-Draft quotes are excluded, same rule as _attrDisabled above.
                // Note Allowed_UoM__c is a MULTI-SELECT picklist, so it is ';'-delimited —
                // unlike Attribute_Values__c right above, which is a comma list.
                _uomOptions:        (() => {
                    if (!this._isQuoteDraft || l.Line_Origin__c === 'Ramp') return [];
                    const dflt = l.Product2?.QuantityUnitOfMeasure ?? '';
                    const allowed = (l.Product2?.Allowed_UoM__c ?? '').split(';').map(v => v.trim()).filter(Boolean);
                    const vals = [];
                    if (dflt) vals.push(dflt);
                    allowed.forEach(v => { if (!vals.includes(v)) vals.push(v); });
                    // Keep a legacy/orphaned value selectable rather than silently dropping it
                    const cur = l.UoM__c ?? '';
                    if (cur && !vals.includes(cur)) vals.push(cur);
                    // One option is not a choice — show plain text instead of a pointless dropdown
                    return vals.length > 1 ? vals.map(v => ({ label: v, value: v })) : [];
                })(),
                _isCrossConnect:        this._isCrossConnectProduct(l) && !this._isNRC(l),
                _xcNeedsSetup:          this._isCrossConnectProduct(l) && !this._isNRC(l) && (!l.A_Side_Asset__c || !l.Z_Side_Asset__c),
                _viewIcon:              this._isCrossConnectProduct(l) && !this._isNRC(l) && (!l.A_Side_Asset__c || !l.Z_Side_Asset__c)
                                            ? 'utility:warning' : 'utility:preview',
                _viewTitle:             this._isCrossConnectProduct(l) && !this._isNRC(l) && (!l.A_Side_Asset__c || !l.Z_Side_Asset__c)
                                            ? 'Cross connect - setup needed' : 'View details',
                _capacityAssignment:    l.Product2?.Capacity_Assignment__c ?? '',
                _showCustomValue:       l.Product2?.Show_Custom_Attribute_Value__c === true,
                Custom_Attribute_Value__c: l.Custom_Attribute_Value__c ?? '',
                // SFDEV-7: show the stored value, never a derived one. The old expression
                // forced 'N/A' on screen for an NRC line and for an MRC line whose product
                // carries no Capacity_Assignment__c, so a line stored as 'Not Reserved'
                // looked settled while Quote_Screen_AcceptQuote kept blocking on it — and
                // picking 'N/A' matched the displayed value, produced no draft row, and
                // never reached _doSave (line ~2162). No row has a null Reserved__c today
                // (restricted picklist, default 'Not Reserved'), so '' is a defensive
                // fallback only: blank reads as "no value", which 'N/A' would misstate.
                Reserved__c: l.Reserved__c || '',
                lineUrl: `/lightning/r/QuoteLineItem/${l.Id}/view`,
                Target_BAN__c: l.Target_BAN__c  || null,
                // Mirrors VR_QLI_04_No_Edit_Qty_Attr_On_CO: a CO line tied to an
                // existing Asset (CHANGE/CHANGE_PRICE/DELETE) can't have its Qty
                // or Attribute edited without desyncing the line from its IB —
                // lock the whole row here so the grid never lets the user try.
                // (Ramp Phase 1 rows re-set this below in groupedLines regardless.)
                _readOnly: !!l.Asset__c && ['CHANGE', 'CHANGE_PRICE', 'DELETE'].includes(l.Change_Type__c)
            }));
            // Fallback: pick currency from line items if getRecord wire didn't return it
            if (this._currencyCode === 'USD' && this._lines.length > 0 && this._lines[0].CurrencyIsoCode) {
                this._currencyCode = this._lines[0].CurrencyIsoCode;
            }
            if (this._lines.some(l => l.Line_Origin__c === 'Ramp')) {
                this._columnDefs = this._columnDefs.map(c =>
                    (c.key === 'StartDate' || c.key === 'EndDate') ? { ...c, visible: true } : c
                );
            }
            this._error = null;
            this._cachedRampSchedule = null;
            this._cachedGroupedLines = null;
        } else if (result.error) {
            this._error  = result.error;
            this._lines  = [];
            this._cachedRampSchedule = null;
            this._cachedGroupedLines = null;
        }
    }

    // Cached getter results — invalidated when _lines changes
    _cachedRampSchedule = null;
    _cachedGroupedLines = null;
    _cachedGroupedDeps = null;

    // ─── Column picker ────────────────────────────────────────────────────

    toggleColumnPicker() {
        this.showColumnPicker = !this.showColumnPicker;
    }

    handleColumnToggle(event) {
        const key     = event.target.dataset.key;
        const checked = event.detail.checked;
        this._columnDefs = this._columnDefs.map(c =>
            c.key === key ? { ...c, visible: checked } : c
        );
        this._saveColumnPrefs();
    }

    _saveColumnPrefs() {
        const bits = this._columnDefs
            .filter(c => !c.required)
            .map(c => c.visible ? '1' : '0')
            .join('');
        saveColumnPreferences({ configJson: bits })
            .catch(() => { /* silent — prefs are best-effort */ });
    }

    // ─── Detail panel ─────────────────────────────────────────────────────

    handleSectionEdit(event) {
        this._editSection = event.currentTarget.dataset.section;
    }

    handleSectionCancel() {
        this._editSection = null;
    }

    handlePanelNav(event) {
        const section = event.currentTarget.dataset.section;
        if (section === 'inventory' && !this._selectedCapAssign) {
            return; // No inventory for products without Capacity_Assignment__c
        }
        this._panelSection = section;
        if (section === 'inventory' && this.selectedLineId && !this.inventoryLoaded) {
            this._loadLineInventory();
        }
        if (section === 'ramp') {
            this._ensureRampInit();
        }
        // Reset section editing when leaving details
        if (section !== 'details') {
            this._editSection = null;
        }
    }

    _ensureRampInit() {
        if (this._isViewingExistingRamp) return;
        if (this.showRampBuilder && this.rampPhases.length > 0) return;

        const line = this._lines.find(l => l.Id === this.selectedLineId);
        if (!line) return;

        // If line is already ramped, load existing ramp for viewing
        if (line.Line_Origin__c === 'Ramp') {
            this._loadExistingRamp();
            return;
        }

        if (!line.Quantity) {
            this._toast('Cannot Ramp', 'Line must have a quantity before adding ramp phases.', 'warning');
            this._panelSection = 'details';
            return;
        }
        this._rampSourceQty       = line.Quantity;
        this._rampSourcePrice     = line.UnitPrice || 0;
        this._rampSourceStartDate = this._getQuoteRddStr();
        this._rampSourceEndDate   = line.EndDate   || null;
        this._rampSourceAttributeOptions = line._attributeOptions || [];
        this._rampSourceAttributeValue   = line.Product_Attribute_Value__c || '';
        this._rampSourceAttributeType    = line._attributeType || '';
        this.rampType             = 'quantity';
        this._initRampPhases();
        this.showRampBuilder = true;
    }

    handleSectionSaveSuccess() {
        this._editSection = null;
        this._toast('Saved', 'Line item updated.', 'success');
        this._refreshAfterLineChange();
    }

    closeDetailPanel() {
        clearTimeout(this._customValueTimer);
        this.showDetailPanel  = false;
        this.selectedLineId   = null;
        this.selectedLineName = null;
        this.selectedLineCode = null;
        this._editSection     = null;
        this.showRampBuilder  = false;
        this.rampPhases       = [];
        this.rampType         = 'quantity';
        this._panelSection    = 'details';
        this._assignedInventory  = [];
        this._availableInventory = [];
        this.inventoryLoaded  = false;
        this._invSearchTerm   = '';
        this._selectedInvIds  = new Set();
        this._isViewingExistingRamp = false;
        this._isEditingExistingRamp = false;
        this._existingRampPhases    = [];
        this._existingRampProducts  = [];
        this._existingRampRaw       = [];
        this._rampInvoiceDisplay    = '';
    }

    // ─── Existing ramp view/edit ─────────────────────────────────────────

    _loadExistingRamp() {
        this.isLoading = true;
        getRampSiblings({ quoteLineItemId: this.selectedLineId })
            .then(result => {
                if (result && result.length > 0) {
                    // Build flat list for raw data
                    this._existingRampRaw = result;

                    // Derive unique phase numbers and unique products
                    const phaseNums = [...new Set(result.map(r => r.rampPhase))].sort((a, b) => a - b);
                    const productMap = new Map();
                    for (const r of result) {
                        if (!productMap.has(r.productCode)) {
                            productMap.set(r.productCode, { name: r.productName, code: r.productCode });
                        }
                    }

                    // Build summary table: one row per phase, columns = products
                    this._existingRampPhases = phaseNums.map(pn => {
                        const phaseLines = result.filter(r => r.rampPhase === pn);
                        const firstLine = phaseLines[0];
                        return {
                            key: `phase-${pn}`,
                            phaseNumber: pn,
                            startDate: firstLine.startDate,
                            endDate: firstLine.endDate,
                            formattedStart: this._fmtDate(firstLine.startDate),
                            formattedEnd: this._fmtDate(firstLine.endDate),
                            products: phaseLines.map(r => ({
                                id: r.id,
                                code: r.productCode,
                                name: r.productName,
                                quantity: r.quantity,
                                unitPrice: r.unitPrice,
                                formattedPrice: this._fmt(r.unitPrice),
                                attributeValue: r.attributeValue || '',
                                nrcCode: r.nrcCode || '',
                                nrcPrice: r.nrcPrice != null ? this._fmt(r.nrcPrice) : ''
                            }))
                        };
                    });

                    this._existingRampProducts = [...productMap.values()];
                    this._rampInvoiceDisplay = result[0].invoiceDisplay || '';
                    this._isViewingExistingRamp = true;
                    this._isEditingExistingRamp = false;
                    this.showRampBuilder = false;
                } else {
                    this._isViewingExistingRamp = false;
                }
            })
            .catch(err => {
                this._toast('Error', err?.body?.message || 'Could not load ramp.', 'error');
                this._isViewingExistingRamp = false;
            })
            .finally(() => { this.isLoading = false; });
    }

    _fmtDate(val) {
        if (!val) return '-';
        const d = new Date(val + 'T00:00:00');
        return d.toLocaleDateString('en-US', { year: 'numeric', month: 'short', day: 'numeric' });
    }

    /** Normalize LDS/Apex date to YYYY-MM-DD for string compare. */
    _toDateStr(val) {
        if (!val) return null;
        if (typeof val === 'string') return val.substring(0, 10);
        if (val instanceof Date && !Number.isNaN(val.getTime())) {
            return `${val.getFullYear()}-${String(val.getMonth() + 1).padStart(2, '0')}-${String(val.getDate()).padStart(2, '0')}`;
        }
        return String(val).substring(0, 10);
    }

    _getContractEndDateStr() {
        return this._toDateStr(this._contractEndDate);
    }

    _getQuoteRddStr() {
        return this._toDateStr(this._quoteRdd);
    }

    /**
     * Ramp Phase 1 start = Quote RDD (locked). Prefills/forces Phase 1 when RDD is set.
     */
    _applyRamp1Rdd(phases, startKey = 'startDate') {
        const rdd = this._getQuoteRddStr();
        if (!rdd) return;
        const p1 = phases.find(p => Number(p.phaseNumber) === 1) || phases[0];
        if (p1) {
            p1[startKey] = rdd;
            p1.startDateLocked = true;
        }
    }

    /**
     * UI-only: block ramp phases that start (or end) after Quote Contract End Date.
     * phases: array of objects; startKey/endKey select the date fields to check.
     * Returns error message or null if OK.
     */
    _validateRampWithinContract(phases, startKey = 'startDate', endKey = 'endDate') {
        const contractEnd = this._getContractEndDateStr();
        if (!contractEnd) {
            return 'Contract End Date is missing on this Quote. Set Contract Term and RDD before creating a ramp.';
        }
        const endLabel = this._fmtDate(contractEnd);
        for (let i = 0; i < phases.length; i++) {
            const start = this._toDateStr(phases[i][startKey]);
            if (start && start > contractEnd) {
                return `Ramp cannot extend beyond the Contract End Date(${endLabel}).`;
            }
            const end = this._toDateStr(phases[i][endKey]);
            if (end && end > contractEnd) {
                return `Ramp cannot extend beyond the Contract End Date(${endLabel}).`;
            }
        }
        return null;
    }


    handleEditExistingRamp() {
        if (!this._isQuoteDraft) {
            this._toast('Quote Not in Draft', 'Ramp can only be modified when the Quote is in Draft status.', 'warning');
            return;
        }
        if (this.isQuoteLocked) {
            this._toast('Locked', 'Cannot modify ramp while approvals are in progress.', 'warning');
            return;
        }
        if (!this._existingRampRaw || this._existingRampRaw.length === 0) return;

        // Derive unique phase numbers
        const phaseNums = [...new Set(this._existingRampRaw.map(r => r.rampPhase))].sort((a, b) => a - b);

        // Build unique product list by ramp family. Each family has exactly one root record
        // (Ramp_Parent_Line__c == null — the original source line). This is the same rule
        // deleteRampPhases uses (QuoteLineEditorController.cls:1801): Ramp_Phase__c is
        // unreliable as an anchor because an excluded Phase 1 leaves the source QLI on
        // globalPhase > 1, and that family then gets counted twice — once as a stale
        // "phase 1" row, again as a "later phase" find — producing duplicate rows on reopen.
        const allProductRaw = this._existingRampRaw.filter(r => r.parentLineId == null);
        const mrcLines = allProductRaw
            .map(r => this._lines.find(l => l.Id === r.id))
            .filter(Boolean);
        // Sort: MRC/Usage-Based first, NRC last (stable order across save cycles)
        mrcLines.sort((a, b) => {
            const aN = a.Charge_Type__c === 'NRC' ? 1 : 0;
            const bN = b.Charge_Type__c === 'NRC' ? 1 : 0;
            return aN - bN;
        });
        if (mrcLines.length === 0) return;

        // Find NRC lines — try Paired_MRC_Line__c first, fallback to product code
        const p1Ids = new Set(mrcLines.map(l => l.Id));
        let nrcLines = this._lines.filter(l =>
            l.Paired_MRC_Line__c && p1Ids.has(l.Paired_MRC_Line__c)
        );
        if (nrcLines.length === 0) {
            const nrcCodes = new Set(mrcLines
                .filter(l => (l.productCode || '').toUpperCase().endsWith('.RC'))
                .map(l => (l.productCode || '').toUpperCase().replace(/\.RC$/, '.NR'))
            );
            // SFDEV-11: the save only splits auto NRCs; a standalone one must not be shown as paired
            nrcLines = this._lines.filter(l =>
                l.Is_Auto_NRC__c === true &&
                nrcCodes.has((l.productCode || '').toUpperCase()) && !p1Ids.has(l.Id)
            );
        }

        this._rampMrcLines = mrcLines;
        this._rampNrcLines = nrcLines;
        this._rampModalPhaseCount = this._existingRampPhases.length;
        this._showRampAddPopover = false;
        this._isEditingRamp = true;
        this._rampInvoiceDisplayVal = this._existingRampRaw[0]?.invoiceDisplay || 'Incremental_Value';

        // Match raw entries to mrcLines by QLI Id relationship
        const findMatch = (phaseRawEntries, lineId) =>
            phaseRawEntries.find(r => r.id === lineId || r.parentLineId === lineId);
        // A repricing phase can supersede several earlier phases at once, saving one line
        // per superseded phase — so a phase may hold N lines for the same product. Taking
        // only the first would drop the rest and re-save the collapsed state.
        const findMatches = (phaseRawEntries, lineId) =>
            phaseRawEntries.filter(r => r.id === lineId || r.parentLineId === lineId);

        // Pre-populate phases from existing ramp data
        // Pre-populate phases from existing ramp data (Phase 1 start locked to Quote RDD)
        const rddStr = this._getQuoteRddStr();
        this._rampModalPhases = phaseNums.map((pn, i) => {
            const phaseLines = this._existingRampRaw.filter(r => r.rampPhase === pn);
            const sd = i === 0 ? (rddStr || phaseLines[0]?.startDate || null) : (phaseLines[0]?.startDate || null);
            return {
                id: i + 1,
                phaseNumber: i + 1,
                colClass: this._computeColClass(i + 1, sd),
                startDate: sd,
                startDateLocked: i === 0 && !!rddStr,
                notes: phaseLines[0]?.notes || '',
                products: mrcLines.map(ml => {
                    const matches = findMatches(phaseLines, ml.Id);
                    const first = matches[0];
                    const price = first ? (Number(first.unitPrice) || 0) : 0;
                    // Sibling lines all reprice the same cell, so they should agree on price.
                    // If they don't, the data was hand-edited outside this modal — say so
                    // rather than silently keeping one and writing it back over the others.
                    if (matches.some(m => (Number(m.unitPrice) || 0) !== price)) {
                        console.warn(`Ramp read-back: ${ml.productCode} phase ${pn} has lines with differing unit prices; using ${price}`);
                    }
                    return {
                        lineId: ml.Id,
                        name: ml.productName,
                        code: ml.productCode,
                        quantity: matches.reduce((sum, m) => sum + (Number(m.quantity) || 0), 0),
                        unitPrice: price,
                        attributeValue: first ? (first.attributeValue || '') : '',
                        attributeOptions: ml._attributeOptions || [],
                        customValue: first ? (first.customValue || '') : ''
                    };
                })
            };
        });

        // Auto-exclude cells for products that don't have a QLI in a given phase
        const autoExcluded = {};
        for (const ml of mrcLines) {
            for (let pi = 0; pi < phaseNums.length; pi++) {
                const phaseRaw = this._existingRampRaw.filter(r => r.rampPhase === phaseNums[pi]);
                if (findMatches(phaseRaw, ml.Id).length === 0) {
                    autoExcluded[ml.Id + '_' + (pi + 1)] = true;
                }
            }
        }
        this._rampExcludedCells = autoExcluded;

        // Restore phase links from existing ramp data — one entry per superseded phase
        const restoredLinks = {};
        for (const pn of phaseNums) {
            const phaseLines = this._existingRampRaw.filter(r => r.rampPhase === pn);
            const currentPhaseIdx = phaseNums.indexOf(pn);
            if (currentPhaseIdx < 0) continue;
            for (const ml of mrcLines) {
                const linked = findMatches(phaseLines, ml.Id)
                    .filter(raw => raw.rampLinkedPhase != null)
                    .map(raw => Number(raw.rampLinkedPhase))
                    .filter(n => n >= 1); // drop NaN / phase 0 — same guard as targetPhaseIdx >= 0
                // A phase supersedes each earlier phase at most once, so a repeat means the
                // data was edited outside this modal — collapse it, but don't hide it.
                const targets = [...new Set(linked)].sort((a, b) => a - b);
                if (targets.length !== linked.length) {
                    console.warn(`Ramp read-back: ${ml.productCode} phase ${pn} links to the same earlier phase more than once; collapsed to ${targets.join(', ')}`);
                }
                // Leave unlinked cells out of the map entirely; callers test the cell for truthiness
                if (targets.length) {
                    restoredLinks[ml.Id + '_' + (currentPhaseIdx + 1)] = targets;
                }
            }
        }
        this._rampCellLinks = restoredLinks;

        // Compute base qty from raw data.
        // Aggregate products (Merge_IB_Task): base qty = last phase qty (running capacity).
        // Non-aggregate: base qty = sum of unlinked ("Add") phases.
        const overrides = {};
        for (const ml of mrcLines) {
            if (this._isAggregateProduct(ml)) {
                // Aggregate: last phase qty = running capacity.
                // Single match by design — aggregates can't be linked, so a phase never
                // holds more than one line for them; findMatch is correct here.
                const lastPhaseRaw = this._existingRampRaw.filter(r => r.rampPhase === phaseNums[phaseNums.length - 1]);
                const lastEntry = findMatch(lastPhaseRaw, ml.Id);
                overrides[ml.Id] = lastEntry ? (Number(lastEntry.quantity) || 0) : (ml.Quantity || 0);
            } else {
                // Non-aggregate: sum of every non-linked line across all phases
                let baseQty = 0;
                for (const pn of phaseNums) {
                    const phaseRaw = this._existingRampRaw.filter(r => r.rampPhase === pn);
                    for (const entry of findMatches(phaseRaw, ml.Id)) {
                        if (!entry.rampLinkedPhase) {
                            baseQty += (Number(entry.quantity) || 0);
                        }
                    }
                }
                overrides[ml.Id] = baseQty || ml.Quantity || 0;
            }
        }
        this._rampBaseQtyOverrides = overrides;

        // Close panel, open modal
        this.showDetailPanel = false;
        this.showRampModal = true;
    }

    handleCancelEditExistingRamp() {
        this._isEditingExistingRamp = false;
        this._loadExistingRamp(); // Reload to discard changes
    }

    handleExistingPhaseChange(event) {
        const phaseId = event.currentTarget.dataset.phaseId;
        const field   = event.currentTarget.dataset.field;
        const value   = event.detail.value;
        this._existingRampPhases = this._existingRampPhases.map(p =>
            p.id === phaseId
                ? { ...p, [field]: (field === 'quantity' || field === 'unitPrice') ? Number(value) : value }
                : p
        );
    }

    handleSaveExistingRamp() {
        // Validate start dates
        for (const p of this._existingRampPhases) {
            if (!p.startDate) {
                this._toast('Validation', 'Each phase must have a start date.', 'error');
                return;
            }
        }

        this._applyRamp1Rdd(this._existingRampPhases);

        // Auto-calculate end dates (next phase start - 1 day)
        const sorted = [...this._existingRampPhases].sort((a, b) =>
            a.startDate < b.startDate ? -1 : a.startDate > b.startDate ? 1 : 0
        );
        for (let i = 0; i < sorted.length - 1; i++) {
            sorted[i].endDate = this._prevDay(sorted[i + 1].startDate);
        }
        const contractEndExisting = this._getContractEndDateStr();
        sorted[sorted.length - 1].endDate = contractEndExisting || null;

        const existingErr = this._validateRampWithinContract(sorted);
        if (existingErr) {
            this._toast('Error', existingErr, 'error');
            return;
        }

        const lines = sorted.map(p => {
            const ql = { Id: p.id };
            if (p.quantity !== undefined)       ql.Quantity                   = p.quantity;
            if (p.unitPrice !== undefined)      ql.UnitPrice                  = p.unitPrice;
            if (p.startDate)                    ql.StartDate                  = p.startDate;
            if (p.endDate)                      ql.EndDate                    = p.endDate;
            if (p.attributeValue !== undefined) ql.Product_Attribute_Value__c = p.attributeValue || null;
            return ql;
        });

        this.isLoading = true;
        updateQuoteLineItems({ lines })
            .then(() => {
                this._toast('Ramp Updated', 'Ramp phases updated.', 'success');
                this._isEditingExistingRamp = false;
                return this._refreshAfterLineChange();
            })
            .then(() => { this._loadExistingRamp(); })
            .catch(err => this._toast('Error', err?.body?.message || 'Could not update ramp.', 'error'))
            .finally(() => { this.isLoading = false; });
    }

    handleDeleteRamp() {
        if (this.isQuoteLocked) {
            this._toast('Locked', 'Cannot modify ramp while approvals are in progress.', 'warning');
            return;
        }
        // eslint-disable-next-line no-alert
        if (!confirm('Delete this ramp? All phases will be collapsed back to a single line.')) return;

        this.isLoading = true;
        deleteRampPhases({ quoteLineItemId: this.selectedLineId })
            .then(() => {
                this._toast('Ramp Deleted', 'Ramp collapsed to a single line.', 'success');
                this._mainTab = 'lines';
                this._isViewingExistingRamp = false;
                this._isEditingExistingRamp = false;
                this._existingRampPhases = [];
                this._panelSection = 'details';
                this.closeDetailPanel();
                return this._refreshAfterLineChange();
            })
            .catch(err => this._toast('Error', err?.body?.message || 'Could not delete ramp.', 'error'))
            .finally(() => { this.isLoading = false; });
    }

    handleAddPhaseToExisting() {
        if (this.isQuoteLocked) {
            this._toast('Locked', 'Cannot modify ramp while approvals are in progress.', 'warning');
            return;
        }
        // Use phase 1 as template
        const p1 = this._existingRampPhases[0];
        if (!p1) return;

        this.isLoading = true;
        addRampPhase({
            phase1Id:       p1.id,
            quantity:       p1.quantity,
            unitPrice:      p1.unitPrice,
            startDate:      new Date().toISOString().split('T')[0], // Today as placeholder
            attributeValue: p1.attributeValue || null
        })
            .then(() => {
                this._toast('Phase Added', 'New ramp phase created.', 'success');
                return this._refreshAfterLineChange();
            })
            .then(() => { this._loadExistingRamp(); })
            .catch(err => this._toast('Error', err?.body?.message || 'Could not add phase.', 'error'))
            .finally(() => { this.isLoading = false; });
    }

    // ─── Product search ───────────────────────────────────────────────────

    handleSearchInput(event) {
        this.searchTerm = event.target.value;
        clearTimeout(this._searchTimer);
        if (this.searchTerm.length < 2) {
            this.searchResults = [];
            this.showDropdown  = false;
            return;
        }
        this.showDropdown = true;
        this.isSearching  = true;
        this._searchTimer = setTimeout(() => this._runSearch(), 300);
    }

    _runSearch() {
        if (!this._pricebook2Id) { this.isSearching = false; return; }
        searchProducts({
            searchTerm: this.searchTerm,
            pricebook2Id: this._pricebook2Id,
            currencyIsoCode: this._currencyCode,
            accountPricebookId: this._accountPricebookId
        })
            .then(results => {
                this.searchResults = results.map(r => {
                    const hasAcctPrice = r.priceSource === 'account' && r.accountPrice != null;
                    const effectivePrice = hasAcctPrice ? r.accountPrice : r.unitPrice;
                    return {
                        ...r,
                        productFamily:  r.family || '',
                        effectivePrice,
                        formattedPrice: this._fmt(effectivePrice),
                        priceLabel:     hasAcctPrice
                            ? this._fmt(effectivePrice) + ' (Account)'
                            : this._fmt(r.unitPrice)
                    };
                });
                this.showDropdown = true;
            })
            .catch(err => {
                this.searchResults = [];
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Product search failed',
                    message: err.body?.message ?? 'Unable to search products. Try again.',
                    variant: 'error'
                }));
            })
            .finally(() => { this.isSearching = false; });
    }

    handleSearchBlur() {
        setTimeout(() => { this.showDropdown = false; }, 200);
    }

    handleResultSelect(event) {
        if (this.isQuoteLocked) {
            this._toast('Locked', 'Products cannot be added while approvals are in progress.', 'warning');
            return;
        }
        const pbeId = event.currentTarget.dataset.id;
        const name  = event.currentTarget.dataset.name;
        const result = this.searchResults.find(r => r.pbeId === pbeId);
        const rName = (result?.productName || '').toLowerCase();
        const isCrossConnect = rName.includes('cross connect') || rName.includes('direct connect');
        // Pass account-specific price as override when available
        const overridePrice = (result?.priceSource === 'account' && result?.accountPrice != null)
            ? result.accountPrice : null;

        this.searchTerm    = '';
        this.searchResults = [];
        this.showDropdown  = false;

        this.isLoading = true;
        addProductToQuote({ quoteId: this.resolvedId, pricebookEntryId: pbeId, quantity: 1, overrideUnitPrice: overridePrice })
            .then(() => {
                this._toast('Added', `${name} added to the quote.`, 'success');
                return this._refreshAfterLineChange();
            })
            .then(() => {
                if (isCrossConnect) {
                    const newLine = [...this._lines].reverse().find(l => l.productName === name);
                    if (newLine) {
                        this.selectedLineId   = newLine.Id;
                        this.selectedLineName = newLine.productName;
                        this.selectedLineCode = newLine.productCode;
                        this.showDetailPanel  = true;
                        this._panelSection    = 'details';
                        this._toast('Setup Required', 'Select A-side and Z-side assets for this cross connect.', 'info');
                    }
                }
            })
            .catch(err => this._toast('Add Failed', err?.body?.message || 'Could not add product.', 'error'))
            .finally(() => { this.isLoading = false; });
    }

    // ─── Row selection (multi-group aware) ────────────────────────────────

    handleRowSelection(event) {
        const groupKey     = event.currentTarget.dataset.group;
        const groupLineIds = this._getLineIdsForGroupKey(groupKey);
        const incoming     = event.detail.selectedRows.map(r => r.Id);
        const fromOthers   = this.selectedRowIds.filter(id => !groupLineIds.includes(id));
        this.selectedRowIds = [...fromOthers, ...incoming];
    }

    handleDeleteSelected() {
        if (this.isQuoteLocked) return;
        const count = this.selectedRowIds.length;
        // eslint-disable-next-line no-alert
        if (!confirm(`Remove ${count} line item${count > 1 ? 's' : ''}? This cannot be undone.`)) return;
        this._deleteLines(this.selectedRowIds);
    }

    handleSave(event) {
        this._executeSave(event.detail.draftValues);
    }

    // ─── Unified draft bar ──────────────────────────────────────────────

    handleDraftChange(event) {
        // Set true immediately — actual draft collection happens on save
        this.hasPendingDrafts = event?.detail?.hasDrafts !== false;
        // SFDC-366: warn as soon as the unit changes, not at save time. Save here is
        // also auto-scheduled, so a save-time toast could fire from a timer with no
        // user gesture behind it. Nothing is cleared or recalculated — the rep decides.
        const ch = event?.detail?.change;
        if (ch?.field === 'UoM__c' && ch.newValue !== ch.oldValue && !this._uomToastShown) {
            this._uomToastShown = true;   // one toast per draft batch, not one per row
            this._toast(
                'Unit of Measure changed',
                'Quantity and price were left as they are. Check them against the new unit before saving.',
                'warning'
            );
        }
        this._scheduleAutoSave();
    }

    handleUnifiedSave() {
        const tables = this.template.querySelectorAll('c-quote-line-datatable');
        const allDrafts = [];
        tables.forEach(t => {
            const d = t.getDraftValues();
            if (d) allDrafts.push(...d);
        });
        if (!allDrafts.length) return;
        this._executeSave(allDrafts);
    }

    handleUnifiedCancel() {
        const tables = this.template.querySelectorAll('c-quote-line-datatable');
        tables.forEach(t => t.clearDrafts());
        this._draftValues = [];
        this.hasPendingDrafts = false;
        this._uomToastShown = false;   // SFDC-366: new batch, warn again
    }

    // ─── Autosave ───────────────────────────────────────────────────────

    get autoSaveLabel() { return this._autoSave ? 'Auto' : 'Manual'; }
    get autoSaveVariant() { return this._autoSave ? 'success' : 'neutral'; }
    get autoSaveTitle() { return this._autoSave ? 'Auto-save: On - saves 1.5s after last edit' : 'Auto-save: Off - click Save manually'; }

    handleAutoSaveToggle() {
        this._autoSave = !this._autoSave;
        clearTimeout(this._autoSaveTimer);
        saveAutoSavePreference({ autoSave: this._autoSave })
            .catch(() => { /* silent */ });
    }

    _autoSaveTimer = null;

    _scheduleAutoSave() {
        if (!this._autoSave || !this.hasPendingDrafts) return;
        clearTimeout(this._autoSaveTimer);
        this._autoSaveTimer = setTimeout(() => {
            if (this.hasPendingDrafts && this._autoSave) {
                this.handleUnifiedSave();
            }
        }, 1500);
    }

    // ─── SBI billing mode validation ────────────────────────────────────

    _executeSave(drafts) {
        if (this.isQuoteLocked) {
            this._toast('Locked', 'Line items cannot be edited while approvals are in progress.', 'warning');
            return;
        }
        // Filter out edits on ramp-managed lines — those are controlled by the ramp modal
        drafts = drafts.filter(d => {
            const line = this._lines.find(l => l.Id === d.Id);
            return !line || line.Line_Origin__c !== 'Ramp';
        });
        if (!drafts.length) return;

        // FB-455/FB-960: Custom Attribute Value must be numeric. The datatable's custom-value
        // input is a plain text field (the field itself is Text on QuoteLineItem), so nothing
        // stops a keystroke-level entry like "lalala" — validate here before it ever reaches
        // the server. VR_QLI_05_Custom_Attr_Must_Be_Number is the matching backstop.
        const invalidCustomAttr = drafts.find(d => {
            if (d.Custom_Attribute_Value__c === undefined || d.Custom_Attribute_Value__c === null
                || d.Custom_Attribute_Value__c === '') return false;
            return isNaN(Number(d.Custom_Attribute_Value__c));
        });
        if (invalidCustomAttr) {
            const line = this._lines.find(l => l.Id === invalidCustomAttr.Id);
            const name = line?.productName || line?.Product2?.Name || invalidCustomAttr.Id;
            this._toast('Invalid Value', `Custom Attribute Value for "${name}" must be a number.`, 'error');
            return;
        }

        // FB-808: Billing Mode is editable from Draft through Presented regardless of Is_Binding__c.
        // This gate returned before the SBI acknowledgement below, so a non-binding quote could
        // neither change Billing Mode nor raise the Special Instruction for Finance. Acceptance is
        // still blocked server-side by VR_QLI_No_Edit_After_Presented. Retained in case the
        // binding precondition is reinstated.
        // if (!this._isBinding) {
        //     const hasBillingModeChange = drafts.some(d => {
        //         if (d.Billing_Mode__c === undefined) return false;
        //         const orig = this._lines.find(l => l.Id === d.Id);
        //         return orig && orig.Billing_Mode__c === 'Advance' && d.Billing_Mode__c === 'Arrear';
        //     });
        //     if (hasBillingModeChange) {
        //         this._toast('Not Allowed', 'Billing Mode cannot be changed from Advance to Arrear on a non-binding quote. Mark the quote as Binding first.', 'error');
        //         return;
        //     }
        // }

        // Check for non-standard billing mode changes (Advance → Arrears)
        const sbiDetails = [];
        for (const d of drafts) {
            if (d.Billing_Mode__c !== undefined) {
                const orig = this._lines.find(l => l.Id === d.Id);
                if (orig && orig.Billing_Mode__c === 'Advance' && d.Billing_Mode__c === 'Arrear') {
                    const name = orig.productName || orig.Product2?.Name || d.Id;
                    sbiDetails.push(`• ${name}: Advance → Arrear`);
                }
            }
        }

        if (sbiDetails.length > 0) {
            this._pendingSbiDrafts = drafts;
            this._sbiChangeDetails = sbiDetails;
            this.showSbiWarning = true;
            return;
        }

        this._doSave(drafts);
    }

    get sbiChangeDetails() {
        return this._sbiChangeDetails;
    }

    handleSbiConfirm() {
        this.showSbiWarning = false;
        const drafts = this._pendingSbiDrafts;
        this._pendingSbiDrafts = null;
        this._sbiChangeDetails = [];
        this._doSave(drafts);
    }

    handleSbiCancel() {
        this.showSbiWarning = false;
        this._pendingSbiDrafts = null;
        this._sbiChangeDetails = [];
        // Revert all draft values so the UI reflects the original data
        const tables = this.template.querySelectorAll('c-quote-line-datatable');
        tables.forEach(t => t.clearDrafts());
        this.hasPendingDrafts = false;
    }

    _doSave(drafts) {
        const lines = drafts.map(d => {
            const ql = { Id: d.Id };
            if (d.Quantity  !== undefined) ql.Quantity  = d.Quantity;
            if (d.UnitPrice !== undefined) ql.UnitPrice = d.UnitPrice;
            if (d.Discount  !== undefined) ql.Discount  = d.Discount;
            if (d.StartDate !== undefined) ql.StartDate = d.StartDate;
            if (d.EndDate   !== undefined) ql.EndDate   = d.EndDate;
            if (d.Reserved__c !== undefined) ql.Reserved__c = d.Reserved__c;
            if (d.Billing_Mode__c !== undefined) ql.Billing_Mode__c = d.Billing_Mode__c;
            if (d.Target_BAN__c !== undefined) ql.Target_BAN__c = d.Target_BAN__c || null;
            if (d.Line_Remarks__c !== undefined) ql.Line_Remarks__c = d.Line_Remarks__c;
            if (d.Product_Attribute_Value__c !== undefined) ql.Product_Attribute_Value__c = d.Product_Attribute_Value__c;
            if (d.Custom_Attribute_Value__c !== undefined) ql.Custom_Attribute_Value__c = d.Custom_Attribute_Value__c;
            if (d.List_Price__c !== undefined) ql.List_Price__c = d.List_Price__c;
            // SFDC-366. This allowlist is the ONLY gate — updateQuoteLineItems does a
            // bare doUpdate — so a field missing from here is dropped without an error.
            if (d.UoM__c !== undefined) ql.UoM__c = d.UoM__c || null;
            return ql;
        });
        this.isLoading = true;
        updateQuoteLineItems({ lines })
            .then(() => {
                this._toast('Saved', 'Line items updated.', 'success');
                const tables = this.template.querySelectorAll('c-quote-line-datatable');
                tables.forEach(t => t.clearDrafts());
                this.hasPendingDrafts = false;
                this._uomToastShown = false;   // SFDC-366: new batch, warn again
            })
            .then(() => {
                this._loadActiveApprovals();
                return this._refreshAfterLineChange();
            })
            .then(() => {
                this._draftValues = [];
            })
            .catch(err => {
                const msg = err?.body?.message
                    || err?.body?.output?.errors?.[0]?.message
                    || err?.message
                    || 'Could not save changes.';
                this._toast('Save Failed', msg, 'error');
                // A rejected save (e.g. a validation rule error) must not leave the
                // invalid entry displayed — revert the grid to server state so the
                // user isn't misled into thinking the edit went through.
                const tables = this.template.querySelectorAll('c-quote-line-datatable');
                tables.forEach(t => t.clearDrafts());
                this.hasPendingDrafts = false;
                this._draftValues = [];
            })
            .finally(() => { this.isLoading = false; });
    }

    // ─── Attribute picklist change ───────────────────────────────────────

    handleAttributeChange(event) {
        const { rowId, value } = event.detail;
        const lines = [{ Id: rowId, Product_Attribute_Value__c: value }];
        this.isLoading = true;
        updateQuoteLineItems({ lines })
            .then(() => {
                this._toast('Saved', 'Attribute updated.', 'success');
                return this._refreshAfterLineChange();
            })
            .catch(err => {
                this._toast('Save Failed', err?.body?.message || 'Could not save attribute.', 'error');
                // Revert the picklist to the actual server value on rejection.
                return this._refreshAfterLineChange();
            })
            .finally(() => { this.isLoading = false; });
    }

    // ─── Row actions ──────────────────────────────────────────────────────

    handleRowAction(event) {
        const actionName = event.detail.action.name;
        if (actionName === 'moveUp' || actionName === 'moveDown') {
            this._reorderLine(event.detail.row.Id, actionName === 'moveUp' ? 'up' : 'down');
            return;
        }
        if (actionName === 'view') {
            this.selectedLineId   = event.detail.row.Id;
            this.selectedLineName = event.detail.row.productName;
            this.selectedLineCode = event.detail.row.productCode;
            this._selectedCapAssign = event.detail.row._capacityAssignment || '';
            this.showDetailPanel  = true;
            this._editSection     = null;
            this.showColumnPicker = false;
            // Reset inventory tab so stale data from another line doesn't show
            this._assignedInventory  = [];
            this._availableInventory = [];
            this.inventoryLoaded  = false;
            this._invSearchTerm   = '';
            this._selectedInvIds  = new Set();
            // Reset ramp state so stale ramp data doesn't bleed across lines
            this._isViewingExistingRamp = false;
            this._isEditingExistingRamp = false;
            this._existingRampPhases    = [];
            this.showRampBuilder  = false;
            this.rampPhases       = [];
            // Auto-set inventory filter based on product's Capacity_Assignment__c
            this._invTypeFilter   = this._detectInvType(this.selectedLineCode, this._selectedCapAssign);
            // If switching to a line without capacity assignment while on inventory tab, go to details
            if (!this._selectedCapAssign && this._panelSection === 'inventory') {
                this._panelSection = 'details';
            }
            // If switching to a non-ramped line while on ramp tab, go to details
            if (this._panelSection === 'ramp') {
                this._panelSection = 'details';
            }
        }
    }

    _reorderLine(lineId, direction) {
        if (!this.allowLineReorder || !lineId || this.isLoading) return;
        if (this.hasPendingDrafts) {
            this._toast('Save changes first', 'Save or cancel unsaved edits before reordering lines.', 'warning');
            return;
        }
        this.isLoading = true;
        reorderQuoteLineItem({
            quoteId: this.resolvedId,
            lineId,
            direction
        })
            .then(() => this._refreshAfterLineChange())
            .catch(err => this._toast(
                'Reorder Failed',
                err?.body?.message || 'Could not reorder line.',
                'error'
            ))
            .finally(() => { this.isLoading = false; });
    }

    /**
     * Detect the expected inventory type from the product's
     * Capacity_Assignment__c field; falls back to code prefix.
     */
    _detectInvType(code, capAssign) {
        // Prefer the explicit Capacity_Assignment__c value
        if (capAssign) {
            const ca = capAssign.toLowerCase();
            if (ca.startsWith('space'))   return 'Space';
            if (ca.startsWith('breaker')) return 'Breaker';
        }
        // Fallback to code prefix
        if (!code) return 'All';
        const pfx = code.substring(0, 3).toUpperCase();
        if (pfx === 'CAB' || pfx === 'CAG' || pfx === 'HYS' || pfx === 'SPC') return 'Space';
        if (pfx === 'POW' || pfx === 'CCX' || pfx === 'PCM')                   return 'Breaker';
        return 'All';
    }

    /**
     * For Space products, determine the expected Space_Type__c.
     * CAB* / SPC* → Cabinet, CAG* → Cage, HYS* → null (could be cage or hall)
     */
    _detectSpaceType(code) {
        if (!code) return null;
        const pfx = code.substring(0, 3).toUpperCase();
        if (pfx === 'CAB' || pfx === 'SPC') return 'Cabinet';
        if (pfx === 'CAG') return 'Cage';
        return null;
    }

    // ─── Inventory tab ─────────────────────────────────────────────────────

    // Single lookup — all detail panel getters reference this instead of repeated .find()
    get _selectedLine() {
        if (!this.selectedLineId) return null;
        return this._lines.find(l => l.Id === this.selectedLineId) || null;
    }

    get selectedLineQuantity()         { return this._effectiveLineQuantity(this._selectedLine); }

    // FB-779: On a ramped product the Phase-1 record only carries Phase-1's
    // Quantity, so the inventory panel was capping assignment at that (e.g. 1)
    // even though the Lines grid shows the aggregated quantity (e.g. 3). Mirror
    // the exact aggregation used by groupedLines so the inventory target matches
    // the displayed line quantity: aggregate products use the last (running-peak)
    // phase, others use the sum of net additions (unlinked phases). Non-ramp
    // lines are unchanged — they just return their own Quantity.
    _effectiveLineQuantity(line) {
        if (!line) return 0;
        // Parent test is the empty parent pointer, not phase 1 — a product excluded from
        // phase 1 is still the parent, and treating it as a plain line reserved only its
        // first phase's quantity instead of the rolled-up figure the grid shows.
        const isRampParent = line.Line_Origin__c === 'Ramp'
            && !line.Ramp_Parent_Line__c
            && line.Charge_Type__c !== 'NRC';
        if (!isRampParent) return line.Quantity || 0;

        const siblings = this._lines.filter(s =>
            s.Line_Origin__c === 'Ramp' &&
            s.Charge_Type__c !== 'NRC' &&
            (s.Ramp_Parent_Line__c === line.Id || s.Id === line.Id)
        );
        if (!siblings.length) return line.Quantity || 0;

        if (this._isAggregateProduct(line)) {
            const lastSibling = siblings.reduce((max, s) =>
                (s.Ramp_Phase__c || 0) > (max.Ramp_Phase__c || 0) ? s : max, siblings[0]);
            return lastSibling.Quantity || 0;
        }
        return siblings
            .filter(s => !s.Ramp_Linked_Phase__c)
            .reduce((sum, s) => sum + (s.Quantity || 0), 0);
    }
    get selectedLineHasAttribute()     { return !!this._selectedLine?._hasAttribute; }
    get selectedLineAttributeOptions() { return this._selectedLine?._attributeOptions || []; }
    get selectedLineAttributeValue()   { return this._selectedLine?.Product_Attribute_Value__c || ''; }
    get selectedLineOriginalPrice() {
        const p = this._selectedLine?._originalPrice;
        if (p == null) return '—';
        return new Intl.NumberFormat('en-US', { style: 'currency', currency: this._currencyCode || 'USD', minimumFractionDigits: 2 }).format(p);
    }
    get selectedLineOriginalAttribute() { return this._selectedLine?._originalAttribute || '—'; }
    get selectedLineBillingFrequency() { return this._selectedLine?.BillingFrequency || ''; }
    get selectedLineRampPhase()        { return this._selectedLine?.Ramp_Phase__c || ''; }

    get selectedLineStartDate() {
        const sd = this._selectedLine?.StartDate;
        return sd ? new Date(sd + 'T00:00:00').toLocaleDateString('en-US', { year: 'numeric', month: 'short', day: 'numeric' }) : '';
    }

    get selectedLineEndDate() {
        const ed = this._selectedLine?.EndDate;
        return ed ? new Date(ed + 'T00:00:00').toLocaleDateString('en-US', { year: 'numeric', month: 'short', day: 'numeric' }) : '';
    }

    handleDetailAttributeChange(event) {
        this.handleAttributeChange({
            detail: { rowId: this.selectedLineId, value: event.detail.value }
        });
    }

    get assignedInventory() {
        return this._assignedInventory.map(r => this._enrichInv(r));
    }
    get hasAssignedInventory() { return this._assignedInventory.length > 0; }
    get hasAvailableInventory() { return this._availableInventory.length > 0; }

    get inventoryProgressLabel() {
        const qty = Math.floor(this.selectedLineQuantity);
        const assigned = this._assignedInventory.length;
        if (qty <= 0) return 'No assignment required';
        return `${assigned} of ${qty} assigned`;
    }

    get isInventoryComplete() {
        const qty = Math.floor(this.selectedLineQuantity);
        return qty > 0 && this._assignedInventory.length >= qty;
    }

    get inventoryProgressStyle() {
        const qty = Math.floor(this.selectedLineQuantity);
        if (qty <= 0) return 'width:100%';
        const pct = Math.min(100, Math.round((this._assignedInventory.length / qty) * 100));
        return `width:${pct}%`;
    }

    get inventoryProgressBarClass() {
        return this.isInventoryComplete
            ? 'qle-inv-progress-fill qle-inv-progress-fill_complete'
            : 'qle-inv-progress-fill';
    }

    get isAssignDisabled() {
        return this.isInventoryBusy || this.isInventoryComplete;
    }

    // ─── Ramp builder ───────────────────────────────────────────────────

    get isQtyRamp()       { return this.rampType === 'quantity'; }
    get isPriceRamp()     { return this.rampType === 'price'; }
    get isAttributeRamp() { return this.rampType === 'attribute'; }
    get qtyRampVariant()       { return this.rampType === 'quantity'  ? 'brand' : 'neutral'; }
    get priceRampVariant()     { return this.rampType === 'price'     ? 'brand' : 'neutral'; }
    get attributeRampVariant() { return this.rampType === 'attribute' ? 'brand' : 'neutral'; }
    get rampHasAttribute()     { return this._rampSourceAttributeOptions.length > 1; }
    get rampAttributeOptions() { return this._rampSourceAttributeOptions; }
    get rampAttributeLabel()   { return this._rampSourceAttributeType || 'Attribute'; }

    // Aggregate products use independent qty per phase (Merge IB Task = true in Odoo)
    get isIndependentQtyRamp() {
        if (!this.selectedLineId) return false;
        const line = this._lines.find(l => l.Id === this.selectedLineId);
        return line ? !!line.Merge_IB_Task__c : false;
    }

    _isAggregateProduct(line) {
        return !!line?.Merge_IB_Task__c || !!line?.Product2?.Merge_IB_Task__c;
    }

    get rampSourceQty()            { return this._rampSourceQty; }
    get rampSourcePriceFormatted() { return this._fmt(this._rampSourcePrice); }
    get rampPriceLabel()           { return `Price (${this._currencyCode || 'USD'})`; }
    get rampTotalAllocated()       { return this.rampPhases.reduce((s, p) => s + (Number(p.quantity) || 0), 0); }
    get rampRemainingQty()         { return this._rampSourceQty - this.rampTotalAllocated; }
    get hasRampRemaining()         { return !this.isIndependentQtyRamp && this.rampRemainingQty > 0; }
    get rampOverAllocated()        { return !this.isIndependentQtyRamp && this.rampRemainingQty < 0; }
    get rampOverAmount()           { return Math.abs(this.rampRemainingQty); }
    get showQtyAllocationStatus()  { return this.isQtyRamp && !this.isIndependentQtyRamp; }

    get canAddRampPhase() {
        if (this.isPriceRamp || this.isAttributeRamp) return true;
        if (this.isIndependentQtyRamp) return true;
        return this.rampRemainingQty > 0;
    }

    get rampSaveDisabled() {
        if (this.isLoading) return true;
        return this.isQtyRamp && !this.isIndependentQtyRamp && this.rampOverAllocated;
    }

    get rampStatusClass() {
        if (this.isPriceRamp || this.isAttributeRamp) return 'qle-ramp-status';
        if (this.rampOverAllocated) return 'qle-ramp-status qle-ramp-status_error';
        if (this.hasRampRemaining)  return 'qle-ramp-status qle-ramp-status_warning';
        return 'qle-ramp-status qle-ramp-status_success';
    }

    _initRampPhases() {
        this._rampNextId = 2;
        const rdd = this._getQuoteRddStr();
        this.rampPhases = [{
            id: 1, phaseNumber: 1,
            quantity:       this._rampSourceQty,
            unitPrice:      this._rampSourcePrice,
            attributeValue: this._rampSourceAttributeValue,
            startDate:      rdd,
            startDateLocked: !!rdd,
            canRemove:      false
        }];
    }

    handleAddRamp() {
        if (this.isQuoteLocked) {
            this._toast('Locked', 'Ramp cannot be modified while approvals are in progress.', 'warning');
            return;
        }
        const line = this._lines.find(l => l.Id === this.selectedLineId);
        if (!line || !line.Quantity) {
            this._toast('Cannot Ramp', 'Line must have a quantity before adding ramp phases.', 'warning');
            return;
        }
        this._rampSourceQty       = line.Quantity;
        this._rampSourcePrice     = line.UnitPrice || 0;
        this._rampSourceStartDate = this._getQuoteRddStr();
        this._rampSourceEndDate   = line.EndDate   || null;
        this._rampSourceAttributeOptions = line._attributeOptions || [];
        this._rampSourceAttributeValue   = line.Product_Attribute_Value__c || '';
        this._rampSourceAttributeType    = line._attributeType || '';
        this.rampType             = 'quantity';
        this._initRampPhases();
        this.showRampBuilder = true;
        this._panelSection   = 'ramp';
    }

    handleSelectQtyRamp()       { if (this.rampType !== 'quantity')  { this.rampType = 'quantity';  this._initRampPhases(); } }
    handleSelectPriceRamp()     { if (this.rampType !== 'price')     { this.rampType = 'price';     this._initRampPhases(); } }
    handleSelectAttributeRamp() { if (this.rampType !== 'attribute') { this.rampType = 'attribute'; this._initRampPhases(); } }

    handleAddRampPhase() {
        if (this.isQtyRamp && !this.isIndependentQtyRamp && this.rampRemainingQty <= 0) return;
        this.rampPhases = [...this.rampPhases, {
            id:             this._rampNextId++,
            phaseNumber:    this.rampPhases.length + 1,
            quantity:       (this.isQtyRamp && !this.isIndependentQtyRamp) ? this.rampRemainingQty : this._rampSourceQty,
            unitPrice:      this._rampSourcePrice,
            attributeValue: this._rampSourceAttributeValue,
            startDate:      null,
            canRemove:      true
        }];
    }

    handleRemoveRampPhase(event) {
        const phaseId = Number(event.currentTarget.dataset.phaseId);
        this.rampPhases = this.rampPhases
            .filter(p => p.id !== phaseId)
            .map((p, i) => ({ ...p, phaseNumber: i + 1, canRemove: i > 0 }));
    }

    handleRampPhaseChange(event) {
        const phaseId = Number(event.currentTarget.dataset.phaseId);
        const field   = event.currentTarget.dataset.field;
        const value   = event.detail.value;
        this.rampPhases = this.rampPhases.map(p => {
            if (p.id !== phaseId) return p;
            if (field === 'startDate' && p.startDateLocked) return p;
            return { ...p, [field]: (field === 'quantity' || field === 'unitPrice') ? Number(value) : value };
        });
    }

    handleCancelRamp() {
        this.showRampBuilder = false;
        this.rampPhases      = [];
        this.rampType        = 'quantity';
        this._panelSection   = 'details';
    }

    handleSaveRamp() {
        let phases = [...this.rampPhases];

        this._applyRamp1Rdd(phases);

        // All types: validate start dates present
        for (const p of phases) {
            if (!p.startDate) {
                this._toast('Validation', 'Each phase must have a start date.', 'error');
                return;
            }
        }

        // Sort by startDate ascending
        phases.sort((a, b) => (a.startDate < b.startDate ? -1 : a.startDate > b.startDate ? 1 : 0));

        // Qty ramp (distributed): auto-generate final phase for remaining quantity
        if (this.isQtyRamp && !this.isIndependentQtyRamp) {
            const remaining = this._rampSourceQty - phases.reduce((s, p) => s + (Number(p.quantity) || 0), 0);
            if (remaining > 0) {
                phases.push({ quantity: remaining, startDate: null });
            }
        }

        // All qty ramps (distributed + independent): validate qty > 0
        if (this.isQtyRamp) {
            for (const p of phases) {
                if (p.quantity == null || p.quantity < 0) {
                    this._toast('Validation', 'Each phase quantity cannot be negative.', 'error');
                    return;
                }
            }
        }

        // Price ramp OR attribute ramp: validate prices
        if (this.isPriceRamp || this.isAttributeRamp) {
            for (const p of phases) {
                if (p.unitPrice == null || p.unitPrice < 0) {
                    this._toast('Validation', 'Each phase must have a valid unit price.', 'error');
                    return;
                }
            }
        }

        // Attribute ramp: validate attribute values set
        if (this.isAttributeRamp) {
            for (const p of phases) {
                if (!p.attributeValue) {
                    this._toast('Validation', `Each phase must have a ${this.rampAttributeLabel} value.`, 'error');
                    return;
                }
            }
        }

        // Auto-calculate end dates: each phase ends the day before the next starts
        for (let i = 0; i < phases.length - 1; i++) {
            phases[i].endDate = this._prevDay(phases[i + 1].startDate);
        }
        // Last phase: close on Quote Contract End (fallback: source end / open)
        const contractEnd = this._getContractEndDateStr();
        phases[phases.length - 1].endDate = contractEnd || this._rampSourceEndDate || null;

        // Block ramp dates beyond contract term (UI-only; Apex backstop TBD)
        const contractErr = this._validateRampWithinContract(phases);
        if (contractErr) {
            this._toast('Error', contractErr, 'error');
            return;
        }

        // SF rejects same-day StartDate/EndDate without EndTime > StartTime.
        // Strip endDate from payload when it equals startDate.
        const safeEnd = (p) => (p.endDate && p.endDate === p.startDate) ? null : (p.endDate || null);

        // Build payload per ramp type
        let payload;
        if (this.isQtyRamp) {
            payload = phases.map(p => ({ quantity: p.quantity, startDate: p.startDate, endDate: safeEnd(p) }));
        } else if (this.isAttributeRamp) {
            payload = phases.map(p => ({
                quantity: this._rampSourceQty, unitPrice: p.unitPrice,
                attributeValue: p.attributeValue, startDate: p.startDate, endDate: safeEnd(p)
            }));
        } else {
            payload = phases.map(p => ({ unitPrice: p.unitPrice, startDate: p.startDate, endDate: safeEnd(p) }));
        }

        this.isLoading = true;
        splitRampLines({
            sourceLineId: this.selectedLineId,
            phasesJson:   JSON.stringify(payload),
            rampType:     this.rampType
        })
            .then(() => {
                this._toast('Ramp Created', `Line split into ${phases.length} ramp phases.`, 'success');
                this.showRampBuilder = false;
                this.rampPhases      = [];
                this._panelSection   = 'details';
                this.closeDetailPanel();
                return this._refreshAfterLineChange();
            })
            .catch(err => this._toast('Ramp Failed', err?.body?.message || 'Could not split line into ramp phases.', 'error'))
            .finally(() => { this.isLoading = false; });
    }

    // ─── Multi-product ramp modal ────────────────────────────────────────

    get hasRampNrcLines()      { return this._rampNrcLines.length > 0; }
    get isRampModalQty()       { return this._rampModalType === 'quantity'; }
    get isRampModalPrice()     { return this._rampModalType === 'price'; }
    get isRampModalAttr()      { return this._rampModalType === 'attribute'; }
    get rampModalQtyCls()      { return 'qle-ramp-type-btn' + (this._rampModalType === 'quantity'  ? ' qle-ramp-type-on' : ''); }
    get rampModalPriceCls()    { return 'qle-ramp-type-btn' + (this._rampModalType === 'price'     ? ' qle-ramp-type-on' : ''); }
    get rampModalAttrCls()     { return 'qle-ramp-type-btn' + (this._rampModalType === 'attribute' ? ' qle-ramp-type-on' : ''); }

    get rampModalHasAttribute() {
        return this._rampMrcLines.length > 0 && this._rampMrcLines.every(l => l._hasAttribute);
    }

    /**
     * SFDC-208: the ceiling moved from 12 to 30 (a 10-year term needs 13 phases, and Darren
     * has a deal at 25). One button per number stops working at that size — 29 of them wrap
     * into a block — so the quick-pick row is capped at PHASE_PICK_MAX and anything beyond
     * is driven by the stepper below it. Both routes go through _setPhaseCount.
     */
    get phaseCountOptions() {
        const opts = [];
        for (let n = RAMP_PHASE_MIN; n <= PHASE_PICK_MAX; n++) {
            opts.push({
                value: n,
                label: String(n),
                cls: 'qle-ramp-count-pill' + (this._rampModalPhaseCount === n ? ' qle-ramp-count-pill_on' : '')
            });
        }
        return opts;
    }

    get rampPhaseCount()      { return this._rampModalPhaseCount; }
    get phaseStepDownDisabled() { return this._rampModalPhaseCount <= RAMP_PHASE_MIN; }
    get phaseStepUpDisabled()   { return this._rampModalPhaseCount >= RAMP_PHASE_MAX; }
    /** Dim the stepper's readout while a quick-pick button already shows the same number */
    get phaseStepValueCls() {
        return 'qle-ramp-step-value'
            + (this._rampModalPhaseCount > PHASE_PICK_MAX ? ' qle-ramp-step-value_active' : '');
    }

    get rampModalProductCount() {
        return this._rampMrcLines.length + this._rampNrcLines.length;
    }

    get rampModalTitle() {
        return this._isEditingRamp ? 'Edit Ramp' : 'Create Ramp';
    }

    get rampModalSaveLabel() {
        return this._isEditingRamp ? 'Update Ramp' : 'Create Ramp';
    }

    get rampNrcSummary() {
        return `+ ${this._rampNrcLines.length} NRC auto-included`;
    }

    get rampMrcChips() {
        const canRemove = this._rampMrcLines.length > 1;
        return this._rampMrcLines.map(l => ({
            id: l.Id,
            code: l.productCode,
            attr: l.Product_Attribute_Value__c || '',
            canRemove
        }));
    }

    // Grid layout: products as rows, phases as columns
    get rampGridCls() {
        const n = this._rampModalPhaseCount;
        return 'qle-ramp-grid' + (n >= 10 ? ' qle-ramp-dense' : n >= 7 ? ' qle-ramp-compact' : '');
    }

    get rampGridStyle() {
        const hasAnyAttr = this._rampMrcLines.some(l => l._hasAttribute);
        const minCol = hasAnyAttr ? 180 : 150;
        return `grid-template-columns: 140px repeat(${this._rampModalPhaseCount}, minmax(${minCol}px, 1fr))`;
    }

    get rampModalWidthStyle() {
        const base = 140 + 80; // product col + padding
        const hasAnyAttr = this._rampMrcLines.some(l => l._hasAttribute);
        const perPhase = hasAnyAttr ? 200 : 170;
        const px = base + this._rampModalPhaseCount * perPhase;
        return `width: ${px}px; max-width: 92vw;`;
    }

    get _rampGridRows() {
        // Pre-index phase products for O(1) lookups instead of O(n) .find() per cell
        const prodIdx = {};
        for (const phase of this._rampModalPhases) {
            for (const prod of phase.products) {
                prodIdx[prod.lineId + '_' + phase.id] = prod;
            }
        }
        // Pre-index phases by id and position
        const phaseById = {};
        const phaseIdxById = {};
        this._rampModalPhases.forEach((phase, idx) => {
            phaseById[phase.id] = phase;
            phaseIdxById[phase.id] = idx;
        });

        return this._rampMrcLines.map(line => {
            const isAggregate = this._isAggregateProduct(line);
            let phaseComputed;
            if (isAggregate) {
                const lastPhase = this._rampModalPhases[this._rampModalPhases.length - 1];
                const lastPd = lastPhase ? prodIdx[line.Id + '_' + lastPhase.id] : null;
                phaseComputed = Number(lastPd?.quantity) || 0;
            } else {
                // Non-aggregate: base qty = sum of all phase qtys
                phaseComputed = this._rampModalPhases.reduce((sum, phase) => {
                    const pd = prodIdx[line.Id + '_' + phase.id];
                    return sum + (Number(pd?.quantity) || 0);
                }, 0);
            }
            const override = this._rampBaseQtyOverrides[line.Id];
            const baseQty = override != null ? override : (phaseComputed || line.Quantity || 0);
            // One connector per LINK, not per linked cell — a cell superseding three phases
            // draws three lines, so the track row has to be tall enough for all of them
            const prodLinkCount = Object.entries(this._rampCellLinks)
                .filter(([k]) => k.startsWith(line.Id + '_'))
                .reduce((n, [, targets]) => n + (targets ? targets.length : 0), 0);
            const trackHeight = Math.max(20, 10 + prodLinkCount * 8);
            return {
            lineId: line.Id,
            trackKey: 'trk_' + line.Id,
            trackStyle: `height:${trackHeight}px`,
            code: line.productCode,
            name: line.productName,
            attrLabel: line.Product_Attribute_Value__c || '',
            isAggregate,
            aggregateLabel: isAggregate ? 'Aggregate' : 'Non-Aggregate',
            aggregateCls: isAggregate ? 'qle-ramp-grid-agg qle-ramp-grid-agg_yes' : 'qle-ramp-grid-agg qle-ramp-grid-agg_no',
            baseQty: baseQty,
            qty: line.Quantity,
            cells: this._rampModalPhases.map((phase, phaseIdx) => {
                const prod = prodIdx[line.Id + '_' + phase.id];
                const opts = prod ? prod.attributeOptions : [];
                const rawQty   = prod ? prod.quantity  : 0;
                const rawPrice = prod ? prod.unitPrice : 0;
                const rawCv    = prod ? prod.customValue : '';
                const needsInput = !rawQty && !rawPrice;
                const baseCellClass = phase.id % 2 !== 0 ? 'qle-ramp-grid-cell qle-ramp-col-tint' : 'qle-ramp-grid-cell';

                // Exclusion + link data
                const cellLinkKey = `${line.Id}_${phase.id}`;
                const isExcluded = !!this._rampExcludedCells[cellLinkKey];
                const linkedTo = this._rampCellLinks[cellLinkKey] || [];
                const hasLink = linkedTo.length > 0;
                const isLinkable = phaseIdx > 0;
                const linkLocked = this._isLinkLocked(line.Id, phase.id);
                const linkedPhases = linkedTo.map(id => phaseById[id]).filter(Boolean);
                const eligible = this._eligibleLinkTargets(line.Id, phase.id);
                const selected = new Set(linkedTo);
                // "All" only when every eligible target is picked and nothing stale is picked.
                // Needs 2+ eligible, so a lone target still reads "Phase N", not "All Phases".
                const allEligibleSelected = eligible.length > 1 &&
                    linkedTo.length === eligible.length &&
                    eligible.every(p => selected.has(p.id));
                const pillOptions = [{ label: 'None (Add)', value: '', mark: '', cls: 'qle-ramp-pill-opt' }];
                for (const p of eligible) {
                    const isSel = selected.has(p.id);
                    pillOptions.push({
                        label: `Phase ${p.phaseNumber}`,
                        value: String(p.id),
                        mark: isSel ? '\u2611' : '\u2610',
                        cls: 'qle-ramp-pill-opt' + (isSel ? ' qle-ramp-pill-opt-sel' : '')
                    });
                }
                if (eligible.length > 1) {
                    pillOptions.push({
                        label: 'All Phases',
                        value: '*',
                        mark: allEligibleSelected ? '\u2611' : '\u2610',
                        cls: 'qle-ramp-pill-opt qle-ramp-pill-opt-all' + (allEligibleSelected ? ' qle-ramp-pill-opt-sel' : '')
                    });
                }
                // Toggling leaves the menu open, so it needs an explicit way out
                pillOptions.push({ label: 'Done', value: 'done', mark: '', cls: 'qle-ramp-pill-opt qle-ramp-pill-opt-done' });

                let pillLabel = 'Link Phase';
                if (allEligibleSelected) {
                    pillLabel = '\u2190 All Phases';
                } else if (linkedTo.length === 1) {
                    pillLabel = `\u2190 Phase ${linkedPhases[0] ? linkedPhases[0].phaseNumber : '?'}`;
                } else if (linkedTo.length > 1) {
                    const nums = linkedTo.map(id => (phaseById[id] ? phaseById[id].phaseNumber : '?'));
                    pillLabel = `\u2190 Phases ${nums.join(', ')}`;
                }

                // Linked cell: qty is the SUM of every superseded phase's qty, read-only —
                // repricing 2+2+2 from phases 1-3 shows 6 here but still saves 3 lines of 2.
                // Summed from the link targets, not from this cell's own stored quantity.
                let displayQty = rawQty;
                let qtyDisabled = false;
                if (linkedPhases.length) {
                    displayQty = linkedPhases.reduce((sum, lp) => {
                        const srcProd = prodIdx[line.Id + '_' + lp.id];
                        return sum + (srcProd ? (Number(srcProd.quantity) || 0) : 0);
                    }, 0);
                    qtyDisabled = true;
                }

                return {
                    key: `${line.Id}-${phase.id}`,
                    phaseId: phase.id,
                    lineId: line.Id,
                    cellClass: needsInput ? baseCellClass + ' qle-ramp-cell-empty' : baseCellClass,
                    quantity: (displayQty === null || displayQty === undefined) ? '' : displayQty,
                    qtyDisabled,
                    unitPrice: (rawPrice === null || rawPrice === undefined) ? '' : rawPrice,
                    attributeValue: prod ? prod.attributeValue : '',
                    attributeOptions: opts,
                    hasAttribute: line._hasAttribute && Array.isArray(opts) && opts.length > 1,
                    attributeLabel: line._attributeType || 'Attribute',
                    showCustomValue: !!line._showCustomValue || !!line.Merge_IB_Task__c || !!line.Product2?.Merge_IB_Task__c,
                    customValue: rawCv || '',
                    customValueLabel: line._attributeType ? `${line._attributeType} (${line.productUnit || 'value'})` : (line.productUnit || 'Custom Value'),
                    customValuePlaceholder: line.productUnit || 'Value',
                    maxQty: isAggregate ? null : baseQty,
                    isExcluded,
                    // SFDC-264: exclusion is valid on ANY phase, including phase 1 — a product
                    // that only starts in phase 2 must be able to sit out phase 1. Linking is
                    // still phase 2+ only: phase 1 has no earlier phase to supersede.
                    canExclude: !isExcluded,
                    isLinkable: isLinkable && !isExcluded && !isAggregate,
                    pillClass: (hasLink ? 'qle-ramp-pill qle-ramp-pill-linked' : 'qle-ramp-pill qle-ramp-pill-hover')
                        + (linkLocked ? ' qle-ramp-pill-locked' : ''),
                    pillLabel,
                    linkLocked,
                    pillTitle: linkLocked
                        ? 'Inherited from the earlier linked phase. Every phase from here on is a reprice, so this link cannot be removed.'
                        : '',
                    showPillMenu: this._openPillKey === cellLinkKey,
                    pillMenuStyle: this._openPillKey === cellLinkKey ? this._pillMenuStyle : '',
                    pillOptions,
                };
            }),
            // Track cells for connector lines
            trackCells: (() => {
                // phaseIdxById is keyed by phase id; the values here are arrays, which are
                // never valid keys — index each target individually, not the whole array.
                // One connector per linked CELL, not per target. A phase superseding three
                // earlier ones is one relationship ("Phase 4 <- Phases 1,2,3"), so it draws a
                // single span from its earliest target across to itself; drawing three stacked
                // bars for it just made the track taller and harder to read. Node dots still
                // mark every real endpoint, so a non-contiguous target set stays truthful.
                const productLinks = [];
                for (const [ck, targets] of Object.entries(this._rampCellLinks)) {
                    if (!ck.startsWith(line.Id + '_')) continue;
                    const fromIdx = phaseIdxById[Number(ck.split('_')[1])];
                    if (fromIdx === undefined) continue;
                    const toIdxs = (targets || [])
                        .map(t => phaseIdxById[t])
                        .filter(i => i !== undefined);
                    if (!toIdxs.length) continue;
                    productLinks.push({ fromIdx, toIdxs });
                }
                // Lane order follows the repricing phase left-to-right, so the bars stack in a
                // predictable order instead of whatever Object.entries happened to yield.
                productLinks.sort((a, b) => a.fromIdx - b.fromIdx);
                const linkCount = productLinks.length;
                const trackH = Math.max(20, 10 + linkCount * 8);
                const palette = ['#6366F1', '#0891B2', '#D97706', '#059669', '#E11D48'];

                return this._rampModalPhases.map((phase, phaseIdx) => {
                    let hasNode = false;
                    let isSource = false;
                    const lines = [];

                    productLinks.forEach((lk, li) => {
                        const ends = [lk.fromIdx, ...lk.toIdxs];
                        const lo = Math.min(...ends);
                        const hi = Math.max(...ends);
                        if (phaseIdx === lo) { hasNode = true; isSource = true; }
                        else if (ends.includes(phaseIdx)) { hasNode = true; }
                        if (phaseIdx >= lo && phaseIdx <= hi) {
                            const c = palette[li % palette.length];
                            const isStart = phaseIdx === lo;
                            const isEnd   = phaseIdx === hi;
                            const y = 6 + li * 8;
                            let br = '0';
                            if (isStart && isEnd) br = '2px';
                            else if (isStart) br = '2px 0 0 2px';
                            else if (isEnd)   br = '0 2px 2px 0';
                            lines.push({
                                key: `tl_${line.Id}_${phase.id}_${li}`,
                                style: `position:absolute;top:${y}px;left:${isStart?'50%':'0'};right:${isEnd?'50%':'0'};height:2px;background:${c};border-radius:${br}`,
                            });
                        }
                    });

                    return {
                        key: `tc_${line.Id}_${phase.id}`,
                        cls: 'qle-ramp-track-cell',
                        cellStyle: `height:${trackH}px`,
                        hasNode,
                        nodeClass: isSource ? 'qle-ramp-track-node qle-ramp-track-node-src' : 'qle-ramp-track-node',
                        lines,
                    };
                });
            })(),
        };
        });
    }

    get _rampValidationMessages() {
        const msgs = [];
        const missingDates = this._rampModalPhases.filter(p => !p.startDate);
        if (missingDates.length > 0) {
            msgs.push({ key: 'dates', text: `${missingDates.length} phase(s) missing start date` });
        }
        // Duplicate dates
        const dates = this._rampModalPhases.map(p => p.startDate).filter(Boolean);
        if (dates.length > 1 && new Set(dates).size < dates.length) {
            msgs.push({ key: 'dup', text: 'Duplicate start dates - each phase must be unique' });
        }
        // Qty + Price validation (always, unified ramp)
        for (const phase of this._rampModalPhases) {
            for (const prod of phase.products) {
                if (prod.quantity == null || prod.quantity < 0) {
                    msgs.push({ key: `q-${prod.lineId}-${phase.id}`, text: `${prod.code} Phase ${phase.phaseNumber}: qty cannot be negative` });
                }
                if (prod.unitPrice == null || prod.unitPrice < 0) {
                    msgs.push({ key: `p-${prod.lineId}-${phase.id}`, text: `${prod.code} Phase ${phase.phaseNumber}: invalid price` });
                }
            }
        }
        // Attribute validation (only for products that have attributes, skip excluded cells)
        for (const phase of this._rampModalPhases) {
            for (const prod of phase.products) {
                const exKey = `${prod.lineId}_${phase.id}`;
                if (this._rampExcludedCells[exKey]) continue;
                const line = this._rampMrcLines.find(l => l.Id === prod.lineId);
                if (line && line._hasAttribute && !prod.attributeValue) {
                    msgs.push({ key: `a-${prod.lineId}-${phase.id}`, text: `${prod.code} Phase ${phase.phaseNumber}: attribute required` });
                }
            }
        }
        // SFDC-208 #2 + the qty-0 workaround that never worked: a blank quantity on an
        // included phase is silently turned into 1 by Apex (isZeroQty -> 1 on the source
        // line), leaving a junk qty-1 line at full price. Block it here and name the two
        // ways out, so the coercion is never reached. Linked cells are skipped — their qty
        // is derived from the phases they supersede, not typed.
        // Reported once per phase, not once per cell: stepping straight to 30 phases would
        // otherwise post hundreds of messages into a panel that renders every one of them.
        for (const phase of this._rampModalPhases) {
            const blank = phase.products.filter(prod => {
                const key = `${prod.lineId}_${phase.id}`;
                if (this._rampExcludedCells[key]) return false;
                if ((this._rampCellLinks[key] || []).length) return false;
                return isBlankQty(prod.quantity);
            });
            if (!blank.length) continue;
            const names = blank.slice(0, 3).map(p => p.code).join(', ');
            const more = blank.length > 3 ? ` +${blank.length - 3} more` : '';
            msgs.push({
                key: `blank-${phase.id}`,
                text: `Phase ${phase.phaseNumber}: enter a quantity for ${names}${more}, or exclude from this phase`
            });
        }
        // Qty match: total across phases must equal base qty (skip aggregate products)
        for (const mrc of this._rampMrcLines) {
            if (this._isAggregateProduct(mrc)) continue;
            const override = this._rampBaseQtyOverrides[mrc.Id];
            let baseQty;
            if (override != null) {
                baseQty = override;
            } else {
                // Fallback: use the MRC line's current QLI qty
                baseQty = mrc.Quantity || 0;
            }
            if (baseQty <= 0) continue;
            let totalQty = 0;
            for (const phase of this._rampModalPhases) {
                const cellKey = `${mrc.Id}_${phase.id}`;
                if (this._rampExcludedCells[cellKey]) continue;
                // .length, not truthiness — [] is truthy, and a stale empty array would
                // silently drop this phase's qty out of the total
                if ((this._rampCellLinks[cellKey] || []).length) continue; // linked = same allocation, not additional
                const prod = phase.products.find(p => p.lineId === mrc.Id);
                if (prod) totalQty += (Number(prod.quantity) || 0);
            }
            // Tolerance, not ===: quantities are decimal now (132.23 sqm from pyeong) and
            // summing them drifts in the last bits, which an exact test rejects as a
            // mismatch the user cannot fix.
            if (!qtyEquals(totalQty, baseQty)) {
                const attrLabel = mrc.Product_Attribute_Value__c ? ` [${mrc.Product_Attribute_Value__c}]` : '';
                msgs.push({ key: `match-${mrc.Id}`, text: `${mrc.productCode}${attrLabel}: total phase qty (${totalQty}) must equal base qty (${baseQty})` });
            }
        }
        // SFDC-264: phase 1 is excludable now, so a product can be excluded everywhere. That
        // saves an empty payload and the line silently drops off the ramp — block it instead.
        for (const mrc of this._rampMrcLines) {
            const included = this._rampModalPhases.filter(
                p => !this._rampExcludedCells[`${mrc.Id}_${p.id}`]
            );
            if (!included.length) {
                msgs.push({ key: `allex-${mrc.Id}`, text: `${mrc.productCode}: excluded from every phase — keep it in at least one` });
            }
        }
        return msgs;
    }

    get hasRampValidationErrors() {
        // Only blocking errors (not warnings) prevent save
        return this._rampValidationMessages.some(m => !m.isWarning);
    }

    get rampModalSaveDisabled() {
        return this.isLoading || this._rampModalPhases.length < 2 || this.hasRampValidationErrors;
    }

    handleCreateRamp() {
        if (!this._isQuoteDraft) {
            this._toast('Quote Not in Draft', 'Ramp can only be created when the Quote is in Draft status.', 'warning');
            return;
        }
        if (this.isQuoteLocked) {
            this._toast('Locked', 'Ramp cannot be created while approvals are in progress.', 'warning');
            return;
        }
        const selectedLines = this._lines.filter(l => this.selectedRowIds.includes(l.Id));
        // Only exclude auto-paired NRC (handled automatically below via the .RC/.NR pairing
        // loop) — standalone NRC products (Is_Auto_NRC__c false/blank) must stay selectable.
        const mrcLines = selectedLines.filter(l => !(this._isNRC(l) && l.Is_Auto_NRC__c === true));

        // Block already-ramped lines
        const alreadyRamped = mrcLines.filter(l => l.Line_Origin__c === 'Ramp');
        const freshLines = mrcLines.filter(l => l.Line_Origin__c !== 'Ramp');
        if (alreadyRamped.length > 0 && freshLines.length === 0) {
            this._toast('Already Ramped', 'All selected lines are already ramped. Edit existing ramps from the detail panel instead.', 'warning');
            return;
        }
        if (alreadyRamped.length > 0) {
            this._toast('Skipped Ramped Lines', `${alreadyRamped.length} already-ramped line(s) excluded. Only fresh lines included.`, 'info');
        }

        const nrcLines = [];
        for (const mrc of freshLines) {
            const mrcCode = (mrc.productCode || '').toUpperCase();
            if (mrcCode.endsWith('.RC')) {
                const nrcCode = mrcCode.replace(/\.RC$/, '.NR');
                // SFDEV-11: the save only splits auto NRCs; a standalone one must not be shown as paired
                const paired = this._lines.find(l =>
                    l.Is_Auto_NRC__c === true &&
                    (l.productCode || '').toUpperCase() === nrcCode &&
                    !freshLines.some(m => m.Id === l.Id) &&
                    !nrcLines.some(n => n.Id === l.Id)
                );
                if (paired) nrcLines.push(paired);
            }
        }
        if (freshLines.length === 0) {
            this._toast('No MRC Lines', 'Select at least one MRC product to create a ramp.', 'warning');
            return;
        }

        // Standalone NRC: any non-auto NRC is its own editable row. SFDEV-11: this used to skip
        // one whose .RC counterpart was on the quote, but the save never pairs a non-auto NRC,
        // so that line was left unramped and vanished from the schedule and the PDF.
        const orphanNrcLines = this._lines.filter(l =>
            this._isNRC(l) &&
            l.Is_Auto_NRC__c !== true &&
            l.Line_Origin__c !== 'Ramp' &&
            !freshLines.some(m => m.Id === l.Id) &&
            !nrcLines.some(n => n.Id === l.Id)
        );
        freshLines.push(...orphanNrcLines);

        const negQty = freshLines.find(l => l.Quantity != null && l.Quantity < 0);
        if (negQty) {
            this._toast('Invalid Quantity', `${negQty.productName} has a negative quantity.`, 'warning');
            return;
        }
        this._rampMrcLines = freshLines;
        this._rampNrcLines = nrcLines;
        this._rampModalPhaseCount = 2;
        this._rampModalType = 'quantity';
        this._showRampAddPopover = false;
        this._isEditingRamp = false;
        this._initRampModalPhases();
        this.showRampModal = true;
    }

    handlePhaseCountChange(event) {
        this._setPhaseCount(Number(event.currentTarget.dataset.count));
    }

    handlePhaseStepDown() { this._setPhaseCount(this._rampModalPhaseCount - 1); }
    handlePhaseStepUp()   { this._setPhaseCount(this._rampModalPhaseCount + 1); }

    /**
     * Single entry point for every phase-count change — quick-pick buttons and stepper both
     * land here, so the discard guard below cannot be bypassed by using the other control.
     */
    _setPhaseCount(requested) {
        const newCount = Math.min(RAMP_PHASE_MAX, Math.max(RAMP_PHASE_MIN, Number(requested) || RAMP_PHASE_MIN));
        const oldCount = this._rampModalPhaseCount;
        if (newCount === oldCount) return;

        // SFDC-208 #3: trimming used to wipe the later phases on the spot. Ask first — but
        // only when something would actually be lost, or dropping an untouched phase nags.
        if (newCount < oldCount) {
            const doomed = this._rampModalPhases.slice(newCount);
            if (this._phasesHoldData(doomed)) {
                const n = oldCount - newCount;
                // eslint-disable-next-line no-alert
                const ok = confirm(
                    `Phase ${newCount + 1}${n > 1 ? ` to ${oldCount}` : ''} contain data that will be discarded - `
                    + 'quantities, prices, notes, links and exclusions. Continue?'
                );
                if (!ok) return;
            }
        }

        this._rampModalPhaseCount = newCount;

        if (newCount > oldCount) {
            // Add phases at the end — preserve existing data
            for (let i = oldCount; i < newCount; i++) {
                this._rampModalPhases = [...this._rampModalPhases, {
                    id: i + 1,
                    phaseNumber: i + 1,
                    colClass: ((i + 1) % 2 !== 0 ? 'qle-ramp-grid-col-header qle-ramp-col-tint qle-ramp-col-missing' : 'qle-ramp-grid-col-header qle-ramp-col-missing'),
                    startDate: null,
                    notes: '',
                    products: this._rampMrcLines.map(line => ({
                        lineId: line.Id,
                        name: line.productName,
                        code: line.productCode,
                        quantity: '',
                        unitPrice: line.UnitPrice || '',
                        attributeValue: line.Product_Attribute_Value__c || '',
                        attributeOptions: line._attributeOptions || [],
                        customValue: ''
                    }))
                }];
                // Seed after the push so the link helpers can see the new phase. Per-phase,
                // so a run of new phases each inherits from the one immediately before it.
                this._inheritLinksFromPreviousPhase(i + 1);
            }
        } else if (newCount < oldCount) {
            // Trim from end — keep first N phases
            const removed = new Set(this._rampModalPhases.slice(newCount).map(p => p.id));
            this._rampModalPhases = this._rampModalPhases.slice(0, newCount);
            // Slicing the phases alone would strand links/qty/exclusions on phases that
            // no longer exist, and those keys come back on the next save
            this._pruneRemovedPhases(removed);
        }
    }

    /**
     * Would trimming these phases actually lose anything? Prices are ignored on their own:
     * every new phase is seeded with the line's current price, so a price alone means the
     * user never touched the phase. Everything else here is deliberate user input.
     */
    _phasesHoldData(phases) {
        return (phases || []).some(p => {
            if (p.startDate) return true;
            if (p.notes) return true;
            return p.products.some(pr => {
                const key = `${pr.lineId}_${p.id}`;
                if (!isBlankQty(pr.quantity)) return true;
                if (this._rampExcludedCells[key]) return true;
                if ((this._rampCellLinks[key] || []).length) return true;
                // A later phase pointing back at this one also disappears with it
                return Object.values(this._rampCellLinks).some(t => (t || []).includes(p.id));
            });
        });
    }

    handleRampModalQty()   { if (this._rampModalType !== 'quantity')  { this._rampModalType = 'quantity';  this._initRampModalPhases(); } }
    handleRampModalPrice() { if (this._rampModalType !== 'price')     { this._rampModalType = 'price';     this._initRampModalPhases(); } }
    handleRampModalAttr()  { if (this._rampModalType !== 'attribute') { this._rampModalType = 'attribute'; this._initRampModalPhases(); } }

    _initRampModalPhases() {
        const count = this._rampModalPhaseCount;
        const phases = [];
        const rdd = this._getQuoteRddStr();
        for (let i = 0; i < count; i++) {
            const isFirst = i === 0;
            const sd = isFirst ? rdd : null;
            phases.push({
                id: i + 1,
                phaseNumber: i + 1,
                colClass: this._computeColClass(i + 1, sd),
                startDate: sd,
                startDateLocked: isFirst && !!rdd,
                notes: '',
                products: this._rampMrcLines.map(line => {
                    const totalQty = line.Quantity || 0;
                    return {
                        lineId: line.Id,
                        name: line.productName,
                        code: line.productCode,
                        quantity: isFirst ? totalQty : '',
                        unitPrice: line.UnitPrice || 0,
                        attributeValue: line.Product_Attribute_Value__c || '',
                        attributeOptions: line._attributeOptions || [],
                        customValue: line.Custom_Attribute_Value__c || ''
                    };
                })
            });
        }
        this._rampModalPhases = phases;
    }

    _computeColClass(phaseId, startDate) {
        let cls = phaseId % 2 !== 0 ? 'qle-ramp-grid-col-header qle-ramp-col-tint' : 'qle-ramp-grid-col-header';
        if (!startDate) cls += ' qle-ramp-col-missing';
        return cls;
    }

    handleRampModalPhaseDate(event) {
        const phaseId = Number(event.currentTarget.dataset.phaseId);
        const value = event.detail.value;
        this._rampModalPhases = this._rampModalPhases.map(p => {
            if (p.id !== phaseId || p.startDateLocked) return p;
            return { ...p, startDate: value, colClass: this._computeColClass(p.id, value) };
        });
    }

    handleRampModalPhaseNotes(event) {
        const phaseId = Number(event.currentTarget.dataset.phaseId);
        const value = event.target.value;
        this._rampModalPhases = this._rampModalPhases.map(p =>
            p.id === phaseId ? { ...p, notes: value } : p
        );
    }

    // Separate map for base qty overrides — reverted on cancel, applied on save
    @track _rampBaseQtyOverrides = {};

    // ─── Per-product phase linking ──────────────────────────────────────

    handlePillClick(event) {
        event.stopPropagation();
        const phaseId = Number(event.currentTarget.dataset.phaseId);
        const lineId  = event.currentTarget.dataset.lineId;
        const key = `${lineId}_${phaseId}`;
        if (this._openPillKey === key) {
            this._openPillKey = null;
            this._pillMenuStyle = '';
        } else {
            this._openPillKey = key;
            const rect = event.currentTarget.getBoundingClientRect();
            this._pillMenuStyle = `top:${rect.bottom + 4}px;left:${rect.left}px`;
        }
    }

    handlePillMenuClose(event) {
        event.stopPropagation();
        this._openPillKey = null;
        this._pillMenuStyle = '';
    }

    /**
     * Earlier phases a cell may supersede: not excluded for this product, and not themselves
     * linked. Those are the phases actually holding quantity — which is also why an excluded
     * cell needs no override logic, it simply never appears as a target.
     */
    _eligibleLinkTargets(lineId, phaseId) {
        const phaseIdx = this._rampModalPhases.findIndex(p => p.id === phaseId);
        const out = [];
        for (let i = 0; i < phaseIdx; i++) {
            const p = this._rampModalPhases[i];
            const k = `${lineId}_${p.id}`;
            if (this._rampExcludedCells[k]) continue;
            if ((this._rampCellLinks[k] || []).length) continue;
            out.push(p);
        }
        return out;
    }

    /**
     * True when this cell's link supersedes EVERY phase it could have: an "All Phases" link
     * rather than a pick of one or two. Mirrors the allEligibleSelected test used to label
     * the pill — including the 2+ eligible requirement, so a lone target reads "Phase N".
     */
    _isAllPhasesLink(lineId, phaseId) {
        const targets = this._rampCellLinks[`${lineId}_${phaseId}`] || [];
        if (!targets.length) return false;
        const eligible = this._eligibleLinkTargets(lineId, phaseId);
        if (eligible.length < 2) return false;
        if (targets.length !== eligible.length) return false;
        const picked = new Set(targets);
        return eligible.every(p => picked.has(p.id));
    }

    /**
     * A cell is locked once an EARLIER phase for its product carries an ALL PHASES link:
     * that phase already supersedes the whole ramp, so everything after it can only be
     * another reprice of the same units. Letting one be cleared — or hand-linked to a
     * narrower set — would turn it into an Add and deliver those units a second time.
     *
     * Scoped to All Phases links deliberately. A single-target link (phase 3 supersedes
     * phase 2 only) leaves the ramp free to keep growing, so later phases stay linkable.
     *
     * The test is NOT conditional on this cell already being linked. It used to be, which
     * left a back door: excluding a phase deletes its link, so re-including it came back
     * unlocked and freely linkable — or worse, leavable as a plain Add.
     *
     * Derived rather than flagged at seed time, so it survives a save and reopen — the
     * read-back has no record of which links a user picked and which were defaulted.
     */
    _isLinkLocked(lineId, phaseId) {
        const idx = this._rampModalPhases.findIndex(p => p.id === phaseId);
        if (idx < 1) return false;
        return this._rampModalPhases
            .slice(0, idx)
            .some(lp => this._isAllPhasesLink(lineId, lp.id));
    }

    /** A linked cell carries the combined qty of every phase it supersedes (2+2+2 -> 6) */
    _linkedSumQty(lineId, targets) {
        return (targets || []).reduce((sum, tid) => {
            const srcPhase = this._rampModalPhases.find(p => p.id === tid);
            const srcProd  = srcPhase?.products.find(pr => pr.lineId === lineId);
            return sum + (srcProd ? (Number(srcProd.quantity) || 0) : 0);
        }, 0);
    }

    /**
     * Once the footprint is complete every later phase is another reprice, not new
     * quantity — so a phase appended after a linked one inherits that phase's targets
     * and price, per product, instead of arriving as a blank Add the user must re-link.
     * The qty is deliberately NOT copied from the previous phase: it has to stay a
     * consequence of the targets (via _linkedSumQty), or an unlinked cell carrying 6
     * saves as six ADDITIONAL units.
     */
    _inheritLinksFromPreviousPhase(newPhaseId) {
        const idx = this._rampModalPhases.findIndex(p => p.id === newPhaseId);
        if (idx < 1) return;                                    // phase 1 has nothing before it
        const prevPhase = this._rampModalPhases[idx - 1];
        const newPhase  = this._rampModalPhases[idx];
        if (!prevPhase || !newPhase) return;

        const nextLinks = { ...this._rampCellLinks };
        const seeded = new Set();
        for (const prod of newPhase.products) {
            const lineId = prod.lineId;
            if (this._rampExcludedCells[`${lineId}_${newPhaseId}`]) continue;
            // Carry forward ONLY from an All Phases link. That link already supersedes the
            // whole ramp, so the appended phase can only be another reprice — leaving it a
            // plain Add would deliver the same units twice. Any other predecessor (plain Add,
            // or a narrow single-target link) leaves the ramp free to keep growing, so the
            // new phase stays blank until the user picks a link themselves.
            if (!this._isAllPhasesLink(lineId, prevPhase.id)) continue;
            // Eligibility is per-phase, so re-filter rather than trusting the copy
            const eligible = new Set(this._eligibleLinkTargets(lineId, newPhaseId).map(p => p.id));
            const prevTargets = this._rampCellLinks[`${lineId}_${prevPhase.id}`] || [];
            const targets = [...new Set(prevTargets.filter(t => eligible.has(t)))].sort((a, b) => a - b);
            if (!targets.length) continue;                      // nothing survived — leave a plain Add
            nextLinks[`${lineId}_${newPhaseId}`] = targets;
            seeded.add(lineId);
        }
        if (!seeded.size) return;
        this._rampCellLinks = nextLinks;

        this._rampModalPhases = this._rampModalPhases.map(p => {
            if (p.id !== newPhaseId) return p;
            return {
                ...p,
                products: p.products.map(pr => {
                    if (!seeded.has(pr.lineId)) return pr;
                    const prevProd = prevPhase.products.find(x => x.lineId === pr.lineId);
                    return {
                        ...pr,
                        // Derived from the targets, exactly as handlePillSelect would have set it
                        quantity: this._linkedSumQty(pr.lineId, nextLinks[`${pr.lineId}_${newPhaseId}`]),
                        unitPrice: prevProd ? prevProd.unitPrice : pr.unitPrice
                    };
                })
            };
        });
        // Record the qty the cell had BEFORE the seed, same as the 0->N transition in
        // handlePillSelect — without it "None (Add)" would leave the summed qty behind
        // as a real Add. A blank cell caches as 0, which is what a manual link would cache.
        for (const lineId of seeded) {
            const cellKey = `${lineId}_${newPhaseId}`;
            if (this._rampPreLinkQty[cellKey] === undefined) this._rampPreLinkQty[cellKey] = 0;
        }
        for (const lineId of seeded) this._syncBaseQtyOverride(lineId);
    }

    /**
     * Dropping the phase count must not leave links, cached pre-link qty or exclusions
     * pointing at phases that no longer exist. Same stale-target sweep handleExcludeToggle
     * does when a phase stops holding quantity, but for every product at once.
     */
    _pruneRemovedPhases(removedIds) {
        if (!removedIds || !removedIds.size) return;
        // Cell keys are `${lineId}_${phaseId}` and a QLI Id never contains '_'
        const lineOf  = k => k.split('_')[0];
        const isGone  = k => removedIds.has(Number(k.split('_')[1]));
        const touched = new Set();

        const links = {};
        for (const [k, targets] of Object.entries(this._rampCellLinks)) {
            if (isGone(k)) { touched.add(lineOf(k)); continue; }
            const kept = targets.filter(t => !removedIds.has(t));
            if (kept.length !== targets.length) touched.add(lineOf(k));
            if (kept.length) links[k] = kept;                   // empty = no longer a link at all
        }
        this._rampCellLinks = links;

        const preLink = {};
        for (const k of Object.keys(this._rampPreLinkQty)) {
            if (!isGone(k)) preLink[k] = this._rampPreLinkQty[k];
        }
        this._rampPreLinkQty = preLink;

        const excluded = {};
        for (const k of Object.keys(this._rampExcludedCells)) {
            if (isGone(k)) touched.add(lineOf(k));
            else excluded[k] = this._rampExcludedCells[k];
        }
        this._rampExcludedCells = excluded;

        for (const lineId of touched) this._syncBaseQtyOverride(lineId);
    }

    handlePillSelect(event) {
        event.stopPropagation();
        const phaseId = Number(event.currentTarget.dataset.phaseId);
        const lineId  = event.currentTarget.dataset.lineId;
        const target  = event.currentTarget.dataset.target;
        const cellKey = `${lineId}_${phaseId}`;
        // Done is the explicit way out — the toggles above it already applied as they were clicked
        if (target === 'done') {
            this._openPillKey = null;
            this._pillMenuStyle = '';
            return;
        }
        // Backstop for the disabled pill: a cell whose links were inherited from an earlier
        // linked phase cannot be cleared, or the same units get delivered twice — once by
        // the phases it supersedes and again as a new Add here.
        if (this._isLinkLocked(lineId, phaseId)) {
            this._openPillKey = null;
            this._pillMenuStyle = '';
            return;
        }
        const next = { ...this._rampCellLinks };
        const prev = next[cellKey] || [];
        let targets;
        if (!target) {
            targets = [];                                                       // None (Add) — clear every link
        } else if (target === '*') {
            targets = this._eligibleLinkTargets(lineId, phaseId).map(p => p.id); // All Phases shortcut
        } else {
            const t = Number(target);
            targets = prev.includes(t) ? prev.filter(x => x !== t) : [...prev, t];
        }
        targets = [...new Set(targets)].sort((a, b) => a - b); // readers assume ascending + deduped

        if (!targets.length) {
            delete next[cellKey];
            // Only the N->0 transition restores the pre-link qty; a partial unlink falls
            // through to the re-sum below, which is what the cell should now show
            if (prev.length) {
                const savedQty = this._rampPreLinkQty[cellKey];
                if (savedQty !== undefined) {
                    this._rampModalPhases = this._rampModalPhases.map(p =>
                        p.id === phaseId ? {
                            ...p,
                            products: p.products.map(pr =>
                                pr.lineId === lineId ? { ...pr, quantity: savedQty } : pr
                            )
                        } : p
                    );
                }
                delete this._rampPreLinkQty[cellKey];
            }
        } else {
            next[cellKey] = targets;
            // Cache the hand-entered qty once, on the 0->N transition only
            if (!prev.length) {
                const currentPhase = this._rampModalPhases.find(p => p.id === phaseId);
                const currentProd = currentPhase?.products.find(p => p.lineId === lineId);
                if (currentProd && this._rampPreLinkQty[cellKey] === undefined) {
                    this._rampPreLinkQty[cellKey] = Number(currentProd.quantity) || 0;
                }
            }
            // Linked = inherit the combined qty of every superseded phase
            const sumQty = this._linkedSumQty(lineId, targets);
            this._rampModalPhases = this._rampModalPhases.map(p =>
                p.id === phaseId ? {
                    ...p,
                    products: p.products.map(pr =>
                        pr.lineId === lineId ? { ...pr, quantity: sumQty } : pr
                    )
                } : p
            );
        }
        this._rampCellLinks = next;
        // Menu deliberately stays open — multi-select; Done or an outside click dismisses it

        // Sync base qty override after link/unlink changes phase quantities
        this._syncBaseQtyOverride(lineId);
    }

    /** Recalculate base qty override for a product across all phases (skips excluded) */
    _syncBaseQtyOverride(lineId) {
        const line = this._rampMrcLines.find(l => l.Id === lineId);
        const isAggregate = this._isAggregateProduct(line);

        if (isAggregate) {
            // Find last NON-EXCLUDED phase for this product
            let lastQty = 0;
            for (let i = this._rampModalPhases.length - 1; i >= 0; i--) {
                const phase = this._rampModalPhases[i];
                const exKey = `${lineId}_${phase.id}`;
                if (this._rampExcludedCells[exKey]) continue; // skip excluded
                const pd = phase.products.find(pr => pr.lineId === lineId);
                if (pd) { lastQty = Number(pd.quantity) || 0; break; }
            }
            this._rampBaseQtyOverrides = { ...this._rampBaseQtyOverrides, [lineId]: lastQty };
        } else {
            let total = 0;
            for (const p of this._rampModalPhases) {
                const cellKey = `${lineId}_${p.id}`;
                if (this._rampExcludedCells[cellKey]) continue; // skip excluded
                // .length, not truthiness — [] is truthy and would wrongly skip an unlinked cell
                if ((this._rampCellLinks[cellKey] || []).length) continue; // skip linked (same allocation, not additional)
                const prod = p.products.find(pr => pr.lineId === lineId);
                if (prod) total += (Number(prod.quantity) || 0);
            }
            this._rampBaseQtyOverrides = { ...this._rampBaseQtyOverrides, [lineId]: total };
        }
    }

    handleRampBaseQtyChange(event) {
        const lineId = event.currentTarget.dataset.lineId;
        const newQty = Number(event.target.value) || 0;
        this._rampBaseQtyOverrides = { ...this._rampBaseQtyOverrides, [lineId]: newQty };
    }

    handleExcludeToggle(event) {
        event.stopPropagation();
        const phaseId = Number(event.currentTarget.dataset.phaseId);
        const lineId  = event.currentTarget.dataset.lineId;
        const cellKey = `${lineId}_${phaseId}`;
        const next = { ...this._rampExcludedCells };
        if (next[cellKey]) {
            // Re-include has to undo BOTH halves of the exclude below, or the phase comes
            // back as an unlinked Add whose quantity is delivered a second time, and the
            // later cells that used to supersede it stay silently narrowed.
            delete next[cellKey];
            this._rampExcludedCells = next;   // set first — the helpers below read it
            const linkNext = { ...this._rampCellLinks };
            for (const p of this._rampModalPhases) {
                if (p.id <= phaseId) continue;                  // only later cells reprice it
                const k = `${lineId}_${p.id}`;
                const targets = linkNext[k];
                if (!targets || !targets.length) continue;       // a plain Add stays an Add
                if (targets.includes(phaseId)) continue;
                linkNext[k] = [...targets, phaseId].sort((a, b) => a - b);
            }
            this._rampCellLinks = linkNext;
            // Re-link the cell itself the same way a freshly appended phase is seeded
            this._inheritLinksFromPreviousPhase(phaseId);
            this._syncBaseQtyOverride(lineId);
            return;
        } else {
            next[cellKey] = true;
            // Also remove any link on this cell...
            const linkNext = { ...this._rampCellLinks };
            delete linkNext[cellKey];
            // ...and drop this phase as a target anywhere else: an excluded phase holds no
            // qty for this product, so a cell still pointing at it would fan out a zero line
            for (const p of this._rampModalPhases) {
                const k = `${lineId}_${p.id}`;
                const targets = linkNext[k];
                if (!targets) continue;
                const kept = targets.filter(t => t !== phaseId);
                if (kept.length === targets.length) continue;
                if (kept.length) linkNext[k] = kept;
                else delete linkNext[k];
            }
            this._rampCellLinks = linkNext;
        }
        this._rampExcludedCells = next;
        this._syncBaseQtyOverride(lineId);
    }

    // ── Invoice Display toggle ─────────────────────────────────────────
    @track _rampInvoiceDisplayVal = 'Incremental_Value';

    get rampInvoiceDisplayOptions() {
        return [
            { label: 'Incremental', value: 'Incremental_Value' },
            { label: 'Final (cumulative)', value: 'Final_Value' },
        ];
    }
    handleRampInvoiceDisplayChange(event) {
        this._rampInvoiceDisplayVal = event.detail.value;
    }

    handleRampModalProdChange(event) {
        const phaseId = Number(event.currentTarget.dataset.phaseId);
        const lineId  = event.currentTarget.dataset.lineId;
        const field   = event.currentTarget.dataset.field;
        const value   = event.detail.value;
        this._rampModalPhases = this._rampModalPhases.map(p =>
            p.id === phaseId ? {
                ...p,
                products: p.products.map(pr =>
                    pr.lineId === lineId
                        ? { ...pr, [field]: (field === 'quantity' || field === 'unitPrice') ? (value === '' ? null : Number(value)) : value }
                        : pr
                )
            } : p
        );
        // Sync base qty override when phase quantities change
        if (field === 'quantity') {
            this._syncBaseQtyOverride(lineId);

            // Propagate qty to every cell that supersedes the changed phase (for this product)
            const changedPhaseId = phaseId;
            this._rampModalPhases = this._rampModalPhases.map(p => {
                const linkKey = `${lineId}_${p.id}`;
                const targets = this._rampCellLinks[linkKey];
                if (!targets || !targets.includes(changedPhaseId)) return p;
                // Multi-link cells show the SUM of their targets, so re-add the lot rather
                // than copying the one qty that just changed
                const sumQty = this._linkedSumQty(lineId, targets);
                return {
                    ...p,
                    products: p.products.map(pr =>
                        pr.lineId === lineId ? { ...pr, quantity: sumQty } : pr
                    )
                };
            });
        }
    }

    @track _rampModalError = '';

    handleCloseRampModal() {
        this.showRampModal = false;
        this._rampMrcLines = [];
        this._rampNrcLines = [];
        this._rampModalPhases = [];
        this._showRampAddPopover = false;
        this._isEditingRamp = false;
        this._rampBaseQtyOverrides = {};
        this._rampModalError = '';
        this._rampCellLinks = {};
        this._openPillKey = null;
        this._rampPreLinkQty = {};
        this._rampExcludedCells = {};
    }

    _cleanRampError(err) {
        let msg = err?.body?.message || err?.message || 'An unexpected error occurred.';
        // Strip FIELD_CUSTOM_VALIDATION_EXCEPTION wrapper
        if (msg.includes('FIELD_CUSTOM_VALIDATION_EXCEPTION')) {
            const idx = msg.indexOf('FIELD_CUSTOM_VALIDATION_EXCEPTION,');
            if (idx >= 0) msg = msg.substring(idx + 35).replace(/\s*:\s*\[.*\]\s*$/, '').trim();
        }
        // Strip ENTITY_IS_LOCKED
        if (msg.includes('ENTITY_IS_LOCKED') || msg.includes('entity is locked')) {
            msg = 'This quote is locked and cannot be modified. It may be in an approval process or already accepted.';
        }
        // Strip generic Apex wrapper
        if (msg.includes('Update failed. First exception on row')) {
            const match = msg.match(/first error: [A-Z_]+,\s*(.+?)(?:\s*:\s*\[|$)/);
            if (match) msg = match[1].trim();
        }
        return msg;
    }

    handleRampModalClick(event) { event.stopPropagation(); }

    // ── Available lines (not already in ramp, not auto-paired NRC, not already-ramped) ──
    // Standalone NRC (Is_Auto_NRC__c false/blank) stays available — only the NRC lines the
    // ramp engine auto-pairs to their parent .RC line are excluded here.
    get _availableRampLines() {
        const inRampIds = new Set(this._rampMrcLines.map(l => l.Id));
        const nrcIds = new Set(this._rampNrcLines.map(l => l.Id));
        return this._lines.filter(l =>
            !(this._isNRC(l) && l.Is_Auto_NRC__c === true) &&
            !inRampIds.has(l.Id) &&
            !nrcIds.has(l.Id) &&
            l.Line_Origin__c !== 'Ramp' &&
            l.Quantity != null && l.Quantity >= 0
        );
    }

    get hasAvailableRampLines() { return this._availableRampLines.length > 0; }

    get rampAddButtonLabel() {
        return `+ ${this._availableRampLines.length} available`;
    }

    toggleRampAddPopover() {
        this._showRampAddPopover = !this._showRampAddPopover;
    }

    closeRampAddPopover() {
        this._showRampAddPopover = false;
    }

    handleAddLineToRamp(event) {
        const lineId = event.currentTarget.dataset.id;
        const line = this._lines.find(l => l.Id === lineId);
        if (!line) return;
        // Block exact same QLI (not same product - allow same product on multiple lines)
        if (this._rampMrcLines.some(m => m.Id === line.Id)) {
            this._toast('Duplicate', `This line is already in the ramp.`, 'warning');
            return;
        }
        this._rampMrcLines = [...this._rampMrcLines, line];
        // Auto-detect paired NRC
        const mrcCode = (line.productCode || '').toUpperCase();
        if (mrcCode.endsWith('.RC')) {
            const nrcCode = mrcCode.replace(/\.RC$/, '.NR');
            // SFDEV-11: only an auto NRC is paired; a standalone one is added as its own line
            const paired = this._lines.find(l =>
                l.Is_Auto_NRC__c === true &&
                (l.productCode || '').toUpperCase() === nrcCode &&
                !this._rampMrcLines.some(m => m.Id === l.Id) &&
                !this._rampNrcLines.some(n => n.Id === l.Id)
            );
            if (paired) this._rampNrcLines = [...this._rampNrcLines, paired];
        }
        this._initRampModalPhases();
        if (this._availableRampLines.length === 0) this._showRampAddPopover = false;
    }

    handleRemoveLineFromRamp(event) {
        const lineId = event.currentTarget.dataset.id;
        if (this._rampMrcLines.length <= 1) {
            this._toast('Minimum', 'At least one MRC line is required.', 'warning');
            return;
        }
        const removedLine = this._rampMrcLines.find(l => l.Id === lineId);
        this._rampMrcLines = this._rampMrcLines.filter(l => l.Id !== lineId);
        // Remove paired NRC if it was auto-included
        if (removedLine) {
            const mrcCode = (removedLine.productCode || '').toUpperCase();
            if (mrcCode.endsWith('.RC')) {
                const nrcCode = mrcCode.replace(/\.RC$/, '.NR');
                this._rampNrcLines = this._rampNrcLines.filter(l =>
                    (l.productCode || '').toUpperCase() !== nrcCode
                );
            }
        }
        this._initRampModalPhases();
    }

    handleSaveRampModal() {
        this._rampModalError = '';
        // Validate dates
        for (const phase of this._rampModalPhases) {
            if (!phase.startDate) {
                this._toast('Validation', 'Each phase must have a start date.', 'error');
                return;
            }
        }

        this._applyRamp1Rdd(this._rampModalPhases, 'startDate');

        // Unified validation: qty + price always, attribute for products that have it (skip excluded)
        for (const phase of this._rampModalPhases) {
            for (const prod of phase.products) {
                const exKey = `${prod.lineId}_${phase.id}`;
                if (this._rampExcludedCells[exKey]) continue;
                if (prod.quantity == null || prod.quantity < 0) {
                    this._toast('Validation', `${prod.code} Phase ${phase.phaseNumber}: quantity cannot be negative.`, 'error');
                    return;
                }
                if (prod.unitPrice == null || prod.unitPrice < 0) {
                    this._toast('Validation', `${prod.code} Phase ${phase.phaseNumber}: price must be valid.`, 'error');
                    return;
                }
                const line = this._rampMrcLines.find(l => l.Id === prod.lineId);
                if (line && line._hasAttribute && !prod.attributeValue) {
                    this._toast('Validation', `${prod.code} Phase ${phase.phaseNumber}: attribute required.`, 'error');
                    return;
                }
            }
        }

        // Sort phases by start date
        const sorted = [...this._rampModalPhases].sort((a, b) =>
            a.startDate < b.startDate ? -1 : a.startDate > b.startDate ? 1 : 0
        );

        // Auto-calculate end dates
        for (let i = 0; i < sorted.length - 1; i++) {
            sorted[i]._endDate = this._prevDay(sorted[i + 1].startDate);
        }
        const contractEndModal = this._getContractEndDateStr();
        const latestEnd = this._rampMrcLines.reduce((latest, line) => {
            if (line.EndDate && (!latest || line.EndDate > latest)) return line.EndDate;
            return latest;
        }, null);
        // Prefer Contract End so last phase cannot run open-ended past the term
        sorted[sorted.length - 1]._endDate = contractEndModal || latestEnd;

        const modalErr = this._validateRampWithinContract(sorted, 'startDate', '_endDate');
        if (modalErr) {
            this._toast('Error', modalErr, 'error');
            return;
        }

        const safeEnd = (p) => (p._endDate && p._endDate === p.startDate) ? null : (p._endDate || null);

        // Call splitRampLines for each MRC line — unified payload with all fields
        // In edit mode, delete existing phases first so splitRampLines re-creates cleanly
        this.isLoading = true;
        // deleteRampPhases operates quote-wide — only need to call once
        const preWork = this._isEditingRamp
            ? deleteRampPhases({ quoteLineItemId: this._rampMrcLines[0].Id })
            : Promise.resolve();

        preWork.then(() => {
        // Build bulk payload — all MRC lines in one call (replaces N sequential round-trips)
        const isEdit = this._isEditingRamp;
        const bulkPayload = [];
        for (const mrc of this._rampMrcLines) {
            // flatMap, not map: a linked cell fans out to one entry per superseded phase.
            // They all share globalPhase, so Apex (QuoteLineEditorController line ~909 reads
            // globalPhase rather than the loop index) creates N lines on the same phase.
            // Phase order is preserved because flatMap keeps `sorted` order and only ever
            // expands within a phase — rawPhases[0] stays the earliest phase.
            const payload = sorted.flatMap((phase) => {
                const pd = phase.products.find(p => p.lineId === mrc.Id);
                if (!pd) return [];
                const exKey = `${mrc.Id}_${phase.id}`;
                if (this._rampExcludedCells[exKey]) return [];
                const links = this._rampCellLinks[exKey] || [];
                const curPrice = Number(pd.unitPrice) || 0;
                const mkEntry = (quantity, rampIdentifier, rampLinkedPhase) => {
                    const entry = {
                        globalPhase: phase.phaseNumber,
                        quantity,
                        unitPrice: curPrice,
                        startDate: phase.startDate,
                        endDate: safeEnd(phase),
                        invoiceDisplay: this._rampInvoiceDisplayVal || 'Incremental_Value',
                        rampIdentifier,
                        rampLinkedPhase
                    };
                    if (pd.attributeValue) entry.attributeValue = pd.attributeValue;
                    if (pd.customValue) entry.customValue = pd.customValue;
                    // SFDEV-3: always send the key, never guard on truthiness. '' is falsy,
                    // so a cleared note used to drop out of the payload and Apex's
                    // containsKey('notes') guard (QuoteLineEditorController line ~1019) left the
                    // phase-1 source line's old note in place. Phases 2+ are deleted and
                    // re-inserted on edit, so only phase 1 showed the stale text.
                    entry.notes = phase.notes ? phase.notes : null;
                    return entry;
                };
                if (!links.length) {
                    return [mkEntry(Number(pd.quantity) || 0, 'Add', null)];
                }
                // Each entry carries THAT target's qty, not the summed qty the cell displays:
                // repricing phases 1/2/3 of 2+2+2 saves three lines of 2, not one line of 6.
                const linkEntries = links.flatMap(lkId => {
                    const srcPhase = sorted.find(p => p.id === lkId);
                    const srcProd = srcPhase?.products.find(p => p.lineId === mrc.Id);
                    const srcQty = srcProd ? (Number(srcProd.quantity) || 0) : 0;
                    // A target that no longer resolves — read-back can leave one pointing at a
                    // phase that is now excluded for this product — or that holds no quantity
                    // has nothing to supersede. Apex happens to discard a zero-qty row
                    // (QuoteLineEditorController line ~897 `if (isZeroQty(phaseQty)) continue;`)
                    // but that is its business, not a contract: drop the row here so the
                    // payload states what we actually mean.
                    if (!srcPhase || !srcProd || srcQty === 0) return [];
                    const srcPrice = Number(srcProd.unitPrice) || 0;
                    return [mkEntry(
                        srcQty,
                        (curPrice !== srcPrice) ? 'Price_Change' : 'Change',
                        sorted.indexOf(srcPhase) + 1
                    )];
                });
                // Every target filtered out = this phase drops off the ramp entirely. That is
                // never intentional, so say so rather than letting it disappear quietly.
                if (!linkEntries.length) {
                    console.warn(`Ramp save: ${mrc.productCode} phase ${phase.phaseNumber} links only to phases with no quantity for this product; phase omitted`);
                }
                return linkEntries;
            });
            bulkPayload.push({ sourceLineId: mrc.Id, phasesJson: JSON.stringify(payload) });
        }

        splitRampLinesBulk({ bulkPayloadJson: JSON.stringify(bulkPayload), rampType: 'attribute' })
            .then(() => {
                // Post-split: aggregate NRC qty per phase across shared MRCs
                const quoteId = this._rampMrcLines[0]?.QuoteId || this.resolvedId;
                return aggregateRampNrcQty({ quoteId });
            })
            .then(() => {
                this._toast(isEdit ? 'Ramp Updated' : 'Ramp Created',
                    `${this._rampMrcLines.length} product(s) ${isEdit ? 'updated across' : 'split into'} ${sorted.length} phases.`, 'success');
                this.handleCloseRampModal();
                this.selectedRowIds = [];
                return this._refreshAfterLineChange();
            })
            .catch(err => {
                this._rampModalError = this._cleanRampError(err);
                return this._refreshAfterLineChange();
            })
            .finally(() => { this.isLoading = false; });
        }).catch(err => {
            this._rampModalError = this._cleanRampError(err);
            this.isLoading = false;
        });
    }

    _nextDay(dateStr) {
        if (!dateStr) return null;
        const parts = dateStr.split('-');
        const dt    = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]) + 1);
        return `${dt.getFullYear()}-${String(dt.getMonth() + 1).padStart(2, '0')}-${String(dt.getDate()).padStart(2, '0')}`;
    }

    _prevDay(dateStr) {
        if (!dateStr) return null;
        const parts = dateStr.split('-');
        const dt    = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]) - 1);
        return `${dt.getFullYear()}-${String(dt.getMonth() + 1).padStart(2, '0')}-${String(dt.getDate()).padStart(2, '0')}`;
    }

    _enrichInv(r) {
        const rt  = r.RecordType?.DeveloperName || '';
        const pwr = r.Total_IT_Power_kVA__c || r.Total_Capacity_kVA__c || r.Power_kVA__c;
        const st  = r.Status__c || '';
        let statusCls = 'qle-inv-status';
        if (st === 'Available' || st === 'Pending Available') statusCls += ' qle-inv-status_available';
        else if (st === 'Reserved' || st === 'Assigned')      statusCls += ' qle-inv-status_held';
        else if (st === 'Installed' || st === 'Sold')         statusCls += ' qle-inv-status_sold';
        return {
            ...r,
            displayName:  r.Name || r.Unit_Reference__c ||  '-',
            typeLabel:    r.Space_Type__c || (rt === 'Inventory_Breaker' ? 'Breaker' : '-'),
            rtLabel:      rt === 'Inventory_Breaker' ? 'BKR' : 'SPC',
            typeBadgeCls: rt === 'Inventory_Breaker' ? 'qle-inv-type-badge qle-inv-type-badge_breaker' : 'qle-inv-type-badge',
            roomLabel:    r.Data_Hall__r?.Name || null,
            powerLabel:   pwr != null ? pwr + ' kVA' : null,
            cabeLabel:    r.CabE_Count__c != null ? String(r.CabE_Count__c) : null,
            statusCls
        };
    }

    handleInventoryTabActive() {
        if (this.selectedLineId) {
            this._loadLineInventory();
        }
    }

    handleInventorySearch(event) {
        this._invSearchTerm = event.target.value;
    }

    _loadLineInventory() {
        this.isInventoryLoading = true;
        this.inventoryLoaded = false;
        // SFDC-472: the Floor / Data Hall picker needs the site's floors. Every path
        // into the inventory panel comes through here (handlePanelNav calls it
        // directly), so this is the one reliable place to populate them.
        if (this._invFloors.length === 0) this._ensureInvFloors();
        const invType = this._invTypeFilter === 'All' ? null : this._invTypeFilter;
        getLineInventory({
            quoteLineItemId: this.selectedLineId,
            quoteId:         this.resolvedId,
            inventoryType:   invType,
            floorId:         this._invFloorId || null,
            hallId:          this._invHallId  || null
        })
            .then(result => {
                this._assignedInventory  = result.assigned  || [];
                this._availableInventory = result.available || [];
                this._invAvailableTotal  = result.availableTotal || this._availableInventory.length;
                this._invAvailableLimit  = result.availableLimit || 0;
                this.inventoryLoaded = true;
                this._reconcileSelectedInv();
            })
            .catch(err => {
                this._toast('Error', err?.body?.message || 'Could not load inventory.', 'error');
                this._assignedInventory  = [];
                this._availableInventory = [];
                this.inventoryLoaded = true;
            })
            .finally(() => { this.isInventoryLoading = false; });
    }

    handleAssignToLine(event) {
        const invId = event.currentTarget.dataset.id;
        this.isInventoryBusy = true;
        assignInventoryToLine({
            inventoryIds: [invId],
            quoteLineItemId: this.selectedLineId,
            quoteId: this.resolvedId
        })
            .then(() => {
                this._toast('Assigned', 'Inventory assigned to this line.', 'success');
                this._loadLineInventory();
                this._refreshAfterLineChange();
            })
            .catch(err => this._toast('Error', err?.body?.message || 'Could not assign inventory.', 'error'))
            .finally(() => { this.isInventoryBusy = false; });
    }

    handleReleaseFromLine(event) {
        const invId = event.currentTarget.dataset.id;
        this.isInventoryBusy = true;
        releaseInventoryFromLine({ inventoryIds: [invId] })
            .then(() => {
                this._toast('Released', 'Inventory released from this line.', 'success');
                this._loadLineInventory();
                this._refreshAfterLineChange();
            })
            .catch(err => this._toast('Error', err?.body?.message || 'Could not release inventory.', 'error'))
            .finally(() => { this.isInventoryBusy = false; });
    }

    // ─── Inventory type filter ────────────────────────────────────────────

    get invTypeFilterOptions() {
        // Show only the relevant tab when product specifies Capacity_Assignment__c
        const ca = (this._selectedCapAssign || '').toLowerCase();
        let tabs = INV_TYPE_FILTERS;
        if (ca.startsWith('space'))   tabs = ['Space'];
        else if (ca.startsWith('breaker')) tabs = ['Breaker'];
        return tabs.map(t => ({
            value: t,
            label: t,
            cls: t === this._invTypeFilter ? 'qle-inv-pill qle-inv-pill-active' : 'qle-inv-pill'
        }));
    }

    // ─── Floor / Data Hall scope (SFDC-472) ───────────────────────────────

    async _ensureInvFloors() {
        await this._loadSiteInfo();
        await this._loadInvFloors();
    }

    async _loadInvFloors() {
        if (!this._siteId) return;
        try {
            this._invFloors = await getFloorsBySite({ siteId: this._siteId });
        } catch (_e) { this._invFloors = []; }
    }

    async _loadInvHalls() {
        if (!this._invFloorId) { this._invHalls = []; return; }
        try {
            this._invHalls = await getHallsByFloor({ floorId: this._invFloorId });
        } catch (_e) { this._invHalls = []; }
    }

    get invFloorOptions() {
        return [{ label: 'All floors', value: '' }]
            .concat(this._invFloors.map(f => ({ label: f.Name, value: f.Id })));
    }

    get invHallOptions() {
        return [{ label: 'All data halls', value: '' }]
            .concat(this._invHalls.map(h => ({ label: h.Name, value: h.Id })));
    }

    get invFloorId()       { return this._invFloorId; }
    get invHallId()        { return this._invHallId; }
    get noInvHallOptions() { return !this._invFloorId || this._invHalls.length === 0; }

    get invIsTruncated() {
        return this._invAvailableLimit > 0 && this._invAvailableTotal > this._invAvailableLimit;
    }

    get invTruncationNotice() {
        return `Showing the first ${this._invAvailableLimit} of ${this._invAvailableTotal} available records. `
             + 'Pick a Floor or Data Hall to see the rest.';
    }

    async handleInvFloorChange(event) {
        this._invFloorId = event.detail.value || '';
        this._invHallId  = '';
        this._selectedInvIds = new Set();
        await this._loadInvHalls();
        if (this.selectedLineId) this._loadLineInventory();
    }

    handleInvHallChange(event) {
        this._invHallId = event.detail.value || '';
        this._selectedInvIds = new Set();
        if (this.selectedLineId) this._loadLineInventory();
    }

    handleInvTypeFilter(event) {
        this._invTypeFilter = event.currentTarget.dataset.value;
        this._selectedInvIds = new Set();
        if (this.selectedLineId) this._loadLineInventory();
    }

    get filteredAvailableInventory() {
        const term = (this._invSearchTerm || '').toLowerCase();
        let list = this._availableInventory;
        if (this._invTypeFilter === 'Space') {
            list = list.filter(r => (r.RecordType?.DeveloperName || '') === 'Inventory_Space');
            // Further filter by Space_Type if product code implies a specific type
            const expectedST = this._detectSpaceType(this.selectedLineCode);
            if (expectedST) {
                list = list.filter(r => r.Space_Type__c === expectedST);
            }
        } else if (this._invTypeFilter === 'Breaker') {
            list = list.filter(r => (r.RecordType?.DeveloperName || '') === 'Inventory_Breaker');
        }
        if (term.length >= 2) {
            list = list.filter(r =>
                (r.Name || '').toLowerCase().includes(term) ||
                (r.Unit_Reference__c || '').toLowerCase().includes(term) ||
                (r.Data_Hall__r?.Name || '').toLowerCase().includes(term)
            );
        }
        const full = this._isSelectionFull;
        return list.map(r => ({
            ...this._enrichInv(r),
            _checked:   this._selectedInvIds.has(r.Id),
            _disabled:  !this._selectedInvIds.has(r.Id) && full
        }));
    }

    // ─── Inventory selection & bulk assign ────────────────────────────────

    // How many more items can still be selected before reaching the line qty
    get _remainingNeeded() {
        const qty = Math.floor(this.selectedLineQuantity);
        return Math.max(0, qty - this._assignedInventory.length);
    }

    // True when no more selections are allowed:
    // - already fully assigned (remainingNeeded = 0), OR
    // - pending selection has filled the remaining slots
    get _isSelectionFull() {
        const qty = Math.floor(this.selectedLineQuantity);
        if (qty <= 0) return false; // no quota — don't restrict
        return this._remainingNeeded <= 0 || this._selectedInvIds.size >= this._remainingNeeded;
    }

    // Drops selections that are no longer available (already assigned via another
    // path, e.g. the individual "+" button) or that now exceed the remaining
    // capacity — prevents a stale checkbox from over-assigning on bulk submit.
    _reconcileSelectedInv() {
        if (this._selectedInvIds.size === 0) return;
        const availableIds = new Set(this._availableInventory.map(r => r.Id));
        let next = [...this._selectedInvIds].filter(id => availableIds.has(id));
        const remaining = this._remainingNeeded;
        if (next.length > remaining) next = next.slice(0, remaining);
        this._selectedInvIds = new Set(next);
    }

    handleInvCheckbox(event) {
        const invId = event.currentTarget.dataset.id;
        const next = new Set(this._selectedInvIds);
        if (event.target.checked) {
            if (this._isSelectionFull) {
                event.target.checked = false;
                return;
            }
            next.add(invId);
        } else {
            next.delete(invId);
        }
        this._selectedInvIds = next;
    }

    get hasSelectedInv() {
        return this._selectedInvIds.size > 0;
    }

    get selectedInvCount() {
        return this._selectedInvIds.size;
    }

    get assignSelectedLabel() {
        return `Assign Selected (${this._selectedInvIds.size})`;
    }

    handleBulkAssignToLine() {
        if (this._selectedInvIds.size === 0) return;
        // Defensive re-check: capacity may have filled via the individual "+"
        // button since these items were selected. Cap to what's actually left.
        const remaining = this._remainingNeeded;
        const qty = Math.floor(this.selectedLineQuantity);
        if (qty > 0 && remaining <= 0) {
            this._toast('Error', 'This line is already fully assigned.', 'error');
            this._selectedInvIds = new Set();
            return;
        }
        const ids = qty > 0 ? [...this._selectedInvIds].slice(0, remaining) : [...this._selectedInvIds];
        this.isInventoryBusy = true;
        assignInventoryToLine({
            inventoryIds: ids,
            quoteLineItemId: this.selectedLineId,
            quoteId: this.resolvedId
        })
            .then(() => {
                this._toast('Assigned', `${ids.length} inventory item(s) assigned.`, 'success');
                this._selectedInvIds = new Set();
                this._loadLineInventory();
                this._refreshAfterLineChange();
            })
            .catch(err => this._toast('Error', err?.body?.message || 'Could not assign inventory.', 'error'))
            .finally(() => { this.isInventoryBusy = false; });
    }

    // ─── Create inventory ─────────────────────────────────────────────────

    get createRTOptions()        { return CREATE_RT_OPTIONS; }
    get spaceTypeCreateOptions() { return SPACE_TYPE_CREATE_OPTIONS; }
    get capacityTypeOptions()    { return CAPACITY_TYPE_OPTIONS; }
    get floorOptions()           { return this._floors.map(f => ({ label: f.Name, value: f.Id })); }
    get hallOptions()            { return this._halls.map(h => ({ label: h.Name, value: h.Id })); }
    get isSpaceRT()              { return this.createRT === 'Inventory_Space'; }
    get isBreakerRT()            { return this.createRT === 'Inventory_Breaker'; }
    get noHallOptions()          { return this._halls.length === 0; }

    get createBtnLabel() { return this.creating ? 'Creating...' : 'Create'; }

    get createDisabled() {
        if (this.creating || !this._siteId) return true;
        if (this.isSpaceRT && !this.createSpaceType) return true;
        if (this.isBreakerRT && !this.createCapType) return true;
        return false;
    }

    async _loadSiteInfo() {
        if (this._siteLoaded) return;
        try {
            const result = await getQuoteSiteInfo({ quoteId: this.resolvedId });
            if (result) {
                this._siteId = result.id;
                this._siteLoaded = true;
            }
        } catch (_e) { /* silent */ }
    }

    async _loadCreateFloors() {
        if (!this._siteId) return;
        try {
            this._floors = await getFloorsBySite({ siteId: this._siteId });
        } catch (_e) { /* silent */ }
    }

    async _loadCreateHalls() {
        if (!this.createFloorId) { this._halls = []; return; }
        try {
            this._halls = await getHallsByFloor({ floorId: this.createFloorId });
        } catch (_e) { /* silent */ }
    }

    async handleOpenCreate() {
        await this._loadSiteInfo();
        if (!this._siteId) {
            this._toast('No Site', 'Quote needs a target site to create inventory.', 'warning');
            return;
        }
        this.showCreateModal = true;
        if (this._floors.length === 0) this._loadCreateFloors();
    }

    handleCloseCreate()               { this.showCreateModal = false; this._resetCreateForm(); }
    handleCreateModalClick(event)     { event.stopPropagation(); }
    handleCreateRTChange(event)       { this.createRT = event.detail.value; }
    handleCreateFloorChange(event)    { this.createFloorId = event.detail.value; this.createHallId = undefined; this._loadCreateHalls(); }
    handleCreateHallChange(event)     { this.createHallId = event.detail.value; }
    handleCreateSpaceTypeChange(event){ this.createSpaceType = event.detail.value; }
    handleCreateCapTypeChange(event)  { this.createCapType = event.detail.value; }
    handleCreatePowerKva(event)       { this.createPowerKva = event.detail.value; }
    handleCreateTotalCapKva(event)    { this.createTotalCapKva = event.detail.value; }
    handleCreatePanel(event)          { this.createPanel = event.detail.value; }
    handleCreateNotes(event)          { this.createNotes = event.detail.value; }
    handleCreateQty(event)            { this.createQty = event.detail.value; }

    async handleCreateSubmit() {
        if (this.createDisabled) return;
        this.creating = true;
        try {
            const count = await createInventoryRecords({
                recordTypeName:   this.createRT,
                siteId:           this._siteId,
                floorId:          this.createFloorId || null,
                dataHallId:       this.createHallId || null,
                spaceType:        this.isSpaceRT ? this.createSpaceType : null,
                capacityType:     this.isBreakerRT ? this.createCapType : null,
                powerKva:         this.createPowerKva || null,
                totalKw:          null,
                totalCapacityKva: this.createTotalCapKva || null,
                unitRefPrefix:    null,
                breakerPanel:     this.createPanel || null,
                notes:            this.createNotes || null,
                quantity:         this.createQty || 1,
                newFloorName:     null,
                newDataHallName:  null
            });
            this._toast('Created', `${count} inventory record${count > 1 ? 's' : ''} created.`, 'success');
            this.showCreateModal = false;
            this._resetCreateForm();
            if (this.selectedLineId) this._loadLineInventory();
        } catch (e) {
            this._toast('Error', e?.body?.message || 'Could not create inventory.', 'error');
        } finally {
            this.creating = false;
        }
    }

    _resetCreateForm() {
        this.createRT          = 'Inventory_Space';
        this.createFloorId     = undefined;
        this.createHallId      = undefined;
        this.createSpaceType   = 'Cabinet';
        this.createCapType     = 'Power Circuit';
        this.createPowerKva    = undefined;
        this.createTotalCapKva = undefined;
        this.createPanel       = '';
        this.createNotes       = '';
        this.createQty         = 1;
        this._halls            = [];
    }

    // ─── Cross Connect detail panel getters ────────────────────────────────

    get selectedLineIsCrossConnect()      { return !!this._selectedLine?._isCrossConnect; }
    get selectedLineCrossConnectComplete() { const l = this._selectedLine; return l ? (l._isCrossConnect && l.A_Side_Asset__c && l.Z_Side_Asset__c) : false; }
    get selectedLineASideAsset()          { return this._selectedLine?.A_Side_Asset__c || null; }
    get selectedLineZSideAsset()          { return this._selectedLine?.Z_Side_Asset__c || null; }

    handleXcSaveSuccess() {
        this._toast('Saved', 'Cross connect assets updated.', 'success');
        this._refreshAfterLineChange();
    }

    assetDisplayInfo = { primaryField: 'Name', additionalFields: ['Product2.Name'] };
    assetMatchingInfo = { primaryField: { fieldPath: 'Name' } };
    assetLookupFilter = {
        criteria: [
            { fieldPath: 'Product2.Family', operator: 'eq', value: 'Space' }
        ]
    };

    @track _pendingASide = undefined;
    @track _pendingZSide = undefined;
    @track xcSaving = false;

    handleASideChange(event) {
        this._pendingASide = event.detail.recordId || null;
    }

    handleZSideChange(event) {
        this._pendingZSide = event.detail.recordId || null;
    }
    updateCrossIdOnLineItem(){
        return updateCrossId({
            lineItemId: this.selectedLineId,
            A_Side_Asset :   this._pendingASide,
            Z_Side_Asset :     this._pendingZSide
        })
        .then(() => {
            this._toast('Saved', 'Cross connect assets updated.', 'success');
            this._pendingASide = undefined;
            this._pendingZSide = undefined;
            this._refreshAfterLineChange();
        })
        .catch(e => {
            this._toast('Error', (e.body && e.body.message) || 'Failed to save Cross.', 'error');
        })
    }
    handleXcSave() {
        this.xcSaving = true;
        this.updateCrossIdOnLineItem()
            .catch(e => {
                this._toast('Error', (e.body && e.body.message) || 'Failed to save.', 'error');
            })
            .finally(() => { this.xcSaving = false; });
    }

    // ─── Custom attribute value (PUE) getters ───────────────────────────

    get selectedLineShowCustomValue() { return !!this._selectedLine?._showCustomValue; }
    get selectedLineCustomValue()    { return this._selectedLine?.Custom_Attribute_Value__c || ''; }

    // lightning-input's onchange fires on every keystroke for type="text" (not
    // just on blur like a native input), so saving directly here fired an Apex
    // update + toast + refreshApex per character typed. Debounce so the save
    // only fires once typing pauses.
    _customValueTimer = null;

    handleDetailCustomValueChange(event) {
        const value = event.detail.value;
        const lineId = this.selectedLineId;
        clearTimeout(this._customValueTimer);
        this._customValueTimer = setTimeout(() => {
            this._saveCustomValue(lineId, value);
        }, 600);
    }

    _saveCustomValue(lineId, value) {
        const lines = [{ Id: lineId, Custom_Attribute_Value__c: value }];
        this.isLoading = true;
        updateQuoteLineItems({ lines })
            .then(() => {
                this._toast('Saved', 'Custom attribute value updated.', 'success');
                return this._refreshAfterLineChange();
            })
            .catch(err => this._toast('Save Failed', err?.body?.message || 'Could not update custom value.', 'error'))
            .finally(() => { this.isLoading = false; });
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    _deleteLines(ids) {
        this.isLoading = true;
        deleteQuoteLineItems({ lineIds: ids })
            .then(() => {
                this.selectedRowIds = this.selectedRowIds.filter(id => !ids.includes(id));
                this._toast('Removed', `${ids.length} line item${ids.length > 1 ? 's' : ''} removed.`, 'success');
                return this._refreshAfterLineChange();
            })
            .catch(err => this._toast('Delete Failed', err?.body?.message || 'Could not remove line items.', 'error'))
            .finally(() => { this.isLoading = false; });
    }

    _toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}