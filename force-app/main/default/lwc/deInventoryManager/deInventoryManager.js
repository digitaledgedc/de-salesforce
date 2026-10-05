import { LightningElement, track, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { CurrentPageReference } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

import { updateRecord }      from 'lightning/uiRecordApi';
import getSites              from '@salesforce/apex/DeInventoryManagerController.getSites';
import getFloorsBySite       from '@salesforce/apex/DeInventoryManagerController.getFloorsBySite';
import getInventorySummary   from '@salesforce/apex/DeInventoryManagerController.getInventorySummary';
import getAllSiteSummaries   from '@salesforce/apex/DeInventoryManagerController.getAllSiteSummaries';
import getFloorHallSummary   from '@salesforce/apex/DeInventoryManagerController.getFloorHallSummary';
import getInventoryByHall    from '@salesforce/apex/DeInventoryManagerController.getInventoryByHall';
import createInventoryRecords from '@salesforce/apex/DeInventoryManagerController.createInventoryRecords';
import createFloor           from '@salesforce/apex/DeInventoryManagerController.createFloor';
import bulkReleaseInventory  from '@salesforce/apex/DeInventoryManagerController.bulkReleaseInventory';
import getExportData         from '@salesforce/apex/DeInventoryManagerController.getExportData';
import getExportCount        from '@salesforce/apex/DeInventoryManagerController.getExportCount';
import importInventoryBulk   from '@salesforce/apex/DeInventoryManagerController.importInventoryBulk';
import getOdooSyncStatus     from '@salesforce/apex/DeInventoryManagerController.getOdooSyncStatus';
import updateInventoryField  from '@salesforce/apex/DeInventoryManagerController.updateInventoryField';
import updateInventoryFieldBulk from '@salesforce/apex/DeInventoryManagerController.updateInventoryFieldBulk';
import checkDuplicate        from '@salesforce/apex/DeInventoryManagerController.checkDuplicate';
import addHallToFloor        from '@salesforce/apex/DeInventoryManagerController.addHallToFloor';
import getCageHallOptions    from '@salesforce/apex/DeInventoryManagerController.getCageHallOptions';
import getAssignmentDemand   from '@salesforce/apex/DeInventoryManagerController.getAssignmentDemand';
import getAssignmentDemandMeta from '@salesforce/apex/DeInventoryManagerController.getAssignmentDemandMeta';
import getAvailableByType    from '@salesforce/apex/DeInventoryManagerController.getAvailableByType';
import decommissionInventory from '@salesforce/apex/DeInventoryManagerController.decommissionInventory';

const STATUS_ORDER = [
    'Available', 'Reserved', 'Assigned', 'Sold', 'Installed', 'Stranded','Decommissioned'
];

// Assignment stage chips. 'All' means the pending-review set the Apex default
// returns ('In Review', 'Presented', 'Approved'); 'Accepted' is fetched only when
// picked, since closed quotes outnumber live demand there (DIG-863).
const ASGN_STAGES = ['All', 'In Review', 'Approved', 'Presented', 'Accepted'];

// CHANGE 2026-08-24 (search): the Assignment search queries the database instead
// of filtering loaded rows, so it waits for enough characters to be worth a round
// trip. Keep in step with MIN_SEARCH_LENGTH in DeInventoryManagerController.
const MIN_ASGN_SEARCH = 3;

const STATUS_COLOR = {
    'Available':          '#2e844a',
    'Pending Available':  '#fe9339',
    'Reserved':           '#5c4d7a',
    'Assigned':           '#0b5394',
    'Sold':               '#0176d3',
    'Installed':          '#0d9dda',
    'Stranded':           '#ea001e',
    'Decommissioned':           '#ea001e'
};

const COUNTRY_LABELS = {
    SG: 'Singapore', HK: 'Hong Kong', JP: 'Japan', KR: 'South Korea',
    PH: 'Philippines', ID: 'Indonesia', CN: 'China', IN: 'India',
    TH: 'Thailand', MY: 'Malaysia'
};

const SITE_BREAKER_SPECS = {
    MNL1: [{ type: '3 Phase', voltage: '400V', current: '32A' }, { type: '1 Phase', voltage: '230V', current: '32A' }],
    PEK1: [{ type: '3 Phase', voltage: '400V', current: '32A' }, { type: '1 Phase', voltage: '250V', current: '32A' }],
    JKT1: [{ type: '3 Phase', voltage: '400V', current: '32A' }, { type: '1 Phase', voltage: '230V', current: '32A' }],
    JKT2: [{ type: '3 Phase', voltage: '400V', current: '32A' }, { type: '1 Phase', voltage: '230V', current: '32A' }],
    SEL1: [{ type: '3 Phase', voltage: '380V', current: '30A' }, { type: '3 Phase', voltage: '380V', current: '15A' }, { type: '3 Phase', voltage: '380V', current: '50A' }, { type: '1 Phase', voltage: '220V', current: '15A' }, { type: '1 Phase', voltage: '220V', current: '20A' }, { type: '1 Phase', voltage: '220V', current: '25A' }, { type: '1 Phase', voltage: '220V', current: '30A' }, { type: '1 Phase', voltage: '220V', current: '50A' }, { type: '1 Phase', voltage: '220V', current: '60A' }],
    SEL2: [{ type: '3 Phase', voltage: '415V', current: '40A' }, { type: '3 Phase', voltage: '415V', current: '32A' }, { type: '1 Phase', voltage: '240V', current: '16A' }, { type: '1 Phase', voltage: '240V', current: '32A' }],
    PUS1: [{ type: '3 Phase', voltage: '380V', current: '32A' }, { type: '3 Phase', voltage: '380V', current: '16A' }, { type: '1 Phase', voltage: '220V', current: '15A' }, { type: '1 Phase', voltage: '220V', current: '30A' }],
    TYO1: [{ type: '3 Phase', voltage: '210V', current: '30A' }, { type: '1 Phase', voltage: '105V', current: '20A' }, { type: '1 Phase', voltage: '105V', current: '30A' }, { type: '1 Phase', voltage: '210V', current: '20A' }, { type: '1 Phase', voltage: '210V', current: '30A' }],
    TYO2: [{ type: '1 Phase', voltage: '105V', current: '20A' }, { type: '1 Phase', voltage: '105V', current: '30A' }, { type: '1 Phase', voltage: '210V', current: '20A' }, { type: '1 Phase', voltage: '210V', current: '30A' }, { type: 'DC', voltage: '48V', current: '20A' }, { type: 'DC', voltage: '48V', current: '30A' }, { type: 'DC', voltage: '48V', current: '40A' }, { type: 'DC', voltage: '48V', current: '50A' }],
    TYO3: [{ type: '1 Phase', voltage: '105V', current: '15A' }, { type: '1 Phase', voltage: '105V', current: '20A' }, { type: '1 Phase', voltage: '105V', current: '30A' }, { type: '1 Phase', voltage: '210V', current: '20A' }, { type: '1 Phase', voltage: '210V', current: '30A' }, { type: 'DC', voltage: '48V', current: '20A' }, { type: 'DC', voltage: '48V', current: '30A' }, { type: 'DC', voltage: '48V', current: '40A' }, { type: 'DC', voltage: '48V', current: '50A' }],
    TYO4: [{ type: '1 Phase', voltage: '105V', current: '15A' }, { type: '1 Phase', voltage: '105V', current: '20A' }, { type: '1 Phase', voltage: '105V', current: '30A' }, { type: '1 Phase', voltage: '105V', current: '50A' }, { type: '1 Phase', voltage: '210V', current: '15A' }, { type: '1 Phase', voltage: '210V', current: '20A' }, { type: '1 Phase', voltage: '210V', current: '30A' }, { type: '1 Phase', voltage: '210V', current: '50A' }, { type: '1 Phase', voltage: '210V', current: '75A' }, { type: '1 Phase', voltage: '210V', current: '100A' }],
    TYO5: [{ type: '1 Phase', voltage: '105V', current: '20A' }, { type: '1 Phase', voltage: '105V', current: '30A' }, { type: '1 Phase', voltage: '210V', current: '20A' }, { type: '1 Phase', voltage: '210V', current: '30A' }],
    TYO6: [{ type: '1 Phase', voltage: '105V', current: '20A' }, { type: '1 Phase', voltage: '105V', current: '30A' }, { type: '1 Phase', voltage: '210V', current: '20A' }, { type: '1 Phase', voltage: '210V', current: '30A' }],
    TYO7: [{ type: '3 Phase', voltage: '415V', current: '30A' }, { type: '1 Phase', voltage: '240V', current: '30A' }, { type: '1 Phase', voltage: '105V', current: '30A' }],
    OSA1: [{ type: '3 Phase', voltage: '200V', current: '30A' }, { type: '1 Phase', voltage: '120V', current: '30A' }, { type: '1 Phase', voltage: '200/208V', current: '30A' }],
    OSA2: [{ type: '3 Phase', voltage: '200V', current: '30A' }, { type: '1 Phase', voltage: '120V', current: '30A' }, { type: '1 Phase', voltage: '200/208V', current: '30A' }],
    BOM1: [{ type: '3 Phase', voltage: '415V', current: '40A' }, { type: '3 Phase', voltage: '415V', current: '50A' }, { type: '1 Phase', voltage: '230V', current: '32A' }],
    BOM2: [{ type: '3 Phase', voltage: '415V', current: '32A' }, { type: '1 Phase', voltage: '230V', current: '32A' }],
    BOM3: [{ type: '3 Phase', voltage: '415V', current: '32A' }, { type: '1 Phase', voltage: '230V', current: '32A' }],
    BKK1: [{ type: '3 Phase', voltage: '400V', current: '32A' }, { type: '1 Phase', voltage: '230V', current: '32A' }],
    BKK2: [{ type: '3 Phase', voltage: '400V', current: '32A' }, { type: '1 Phase', voltage: '230V', current: '32A' }],
};

// Columns common to every inventory record, regardless of type.
// Labels that also exist in the Import template use the EXACT same text as
// IMPORT_FIELD_MAP (Apex) so an exported CSV can be edited and re-imported
// without values landing under an unrecognized header.
const EXPORT_COMMON_HEADERS = [
    'Id', 'Inventory ID', 'RecordType', 'Site', 'Floor', 'Data_Hall', 'Inventory Status',
    'Remarks', 'Account', 'Opportunity', 'Odoo_Inventory_Id'
];
// Columns that only apply to Space inventory. Odoo_Space_ID lives here (not in the
// common list) since it's only meaningful for Space records — showing it on a Breaker
// export was confusing per client feedback.
const EXPORT_SPACE_HEADERS = [
    'Space Type', 'Usage Type', 'Other Inventory Name', 'Cage Reference', 'Hall Reference',
    'CabE Size', 'CabE Count', 'Average Power per Cab (kVA)', 'Subscribed/Contracted Power (kVA)',
    'Contracted Power (kVA)',
    'SLA Temperature Min', 'SLA Temperature Max', 'SLA Humidity Min', 'SLA Humidity Max', 'SLA Availability',
    'TH Sensor ID', 'Odoo_Space_ID'
];
// Columns that only apply to Breaker inventory. Capacity Type, Breaker Panel Reference,
// and Power_Circuit_kVA are intentionally excluded per client feedback (kept off both
// import and export to avoid feeding bad/free-text data into the Odoo integration).
// Used only when exporting All types combined — see EXPORT_BREAKER_FULL_HEADERS below
// for the standalone Breaker-only export order.
const EXPORT_BREAKER_HEADERS = [
    'Breaker Type', 'Voltage Rating (V)', 'Current Rating (A)'
];
// Full column order for a Breaker-only export. The first 8 columns are deliberately
// in the EXACT same order as the Breaker Import template (Id, Inventory ID, Inventory
// Status, Other Inventory Name, Breaker Type, Voltage Rating (V), Current Rating (A),
// Remarks) so an exported file's leading columns can be copy-pasted straight into the
// import template with no rearranging; export-only/metadata columns trail after.
const EXPORT_BREAKER_FULL_HEADERS = [
    'Id', 'Inventory ID', 'Inventory Status', 'Other Inventory Name',
    'Breaker Type', 'Voltage Rating (V)', 'Current Rating (A)', 'Remarks',
    'RecordType', 'Site', 'Floor', 'Data_Hall', 'Account', 'Opportunity', 'Odoo_Inventory_Id'
];

// Column labels the importer actually recognizes — must mirror IMPORT_FIELD_MAP's
// keys in DeInventoryManagerController.cls. 'Id' is handled separately (update routing);
// 'Cage Reference'/'Hall Reference' are handled separately too (name → Id resolution).
const RECOGNIZED_IMPORT_LABELS = new Set([
    'Id', 'Inventory ID', 'Inventory Status', 'Space Type', 'Usage Type', 'CabE Size', 'CabE Count',
    'Cage Reference', 'Hall Reference',
    'Average Power per Cab (kVA)', 'Subscribed/Contracted Power (kVA)', 'Contracted Power (kVA)',
    'Breaker Type', 'Voltage Rating (V)', 'Current Rating (A)',
    'Remarks', 'Other Inventory Name',
    'SLA Temperature Min', 'SLA Temperature Max', 'SLA Humidity Min', 'SLA Humidity Max',
    'SLA Availability', 'TH Sensor ID', 'TH Sensor Group ID'
]);

export default class DeInventoryManager extends NavigationMixin(LightningElement) {

    /* ─── Sites ────────────────────────────────────────────────── */
    @track sites = [];
    @track _siteSummaries = {};
    @track selectedSiteId;
    @track sitesLoading = true;
    @track _countryFilter = '';

    /* ─── Dashboard ────────────────────────────────────────────── */
    @track summary = {};
    @track _cards = [];
    @track dashLoading = false;
    @track _selectedKey;

    /* ─── Detail (drill-down) ──────────────────────────────────── */
    @track _detailRecords = [];
    @track detailLoading = false;
    @track _detailStatus = 'All';
    @track _detailSearch = '';
    _detailTimer;

    /* ─── Selection (checkboxes) ───────────────────────────────── */
    @track _selectedIds = [];

    /* ─── Floor search ────────────────────────────────────────────── */
    @track _cardSearch = '';
    _cardSearchTimer;

    /* ─── Panel mode: detail | type-select | create-inv | create-floor */
    @track _bottomMode = 'detail';

    /* ─── Floor creation ───────────────────────────────────────── */
    @track _newFloorNum = '';
    @track _newFloorHalls = [];
    _hallCounter = 1;

    /* ─── Inventory creation (from floor context) ──────────────── */
    @track _invType = '';          // 'Space' | 'Breaker'
    @track _invSpaceType = '';     // Cabinet | Cage (selected in form for Space type)
    @track _invUsageType = 'Shared'; // Shared | Private Cage | Private Hall (Cabinet only)
    @track _cageHallRefId = null;    // Selected Cage/Hall Reference Id
    @track _cageHallOptions = [];    // Available Cage/Hall records for current floor
    @track createPowerKva;
    @track createTotalCapKva;
    @track createNotes = '';
    @track createUnitRef = '';
    @track createBreakerPanel = '';
    @track createCapacityType = 'Power Circuit';
    @track createBreakerType = '';
    @track createVoltageRating = '';
    @track createCurrentRating = '';
    @track createCabESize = 'Full';
    @track createSLATempMin = '';
    @track createSLATempMax = '';
    @track createSLAHumMin = '';
    @track createSLAHumMax = '';
    @track createSLAAvail = '99.99';
    @track creating = false;
    @track createQty = 1;

    /* ─── Naming convention (row/col) ─────────────────────────────── */
    @track _createRow = '';         // '00' to '99'
    @track _createCol = '';         // '00' to '99'
    @track _createUnitNum = '';     // unit identifier XX in USAGEXX
    @track _createBreakerName = '';
    @track _createHallNumber = '';
    @track _createSubPos = '';
    @track createStatus = 'Available';
    @track createContractedPower = null;
    @track _duplicateWarning = false;
    _dupCheckTimer;

    /* ─── Export / Import ──────────────────────────────────────── */
    @track _showExportModal = false;
    @track _showImportModal = false;
    @track _exportLoading = false;
    @track _importLoading = false;
    @track _exportHallFilter = '';
    @track _exportStatusFilter = 'All';
    @track _exportTypeFilter = 'All';
    @track _exportCount = null;
    @track _exportCountLoading = false;
    _exportCountTimer;
    @track _importStep = 'upload';
    @track _importFileName = '';
    @track _importRows = [];
    @track _importStats = {};
    @track _importResult = {};
    @track _dragOver = false;

    /* ─── Floors lookup ────────────────────────────────────────── */
    @track floors = [];

    /* ─── View toggle ────────────────────────────────────────── */
    @track _viewMode = 'inventory';

    /* ─── Assignments ────────────────────────────────────────── */
    @track _assignmentRecords = [];
    @track _assignmentsLoading = false;
    @track _openAssgnSections = new Set();
    @track _asgnStatusFilter = 'All';
    @track _asgnFulfillmentFilter = 'All';
    @track _asgnSearch = '';
    _asgnSearchTimer;
    // CHANGE 2026-08-24 (search): the term the current rows were fetched with.
    // _asgnSearch follows every keystroke; this one only moves when a query is
    // actually issued, so it is what a stage re-query has to send along and what
    // tells us a re-query is needed at all.
    _asgnSearchApplied = '';
    // CHANGE 2026-08-24b (quote cap): true totals for the current filters. The
    // rows are capped to whole quotes that fit the line budget, so without this
    // a truncated result looked identical to a complete one.
    @track _asgnMeta = {};
    @track _availByType = {};
    _demandReqToken = 0;            // guards against out-of-order stage re-queries

    /* ─── Bulk action from URL param ─────────────────────────── */
    @track _pendingAction = '';     // 'import' | 'export' | ''
    @track _showSitePicker = false;
    @track _sitePickerValue = '';
    _actionHandled = false;

    @wire(CurrentPageReference)
    handlePageRef(ref) {
        if (!ref || !ref.state || this._actionHandled) return;
        const action = ref.state.c__action;
        if (action === 'import' || action === 'export') {
            this._pendingAction = action;
            this._showSitePicker = true;
            this._actionHandled = true;
        }
    }

    /* ════════════════════════════════════════════════════════════
     *  LIFECYCLE
     * ════════════════════════════════════════════════════════ */

    connectedCallback() { this._loadSites(); }

    /* ════════════════════════════════════════════════════════════
     *  GETTERS — Site Cards
     * ════════════════════════════════════════════════════════ */

    get hasSites() { return this.sites.length > 0; }
    get hasSite()  { return !!this.selectedSiteId; }

    get siteCards() {
        let filtered = this.sites;
        if (this._countryFilter) {
            filtered = filtered.filter(s => s.Country__c === this._countryFilter);
        }
        if (this.selectedSiteId) {
            filtered = filtered.filter(s => s.Id === this.selectedSiteId);
        }
        return filtered.map(s => this._buildSiteCard(s, this.selectedSiteId));
    }

    get countryPills() {
        if (this._countryFilter) {
            return [
                { value: '', label: 'All', cls: 'dim-pill' },
                { value: this._countryFilter, label: COUNTRY_LABELS[this._countryFilter] || this._countryFilter, cls: 'dim-pill dim-pill-on' }
            ];
        }
        const countries = new Set();
        this.sites.forEach(s => { if (s.Country__c) countries.add(s.Country__c); });
        const sorted = [...countries].sort();
        const pills = [{ value: '', label: 'All', cls: 'dim-pill dim-pill-on' }];
        sorted.forEach(c => {
            pills.push({
                value: c,
                label: COUNTRY_LABELS[c] || c,
                cls: 'dim-pill'
            });
        });
        return pills;
    }

    _buildSiteCard(s, activeId) {
        const sum       = this._siteSummaries[s.Id] || {};
        const total     = sum.Total || 0;
        const installed = sum.Installed || 0;
        const sold      = sum.Sold || 0;
        const available = (sum.Available || 0) + (sum['Pending Available'] || 0);
        const held      = (sum.Reserved || 0) + (sum.Assigned || 0);
        const active    = installed + sold;
        const utilPct   = total > 0 ? Math.round((active / total) * 100) : 0;
        const selected  = s.Id === activeId;
        const spaceTotal     = sum['Space_Total'] || 0;
        const spaceAvail     = (sum['Space_Available'] || 0) + (sum['Space_Pending Available'] || 0);
        const spaceSold      = sum['Space_Sold'] || 0;
        const spaceInstalled = sum['Space_Installed'] || 0;
        const spaceHeld      = (sum['Space_Reserved'] || 0) + (sum['Space_Assigned'] || 0);
        const spaceActive    = spaceSold + spaceInstalled;
        const spaceUtilPct   = spaceTotal > 0 ? Math.round((spaceActive / spaceTotal) * 100) : 0;

        return {
            id:        s.Id,
            code:      s.Site_Code__c || s.Name,
            name:      s.Name,
            country:   s.Country__c || '',
            total: spaceTotal,
            available: spaceAvail,
            held: spaceHeld,
            active: spaceActive,
            installed: spaceInstalled,
            sold: spaceSold,
            spaceTotal,
            spaceAvail,
            utilPct: spaceUtilPct,
            utilStyle: `width:${spaceUtilPct}%;background:${this._utilColor(spaceUtilPct)}`,
            cls:       'dim-sc' + (selected ? ' dim-sc-sel' : '')
        };
    }

    _utilColor(pct) {
        if (pct >= 75) return '#0cad56';
        if (pct >= 50) return '#0070f3';
        if (pct >= 25) return '#f5a623';
        return '#e00';
    }

    /* ════════════════════════════════════════════════════════════
     *  GETTERS — Global Metrics (no site selected)
     * ════════════════════════════════════════════════════════ */

    get globalSiteCount() {
        if (this._countryFilter) {
            return this.sites.filter(s => s.Country__c === this._countryFilter).length;
        }
        return this.sites.length;
    }

    get globalTotal() {
        let total = 0;
        const filtered = this._countryFilter
            ? this.sites.filter(s => s.Country__c === this._countryFilter)
            : this.sites;
        filtered.forEach(s => {
            const sum = this._siteSummaries[s.Id] || {};
            total += sum['Space_Total'] || 0;
        });
        return total;
    }

    get globalAvailable() {
        let avail = 0;
        const filtered = this._countryFilter
            ? this.sites.filter(s => s.Country__c === this._countryFilter)
            : this.sites;
        filtered.forEach(s => {
            const sum = this._siteSummaries[s.Id] || {};
            avail += (sum['Space_Available'] || 0) + (sum['Space_Pending Available'] || 0);
        });
        return avail;
    }

    /* ════════════════════════════════════════════════════════════
     *  GETTERS — Summary (site selected)
     * ════════════════════════════════════════════════════════ */

    get totalCount()     { return this.summary.Total || 0; }
    get availableCount() {
        return (this.summary.Available || 0) + (this.summary['Pending Available'] || 0);
    }
    get reservedCount() {
        return this.summary.Committed || 0;
    }
    get soldCount()      { return this.summary.Sold      || 0; }
    get installedCount() { return this.summary.Installed  || 0; }

    get floorCount() {
        const fset = new Set(this._cards.map(c => c.floorId).filter(Boolean));
        return fset.size;
    }
    get hallCount() { return this._cards.length; }

    get utilPct() {
        const t = this.totalCount;
        return t ? Math.round(((this.installedCount + this.soldCount) / t) * 100) : 0;
    }
    get utilStyle() {
        return `width:${this.utilPct}%;background:${this._utilColor(this.utilPct)}`;
    }
    get selectedSiteCode() {
        if (!this.selectedSiteId) return '';
        const s = this.sites.find(x => x.Id === this.selectedSiteId);
        return s ? (s.Site_Code__c || '') : '';
    }
    get selectedSiteName() {
        if (!this.selectedSiteId) return '';
        const s = this.sites.find(x => x.Id === this.selectedSiteId);
        return s ? (s.Name || '') : '';
    }

    /* ════════════════════════════════════════════════════════════
     *  GETTERS — View Toggle
     * ════════════════════════════════════════════════════════ */

    get isInventoryView()   { return this._viewMode === 'inventory'; }
    get isAssignmentsView() { return this._viewMode === 'assignments'; }

    get inventoryToggleCls() {
        return 'dim-toggle-btn' + (this.isInventoryView ? ' dim-toggle-btn-on' : '');
    }
    get assignmentsToggleCls() {
        return 'dim-toggle-btn' + (this.isAssignmentsView ? ' dim-toggle-btn-on' : '');
    }

    /* ════════════════════════════════════════════════════════════
     *  GETTERS — Assignments View
     * ════════════════════════════════════════════════════════ */

    get asgnTotalDemand()  { return this.filteredAssignmentRecords.length; }
    get asgnFulfilled()    { return this.filteredAssignmentRecords.filter(r => r.Reserved__c === 'Reserved').length; }
    get asgnUnfulfilled()  {
        return this.filteredAssignmentRecords.filter(r =>
            r.Reserved__c !== 'Reserved' && r.Reserved__c !== 'N/A'
        ).length;
    }
    get asgnAvailSupply()  { return this.availableCount; }
    get asgnQuoteCount()   {
        return new Set(this.filteredAssignmentRecords.map(r => r.QuoteId)).size;
    }
    get hasAssignments() { return this._assignmentRecords.length > 0; }
    get hasFilteredAssignments() { return this.filteredAssignmentRecords.length > 0; }

    get _siteCountryMap() {
        const map = {};
        this.sites.forEach(s => { if (s.Site_Code__c && s.Country__c) map[s.Site_Code__c] = s.Country__c; });
        return map;
    }

    get filteredAssignmentRecords() {
        // Draft never reaches us any more (DIG-863 dropped it from the SOQL), and
        // stage is filtered in Apex — re-filtering it here would be a no-op that
        // hides the fact that switching a chip is a re-query.
        let records = this._assignmentRecords;
        if (this._countryFilter && !this.selectedSiteId) {
            const scMap = this._siteCountryMap;
            records = records.filter(r => {
                const sc = r.Quote && r.Quote.Target_Site__r ? r.Quote.Target_Site__r.Site_Code__c : '';
                return scMap[sc] === this._countryFilter;
            });
        }
        // Fulfillment status narrows the Stage/search result set in the browser.
        // A quote is Fulfilled when every reservable line is Reserved; Unfulfilled
        // when any reservable line is still open. N/A-only quotes are excluded from
        // both Fulfilled and Unfulfilled (they are not demand to reserve).
        if (this._asgnFulfillmentFilter === 'Fulfilled'
                || this._asgnFulfillmentFilter === 'Unfulfilled') {
            const byQuote = new Map();
            records.forEach(r => {
                if (!byQuote.has(r.QuoteId)) byQuote.set(r.QuoteId, []);
                byQuote.get(r.QuoteId).push(r);
            });
            const keep = new Set();
            byQuote.forEach((lines, qid) => {
                const reservable = lines.filter(l => l.Reserved__c !== 'N/A');
                if (reservable.length === 0) return;
                const allFulfilled = reservable.every(l => l.Reserved__c === 'Reserved');
                if (this._asgnFulfillmentFilter === 'Fulfilled' && allFulfilled) {
                    keep.add(qid);
                } else if (this._asgnFulfillmentFilter === 'Unfulfilled' && !allFulfilled) {
                    keep.add(qid);
                }
            });
            records = records.filter(r => keep.has(r.QuoteId));
        }
        // CHANGE 2026-08-24 (search): search moved into SOQL, so the rows below
        // are already the search result — re-filtering them here would hide
        // valid matches, because this predicate only consults opp.Name when the
        // account name is blank while the query matches either field on its own.
        // Kept for reference: restore this block and drop searchTerm from the
        // getAssignmentDemand calls to return to client-side searching.
        //
        // const q = (this._asgnSearch || '').trim().toLowerCase();
        // if (q) {
        //     records = records.filter(r => {
        //         const quote = r.Quote || {};
        //         const opp = quote.Opportunity || {};
        //         const acct = opp.Account || {};
        //         const accountName = (acct.Name || opp.Name || '').toLowerCase();
        //         const quoteNumber = (quote.QuoteNumber || '').toLowerCase();
        //         return accountName.includes(q) || quoteNumber.includes(q);
        //     });
        // }
        return records;
    }

    get hasAsgnSearch() { return (this._asgnSearch || '').trim().length > 0; }

    // CHANGE 2026-08-24 (search): the Stage chips and the search box must stay
    // mounted even when the current query returned nothing — they are the only
    // way to undo the search or filter that emptied the list. Keeping them
    // rendered also stops the input being torn out from under the cursor on
    // every query, which lost focus and any keystroke still in flight.
    get _asgnFilterActive() {
        return this.hasAsgnSearch
            || this._asgnStatusFilter !== 'All'
            || this._asgnFulfillmentFilter !== 'All';
    }

    get asgnFulfillmentOptions() {
        return ['All', 'Fulfilled', 'Unfulfilled'].map(v => ({
            value: v,
            label: v,
            selected: this._asgnFulfillmentFilter === v
        }));
    }
    get showAsgnFilterBar() {
        return this.hasAssignments || this._asgnFilterActive;
    }
    // Nothing came back, but the user narrowed it — say so, and keep the
    // controls. The full "No Active Assignments" illustration is for a genuinely
    // empty pipeline, which is a different message and offers nothing to undo.
    get showAsgnNoMatch() {
        return !this.hasAssignments && this._asgnFilterActive;
    }
    get showAsgnEmptyState() {
        return !this.hasAssignments && !this._asgnFilterActive;
    }

    // CHANGE 2026-08-24b (quote cap): say so when the budget cut the result.
    // Silence here is what made "All=301 quotes" look like the whole answer when
    // 641 quotes actually matched.
    get isAsgnTruncated() { return this._asgnMeta.truncated === true; }
    get asgnTruncationNote() {
        const m = this._asgnMeta || {};
        const shown = m.shownQuotes || 0;
        const total = m.scanCapped ? `${m.totalQuotes}+` : (m.totalQuotes || 0);
        return `Showing ${shown} of ${total} matching quotes — narrow your search`
             + ' to see the rest.';
    }
    get asgnSearchCount() {
        return new Set(this.filteredAssignmentRecords.map(r => r.QuoteId)).size;
    }

    get asgnStatusPills() {
        return ASGN_STAGES.map(s => ({
            label: s, value: s,
            cls: 'dim-pill' + (this._asgnStatusFilter === s ? ' dim-pill-on' : '')
        }));
    }

    get asgnAvailSpaces()   { return this._availByType.Space || 0; }
    get asgnAvailBreakers() { return this._availByType.Breaker || 0; }
    get asgnSiteCount() {
        return new Set(this.filteredAssignmentRecords
            .filter(r => r.Quote && r.Quote.Target_Site__c)
            .map(r => r.Quote.Target_Site__c)
        ).size;
    }
    get isGlobalAssignments() { return this.isAssignmentsView && !this.selectedSiteId; }

    /* ─── Type breakdown (overview card) ────────────────────────── */
    get spaceTotal()       { return this._availByType.SpaceTotal || 0; }
    get spaceAvailable()   { return this._availByType.Space || 0; }
    get breakerTotal()     { return this._availByType.BreakerTotal || 0; }
    get breakerAvailable() { return this._availByType.Breaker || 0; }

    get assignmentGroups() {
        const map = new Map();
        this.filteredAssignmentRecords.forEach(r => {
            const qid = r.QuoteId;
            if (!map.has(qid)) {
                const q = r.Quote || {};
                const opp = q.Opportunity || {};
                const acct = opp.Account || {};
                const site = q.Target_Site__r || {};
                const rddVal = q.RDD__c;
                map.set(qid, {
                    quoteId: qid,
                    quoteNumber: q.QuoteNumber || '',
                    quoteStatus: q.Status || '',
                    accountName: acct.Name || opp.Name || '',
                    oppName: opp.Name || '',
                    siteCode: site.Site_Code__c || '',
                    hasSiteCode: !!site.Site_Code__c && !this.selectedSiteId,
                    rdd: rddVal
                        ? new Date(rddVal).toLocaleDateString('en-US', {
                              month: 'short', day: 'numeric', year: 'numeric'
                          })
                        : '',
                    hasRdd: !!rddVal,
                    lines: [],
                    statusCls: 'dim-status dim-st-'
                        + (q.Status || '').toLowerCase().replace(/\s+/g, '-')
                });
            }

            const spName = (r.Space_ID__r && r.Space_ID__r.Name) || '';
            const brkName = (r.Breaker_ID__r && r.Breaker_ID__r.Name) || '';

            map.get(qid).lines.push({
                id: r.Id,
                productName: (r.Product2 && r.Product2.Name) || '',
                productCode: (r.Product2 && r.Product2.ProductCode) || '',
                quantity: r.Quantity || 0,
                reserved: r.Reserved__c || 'Not Reserved',
                reservedCls: this._reservedBadge(r.Reserved__c),
                spaceName: spName,
                breakerName: brkName,
                powerLabel: r.Power_kVA__c ? r.Power_kVA__c + ' kVA' : '',
                cabeLabel: r.CabE__c != null ? String(r.CabE__c) : ''
            });
        });

        return [...map.values()].map(g => {
            const reservable = g.lines.filter(l => l.reserved !== 'N/A');
            const total = reservable.length;
            const fulfilled = reservable.filter(l => l.reserved === 'Reserved').length;
            const isOpen = this._openAssgnSections.has(g.quoteId);
            return {
                ...g,
                isOpen,
                chevronCls: 'dim-chevron' + (isOpen ? ' dim-chevron-open' : ''),
                fulfillLabel: `${fulfilled}/${total} reserved`,
                fulfillCls: fulfilled === total
                    ? 'dim-asgn-tag dim-asgn-tag-full'
                    : fulfilled > 0
                        ? 'dim-asgn-tag dim-asgn-tag-partial'
                        : 'dim-asgn-tag dim-asgn-tag-none'
            };
        });
    }

    /* ════════════════════════════════════════════════════════════
     *  GETTERS — Cards (sorted by floor number)
     * ════════════════════════════════════════════════════════ */

    get hasCards() { return this._cards.length > 0; }

    get enrichedCards() {
        const sc = this.selectedSiteCode;
        const sorted = [...this._cards].sort((a, b) => {
            const fa = this._floorNum(a.floorName);
            const fb = this._floorNum(b.floorName);
            if (fa !== fb) return fa - fb;
            return (a.hallName || '').localeCompare(b.hallName || '');
        });

        return sorted.map(c => {
            const key = c.hallId || '_none';
            const sel = this._selectedKey === key;
            // Space-only utilization, matching the space-only "spaces"/"avail" figures
            // shown alongside it — total minus available equals held+active.
            const up  = c.spaceTotal > 0
                ? Math.round(((c.spaceTotal - c.spaceAvail) / c.spaceTotal) * 100) : 0;

            const fn = c.floorName
                ? c.floorName.replace(sc + '-', '').replace(/^0+(?=\d)/, '')
                : '—';
            return {
                ...c,
                key,
                sel,
                floorLabel: `Floor ${fn}`,
                hallLabel:  c.hallName || '—',
                totalLabel: `${c.spaceTotal || 0}`,
                availLabel: `${c.spaceAvail || 0} avail`,
                breakdownParts: this._bdParts(c),
                utilPct: up,
                utilStyle: `width:${up}%;background:${this._utilColor(up)}`,
                cls: 'dim-card' + (sel ? ' dim-card-sel' : ''),
            };
        });
    }

    get filteredCards() {
        let cards = this.enrichedCards;
        if (this._selectedKey) {
            cards = cards.filter(c => c.key === this._selectedKey);
        }
        const q = (this._cardSearch || '').trim().toLowerCase();
        if (!q) return cards;
        return cards.filter(c =>
            c.floorLabel.toLowerCase().includes(q) ||
            c.hallLabel.toLowerCase().includes(q) ||
            (c.floorName || '').toLowerCase().includes(q) ||
            (c.hallName || '').toLowerCase().includes(q)
        );
    }

    get hasCardSearch() { return (this._cardSearch || '').trim().length > 0; }
    get cardSearchCount() { return this.filteredCards.length; }
    get showCardControls() { return !this._selectedKey; }

    _floorNum(name) {
        if (!name) return 0;
        const parts = name.split('-');
        for (let i = parts.length - 1; i >= 0; i--) {
            const n = parseInt(parts[i], 10);
            if (!isNaN(n)) return n;
        }
        return 0;
    }

    _bdParts(c) {
        const p = [];
        // Installed always shows (even "0 Installed") — it's meaningful in-service data.
        // Sold/Assigned only show when there's actually something to report.
        if (c.spaceSold) p.push({ k: 's', t: `${c.spaceSold} sold`,     c: 'dim-bd-s' });
        p.push({ k: 'x', t: `${c.spaceInstalled || 0} installed`, c: 'dim-bd-x' });
        if (c.spaceHeld) p.push({ k: 'h', t: `${c.spaceHeld} assigned`, c: 'dim-bd-h' });
        return p;
    }

    /* ════════════════════════════════════════════════════════════
     *  GETTERS — Detail Panel
     * ════════════════════════════════════════════════════════ */

    get hasDetailPanel() {
        return !!this._selectedKey
            && ['detail', 'type-select', 'create-inv'].includes(this._bottomMode);
    }
    get isDetailMode()  { return this._bottomMode === 'detail'; }
    get isTypeSelect()  { return this._bottomMode === 'type-select'; }
    get isInvCreate()   { return this._bottomMode === 'create-inv'; }
    get showFloorPanel(){ return this._bottomMode === 'create-floor'; }
    get isNotDetail()   { return !this.isDetailMode; }
    get showCardRow()   { return !this._selectedKey && !this.showFloorPanel; }

    get selCard() {
        if (!this._selectedKey) return null;
        return this.enrichedCards.find(c => c.key === this._selectedKey) || null;
    }
    get detailTitle() {
        const c = this.selCard;
        return c ? `${c.floorLabel} / ${c.hallLabel}` : '';
    }
    get detailTotal() {
        const c = this.selCard;
        return c ? c.total : 0;
    }

    get detailPills() {
        return ['All', ...STATUS_ORDER].map(s => ({
            label: s, value: s,
            cls: 'dim-pill' + (this._detailStatus === s ? ' dim-pill-on' : '')
        }));
    }

    get filteredDetail() {
        let list = this._detailRecords;
        const st = this._detailStatus;
        const q  = (this._detailSearch || '').toLowerCase();

        if (st && st !== 'All') {
            list = list.filter(r => r.Status__c === st);
        }
        if (q) {
            list = list.filter(r =>
                (r.Name || '').toLowerCase().includes(q) ||
                (r.Unit_Reference__c || '').toLowerCase().includes(q) ||
                (r.Account__r && r.Account__r.Name || '').toLowerCase().includes(q)
            );
        }
        const selSet = new Set(this._selectedIds);
        return list.map(r => {
            const enriched = this._enrich(r);
            enriched.isChecked = selSet.has(r.Id);
            enriched.rowCls = 'dim-row' + (enriched.isChecked ? ' dim-row-sel' : '');
            return enriched;
        });
    }
    get hasDetail()   { return this.filteredDetail.length > 0; }
    get detailShown() { return this.filteredDetail.length; }

    @track _openSections = new Set();

    get groupedDetail() {
        const all = this.filteredDetail;
        const space   = all.filter(r => r.typeLabel === 'Space');
        const breaker = all.filter(r => r.typeLabel === 'Breaker');
        const groups = [];
        if (space.length)   groups.push({ key: 'space',   label: 'SPACE',   count: space.length,   rows: space,   isSpace: true,  isBreaker: false, isOpen: this._openSections.has('space'),   chevronCls: 'dim-chevron' + (this._openSections.has('space') ? ' dim-chevron-open' : '') });
        if (breaker.length) groups.push({ key: 'breaker', label: 'BREAKER', count: breaker.length, rows: breaker, isSpace: false, isBreaker: true,  isOpen: this._openSections.has('breaker'), chevronCls: 'dim-chevron' + (this._openSections.has('breaker') ? ' dim-chevron-open' : '') });
        return groups;
    }

    handleSectionToggle(e) {
        const key  = e.currentTarget.dataset.key;
        const next = new Set(this._openSections);
        if (next.has(key)) next.delete(key); else next.add(key);
        this._openSections = next;
    }

    /* ─── Selection ────────────────────────────────────────────── */
    get hasSelected()   { return this._selectedIds.length > 0; }
    get selectedCount() { return this._selectedIds.length; }
    get isAllSelected() {
        const visible = this._filteredIds();
        if (!visible.length) return false;
        const selSet = new Set(this._selectedIds);
        return visible.every(id => selSet.has(id));
    }
    _filteredIds() {
        let list = this._detailRecords;
        const st = this._detailStatus;
        const q  = (this._detailSearch || '').toLowerCase();
        if (st && st !== 'All') list = list.filter(r => r.Status__c === st);
        if (q) {
            list = list.filter(r =>
                (r.Name || '').toLowerCase().includes(q) ||
                (r.Unit_Reference__c || '').toLowerCase().includes(q) ||
                (r.Account__r && r.Account__r.Name || '').toLowerCase().includes(q)
            );
        }
        return list.map(r => r.Id);
    }

    /* ─── Floor creation ───────────────────────────────────────── */
    get floorNamePreview() {
        return `${this.selectedSiteCode}-${this._newFloorNum}`;
    }
    get newFloorHalls() {
        const sc = this.selectedSiteCode;
        const fn = this._newFloorNum;
        return this._newFloorHalls.map((h, i) => ({
            key: h.key,
            name: sc && fn ? `${sc}-${fn}-${i + 1}` : `Hall ${i + 1}`,
            canRemove: this._newFloorHalls.length > 1
        }));
    }
    get floorCreateOff() {
        return this.creating || !this._newFloorNum || !this.selectedSiteId;
    }

    /* ─── Inventory creation ───────────────────────────────────── */
    get invTypeLabel() { return this._invType || 'Inventory'; }
    get isBreaker()    { return this._invType === 'Breaker'; }
    get isSpace()      { return this._invType === 'Space'; }

    get selectedTypeCardCls() {
        const base = 'dim-type-card dim-type-card-chosen';
        return this.isBreaker ? base + ' dim-type-card-breaker' : base + ' dim-type-card-cabinet';
    }
    get selectedTypeIconCls() {
        return this.isBreaker ? 'dim-type-icon dim-type-breaker' : 'dim-type-icon dim-type-cabinet';
    }
    get selectedTypeIcon() {
        return this.isBreaker ? 'utility:thunder' : 'utility:database';
    }
    get selectedTypeDesc() {
        return this.isBreaker ? 'Power circuit / breaker' : 'Colocation space unit';
    }

    get spaceTypeOptions() {
        return [
            { label: 'Cabinet', value: 'Cabinet', selected: this._invSpaceType === 'Cabinet' },
            { label: 'Cage', value: 'Cage', selected: this._invSpaceType === 'Cage' },
            { label: 'Hall', value: 'Hall', selected: this._invSpaceType === 'Hall' },
            { label: 'Flex Office', value: 'Flex Office', selected: this._invSpaceType === 'Flex Office' }
        ];
    }

    get usageTypeOptions() {
        return [
            { label: 'Shared', value: 'Shared', selected: this._invUsageType === 'Shared' },
            { label: 'Private Cage', value: 'Private Cage', selected: this._invUsageType === 'Private Cage' },
            { label: 'Private Hall', value: 'Private Hall', selected: this._invUsageType === 'Private Hall' }
        ];
    }
    get showUsageType() { return this._invSpaceType === 'Cabinet'; }
    get showCageHallRef() { return this._invSpaceType === 'Cabinet' && (this._invUsageType === 'Private Cage' || this._invUsageType === 'Private Hall'); }
    get cageHallRefLabel() { return this._invUsageType === 'Private Hall' ? 'Hall Reference' : 'Cage Reference'; }
    get cageHallRefOptions() {
        const targetType = this._invUsageType === 'Private Hall' ? 'Hall' : 'Cage';
        return this._cageHallOptions
            .filter(o => o.type === targetType)
            .map(o => ({ label: o.name, value: o.id, selected: o.id === this._cageHallRefId }));
    }
    handleUsageType(e) {
        this._invUsageType = e.target.value;
        this._cageHallRefId = null;
        if (this._invUsageType === 'Private Cage' || this._invUsageType === 'Private Hall') {
            this._loadCageHallOptions();
        }
    }
    handleCageHallRef(e) { this._cageHallRefId = e.target.value || null; }
    async _loadCageHallOptions() {
        const card = this.selCard;
        if (!card || !card.floorId) { this._cageHallOptions = []; return; }
        try {
            this._cageHallOptions = await getCageHallOptions({ floorId: card.floorId });
        } catch (err) {
            this._cageHallOptions = [];
        }
    }

    get capacityTypeOptions() {
        return [
            { label: 'Power Circuit', value: 'Power Circuit', selected: this.createCapacityType === 'Power Circuit' },
            { label: 'Cross Connect Port', value: 'Cross Connect Port', selected: this.createCapacityType === 'Cross Connect Port' }
        ];
    }

    get _siteSpecs() {
        const sc = this.selectedSiteCode;
        return SITE_BREAKER_SPECS[sc] || [];
    }

    get breakerTypeOptions() {
        const types = [...new Set(this._siteSpecs.map(s => s.type))];
        return types.map(t => ({ label: t, value: t, selected: this.createBreakerType === t }));
    }

    get voltageOptions() {
        const specs = this._siteSpecs.filter(s => !this.createBreakerType || s.type === this.createBreakerType);
        const voltages = [...new Set(specs.map(s => s.voltage))];
        return voltages.map(v => ({ label: v, value: v, selected: this.createVoltageRating === v }));
    }

    get currentOptions() {
        const specs = this._siteSpecs.filter(s =>
            (!this.createBreakerType || s.type === this.createBreakerType) &&
            (!this.createVoltageRating || s.voltage === this.createVoltageRating)
        );
        const currents = [...new Set(specs.map(s => s.current))];
        return currents.map(c => ({ label: c, value: c, selected: this.createCurrentRating === c }));
    }

    get slaTempMinOptions() {
        const opts = [{ label: '—', value: '', selected: !this.createSLATempMin }];
        for (let i = 15; i <= 25; i++) {
            const v = String(i);
            opts.push({ label: v + '°C', value: v, selected: this.createSLATempMin === v });
        }
        return opts;
    }
    get slaTempMaxOptions() {
        const opts = [{ label: '—', value: '', selected: !this.createSLATempMax }];
        for (let i = 25; i <= 35; i++) {
            const v = String(i);
            opts.push({ label: v + '°C', value: v, selected: this.createSLATempMax === v });
        }
        return opts;
    }
    get slaHumMinOptions() {
        const opts = [{ label: '—', value: '', selected: !this.createSLAHumMin }];
        for (let i = 10; i <= 50; i += 5) {
            const v = String(i);
            opts.push({ label: v + '%', value: v, selected: this.createSLAHumMin === v });
        }
        return opts;
    }
    get slaHumMaxOptions() {
        const opts = [{ label: '—', value: '', selected: !this.createSLAHumMax }];
        for (let i = 50; i <= 80; i += 5) {
            const v = String(i);
            opts.push({ label: v + '%', value: v, selected: this.createSLAHumMax === v });
        }
        return opts;
    }

    get slaAvailabilityOptions() {
        const opts = ['99.9', '99.95', '99.99', '99.995', '99.999'];
        return opts.map(o => ({ label: o + '%', value: o, selected: this.createSLAAvail === o })); // label matches picklist label
    }

    get cabeSizeOptions() {
        return [
            { label: '0.125', value: '0.125', selected: this.createCabESize === '0.125' },
            { label: '0.25', value: '0.25', selected: this.createCabESize === '0.25' },
            { label: '0.5', value: '0.5', selected: this.createCabESize === '0.5' },
            { label: '3U', value: '3U', selected: this.createCabESize === '3U' },
            { label: 'Full', value: 'Full', selected: this.createCabESize === 'Full' }
        ];
    }

    /* ─── Naming convention getters ───────────────────────────────── */

    get _typeCode() {
        if (this._invType === 'Breaker') return 'BRK';
        if (this._invSpaceType === 'Cage') return 'C';
        if (this._invSpaceType === 'Hall') return 'H';
        if (this._invSpaceType === 'Cabinet') {
            if (this._invUsageType === 'Private Cage') return 'C';
            if (this._invUsageType === 'Private Hall') return 'H';
            return 'S';
        }
        return '_';
    }

    get isFlexOffice() {
        return this._invSpaceType === 'Flex Office';
    }

    get needsRowCol() {
        return this.isSpace && this._invSpaceType === 'Cabinet';
    }
    get needsSubPos() {
        return this.needsRowCol && this.createCabESize && this.createCabESize !== 'Full' && this.createCabESize !== '3U';
    }
    get subPosOptions() {
        const size = this.createCabESize;
        if (size === '0.5')   return [{ label: '—', value: '' }, { label: 'X', value: 'X' }, { label: 'Y', value: 'Y' }];
        if (size === '0.25')  return [{ label: '—', value: '' }, { label: 'A', value: 'A' }, { label: 'B', value: 'B' }, { label: 'C', value: 'C' }, { label: 'D', value: 'D' }];
        if (size === '0.125') return [{ label: '—', value: '' }, { label: 'E1', value: 'E1' }, { label: 'E2', value: 'E2' }, { label: 'E3', value: 'E3' }, { label: 'E4', value: 'E4' }, { label: 'E5', value: 'E5' }, { label: 'E6', value: 'E6' }, { label: 'E7', value: 'E7' }, { label: 'E8', value: 'E8' }];
        return [];
    }
    get showCabEFields() {
        return this.isSpace && this._invSpaceType === 'Cabinet';
    }
    get isHallType() {
        return this._invSpaceType === 'Hall';
    }

    get _roomPart() {
        const card = this.selCard;
        if (!card || !card.hallName) return '00';
        // Use the last segment of the hall name (e.g. "MNL1-01-COLP5" → "COLP5")
        const hallName = card.hallName || '';
        const lastSeg = hallName.includes('-')
            ? hallName.substring(hallName.lastIndexOf('-') + 1)
            : hallName;
        // Split into alpha prefix and trailing digits
        // e.g. "COLP5" → prefix="COLP", digits="5" → "COLP05"
        // e.g. "DH01" → prefix="DH", digits="01" → "DH01"
        const match = lastSeg.match(/^([A-Za-z]+)(\d+)$/);
        if (match) {
            return match[1] + match[2].padStart(2, '0');
        }
        // If no trailing digits, return as-is
        return lastSeg;
    }

    get _floorPart() {
        const card = this.selCard;
        if (!card || !card.floorName) return '00';
        const sc = this.selectedSiteCode;
        let fp = (card.floorName || '').replace(sc + '-', '');
        if (/^\d+$/.test(fp)) fp = fp.padStart(2, '0');
        return fp;
    }

    get _hallPart() {
        // In create mode, use the editable hall number
        if (this._createHallNumber) {
            const hp = this._createHallNumber;
            return /^\d+$/.test(hp) ? hp.padStart(2, '0') : hp;
        }
        const card = this.selCard;
        if (!card) return '00';
        // Prefer Hall_Number__c from the DataHall record
        if (card.hallNumber) {
            const hp = card.hallNumber;
            return /^\d+$/.test(hp) ? hp.padStart(2, '0') : hp;
        }
        // Fall back to parsing the hall name
        if (!card.hallName) return '00';
        const match = (card.hallName || '').match(/(\d+)\s*$/);
        let hp = match ? match[1] : '00';
        hp = hp.padStart(2, '0');
        return hp;
    }

    get createNamePreview() {
        const sc = this.selectedSiteCode;
        if (!sc) return '';
        const unitPart = this._createUnitNum
            ? this._createUnitNum.padStart(2, '0')
            : '__';

        // Flex Office: Section 5 format — SITE-FLOOR-ROOMXX-FSXX
        if (this.isFlexOffice) {
            return `${sc}-${this._floorPart}-${this._roomPart}-FS${unitPart}`;
        }

        // Section 6 format — SITE-FLOOR-DHAA-USAGEXX[-RKYYZZ]
        const prefix = `${sc}-${this._floorPart}-DH${this._hallPart}-${this._typeCode}${unitPart}`;

        // Only Cabinet gets rack suffix
        if (this._invSpaceType !== 'Cabinet') {
            return prefix;
        }
        if (!this._createRow && !this._createCol) {
            return `${prefix}-RK____`;
        }
        const rp = (this._createRow || '__').padStart(2, '0');
        const cp = (this._createCol || '__').padStart(2, '0');
        const rDisplay = this._createRow ? rp : '__';
        const cDisplay = this._createCol ? cp : '__';
        const subPos = this._createSubPos || '';
        return `${prefix}-RK${rDisplay}${cDisplay}${subPos}`;
    }

    get hasNamePreview() {
        if (!this._createUnitNum) return false;
        if (this._invSpaceType === 'Cabinet') {
            return !!this._createRow && !!this._createCol;
        }
        return true;
    }

    get showBulkQty() { return !this._selectedKey && this._invSpaceType !== 'Cabinet'; }

    get createContextBreadcrumb() {
        const sc = this.selectedSiteCode;
        const card = this.selCard;
        if (!card) return sc || '';
        const parts = [sc];
        if (card.floorLabel) parts.push(card.floorLabel);
        if (card.hallLabel) parts.push(card.hallLabel);
        return parts.join('  /  ');
    }

    get invCreateOff() {
        if (this.creating || !this._invType) return true;
        if (this._invType === 'Space') {
            if (!this._invSpaceType) return true;
            if (!this._createUnitNum || !/^\d{1,2}$/.test(this._createUnitNum)) return true;
            // Only Cabinet needs row/col for rack position
            if (this._invSpaceType === 'Cabinet') {
                const rowOk = this._createRow && /^\d{1,2}$/.test(this._createRow);
                const colOk = this._createCol && /^\d{1,2}$/.test(this._createCol);
                if (!rowOk || !colOk) return true;
            }
        }
        if (this._invType === 'Breaker') {
            if (!this._createBreakerName) return true;
            if (!this.createBreakerType || !this.createVoltageRating || !this.createCurrentRating) return true;
        }
        return false
            || this._duplicateWarning;
    }

    /* ─── Export modal ────────────────────────────────────────── */
    get exportHallOptions() {
        const f = this._exportHallFilter;
        const opts = [{ label: 'All Data Halls', value: '', selected: f === '' }];
        this._cards.forEach(c => {
            if (c.hallId) {
                opts.push({
                    label: (c.floorName || '') + ' / ' + (c.hallName || ''),
                    value: c.hallId,
                    selected: f === c.hallId
                });
            }
        });
        return opts;
    }
    get exportStatusOptions() {
        const f = this._exportStatusFilter;
        return [
            { label: 'All Statuses', value: 'All', selected: f === 'All' },
            ...STATUS_ORDER.map(s => ({ label: s, value: s, selected: f === s }))
        ];
    }
    get exportTypeOptions() {
        const f = this._exportTypeFilter;
        return [
            { label: 'All Types', value: 'All', selected: f === 'All' },
            { label: 'Space', value: 'Inventory_Space', selected: f === 'Inventory_Space' },
            { label: 'Breaker', value: 'Inventory_Breaker', selected: f === 'Inventory_Breaker' }
        ];
    }

    /* ─── Import modal ────────────────────────────────────────── */
    get isImportSetup()   { return this._importStep === 'setup'; }
    get isImportUpload()  { return this._importStep === 'upload'; }
    get isImportConfirm() { return this._importStep === 'confirm'; }
    get isImportResult()  { return this._importStep === 'result'; }

    // Setup step state
    _importRT = '';
    _importHallId = '';
    _importFloorId = '';

    get importSetupIncomplete() { return !this._importRT || !this._importHallId; }
    get importRTLabel() { return this._importRT === 'Inventory_Space' ? 'Space' : 'Breaker'; }
    get importHallLabel() {
        const opt = (this.importHallOptions || []).find(o => o.value === this._importHallId);
        return opt ? opt.label : '';
    }
    get importSpaceBtnCls()   { return 'dim-pill' + (this._importRT === 'Inventory_Space' ? ' dim-pill-on' : ''); }
    get importBreakerBtnCls() { return 'dim-pill' + (this._importRT === 'Inventory_Breaker' ? ' dim-pill-on' : ''); }

    get importHallOptions() {
        if (!this._cards) return [];
        return this._cards
            .filter(card => card.hallId)
            .map(card => ({
                value: card.hallId,
                label: (card.floorName || '') + ' > ' + card.hallName,
                floorId: card.floorId
            }));
    }

    handleImportRTSelect(e) { this._importRT = e.currentTarget.dataset.value; }
    handleImportHallSelect(e) {
        this._importHallId = e.target.value;
        const opt = this.importHallOptions.find(o => o.value === this._importHallId);
        this._importFloorId = opt ? opt.floorId : '';
    }
    handleImportNext() { this._importStep = 'upload'; }
    handleImportBackToSetup() { this._importStep = 'setup'; }

    handleDownloadTemplate() {
        const isSpace = this._importRT === 'Inventory_Space';
        const headers = isSpace
            ? ['Id','Inventory ID*','Inventory Status*','Other Inventory Name','Space Type*','Usage Type','Cage Reference','Hall Reference','Average Power per Cab (kVA)*','Contracted Power (kVA)*','Subscribed/Contracted Power (kVA)','CabE Size','SLA Temperature Min','SLA Temperature Max','SLA Humidity Min','SLA Humidity Max','SLA Availability','CabE Count','TH Sensor ID','TH Sensor Group ID','Remarks']
            : ['Id','Inventory ID*','Inventory Status*','Other Inventory Name','Breaker Type*','Voltage Rating (V)*','Current Rating (A)*','Remarks'];
        // 'Id' — leave blank to create a new record; paste an existing record's Salesforce ID
        // (e.g. from an export) to update that record instead.
        // 'Inventory ID*' is the record's Name — shown filled in below as an example; leave
        // it blank instead to auto-generate a name per the naming convention.
        // 'Cage Reference' / 'Hall Reference' — the exact Inventory Name of the parent Cage or
        // Hall record on this floor (only one applies, matching Usage Type); validated on import.
        // CabE Size must be one of the actual picklist values (0.125, 0.25, 0.5, 3U, Full), not a rack-unit count.
        // SLA Temperature/Humidity fields expect a plain number (e.g. 18), not a percentage or unit.
        const example = isSpace
            ? ['','TYO1-04-DH01-S01','Available','CUST-REF-01','Cabinet','Private Cage','TYO1-04-DH01-C01','','5','5','4.5','Full','18','25','40','60','99.99','1','TH-0001','THG-01','Sample row for reference only']
            : ['','','Available','','3 Phase','415V','32A',''];
        const csv = headers.join(',') + '\n' + example.join(',') + '\n';
        const url = 'data:text/csv;charset=utf-8,' + encodeURIComponent(csv);
        const link = document.createElement('a');
        link.setAttribute('href', url);
        // Filename carries the target hall + record type (both required before this
        // button is enabled — see importSetupIncomplete) so downloading templates for
        // multiple halls doesn't produce identically-named files.
        const hallCard = (this._cards || []).find(c => c.hallId === this._importHallId);
        const safeHallName = (hallCard && hallCard.hallName ? hallCard.hallName : 'Hall')
            .replace(/[^A-Za-z0-9_-]/g, '_');
        const recordTypeLabel = isSpace ? 'Space' : 'Breaker';
        link.setAttribute('download', `${safeHallName}_${recordTypeLabel}_import.csv`);
        link.click();
    }

    // Validation
    _importValidationErrors = [];
    _invalidCellsByRow = {}; // 0-based row index -> Set of header keys with an invalid/missing value
    @track _unrecognizedHeaders = [];
    get hasImportValidationErrors() { return this._importValidationErrors.length > 0; }
    get importConfirmSubmitDisabled() { return this._importLoading || this.hasImportValidationErrors; }
    get hasUnrecognizedHeaders() { return this._unrecognizedHeaders.length > 0; }
    get unrecognizedHeadersText() {
        return this._unrecognizedHeaders.length + ' unrecognized column(s) will be ignored: '
            + this._unrecognizedHeaders.join(', ');
    }
    get importValidationBlockedTitle() {
        return this.hasImportValidationErrors
            ? 'Fix the validation errors above before importing.' : '';
    }
    get importValidationErrors() { return this._importValidationErrors; }
    get dropZoneCls() {
        return 'dim-drop-zone' + (this._dragOver ? ' dim-drop-zone-active' : '');
    }
    get importConfirmMsg() {
        const s = this._importStats;
        const ctx = ' as ' + this.importRTLabel + ' in ' + this.importHallLabel + '.';
        if (!s.hasIdCol || s.creates === s.total) {
            return 'All ' + s.total + ' row(s) will be created' + ctx;
        }
        if (s.creates > 0 && s.updates > 0) {
            return s.updates + ' record(s) will be updated and '
                + s.creates + ' new record(s) will be created' + ctx;
        }
        return s.updates + ' record(s) will be updated' + ctx;
    }
    get importIsWarning() {
        const s = this._importStats;
        return !s.hasIdCol || s.creates === s.total;
    }
    get importNoticeCls() {
        return 'dim-import-notice'
            + (this.importIsWarning ? ' dim-import-notice-warn' : ' dim-import-notice-info');
    }
    get importNoticeIcon() {
        return this.importIsWarning ? 'utility:warning' : 'utility:info';
    }
    get importResultInserted() { return this._importResult.inserted || 0; }
    get importResultUpdated()  { return this._importResult.updated  || 0; }
    get importResultErrors()   { return this._importResult.errors   || []; }
    get hasImportErrors()      { return (this._importResult.errors || []).length > 0; }
    get importResultSummary() {
        const r = this._importResult;
        const parts = [];
        if (r.inserted) parts.push(r.inserted + ' created');
        if (r.updated)  parts.push(r.updated  + ' updated');
        return parts.join(', ') || 'No changes';
    }

    // Odoo sync status (checked on demand — the sync itself runs async after this
    // screen already reports the Salesforce insert as successful).
    @track _syncStatus = null;
    @track _syncStatusLoading = false;

    get canCheckSyncStatus() { return this._recentIds.length > 0 && !this._syncStatusLoading; }
    get hasSyncStatus() { return !!this._syncStatus; }
    get syncStatusText() {
        const s = this._syncStatus;
        if (!s) return '';
        const parts = [];
        if (s.synced)  parts.push(s.synced + ' synced to Odoo');
        if (s.pending) parts.push(s.pending + ' still processing');
        if (s.failed)  parts.push(s.failed + ' failed');
        return parts.join(', ') || 'No records to check.';
    }
    get syncStatusCls() {
        const s = this._syncStatus;
        return 'dim-import-notice' + (s && s.failed ? ' dim-import-notice-warn' : ' dim-import-notice-info');
    }

    async handleCheckSyncStatus() {
        if (!this._recentIds.length) return;
        this._syncStatusLoading = true;
        try {
            this._syncStatus = await getOdooSyncStatus({ inventoryIds: this._recentIds });
        } catch (e) {
            this._toast('Error', this._err(e), 'error');
        } finally {
            this._syncStatusLoading = false;
        }
    }

    get importPreviewHeaders() {
        if (!this._importRows.length) return [];
        return Object.keys(this._importRows[0]).slice(0, 8)
            .map((h, i) => ({ key: i, label: h }));
    }
    get importPreviewRows() {
        return this._importRows.slice(0, 5).map((r, i) => {
            const invalidKeys = this._invalidCellsByRow[i];
            return {
                key: i,
                cells: Object.keys(r).slice(0, 8).map((h, j) => ({
                    key: j,
                    val: r[h] || '\u2014',
                    cls: 'dim-preview-cell' + (invalidKeys && invalidKeys.has(h) ? ' dim-preview-cell-invalid' : '')
                }))
            };
        });
    }
    get hasMoreImportRows()   { return this._importRows.length > 5; }
    get importRemainingCount() { return this._importRows.length - 5; }

    /* ════════════════════════════════════════════════════════════
     *  DATA LOADING
     * ════════════════════════════════════════════════════════ */

    async _loadSites() {
        this.sitesLoading = true;
        try {
            this.sites = await getSites();
            this._loadSiteSummaries();
        } catch (e) {
            this._toast('Error loading sites', this._err(e), 'error');
        } finally { this.sitesLoading = false; }
    }

    async _loadSiteSummaries() {
        try {
            const allSummaries = await getAllSiteSummaries();
            this._siteSummaries = { ...allSummaries };
        } catch (_e) {
            // Fallback: individual calls if bulk fails
            const promises = this.sites.map(s =>
                getInventorySummary({ siteId: s.Id })
                    .then(sum => ({ id: s.Id, sum }))
                    .catch(() => ({ id: s.Id, sum: {} }))
            );
            const results = await Promise.all(promises);
            const map = {};
            results.forEach(r => { map[r.id] = r.sum; });
            this._siteSummaries = { ...map };
        }
    }

    async _loadDash() {
        if (!this.selectedSiteId) return;
        this.dashLoading = true;
        try {
            const [cards, sum, typeBreakdown] = await Promise.all([
                getFloorHallSummary({ siteId: this.selectedSiteId }),
                getInventorySummary({ siteId: this.selectedSiteId }),
                getAvailableByType({ siteId: this.selectedSiteId })
            ]);
            this._cards  = cards;
            this.summary = sum;
            this._availByType = typeBreakdown;
        } catch (e) {
            this._toast('Error loading dashboard', this._err(e), 'error');
        } finally { this.dashLoading = false; }
    }

    async _loadDetail(hallId) {
        this.detailLoading = true;
        this._detailStatus = 'All';
        this._detailSearch = '';
        this._selectedIds  = [];
        this._openSections = new Set();
        try {
            this._detailRecords = await getInventoryByHall({ dataHallId: hallId });
        } catch (e) {
            this._toast('Error loading inventory', this._err(e), 'error');
        } finally { this.detailLoading = false; }
    }

    async _loadFloors() {
        if (!this.selectedSiteId) return;
        try { this.floors = await getFloorsBySite({ siteId: this.selectedSiteId }); }
        catch (_) { /* silent */ }
    }

    async _loadAssignments() {
        // CHANGE 2026-08-24 (search): a debounce armed just before a site change
        // or view toggle would otherwise fire afterwards and repopulate the rows
        // from a search the user had already navigated away from.
        clearTimeout(this._asgnSearchTimer);
        this._assignmentsLoading = true;
        this._openAssgnSections = new Set();
        this._asgnStatusFilter = 'All';
        this._asgnFulfillmentFilter = 'All';
        this._asgnSearch = '';
        this._asgnSearchApplied = '';
        const token = ++this._demandReqToken;
        try {
            const promises = [
                getAssignmentDemand({
                    siteId: this.selectedSiteId || null,
                    stage: this._asgnStatusFilter,
                    searchTerm: ''
                }),
                getAssignmentDemandMeta({
                    siteId: this.selectedSiteId || null,
                    stage: this._asgnStatusFilter,
                    searchTerm: ''
                })
            ];
            if (this.selectedSiteId) {
                promises.push(getAvailableByType({ siteId: this.selectedSiteId }));
            }
            const results = await Promise.all(promises);
            if (token !== this._demandReqToken) return;   // a newer request won
            this._assignmentRecords = results[0];
            this._asgnMeta = results[1] || {};
            if (results[2]) this._availByType = results[2];
        } catch (e) {
            if (token !== this._demandReqToken) return;
            this._toast('Error loading assignments', this._err(e), 'error');
        } finally {
            if (token === this._demandReqToken) this._assignmentsLoading = false;
        }
    }

    // Stage filtering lives in SOQL, so switching a chip is a re-query. Only the
    // demand rows change — the supply/availability numbers are stage-independent.
    async _reloadAssignmentDemand() {
        const token = ++this._demandReqToken;
        this._assignmentsLoading = true;
        try {
            const args = {
                siteId: this.selectedSiteId || null,
                stage: this._asgnStatusFilter,
                // CHANGE 2026-08-24 (search): switching a chip mid-search
                // re-queries with both, so the chip narrows the search result
                // rather than replacing it.
                searchTerm: this._asgnSearchApplied
            };
            const [rows, meta] = await Promise.all([
                getAssignmentDemand(args),
                getAssignmentDemandMeta(args)
            ]);
            if (token !== this._demandReqToken) return;
            this._assignmentRecords = rows;
            this._asgnMeta = meta || {};
            this._openAssgnSections = new Set();
        } catch (e) {
            if (token !== this._demandReqToken) return;
            // CHANGE 2026-08-24 (search): clear the rows on failure. Leaving the
            // previous result up under an active search term presented
            // non-matching quotes as matches, with the count badge agreeing.
            this._assignmentRecords = [];
            this._asgnMeta = {};
            this._toast('Error loading assignments', this._err(e), 'error');
        } finally {
            if (token === this._demandReqToken) this._assignmentsLoading = false;
        }
    }

    /* ════════════════════════════════════════════════════════════
     *  HANDLERS — Site Selection & Country Filter
     * ════════════════════════════════════════════════════════ */

    handleSiteCard(e) {
        const id = e.currentTarget.dataset.id;
        if (id === this.selectedSiteId) {
            this.selectedSiteId    = null;
            this._selectedKey      = null;
            this._detailRecords    = [];
            this._selectedIds      = [];
            this._bottomMode       = 'detail';
            this._viewMode         = 'inventory';
            this._assignmentRecords = [];
            this._availByType      = {};
            return;
        }
        this.selectedSiteId   = id;
        this._selectedKey     = null;
        this._detailRecords   = [];
        this._selectedIds     = [];
        this._bottomMode      = 'detail';
        this._viewMode        = 'inventory';
        this._assignmentRecords = [];
        this._loadDash();
        this._loadFloors();
    }

    handleDeselectSite() {
        this.selectedSiteId    = null;
        this._selectedKey      = null;
        this._detailRecords    = [];
        this._selectedIds      = [];
        this._bottomMode       = 'detail';
        this._viewMode         = 'inventory';
        this._assignmentRecords = [];
        this._availByType      = {};
    }

    handleDeselectCard() {
        this._selectedKey   = null;
        this._detailRecords = [];
        this._selectedIds   = [];
        this._bottomMode    = 'detail';
    }

    handleCountry(e) {
        this._countryFilter = e.currentTarget.dataset.value;
    }

    handleViewToggle(e) {
        const view = e.currentTarget.dataset.view;
        if (view === this._viewMode) return;
        this._viewMode = view;
        if (view === 'assignments' && !this._assignmentRecords.length) {
            this._loadAssignments();
        }
    }

    handleAssgnToggle(e) {
        const key = e.currentTarget.dataset.key;
        const next = new Set(this._openAssgnSections);
        if (next.has(key)) next.delete(key); else next.add(key);
        this._openAssgnSections = next;
    }

    handleQuoteNav(e) {
        e.stopPropagation();
        const quoteId = e.currentTarget.dataset.id;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: quoteId,
                objectApiName: 'Quote',
                actionName: 'view'
            }
        });
    }

    handleAsgnStatusPill(e) {
        const stage = e.currentTarget.dataset.value;
        if (stage === this._asgnStatusFilter) return;
        this._asgnStatusFilter = stage;
        this._reloadAssignmentDemand();
    }

    handleAsgnFulfillmentFilter(e) {
        const next = e.target.value || 'All';
        if (next === this._asgnFulfillmentFilter) return;
        this._asgnFulfillmentFilter = next;
    }

    // CHANGE 2026-08-24 (search): was a 200ms debounce that only set _asgnSearch
    // and let the getter filter loaded rows:
    //     this._asgnSearchTimer = setTimeout(() => { this._asgnSearch = v; }, 200);
    // Now it queries the org, so the debounce is longer and short terms are held
    // back. 1-2 characters intentionally do nothing at all — they neither query
    // nor filter, since a two-letter LIKE over every quote is not a search.
    handleAsgnSearch(e) {
        clearTimeout(this._asgnSearchTimer);
        const v = e.target.value;
        this._asgnSearchTimer = setTimeout(() => {
            this._asgnSearch = v;
            const term = (v || '').trim();
            const next = term.length >= MIN_ASGN_SEARCH ? term : '';
            // Only two transitions are worth a round trip: a term becoming long
            // enough, and a term being abandoned. Everything else is noise.
            if (next !== this._asgnSearchApplied) {
                this._asgnSearchApplied = next;
                this._reloadAssignmentDemand();
            }
        }, 350);
    }

    clearAsgnSearch() {
        clearTimeout(this._asgnSearchTimer);
        this._asgnSearch = '';
        // CHANGE 2026-08-24 (search): clearing has to put the unsearched rows
        // back, which is now a query rather than a getter re-run.
        if (this._asgnSearchApplied) {
            this._asgnSearchApplied = '';
            this._reloadAssignmentDemand();
        }
    }

    /* ════════════════════════════════════════════════════════════
     *  HANDLERS — Card Selection & Detail
     * ════════════════════════════════════════════════════════ */

    handleCardSearch(e) {
        clearTimeout(this._cardSearchTimer);
        const v = e.target.value;
        this._cardSearchTimer = setTimeout(() => { this._cardSearch = v; }, 200);
    }

    clearCardSearch() {
        this._cardSearch = '';
    }

    handleCard(e) {
        const key = e.currentTarget.dataset.key;
        if (this._selectedKey === key && this._bottomMode === 'detail') {
            this._selectedKey   = null;
            this._detailRecords = [];
            this._selectedIds   = [];
        } else {
            this._selectedKey = key;
            this._bottomMode  = 'detail';
            this._selectedIds = [];
            this._loadDetail(key);
        }
    }

    handlePill(e) {
        this._detailStatus = e.currentTarget.dataset.value;
        this._showRecentOnly = false; // clear recent filter when switching status
    }

    // Recently created/imported filter
    _recentIds = [];
    _showRecentOnly = false;

    handleShowRecent() { this._showRecentOnly = true; }
    handleDismissRecent() { this._showRecentOnly = false; this._recentIds = []; }

    get hasRecentIds() { return this._recentIds.length > 0; }
    get recentPillLabel() { return 'Show Created (' + this._recentIds.length + ')'; }
    get recentPillClass() { return 'dim-pill' + (this._showRecentOnly ? ' dim-pill-on' : ''); }

    handleSearch(e) {
        clearTimeout(this._detailTimer);
        const v = e.target.value;
        this._detailTimer = setTimeout(() => { this._detailSearch = v; }, 300);
    }

    handleNav(e) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: e.currentTarget.dataset.id,
                objectApiName: 'Inventory__c',
                actionName: 'view'
            }
        });
    }

    /* ════════════════════════════════════════════════════════════
     *  HANDLERS — Checkbox Selection
     * ════════════════════════════════════════════════════════ */

    handleSelectAll(e) {
        if (e.target.checked) {
            this._selectedIds = [...this._filteredIds()];
        } else {
            this._selectedIds = [];
        }
    }

    handleRowCheck(e) {
        const id = e.currentTarget.dataset.id;
        if (e.target.checked) {
            this._selectedIds = [...this._selectedIds, id];
        } else {
            this._selectedIds = this._selectedIds.filter(x => x !== id);
        }
    }

    /* ════════════════════════════════════════════════════════════
     *  HANDLERS — Bulk Actions
     * ════════════════════════════════════════════════════════ */

    async handleBulkRelease() {
        if (!this._selectedIds.length) return;
        const releasable = this._detailRecords
            .filter(r => this._selectedIds.includes(r.Id) && r.Status__c === 'Reserved');
        const skipped = this._selectedIds.length - releasable.length;
        if (!releasable.length) {
            this._toast('Cannot Release',
                'Only Reserved inventory can be released.', 'warning');
            return;
        }
        if (skipped > 0) {
            this._toast('Skipped',
                `${skipped} non-Reserved record(s) skipped.`, 'warning');
        }
        this.creating = true;
        try {
            const ids = releasable.map(r => r.Id);
            await bulkReleaseInventory({ inventoryIds: ids });
            this._toast('Released',
                `${ids.length} record(s) released.`, 'success');
            this._selectedIds = [];
            this._loadDash();
            this._loadSiteSummaries();
            if (this._selectedKey) this._loadDetail(this._selectedKey);
        } catch (e) {
            this._toast('Error', this._err(e), 'error');
        } finally { this.creating = false; }
    }

    /* ════════════════════════════════════════════════════════════
     *  HANDLERS — Decommission
     * ════════════════════════════════════════════════════════ */

    async handleBulkDecommission() {
        const ids = this._selectedIds;
        if (!ids.length) return;
        // eslint-disable-next-line no-alert
        if (!confirm(`Archive ${ids.length} selected record(s)? This will decommission them in Odoo and cannot be undone.`)) return;
        this.creating = true;
        let succeeded = 0;
        let failed = 0;
        try {
            for (const id of ids) {
                try {
                    await decommissionInventory({ inventoryId: id });
                    succeeded++;
                } catch (err) {
                    failed++;
                }
            }
            if (succeeded) this._toast('Archived', `${succeeded} record(s) archived.`, 'success');
            if (failed)    this._toast('Partial Error', `${failed} record(s) failed to archive.`, 'warning');
            this._selectedIds = [];
            this._loadDash();
            this._loadSiteSummaries();
            if (this._selectedKey) this._loadDetail(this._selectedKey);
        } finally { this.creating = false; }
    }

    async handleDecommission(e) {
        const id = e.currentTarget.dataset.id;
        const name = e.currentTarget.dataset.name;
        // eslint-disable-next-line no-alert
        if (!confirm(`Decommission "${name}"? This will archive it in Odoo and cannot be undone.`)) return;
        this.creating = true;
        try {
            await decommissionInventory({ inventoryId: id });
            this._toast('Decommissioned', `"${name}" has been decommissioned.`, 'success');
            this._loadDash();
            this._loadSiteSummaries();
            if (this._selectedKey) this._loadDetail(this._selectedKey);
        } catch (err) {
            this._toast('Error', this._err(err), 'error');
        } finally { this.creating = false; }
    }

    /* ════════════════════════════════════════════════════════════
     *  HANDLERS — Inline Edit
     * ════════════════════════════════════════════════════════ */

    async handleInlineSave(e) {
        const recordId = e.currentTarget.dataset.id;
        const field = e.currentTarget.dataset.field;
        const value = e.target.value;
        try {
            await updateInventoryField({ recordId, fieldName: field, fieldValue: value || '' });
            this._detailRecords = this._detailRecords.map(r =>
                r.Id === recordId ? { ...r, [field]: value } : r
            );
            if (field === 'Status__c') {
                this._loadDash();
                this._loadSiteSummaries();
            }
        } catch (err) {
            this._toast('Error', this._err(err), 'error');
            if (this._selectedKey) this._loadDetail(this._selectedKey);
        }
    }

    /* ════════════════════════════════════════════════════════════
     *  HANDLERS — Site Picker (from list view buttons)
     * ════════════════════════════════════════════════════════ */

    get sitePickerOptions() {
        return this.sites.map(s => {
            const code = s.Site_Code__c || '';
            const name = s.Name || '';
            const label = code && code !== name ? `${code} — ${name}` : name;
            return { label, value: s.Id, selected: this._sitePickerValue === s.Id };
        });
    }

    get sitePickerReady() {
        return !!this._sitePickerValue;
    }

    get sitePickerNotReady() {
        return !this._sitePickerValue;
    }

    handleSitePickerChange(e) {
        this._sitePickerValue = e.target.value;
    }

    async handleSitePickerContinue() {
        if (!this._sitePickerValue) return;
        this.selectedSiteId = this._sitePickerValue;
        this._showSitePicker = false;
        const action = this._pendingAction;
        this._pendingAction = '';
        // Load site data
        await this._loadDash();
        this._loadFloors();
        // Open the requested modal
        if (action === 'export') {
            this.handleOpenExport();
        } else if (action === 'import') {
            this.handleOpenImport();
        }
    }

    handleSitePickerClose() {
        this._showSitePicker = false;
        this._pendingAction = '';
        this._actionHandled = false;
    }

    /* ════════════════════════════════════════════════════════════
     *  HANDLERS — Export / Import
     * ════════════════════════════════════════════════════════ */

    handleOpenExport() {
        // Hall/Status/Type/Country filters intentionally persist across reopens within
        // the session — re-exporting the same slice repeatedly (e.g. while testing a
        // hall/type) shouldn't require re-picking the same filters every time.
        this._showExportModal = true;
        this._exportGlobal = !this.selectedSiteId; // global if no site selected
        this._refreshExportCount();
    }
    get isExportGlobal() { return this._exportGlobal; }
    _exportGlobal = false;
    _exportCountries = [];

    // Debounced live count of records matching the current export filters, so the
    // user knows roughly what they're about to download before clicking Export.
    async _refreshExportCount() {
        clearTimeout(this._exportCountTimer);
        this._exportCountLoading = true;
        this._exportCountTimer = setTimeout(async () => {
            try {
                this._exportCount = await getExportCount({
                    siteId:           this._exportGlobal ? null : this.selectedSiteId,
                    dataHallId:       this._exportGlobal ? null : (this._exportHallFilter || null),
                    statusFilter:     this._exportStatusFilter,
                    recordTypeFilter: this._exportTypeFilter,
                    countries:        this._exportGlobal ? (this._exportCountries.length > 0 ? this._exportCountries : null) : null
                });
            } catch (e) {
                this._exportCount = null;
            } finally {
                this._exportCountLoading = false;
            }
        }, 300);
    }
    get exportCountText() {
        if (this._exportCountLoading) return 'Counting matching records…';
        if (this._exportCount == null) return '';
        return this._exportCount + (this._exportCount === 1 ? ' record matches' : ' records match') + ' these filters.';
    }

    handleExportCountryToggle(e) {
        const country = e.currentTarget.dataset.value;
        if (country === 'All') {
            this._exportCountries = this._exportCountries.length === this.countryList.length
                ? [] : [...this.countryList];
        } else {
            const next = [...this._exportCountries];
            const idx = next.indexOf(country);
            if (idx >= 0) next.splice(idx, 1); else next.push(country);
            this._exportCountries = next;
        }
        this._refreshExportCount();
    }
    get exportCountryPills() {
        const selected = new Set(this._exportCountries);
        const allSelected = selected.size === this.countryList.length;
        const pills = [{ value: 'All', label: 'All', cls: 'dim-pill' + (allSelected ? ' dim-pill-on' : '') }];
        for (const c of this.countryList) {
            pills.push({ value: c, label: c, cls: 'dim-pill' + (selected.has(c) ? ' dim-pill-on' : '') });
        }
        return pills;
    }
    get countryList() {
        return [...new Set(this.sites.map(s => s.Country__c).filter(Boolean))].sort();
    }
    handleCloseExport() { this._showExportModal = false; this._actionHandled = false; }
    handleExpHall(e)    { this._exportHallFilter   = e.target.value; this._refreshExportCount(); }
    handleExpStatus(e)  { this._exportStatusFilter = e.target.value; this._refreshExportCount(); }
    handleExpType(e)    { this._exportTypeFilter   = e.target.value; this._refreshExportCount(); }
    handleModalStop(e)  { e.stopPropagation(); }

    async handleExportDownload() {
        this._exportLoading = true;
        try {
            const records = await getExportData({
                siteId:           this._exportGlobal ? null : this.selectedSiteId,
                dataHallId:       this._exportGlobal ? null : (this._exportHallFilter || null),
                statusFilter:     this._exportStatusFilter,
                recordTypeFilter: this._exportTypeFilter,
                countries:        this._exportGlobal ? (this._exportCountries.length > 0 ? this._exportCountries : null) : null
            });
            if (!records.length) {
                this._toast('No Data',
                    'No records match the selected filters.', 'warning');
                return;
            }
            // Only include the columns relevant to the selected type — Space-only
            // fields for a Space export, Breaker-only fields (in Import-matching order)
            // for a Breaker export.
            const headers = this._exportTypeFilter === 'Inventory_Space'
                ? [...EXPORT_COMMON_HEADERS, ...EXPORT_SPACE_HEADERS]
                : this._exportTypeFilter === 'Inventory_Breaker'
                    ? EXPORT_BREAKER_FULL_HEADERS
                    : [...EXPORT_COMMON_HEADERS, ...EXPORT_SPACE_HEADERS, ...EXPORT_BREAKER_HEADERS];
            const lines = [headers.join(',')];
            records.forEach(r => {
                lines.push(
                    headers.map(h =>
                        this._csvEscape(this._exportVal(r, h))
                    ).join(',')
                );
            });
            const blob = new Blob([lines.join('\n')],
                { type: 'application/octet-stream' });
            const url = URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url;
            a.download = (this._exportGlobal
                ? (this._exportCountries.length > 0 ? this._exportCountries.join('_') : 'global')
                : this.selectedSiteCode) + '_inventory_export.csv';
            document.body.appendChild(a);
            a.click();
            document.body.removeChild(a);
            URL.revokeObjectURL(url);
            this._toast('Exported',
                records.length + ' records exported.', 'success');
            this._showExportModal = false;
        } catch (e) {
            this._toast('Export Error', this._err(e), 'error');
        } finally { this._exportLoading = false; }
    }

    handleOpenImport() {
        this._showImportModal = true;
        this._importStep     = 'setup';
        this._importRT       = '';
        this._importHallId   = this._selectedHallId || '';
        this._importFloorId  = this._selectedFloorId || '';
        this._importFileName = '';
        this._importRows     = [];
        this._importStats    = {};
        this._importResult   = {};
        this._importValidationErrors = [];
        this._invalidCellsByRow = {};
        this._unrecognizedHeaders = [];
        this._dragOver       = false;
        this._syncStatus     = null;
        this._recentIds      = [];
    }
    handleCloseImport() { this._showImportModal = false; this._actionHandled = false; }

    handleDragOver(e) {
        e.preventDefault();
        e.stopPropagation();
        this._dragOver = true;
    }
    handleDragLeave(e) {
        e.preventDefault();
        e.stopPropagation();
        this._dragOver = false;
    }
    handleDrop(e) {
        e.preventDefault();
        e.stopPropagation();
        this._dragOver = false;
        const file = e.dataTransfer && e.dataTransfer.files
            && e.dataTransfer.files[0];
        if (file) this._processImportFile(file);
    }
    handleFileSelect(e) {
        const file = e.target.files && e.target.files[0];
        if (file) this._processImportFile(file);
    }

    _processImportFile(file) {
        if (!file.name.toLowerCase().endsWith('.csv')) {
            this._toast('Invalid File',
                'Please upload a CSV file.', 'error');
            return;
        }
        this._importFileName = file.name;
        const reader = new FileReader();
        reader.onload = (evt) => {
            let text = evt.target.result;
            if (text.charCodeAt(0) === 0xFEFF) text = text.slice(1);
            const parsed = this._parseCsv(text);
            if (parsed.length < 2) {
                this._toast('Empty File',
                    'The CSV file has no data rows.', 'error');
                return;
            }
            const headers = parsed[0];
            const rows = [];
            for (let i = 1; i < parsed.length; i++) {
                const row = parsed[i];
                if (row.every(cell => !cell)) continue;
                const map = {};
                headers.forEach((h, j) => { map[h] = row[j] || ''; });
                rows.push(map);
            }
            if (!rows.length) {
                this._toast('Empty File',
                    'The CSV file has no data rows.', 'error');
                return;
            }
            this._importRows = rows;
            // Flag headers the importer won't recognize (e.g. leftover export-style
            // names like 'Breaker_Type') — those columns' values are otherwise
            // silently dropped with no indication why a row failed validation.
            this._unrecognizedHeaders = headers
                .map(h => h.replace('*', ''))
                .filter(h => h && !RECOGNIZED_IMPORT_LABELS.has(h));
            const hasIdCol = headers.includes('Id');
            const creates  = rows.filter(r => !r.Id || !r.Id.trim()).length;
            const updates  = rows.length - creates;
            this._importStats = {
                creates, updates,
                total: rows.length, hasIdCol
            };
            // Validate immediately so errors are visible before the user ever clicks
            // Import — a blocked click should never look like a silent no-op.
            this._validateImportRows();
            this._importStep = 'confirm';
        };
        reader.readAsText(file);
    }

    handleImportBack() {
        this._importStep     = 'upload';
        this._importFileName = '';
        this._importRows     = [];
        this._importValidationErrors = [];
        this._invalidCellsByRow = {};
        this._unrecognizedHeaders = [];
    }

    // Validate required fields client-side before sending to Apex
    _validateImportRows() {
        const isSpace = this._importRT === 'Inventory_Space';
        const required = isSpace
            ? ['Inventory Status', 'Space Type', 'Average Power per Cab (kVA)', 'Contracted Power (kVA)']
            : ['Inventory Status', 'Breaker Type', 'Voltage Rating (V)', 'Current Rating (A)'];
        const errors = [];
        const invalidCellsByRow = {};
        this._importRows.forEach((row, i) => {
            // An 'Id' column with a value means this row updates an existing record —
            // it may legitimately touch just one field, so required-field checks don't apply.
            const idKey = Object.keys(row).find(k => k === 'Id');
            const isUpdate = idKey && String(row[idKey] || '').trim() !== '';
            if (isUpdate) return;

            const missingLabels = [];
            const missingKeys = new Set();
            required.forEach(f => {
                // Check both exact and asterisk-stripped versions
                const key = Object.keys(row).find(k => k.replace('*','') === f || k === f);
                const blank = !key || !row[key] || String(row[key]).trim() === '';
                if (blank) {
                    missingLabels.push(f);
                    if (key) missingKeys.add(key);
                }
            });
            if (missingLabels.length) {
                errors.push(`Row ${i + 1}: Missing ${missingLabels.join(', ')}`);
                invalidCellsByRow[i] = missingKeys;
            }
        });
        this._importValidationErrors = errors;
        this._invalidCellsByRow = invalidCellsByRow;
        return errors.length === 0;
    }

    async handleImportConfirmBulk() {
        if (!this._validateImportRows()) return;

        this._importLoading = true;
        try {
            // Strip asterisks from header keys (template marks required with *)
            const cleanRows = this._importRows.map(row => {
                const clean = {};
                for (const k of Object.keys(row)) {
                    clean[k.replace('*', '')] = row[k];
                }
                return clean;
            });

            const result = await importInventoryBulk({
                recordTypeName: this._importRT,
                siteId:         this.selectedSiteId,
                floorId:        this._importFloorId,
                dataHallId:     this._importHallId,
                rowsJson:       JSON.stringify(cleanRows)
            });
            this._importResult = result;
            this._importStep = 'result';

            // Store created IDs for "Show Created" pill
            if (result.createdIds && result.createdIds.length) {
                this._recentIds = result.createdIds;
            }

            this._loadDash();
            this._loadSiteSummaries();
            if (this._selectedKey) this._loadDetail(this._selectedKey);
        } catch (e) {
            this._toast('Import Error', this._err(e), 'error');
        } finally { this._importLoading = false; }
    }

    get canDownloadImportResults() { return this._importRows.length > 0; }

    // Downloads the original uploaded rows with an outcome column appended per row —
    // so a failed/partial import can be diagnosed directly in the same spreadsheet
    // instead of manually cross-referencing row numbers against a flat error list.
    handleDownloadResults() {
        const rows = this._importRows;
        if (!rows.length) return;
        const resultByRow = {};
        (this._importResult.rowResults || []).forEach(r => { resultByRow[r.row] = r; });

        const headers = Object.keys(rows[0]);
        const outHeaders = [...headers, 'Import Status', 'Import Message', 'Salesforce ID'];
        const lines = [outHeaders.map(h => this._csvEscape(h)).join(',')];
        rows.forEach((row, i) => {
            const res = resultByRow[i + 1] || {};
            const cells = headers.map(h => this._csvEscape(row[h]));
            cells.push(this._csvEscape(res.status || 'unknown'));
            cells.push(this._csvEscape(res.message || ''));
            cells.push(this._csvEscape(res.id || ''));
            lines.push(cells.join(','));
        });

        const blob = new Blob([lines.join('\n') + '\n'], { type: 'application/octet-stream' });
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = 'import_results.csv';
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        URL.revokeObjectURL(url);
    }

    /* ════════════════════════════════════════════════════════════
     *  HANDLERS — Add Floor
     * ════════════════════════════════════════════════════════ */

    handleAddFloor() {
        this._bottomMode    = 'create-floor';
        this._selectedKey   = null;
        this._selectedIds   = [];
        this._newFloorNum   = '';
        this._hallCounter   = 1;
        this._newFloorHalls = [{ key: 0 }];
    }

    handleCloseFloor() {
        this._bottomMode = 'detail';
    }

    handleFloorNum(e) {
        this._newFloorNum = e.target.value;
    }

    handleAddHall() {
        this._newFloorHalls = [...this._newFloorHalls, { key: this._hallCounter++ }];
    }

    handleRemoveHall(e) {
        const key = parseInt(e.currentTarget.dataset.key, 10);
        this._newFloorHalls = this._newFloorHalls.filter(h => h.key !== key);
    }

    async handleFloorSubmit() {
        if (this.floorCreateOff) return;
        this.creating = true;
        const sc = this.selectedSiteCode;
        const fn = this._newFloorNum;
        const floorName = `${sc}-${fn}`;
        const hallNames = this._newFloorHalls.map((_, i) => `${sc}-${fn}-${i + 1}`);

        try {
            await createFloor({
                siteId: this.selectedSiteId,
                floorName: floorName,
                hallNames: hallNames
            });
            this._toast('Created',
                `Floor ${floorName} created with ${hallNames.length} hall(s).`,
                'success');
            this._bottomMode = 'detail';
            this._loadDash();
            this._loadFloors();
            this._loadSiteSummaries();
        } catch (e) {
            this._toast('Error creating floor', this._err(e), 'error');
        } finally { this.creating = false; }
    }

    /* ════════════════════════════════════════════════════════════
     *  HANDLERS — Add Hall to Existing Floor
     * ════════════════════════════════════════════════════════ */

    async handleAddHallFromCard(e) {
        e.stopPropagation();
        if (this.creating) return;
        const floorId = e.currentTarget.dataset.floorId;
        if (!floorId) return;
        this.creating = true;
        try {
            const result = await addHallToFloor({
                floorId: floorId,
                siteId:  this.selectedSiteId
            });
            this._toast('Hall Created',
                `${result.name} added.`, 'success');
            this._loadDash();
            this._loadFloors();
            this._loadSiteSummaries();
        } catch (e) {
            this._toast('Error', this._err(e), 'error');
        } finally { this.creating = false; }
    }

    /* ════════════════════════════════════════════════════════════
     *  HANDLERS — Add Inventory (from floor context)
     * ════════════════════════════════════════════════════════ */

    handleAddInv() {
        this._bottomMode = 'type-select';
        this._invType    = '';
        this._invSpaceType = '';
        this._invUsageType = 'Shared';
        this._cageHallRefId = null;
        this._cageHallOptions = [];
    }

    handleTypeSelect(e) {
        const type = e.currentTarget.dataset.type;
        this._invType          = type;
        this._invSpaceType     = type === 'Space' ? '' : '';
        this._bottomMode       = 'create-inv';
        this.createTotalCapKva = undefined;
        this.createPowerKva    = undefined;
        this.createNotes       = '';
        this.createUnitRef     = '';
        this.createBreakerPanel = '';
        this.createCapacityType = 'Power Circuit';
        this._createRow         = '';
        this._createCol         = '';
        this._createUnitNum     = '';
        this._createBreakerName = '';
        // Auto-populate hall number from card context
        this._createHallNumber  = this._hallPart;
        this.createBreakerType  = '';
        this.createVoltageRating = '';
        this.createCurrentRating = '';
        this.createCabESize     = 'Full';
        this.createSLATempMin   = '';
        this.createSLATempMax   = '';
        this.createSLAHumMin    = '';
        this.createSLAHumMax    = '';
        this.createSLAAvail     = '99.99';
        this._createSubPos      = '';
        this.createStatus       = 'Available';
        this.createQty          = 1;
        this.createContractedPower = null;
        this._duplicateWarning  = false;
    }

    handleBackToDetail() {
        this._bottomMode = 'detail';
    }

    handleCloseInv() {
        this._bottomMode = 'detail';
    }

    handleCTC(e) { this.createTotalCapKva  = e.target.value; }
    handleCPK(e) { this.createPowerKva     = e.target.value; }
    handleCN(e)  { this.createNotes        = e.target.value; }
    handleCUR(e) { this.createUnitRef      = e.target.value; }
    handleCBP(e) { this.createBreakerPanel = e.target.value; }
    handleCCT(e) { this.createCapacityType = e.target.value; }
    handleCBT(e) {
        this.createBreakerType = e.target.value;
        this.createVoltageRating = '';
        this.createCurrentRating = '';
        const specs = this._siteSpecs.filter(s => s.type === e.target.value);
        const voltages = [...new Set(specs.map(s => s.voltage))];
        if (voltages.length === 1) {
            this.createVoltageRating = voltages[0];
            const currents = [...new Set(specs.filter(s => s.voltage === voltages[0]).map(s => s.current))];
            if (currents.length === 1) this.createCurrentRating = currents[0];
        }
    }
    handleCVR(e) {
        this.createVoltageRating = e.target.value;
        this.createCurrentRating = '';
        const specs = this._siteSpecs.filter(s =>
            (!this.createBreakerType || s.type === this.createBreakerType) &&
            s.voltage === e.target.value
        );
        const currents = [...new Set(specs.map(s => s.current))];
        if (currents.length === 1) this.createCurrentRating = currents[0];
    }
    handleCCR(e) { this.createCurrentRating = e.target.value; }
    handleCCS(e) { this.createCabESize = e.target.value; }
    handleBreakerName(e) { this._createBreakerName = e.target.value; }
    handleCreateQtyChange(e) { this.createQty = Math.max(1, parseInt(e.target.value, 10) || 1); }
    handleSLATempMin(e) { this.createSLATempMin = e.target.value; }
    handleSLATempMax(e) { this.createSLATempMax = e.target.value; }
    handleSLAHumMin(e) { this.createSLAHumMin = e.target.value; }
    handleSLAHumMax(e) { this.createSLAHumMax = e.target.value; }
    handleSLAAvail(e) { this.createSLAAvail = e.target.value; }
    handleHallNumber(e) {
        this._createHallNumber = e.target.value || '';
    }
    handleSubPos(e) { this._createSubPos = e.target.value; }
    handleCreateStatus(e) { this.createStatus = e.target.value; }
    handleContractedPower(e) { this.createContractedPower = e.target.value; }
    get statusOptions() {
        return ['Available', 'Assigned', 'Reserved', 'Sold', 'Installed', 'ROFR', 'Pending Available', 'Stranded','Decommissioned'].map(s => ({
            label: s, value: s, selected: this.createStatus === s
        }));
    }
    handleUnitNum(e) {
        const raw = (e.target.value || '').replace(/\D/g, '').slice(0, 2);
        this._createUnitNum = raw;
        this._debounceDupCheck();
    }
    handleUnitNumBlur() {
        if (this._createUnitNum && this._createUnitNum.length === 1) {
            this._createUnitNum = this._createUnitNum.padStart(2, '0');
            this._debounceDupCheck();
        }
    }
    handleCST(e) {
        this._invSpaceType = e.target.value;
        this._invUsageType = 'Shared'; // Reset usage type when space type changes
        this._cageHallRefId = null;
        this._cageHallOptions = [];
        // Auto-set unit number: Cage starts from 99 (descending), others from 01
        if (e.target.value === 'Cage') {
            this._createUnitNum = '99';
        } else if (e.target.value === 'Flex Office') {
            this._createUnitNum = '01';
        } else if (e.target.value) {
            this._createUnitNum = '01';
        } else {
            this._createUnitNum = '';
        }
        this._debounceDupCheck();
    }

    handleCreateRow(e) {
        const raw = (e.target.value || '').replace(/\D/g, '').slice(0, 2);
        this._createRow = raw;
        this._debounceDupCheck();
    }
    handleCreateRowBlur() {
        if (this._createRow && this._createRow.length === 1) {
            this._createRow = this._createRow.padStart(2, '0');
            this._debounceDupCheck();
        }
    }
    handleCreateCol(e) {
        const raw = (e.target.value || '').replace(/\D/g, '').slice(0, 2);
        this._createCol = raw;
        this._debounceDupCheck();
    }
    handleCreateColBlur() {
        if (this._createCol && this._createCol.length === 1) {
            this._createCol = this._createCol.padStart(2, '0');
            this._debounceDupCheck();
        }
    }

    _debounceDupCheck() {
        clearTimeout(this._dupCheckTimer);
        this._dupCheckTimer = setTimeout(() => { this._runDupCheck(); }, 400);
    }

    async _runDupCheck() {
        if (!this._createUnitNum) {
            this._duplicateWarning = false;
            return;
        }
        // Flex Office only needs unit number; Cabinet/Cage need row+col too
        if (!this.isFlexOffice && (!this._createRow || !this._createCol)) {
            this._duplicateWarning = false;
            return;
        }
        const name = this.createNamePreview;
        if (!name || name.includes('__')) {
            this._duplicateWarning = false;
            return;
        }
        try {
            this._duplicateWarning = await checkDuplicate({ inventoryName: name });
        } catch (_) {
            this._duplicateWarning = false;
        }
    }

    async handleInvSubmit() {
        // Auto-pad on submit
        if (this._createUnitNum && this._createUnitNum.length === 1) {
            this._createUnitNum = this._createUnitNum.padStart(2, '0');
        }
        if (!this.isFlexOffice) {
            if (this._createRow && this._createRow.length === 1) {
                this._createRow = this._createRow.padStart(2, '0');
            }
            if (this._createCol && this._createCol.length === 1) {
                this._createCol = this._createCol.padStart(2, '0');
            }
        }
        if (this.invCreateOff) return;
        const card = this.selCard;
        if (!card) return;

        const isBreaker = this._invType === 'Breaker';
        if (!isBreaker && !this._invSpaceType) {
            this._toast('Missing field', 'Please select a Space Type.', 'error');
            return;
        }
        // Mandate field validation
        const missing = [];
        if (isBreaker) {
            if (!this.createBreakerType)    missing.push('Breaker Type');
            if (!this.createVoltageRating)  missing.push('Voltage Rating');
            if (!this.createCurrentRating)  missing.push('Current Rating');
        } else {
            if (this._invSpaceType === 'Cabinet') {
                if (!this.createCabESize)    missing.push('CabE Size');
                if (!this.createTotalCapKva) missing.push('Avg Power per Cab (kVA)');
            }
        }
        if (!this.createStatus) missing.push('Status');
        if (missing.length > 0) {
            this._toast('Required fields', missing.join(', ') + ' must be filled.', 'error');
            return;
        }
        this.creating = true;
        try {
            const newId = await createInventoryRecords({
                recordTypeName:   isBreaker ? 'Inventory_Breaker' : 'Inventory_Space',
                siteId:           this.selectedSiteId,
                floorId:          card.floorId || null,
                dataHallId:       card.hallId  || null,
                spaceType:        isBreaker ? null : this._invSpaceType,
                capacityType:     isBreaker ? this.createCapacityType : null,
                powerKva:         this.createPowerKva    || null,
                totalKw:          null,
                totalCapacityKva: isBreaker ? null : (this.createTotalCapKva || null),
                unitRefPrefix:    this.createUnitRef || null,
                breakerPanel:     isBreaker ? (this.createBreakerPanel || null) : null,
                notes:            this.createNotes || null,
                quantity:         this.createQty || 1,
                newFloorName:     null,
                newDataHallName:  null,
                customName:       isBreaker ? (this._createBreakerName || null) : null,
                inventoryRow:     (isBreaker || this.isFlexOffice) ? null : (this._createRow || null),
                inventoryCol:     (isBreaker || this.isFlexOffice) ? null : ((this._createCol || '') + (this._createSubPos || '') || null),
                unitNumber:       isBreaker ? null : (this._createUnitNum || null),
                breakerType:      isBreaker ? (this.createBreakerType || null) : null,
                voltageRating:    isBreaker ? (this.createVoltageRating || null) : null,
                currentRating:    isBreaker ? (this.createCurrentRating || null) : null,
                slaTemperature:   isBreaker ? null : (this.createSLATempMin || null),
                slaTemperatureMax: isBreaker ? null : (this.createSLATempMax || null),
                slaHumidity:      isBreaker ? null : (this.createSLAHumMin || null),
                slaHumidityMax:   isBreaker ? null : (this.createSLAHumMax || null),
                slaAvailability:  isBreaker ? null : (this.createSLAAvail || null),
                cabeSize:         isBreaker ? null : (this.createCabESize || null),
                inventoryStatus:  this.createStatus || 'Available',
                contractedPower:  isBreaker ? null : (this.createContractedPower || null),
                usageType:        (this._invSpaceType === 'Cabinet') ? (this._invUsageType || 'Shared') : null,
                cageReferenceId:  this._cageHallRefId || null
            });
            const qty = this.createQty || 1;
            if (qty === 1) {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Created',
                    message: '{0} created. Click to view record.',
                    messageData: [{ url: `/lightning/r/Inventory__c/${newId}/view`, label: (isBreaker ? this._createBreakerName : this.createNamePreview) }],
                    variant: 'success',
                    mode: 'sticky'
                }));
            } else {
                this._toast('Created', `${qty} inventory records created.`, 'success');
            }
            this._bottomMode = 'detail';
            await this._loadDash();
            this._loadSiteSummaries();
            if (this._selectedKey) await this._loadDetail(this._selectedKey);
        } catch (e) {
            this._toast('Error creating inventory', this._err(e), 'error');
        } finally { this.creating = false; }
    }

    /* ════════════════════════════════════════════════════════════
     *  ENRICHMENT
     * ════════════════════════════════════════════════════════ */

    _enrich(r) {
        const isSp = r.RecordType &&
            r.RecordType.DeveloperName === 'Inventory_Space';
        const st = r.Status__c || '';
        const co = STATUS_COLOR[st] || '#939393';
        const allStatuses = ['Available', 'Pending Available', 'Reserved', 'Assigned', 'Sold', 'Installed', 'ROFR', 'Stranded','Decommissioned'];
        return {
            ...r,
            typeLabel: isSp ? 'Space' : 'Breaker',
            spaceTypeLabel: r.Space_Type__c || '',
            typeDetail: isSp
                ? (r.Space_Type__c || '')
                : [r.Breaker_Type__c, r.Voltage_Rating__c, r.Current_Rating__c].filter(Boolean).join(' / '),
            cabeLabel: r.CabE_Size__c || (r.CabE_Count__c != null ? String(r.CabE_Count__c) : ''),
            powerLabel: this._pwr(r),
            customerLabel: r.Account__r ? r.Account__r.Name
                : (r.Opportunity__r ? r.Opportunity__r.Name : ''),
            unitRef: r.Unit_Reference__c || '',
            contractedLabel: r.Total_IT_Power_kVA__c ? r.Total_IT_Power_kVA__c + ' kVA' : '',
            unitRefLabel: r.Unit_Reference__c || '',
            rowLabel: r.Row__c || '',
            breakerTypeLabel: r.Breaker_Type__c || '',
            voltageLabel: r.Voltage_Rating__c || '',
            currentLabel: r.Current_Rating__c || '',
            breakerPanelLabel: r.Breaker_Panel__c || '',
            breakerSpecLabel: [r.Breaker_Type__c, r.Voltage_Rating__c, r.Current_Rating__c].filter(Boolean).join(' / '),
            slaLabel: [r.SLA_Temperature__c, r.SLA_Humidity__c, r.SLA_Availability__c].filter(Boolean).join(' | '),
            statusCls: 'dim-status dim-st-' + st.toLowerCase().replace(/\s+/g, '-'),
            statusSelCls: 'dim-inline-sel dim-isel-' + st.toLowerCase().replace(/\s+/g, '-'),
            statusOpts: allStatuses.map(s => ({ v: s, l: s, s: s === st })),
            powerVal: r.Total_Capacity_kVA__c || '',
            contractedVal: r.Total_IT_Power_kVA__c || '',
            spaceTypeOpts: ['Cabinet','Cage','Data Hall','Flex Office'].map(s => ({ v: s, l: s, s: s === (r.Space_Type__c || '') })),
            cabeSizeOpts: ['','0.125','0.25','0.5','3U','Full'].map(s => ({ v: s, l: s || '—', s: s === (r.CabE_Size__c || '') })),
            breakerTypeOpts: ['3 Phase','Single Phase'].map(s => ({ v: s, l: s, s: s === (r.Breaker_Type__c || '') })),
            voltageOpts: ['','415V','400V','230V','200V','100V'].map(s => ({ v: s, l: s || '—', s: s === (r.Voltage_Rating__c || '') })),
            currentOpts: ['','16A','32A','40A','63A','100A','125A','200A','250A','400A'].map(s => ({ v: s, l: s || '—', s: s === (r.Current_Rating__c || '') })),
            barStyle: `background:${co}`,
        };
    }

    _pwr(r) {
        if (r.Total_Capacity_kVA__c) return r.Total_Capacity_kVA__c + ' kVA';
        if (r.Power_kVA__c)          return r.Power_kVA__c + ' kVA';
        if (r.Total_kW__c)           return r.Total_kW__c + ' kW';
        if (r.Power_Circuit_kVA__c)  return r.Power_Circuit_kVA__c + ' kVA';
        return '';
    }

    _reservedBadge(val) {
        if (val === 'Reserved') return 'dim-status dim-st-reserved';
        if (val === 'N/A')      return 'dim-status dim-st-decommissioned';
        return 'dim-status dim-st-stranded';
    }

    /* ════════════════════════════════════════════════════════════
     *  CSV UTILITY
     * ════════════════════════════════════════════════════════ */

    _exportVal(rec, header) {
        const map = {
            'Id':                  rec.Id,
            'Inventory ID':        rec.Name,
            'RecordType':          (rec.RecordType || {}).DeveloperName,
            'Site':                (rec.Site_Id__r || {}).Site_Code__c,
            'Floor':               (rec.Floor__r || {}).Name,
            'Data_Hall':           (rec.Data_Hall__r || {}).Name,
            'Inventory Status':    rec.Status__c,
            'Space Type':          rec.Space_Type__c,
            'Usage Type':          rec.Usage_Type__c,
            'Other Inventory Name': rec.Unit_Reference__c,
            'Cage Reference':      (rec.Cage_Reference__r || {}).Name,
            'Hall Reference':      (rec.Hall_Reference__r || {}).Name,
            'Breaker Type':        rec.Breaker_Type__c,
            'Voltage Rating (V)':  rec.Voltage_Rating__c,
            'Current Rating (A)':  rec.Current_Rating__c,
            'CabE Size':           rec.CabE_Size__c,
            'CabE Count':          rec.CabE_Count__c,
            'Average Power per Cab (kVA)':       rec.Total_Capacity_kVA__c,
            'Subscribed/Contracted Power (kVA)': rec.Power_kVA__c,
            'Contracted Power (kVA)': rec.Total_IT_Power_kVA__c,
            'SLA Temperature Min': rec.SLA_Temperature_Min__c,
            'SLA Temperature Max': rec.SLA_Temperature_Max__c,
            'SLA Humidity Min':    rec.SLA_Humidity_Min__c,
            'SLA Humidity Max':    rec.SLA_Humidity_Max__c,
            'SLA Availability':    rec.SLA_Availability__c,
            'TH Sensor ID':        rec.TH_Sensor_ID__c,
            'Remarks':             rec.Notes__c,
            'Account':             (rec.Account__r || {}).Name,
            'Opportunity':         (rec.Opportunity__r || {}).Name,
            'Odoo_Space_ID':       rec.Odoo_Space_ID__c,
            'Odoo_Inventory_Id':   rec.Odoo_Inventory_Id__c,
        };
        const v = map[header];
        return v != null ? v : '';
    }

    _csvEscape(val) {
        if (val == null || val === '') return '';
        const s = String(val);
        if (s.includes(',') || s.includes('"')
                || s.includes('\n') || s.includes('\r')) {
            return '"' + s.replace(/"/g, '""') + '"';
        }
        return s;
    }

    _parseCsv(text) {
        const rows = [];
        let current = [];
        let field = '';
        let inQ = false;
        for (let i = 0; i < text.length; i++) {
            const ch = text[i];
            const nx = text[i + 1];
            if (inQ) {
                if (ch === '"' && nx === '"') { field += '"'; i++; }
                else if (ch === '"') { inQ = false; }
                else { field += ch; }
            } else if (ch === '"') {
                inQ = true;
            } else if (ch === ',') {
                current.push(field.trim()); field = '';
            } else if (ch === '\r' && nx === '\n') {
                current.push(field.trim());
                if (current.length > 1 || current[0] !== '') rows.push(current);
                current = []; field = ''; i++;
            } else if (ch === '\n' || ch === '\r') {
                current.push(field.trim());
                if (current.length > 1 || current[0] !== '') rows.push(current);
                current = []; field = '';
            } else {
                field += ch;
            }
        }
        current.push(field.trim());
        if (current.length > 1 || current[0] !== '') rows.push(current);
        return rows;
    }

    /* ════════════════════════════════════════════════════════════
     *  UTILITY
     * ════════════════════════════════════════════════════════ */

    _toast(t, m, v) {
        this.dispatchEvent(new ShowToastEvent({ title: t, message: m, variant: v }));
    }
    _err(e) {
        return e.body ? e.body.message : (e.message || String(e));
    }
}