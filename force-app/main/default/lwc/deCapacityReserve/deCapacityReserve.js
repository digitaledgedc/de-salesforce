import { LightningElement, api, wire, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

/* ── InventoryController (Quote context) ── */
import getQuoteSiteInfo          from '@salesforce/apex/InventoryController.getQuoteSiteInfo';
import getSiteInventoryForQuote  from '@salesforce/apex/InventoryController.getSiteInventoryForQuote';
import getQuoteInventorySummary  from '@salesforce/apex/InventoryController.getQuoteInventorySummary';
import bulkAssignToQuote         from '@salesforce/apex/InventoryController.bulkAssignToQuote';
import bulkReleaseFromQuote      from '@salesforce/apex/InventoryController.bulkReleaseFromQuote';

/* ── InventoryController (QLI context) ── */
import getLineInventory          from '@salesforce/apex/InventoryController.getLineInventory';
import assignInventoryToLine     from '@salesforce/apex/InventoryController.assignInventoryToLine';
import releaseInventoryFromLine  from '@salesforce/apex/InventoryController.releaseInventoryFromLine';

/* ── DeInventoryManagerController (Create + Floor/Hall lookups) ── */
import createInventoryRecords from '@salesforce/apex/DeInventoryManagerController.createInventoryRecords';
import getFloorsBySite        from '@salesforce/apex/DeInventoryManagerController.getFloorsBySite';
import getHallsByFloor        from '@salesforce/apex/DeInventoryManagerController.getHallsByFloor';

import QUOTE_ID     from '@salesforce/schema/Quote.Id';
import QLI_QUOTE_ID from '@salesforce/schema/QuoteLineItem.QuoteId';

const AVAILABLE_STATUSES = new Set(['Available', 'Pending Available']);
const SPACE_TYPES = ['Cabinet', 'Cage', 'Data Hall'];
const PAGE_SIZE = 100;

const STATUS_ORDER = [
    'Available', 'Pending Available', 'Quoted', 'Reserved',
    'Assigned', 'Sold', 'Installed', 'Decommissioned', 'Stranded'
];
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

export default class DeCapacityReserve extends NavigationMixin(LightningElement) {
    @api recordId;

    // ── Resolved Quote context ──
    @track _quoteId    = null;
    @track _initialized = false;

    // ── Site state ──
    @track _siteId     = null;
    @track _siteName   = null;
    @track _siteCode   = null;

    // ── Data ──
    @track allInventory = [];
    @track summary      = {};

    // ── View / Filter state ──
    @track activeView      = 'available';
    @track selectedType    = 'All';
    @track selectedStatus  = 'All';
    @track searchTerm      = '';
    @track loading         = false;
    @track error           = null;
    @track displayLimit    = PAGE_SIZE;

    // ── Server-side scope filters (SFDC-472) ──
    // The line-level Apex query caps its row count. Narrowing by Floor / Data Hall
    // moves the filter server-side, so floors that sort last are still reachable.
    @track filterFloorId   = '';
    @track filterHallId    = '';
    @track filterHalls     = [];
    @track availableTotal  = 0;
    @track availableLimit  = 0;

    // ── Selection ──
    @track _selectedAssignIds  = new Set();
    @track _selectedReleaseIds = new Set();
    @track _assigning          = false;
    @track _releasing          = false;
    @track _collapsedGroups    = new Set();

    // ── Create form ──
    @track showCreateModal  = false;
    @track createRT         = 'Inventory_Space';
    @track createFloorId;
    @track createHallId;
    @track createSpaceType  = 'Cabinet';
    @track createCapType    = 'Power Circuit';
    @track createPowerKva;
    @track createTotalKw;
    @track createTotalCapKva;
    @track createPanel      = '';
    @track createNotes      = '';
    @track createQty        = 1;
    @track creating         = false;
    @track floors           = [];
    @track halls            = [];

    _searchTimeout;

    // ═══════════════════════════════════════════════════════════
    //  Dual-context wiring: works on both Quote and QuoteLineItem
    //  Key prefixes: Quote = 0Q0, QuoteLineItem = 0QL
    // ═══════════════════════════════════════════════════════════

    get _isOnQuote() {
        return this.recordId && this.recordId.startsWith('0Q0');
    }

    get _quoteWireId() {
        return this._isOnQuote ? this.recordId : undefined;
    }

    get _qliWireId() {
        return (!this._isOnQuote && this.recordId) ? this.recordId : undefined;
    }

    @wire(getRecord, { recordId: '$_quoteWireId', fields: [QUOTE_ID] })
    wiredQuote({ data }) {
        if (data) {
            this._quoteId = this.recordId;
            this._initOnce();
        }
    }

    @wire(getRecord, { recordId: '$_qliWireId', fields: [QLI_QUOTE_ID] })
    wiredQLI({ data }) {
        if (data) {
            const parentId = getFieldValue(data, QLI_QUOTE_ID);
            if (parentId) {
                this._quoteId = parentId;
                this._initOnce();
            }
        }
    }

    _initOnce() {
        if (!this._initialized && this._quoteId) {
            this._initialized = true;
            this._fetchSiteInfo();
        }
    }

    _fetchSiteInfo() {
        getQuoteSiteInfo({ quoteId: this._quoteId })
            .then(result => {
                if (result) {
                    const newSiteId = result.id;
                    this._siteName  = result.name;
                    this._siteCode  = result.siteCode;
                    if (newSiteId !== this._siteId) {
                        this._siteId = newSiteId;
                        this.floors  = [];
                    }
                    if (this.floors.length === 0) {
                        this._loadFloors();
                    }
                    this._loadInventory();
                } else {
                    this._siteId   = null;
                    this._siteName = null;
                    this._siteCode = null;
                }
            })
            .catch(() => {
                this.error = 'Failed to load quote details.';
            });
    }

    // ═══════════════════════════════════════════════════════════
    //  Data loading
    // ═══════════════════════════════════════════════════════════

    async _loadInventory() {
        this.loading = true;
        this.error   = null;
        try {
            if (!this._isOnQuote && this.recordId) {
                // QLI context — line-level inventory
                const result = await getLineInventory({
                    quoteLineItemId: this.recordId,
                    quoteId: this._quoteId,
                    inventoryType: null,
                    floorId: this.filterFloorId || null,
                    hallId:  this.filterHallId  || null
                });
                const assigned  = result.assigned  || [];
                const available = result.available  || [];
                this.availableTotal = result.availableTotal || available.length;
                this.availableLimit = result.availableLimit || 0;
                // Tag assigned items so partitioning works
                assigned.forEach(r => { r._assignedToLine = true; });
                this.allInventory = [...assigned, ...available];
                this.summary = {
                    total: assigned.length + available.length,
                    Available: available.length,
                    thisLine: assigned.length
                };
            } else {
                // Quote context — site-wide inventory
                const [inv, sum] = await Promise.all([
                    getSiteInventoryForQuote({
                        quoteId: this._quoteId,
                        statusFilter: 'All'
                    }),
                    getQuoteInventorySummary({ quoteId: this._quoteId })
                ]);
                this.allInventory = inv;
                this.summary      = sum;
            }
            this._selectedAssignIds  = new Set();
            this._selectedReleaseIds = new Set();
            this._collapsedGroups    = new Set();
            this.displayLimit = PAGE_SIZE;
        } catch (err) {
            this.error = this._msg(err);
        } finally {
            this.loading = false;
        }
    }

    async _loadFloors() {
        if (!this._siteId) return;
        try {
            this.floors = await getFloorsBySite({ siteId: this._siteId });
        } catch (_e) { /* silent — floor picker will be empty */ }
    }

    async _loadHalls() {
        if (!this.createFloorId) { this.halls = []; return; }
        try {
            this.halls = await getHallsByFloor({ floorId: this.createFloorId });
        } catch (_e) { /* silent */ }
    }

    async _loadFilterHalls() {
        if (!this.filterFloorId) { this.filterHalls = []; return; }
        try {
            this.filterHalls = await getHallsByFloor({ floorId: this.filterFloorId });
        } catch (_e) { this.filterHalls = []; }
    }

    // ═══════════════════════════════════════════════════════════
    //  Client-side partitioning
    // ═══════════════════════════════════════════════════════════

    get _isOnQLI() {
        return !this._isOnQuote && this.recordId;
    }

    get _thisQuoteItems() {
        if (this._isOnQLI) {
            return this.allInventory.filter(r => r._assignedToLine);
        }
        return this.allInventory.filter(r => r.Assigned_To_Quote__c === this._quoteId);
    }

    get _availableItems() {
        if (this._isOnQLI) {
            return this.allInventory.filter(r => !r._assignedToLine);
        }
        return this.allInventory.filter(r =>
            AVAILABLE_STATUSES.has(r.Status__c) && !r.Assigned_To_Quote__c
        );
    }

    get _otherHeldItems() {
        return this.allInventory.filter(r =>
            r.Assigned_To_Quote__c && r.Assigned_To_Quote__c !== this._quoteId
        );
    }

    get _activeRawItems() {
        switch (this.activeView) {
            case 'thisQuote':  return this._thisQuoteItems;
            case 'available':  return this._availableItems;
            case 'otherHeld':  return this._otherHeldItems;
            default:           return this.allInventory;
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  Filtered + search
    // ═══════════════════════════════════════════════════════════

    get _filteredItems() {
        let items = this._activeRawItems;

        if (this.selectedType !== 'All') {
            items = items.filter(r => (r.Space_Type__c || '') === this.selectedType);
        }

        if (this.selectedStatus !== 'All') {
            items = items.filter(r => (r.Status__c || '') === this.selectedStatus);
        }

        const search = (this.searchTerm || '').toLowerCase();
        if (search) {
            items = items.filter(r =>
                (r.Name || '').toLowerCase().includes(search) ||
                (r.Account__r && r.Account__r.Name || '').toLowerCase().includes(search)
            );
        }

        return items;
    }

    // ═══════════════════════════════════════════════════════════
    //  Display items (paginated + enriched)
    // ═══════════════════════════════════════════════════════════

    get displayItems() {
        const items = this._filteredItems;
        const selSet = this.activeView === 'thisQuote'
            ? this._selectedReleaseIds
            : this._selectedAssignIds;

        const limited = items.slice(0, this.displayLimit);
        return limited.map(r => ({
            ...r,
            typeLabel:     r.Space_Type__c || '-',
            cabeLabel:     r.CabE_Count__c != null ? String(r.CabE_Count__c) : '-',
            powerLabel:    this._pwr(r),
            roomLabel:     r.Data_Hall__r ? r.Data_Hall__r.Name : '-',
            customerLabel: this._customer(r),
            reservedByLabel: this._reservedBy(r),
            statusCls:     'dcr-status dcr-status-' + (r.Status__c || '').toLowerCase().replace(/\s+/g, '-'),
            isSelected:    selSet.has(r.Id),
            rowClass:      selSet.has(r.Id) ? 'dcr-row dcr-row-selected' : 'dcr-row'
        }));
    }

    _pwr(r) {
        if (r.Total_IT_Power_kVA__c) return r.Total_IT_Power_kVA__c + ' kVA';
        if (r.Total_Capacity_kVA__c) return r.Total_Capacity_kVA__c + ' kVA';
        if (r.Power_kVA__c) return r.Power_kVA__c + ' kVA';
        return '-';
    }

    _customer(r) {
        if (r.Account__r && r.Account__r.Name) return r.Account__r.Name;
        return '-';
    }

    _reservedBy(r) {
        if (r.Order__r && r.Order__r.Order_Number__c) return r.Order__r.Order_Number__c;
        if (r.Assigned_To_Quote__r && r.Assigned_To_Quote__r.QuoteNumber) return 'Q-' + r.Assigned_To_Quote__r.QuoteNumber;
        return '-';
    }

    // ═══════════════════════════════════════════════════════════
    //  Grouped display (Floor / Data Hall)
    // ═══════════════════════════════════════════════════════════

    get groupedDisplay() {
        const items = this.displayItems;
        const map = new Map();
        const groups = [];
        for (const item of items) {
            const floor = item.Floor__r ? item.Floor__r.Name : 'No Floor';
            const hall  = item.roomLabel !== '-' ? item.roomLabel : 'No Hall';
            const key   = floor + '|' + hall;
            if (!map.has(key)) {
                const g = {
                    key,
                    label: floor + ' / ' + hall,
                    items: [],
                    isCollapsed: this._collapsedGroups.has(key),
                    isExpanded: !this._collapsedGroups.has(key),
                    chevron: this._collapsedGroups.has(key) ? '\u25B8' : '\u25BE'
                };
                map.set(key, g);
                groups.push(g);
            }
            map.get(key).items.push(item);
        }
        for (const g of groups) g.count = g.items.length;
        return groups;
    }

    // ═══════════════════════════════════════════════════════════
    //  View tabs
    // ═══════════════════════════════════════════════════════════

    get viewTabs() {
        const s = this.summary;
        if (this._isOnQLI) {
            const avail = s.Available || 0;
            const assigned = s.thisLine || 0;
            return [
                { value: 'available',  label: `Available (${avail})`,      cls: this._tabCls('available') },
                { value: 'thisQuote',  label: `This Line (${assigned})`,   cls: this._tabCls('thisQuote') },
                { value: 'all',        label: `All (${s.total || 0})`,     cls: this._tabCls('all') }
            ];
        }
        const avail = (s.Available || 0) + (s['Pending Available'] || 0);
        return [
            { value: 'available',  label: `Available (${avail})`,             cls: this._tabCls('available') },
            { value: 'thisQuote',  label: `This Quote (${s.thisQuote || 0})`, cls: this._tabCls('thisQuote') },
            { value: 'all',        label: `All (${s.total || 0})`,            cls: this._tabCls('all') },
            { value: 'otherHeld',  label: `Other Held (${s.otherHeld || 0})`, cls: this._tabCls('otherHeld') }
        ];
    }

    _tabCls(val) {
        return val === this.activeView ? 'dcr-tab dcr-tab-active' : 'dcr-tab';
    }

    // ═══════════════════════════════════════════════════════════
    //  Space Type pills
    // ═══════════════════════════════════════════════════════════

    get spaceTypeOptions() {
        const items = this._activeRawItems;
        const counts = {};
        for (const r of items) {
            const t = r.Space_Type__c || 'Other';
            counts[t] = (counts[t] || 0) + 1;
        }
        const opts = [{ value: 'All', label: 'All', count: items.length,
            cssClass: this.selectedType === 'All' ? 'dcr-pill dcr-pill-active' : 'dcr-pill' }];
        for (const t of SPACE_TYPES) {
            if (counts[t]) {
                opts.push({ value: t, label: t, count: counts[t],
                    cssClass: this.selectedType === t ? 'dcr-pill dcr-pill-active' : 'dcr-pill' });
            }
        }
        return opts;
    }

    // ═══════════════════════════════════════════════════════════
    //  Status filter pills
    // ═══════════════════════════════════════════════════════════

    get statusFilterOptions() {
        const items = this._activeRawItems;
        const counts = {};
        for (const r of items) {
            const s = r.Status__c || 'Unknown';
            counts[s] = (counts[s] || 0) + 1;
        }
        const opts = [{ value: 'All', label: 'All', count: items.length,
            cssClass: this.selectedStatus === 'All' ? 'dcr-pill dcr-pill-active' : 'dcr-pill' }];
        for (const s of STATUS_ORDER) {
            if (counts[s]) {
                opts.push({ value: s, label: s, count: counts[s],
                    cssClass: this.selectedStatus === s ? 'dcr-pill dcr-pill-active' : 'dcr-pill' });
            }
        }
        return opts;
    }

    get showStatusFilter() {
        const items = this._activeRawItems;
        const statuses = new Set(items.map(r => r.Status__c));
        return statuses.size > 1;
    }

    // ═══════════════════════════════════════════════════════════
    //  Create form getters
    // ═══════════════════════════════════════════════════════════

    get createRTOptions()        { return CREATE_RT_OPTIONS; }
    get spaceTypeCreateOptions() { return SPACE_TYPE_CREATE_OPTIONS; }
    get capacityTypeOptions()    { return CAPACITY_TYPE_OPTIONS; }
    get floorOptions()           { return this.floors.map(f => ({ label: f.Name, value: f.Id })); }
    get filterFloorOptions() {
        return [{ label: 'All floors', value: '' }]
            .concat(this.floors.map(f => ({ label: f.Name, value: f.Id })));
    }
    get filterHallOptions() {
        return [{ label: 'All data halls', value: '' }]
            .concat(this.filterHalls.map(h => ({ label: h.Name, value: h.Id })));
    }
    get noFilterHallOptions()    { return !this.filterFloorId || this.filterHalls.length === 0; }
    get showScopeFilter()        { return !!this._isOnQLI; }
    get isTruncated() {
        return this.availableLimit > 0 && this.availableTotal > this.availableLimit;
    }
    get truncationNotice() {
        return `Showing the first ${this.availableLimit} of ${this.availableTotal} available records. `
             + 'Pick a Floor or Data Hall to see the rest.';
    }
    get hallOptions()            { return this.halls.map(h => ({ label: h.Name, value: h.Id })); }
    get isSpaceRT()              { return this.createRT === 'Inventory_Space'; }
    get isBreakerRT()            { return this.createRT === 'Inventory_Breaker'; }
    get noHallOptions()          { return this.halls.length === 0; }
    get canCreate()              { return !!this._siteId; }

    get createDisabled() {
        if (this.creating || !this._siteId) return true;
        if (this.isSpaceRT && !this.createSpaceType) return true;
        if (this.isBreakerRT && !this.createCapType) return true;
        return false;
    }

    // ═══════════════════════════════════════════════════════════
    //  Summary getters
    // ═══════════════════════════════════════════════════════════

    get totalCount()     { return this.summary.total || 0; }
    get availableCount() {
        if (this._isOnQLI) return this.summary.Available || 0;
        return (this.summary.Available || 0) + (this.summary['Pending Available'] || 0);
    }
    get thisQuoteCount() {
        if (this._isOnQLI) return this.summary.thisLine || 0;
        return this.summary.thisQuote || 0;
    }
    get thisQuoteLabel() { return this._isOnQLI ? 'This Line' : 'This Quote'; }
    get showOtherHeld()  { return !this._isOnQLI; }
    get otherHeldCount() { return this.summary.otherHeld || 0; }

    // ── Selection getters ──

    get hasAssignSelection()  { return this._selectedAssignIds.size > 0; }
    get hasReleaseSelection() { return this._selectedReleaseIds.size > 0; }
    get assignBtnLabel()      { return `Assign ${this._selectedAssignIds.size} Selected`; }
    get releaseBtnLabel()     { return `Release ${this._selectedReleaseIds.size} Selected`; }
    get showCheckboxes()      { return this.activeView === 'available' || this.activeView === 'thisQuote'; }
    get showAssignBar()       { return this.activeView === 'available'; }
    get showReleaseBar()      { return this.activeView === 'thisQuote'; }
    get filteredCount()       { return this._filteredItems.length; }
    get hasItems()            { return this._filteredItems.length > 0; }
    get hasMoreItems()        { return this._filteredItems.length > this.displayLimit; }

    get allFilteredSelected() {
        const items = this._filteredItems;
        const selSet = this.activeView === 'thisQuote'
            ? this._selectedReleaseIds
            : this._selectedAssignIds;
        return items.length > 0 && items.every(i => selSet.has(i.Id));
    }

    // ── UI state ──

    get noSite()     { return !this._siteId; }
    get siteName()   { return this._siteCode ? (this._siteCode + ' - ' + (this._siteName || '')) : (this._siteName || 'Site'); }
    get hasData()    { return this.allInventory.length > 0; }

    // ═══════════════════════════════════════════════════════════
    //  Event handlers — View / Filter / Search
    // ═══════════════════════════════════════════════════════════

    handleViewTab(event) {
        this.activeView = event.currentTarget.dataset.value;
        this.selectedStatus = 'All';
        this._selectedAssignIds  = new Set();
        this._selectedReleaseIds = new Set();
        this._collapsedGroups    = new Set();
        this.displayLimit = PAGE_SIZE;
    }

    handleTypeFilter(event) {
        this.selectedType = event.currentTarget.dataset.value;
        this._selectedAssignIds  = new Set();
        this._selectedReleaseIds = new Set();
        this.displayLimit = PAGE_SIZE;
    }

    handleStatusFilter(event) {
        this.selectedStatus = event.currentTarget.dataset.value;
        this._selectedAssignIds  = new Set();
        this._selectedReleaseIds = new Set();
        this.displayLimit = PAGE_SIZE;
    }

    handleSearch(event) {
        clearTimeout(this._searchTimeout);
        const val = event.target.value;
        this._searchTimeout = setTimeout(() => {
            this.searchTerm = val;
            this.displayLimit = PAGE_SIZE;
        }, 300);
    }

    handleRefresh() {
        this._loadInventory();
    }

    async handleFilterFloorChange(event) {
        this.filterFloorId = event.detail.value || '';
        this.filterHallId  = '';
        await this._loadFilterHalls();
        this._loadInventory();
    }

    handleFilterHallChange(event) {
        this.filterHallId = event.detail.value || '';
        this._loadInventory();
    }

    handleShowMore() {
        this.displayLimit += PAGE_SIZE;
    }

    handleToggleGroup(event) {
        const key = event.currentTarget.dataset.key;
        const next = new Set(this._collapsedGroups);
        if (next.has(key)) next.delete(key);
        else next.add(key);
        this._collapsedGroups = next;
    }

    // ═══════════════════════════════════════════════════════════
    //  Selection
    // ═══════════════════════════════════════════════════════════

    handleCheck(event) {
        const id = event.currentTarget.dataset.id;
        const selSet = this.activeView === 'thisQuote'
            ? this._selectedReleaseIds
            : this._selectedAssignIds;
        const next = new Set(selSet);
        if (event.currentTarget.checked) { next.add(id); } else { next.delete(id); }
        if (this.activeView === 'thisQuote') {
            this._selectedReleaseIds = next;
        } else {
            this._selectedAssignIds = next;
        }
    }

    handleSelectAll(event) {
        const items = this._filteredItems;
        if (this.activeView === 'thisQuote') {
            this._selectedReleaseIds = event.currentTarget.checked
                ? new Set(items.map(i => i.Id))
                : new Set();
        } else {
            this._selectedAssignIds = event.currentTarget.checked
                ? new Set(items.map(i => i.Id))
                : new Set();
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  Bulk actions
    // ═══════════════════════════════════════════════════════════

    handleBulkAssign() {
        const ids = [...this._selectedAssignIds];
        if (ids.length === 0) return;
        this._assigning = true;
        const promise = this._isOnQLI
            ? assignInventoryToLine({ inventoryIds: ids, quoteLineItemId: this.recordId, quoteId: this._quoteId })
            : bulkAssignToQuote({ inventoryIds: ids, quoteId: this._quoteId });
        const label = this._isOnQLI ? 'this line' : 'this quote';
        promise
            .then(count => {
                this._toast('Assigned', `${count} items assigned to ${label}.`, 'success');
                this._assigning = false;
                this._selectedAssignIds = new Set();
                this._loadInventory();
            })
            .catch(err => {
                this._assigning = false;
                this._toast('Error', this._msg(err), 'error');
            });
    }

    handleBulkRelease() {
        const ids = [...this._selectedReleaseIds];
        if (ids.length === 0) return;
        this._releasing = true;
        const promise = this._isOnQLI
            ? releaseInventoryFromLine({ inventoryIds: ids })
            : bulkReleaseFromQuote({ inventoryIds: ids });
        promise
            .then(count => {
                this._toast('Released', `${count} items released.`, 'success');
                this._releasing = false;
                this._selectedReleaseIds = new Set();
                this._loadInventory();
            })
            .catch(err => {
                this._releasing = false;
                this._toast('Error', this._msg(err), 'error');
            });
    }

    // ═══════════════════════════════════════════════════════════
    //  Create form handlers
    // ═══════════════════════════════════════════════════════════

    handleOpenCreate() {
        this.showCreateModal = true;
        if (this.floors.length === 0) {
            this._loadFloors();
        }
    }

    handleCloseCreate() {
        this.showCreateModal = false;
        this._resetCreateForm();
    }

    handleModalClick(event) {
        event.stopPropagation();
    }

    handleCreateRTChange(event)        { this.createRT = event.detail.value; }
    handleCreateFloorChange(event) {
        this.createFloorId = event.detail.value;
        this.createHallId = undefined;
        this._loadHalls();
    }
    handleCreateHallChange(event)      { this.createHallId = event.detail.value; }
    handleCreateSpaceTypeChange(event) { this.createSpaceType = event.detail.value; }
    handleCreateCapTypeChange(event)   { this.createCapType = event.detail.value; }
    handleCreatePowerKva(event)        { this.createPowerKva = event.detail.value; }
    handleCreateTotalKw(event)         { this.createTotalKw = event.detail.value; }
    handleCreateTotalCapKva(event)     { this.createTotalCapKva = event.detail.value; }
    handleCreatePanel(event)           { this.createPanel = event.detail.value; }
    handleCreateNotes(event)           { this.createNotes = event.detail.value; }
    handleCreateQty(event)             { this.createQty = event.detail.value; }

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
                totalKw:          this.createTotalKw || null,
                totalCapacityKva: this.createTotalCapKva || null,
                unitRefPrefix:    null,
                breakerPanel:     this.createPanel || null,
                notes:            this.createNotes || null,
                quantity:         this.createQty || 1,
                newFloorName:     null,
                newDataHallName:  null
            });
            this._toast('Success',
                `Created ${count} inventory record${count > 1 ? 's' : ''}.`,
                'success');
            this.showCreateModal = false;
            this._resetCreateForm();
            this._loadInventory();
        } catch (e) {
            this._toast('Error creating inventory', this._msg(e), 'error');
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
        this.createTotalKw     = undefined;
        this.createTotalCapKva = undefined;
        this.createPanel       = '';
        this.createNotes       = '';
        this.createQty         = 1;
        this.halls             = [];
    }

    // ═══════════════════════════════════════════════════════════
    //  Navigation
    // ═══════════════════════════════════════════════════════════

    handleRowNav(event) {
        const id = event.currentTarget.dataset.id;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: id,
                objectApiName: 'Inventory__c',
                actionName: 'view'
            }
        });
    }

    // ═══════════════════════════════════════════════════════════
    //  Helpers
    // ═══════════════════════════════════════════════════════════

    _toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    _msg(err) {
        return (err && err.body && err.body.message) ? err.body.message : 'An unexpected error occurred.';
    }
}