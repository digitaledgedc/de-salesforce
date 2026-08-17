import { LightningElement, api, wire, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getByAccount from '@salesforce/apex/OrderAssetsController.getByAccount';
import getAccountAssetSummary from '@salesforce/apex/OrderAssetsController.getAccountAssetSummary';

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
const ALL_CATEGORIES = ['All', 'Space', 'Power', 'Cross Connect', 'IP & Internet', 'Remote Hands', 'Managed Services', 'Other'];

const ROW_ACTIONS = [{ label: 'View Details', name: 'view' }];

export default class DeAccountInstalledBase extends NavigationMixin(LightningElement) {

    @api recordId;

    @track assets          = [];
    @track isLoading       = true;
    @track error;
    @track searchTerm      = '';
    @track activeCategory  = 'All';
    @track activeStatus    = 'All';
    @track summary         = {};

    @wire(getAccountAssetSummary, { accountId: '$recordId' })
    wiredSummary({ data, error }) {
        if (data) {
            this.summary = data;
        } else if (error) {
            this.summary = {};
        }
    }

    @wire(getByAccount, { accountId: '$recordId' })
    wiredAssets({ data, error }) {
        this.isLoading = false;
        if (data) {
            this.assets = data.map(a => {
                const code     = a.Product2 ? a.Product2.ProductCode : '';
                const category = catFromCode(code);
                return {
                    ...a,
                    recordUrl:   '/lightning/r/Asset/' + a.Id + '/view',
                    productName: a.Product2 ? a.Product2.Name : a.Name,
                    productCode: code,
                    category,
                    orderNumber: a.Source_Order__r ? a.Source_Order__r.OrderNumber : '',
                    banName:     a.BillingAccount__r ? a.BillingAccount__r.Name : '',
                };
            });
            this.error = undefined;
        } else if (error) {
            this.error = error;
            this.assets = [];
        }
    }

    // ── Computed ──────────────────────────────────────────────────────────────

    get filteredAssets() {
        let list = this.assets;
        if (this.activeCategory !== 'All') {
            list = list.filter(a => a.category === this.activeCategory);
        }
        if (this.activeStatus !== 'All') {
            list = list.filter(a => a.Status === this.activeStatus);
        }
        if (this.searchTerm) {
            const t = this.searchTerm.toLowerCase();
            list = list.filter(a =>
                (a.productName  || '').toLowerCase().includes(t) ||
                (a.Name         || '').toLowerCase().includes(t) ||
                (a.Description  || '').toLowerCase().includes(t) ||
                (a.orderNumber  || '').toLowerCase().includes(t) ||
                (a.banName      || '').toLowerCase().includes(t)
            );
        }
        return list;
    }

    get hasAssets()    { return this.filteredAssets.length > 0; }
    get isEmpty()     { return !this.isLoading && !this.hasError && !this.hasAssets; }
    get hasError()    { return !!this.error; }
    get errorMessage() {
        return this.error && (this.error.body ? this.error.body.message : JSON.stringify(this.error));
    }

    get totalCount()    { return this.summary.total || 0; }
    get totalMrcFmt()   { return this._fmt(this.summary.totalMrc); }
    get totalNrcFmt()   { return this._fmt(this.summary.totalNrc); }
    get filteredCount() { return this.filteredAssets.length; }

    get filteredMrc() {
        return this._fmt(this.filteredAssets.reduce((s, a) => s + (a.MRC__c || 0), 0));
    }

    get statusOptions() {
        const counts = {};
        this.assets.forEach(a => { counts[a.Status] = (counts[a.Status] || 0) + 1; });
        const options = [{ label: `All (${this.assets.length})`, value: 'All' }];
        Object.keys(counts).sort().forEach(s => {
            options.push({ label: `${s} (${counts[s]})`, value: s });
        });
        return options;
    }

    get categoryPills() {
        const counts = {};
        this.assets.forEach(a => { counts[a.category] = (counts[a.category] || 0) + 1; });
        return ALL_CATEGORIES
            .filter(c => c === 'All' || counts[c])
            .map(c => ({
                value:    c,
                label:    c,
                count:    c === 'All' ? this.assets.length : (counts[c] || 0),
                cssClass: 'aib-pill' + (this.activeCategory === c ? ' aib-pill_active' : ''),
            }));
    }

    get hasCategoryPills() {
        return this.categoryPills.filter(p => p.value !== 'All').length > 1;
    }

    get columns() {
        return [
            {
                label: 'Asset / Product', fieldName: 'recordUrl', type: 'url',
                typeAttributes: { label: { fieldName: 'productName' }, target: '_self' },
                initialWidth: 200,
            },
            { label: 'Description', fieldName: 'Description', type: 'text', wrapText: true },
            { label: 'Category', fieldName: 'category', initialWidth: 120 },
            {
                label: 'MRC', fieldName: 'MRC__c', type: 'currency',
                typeAttributes: { currencyCode: { fieldName: 'CurrencyIsoCode' }, minimumFractionDigits: 2 },
                initialWidth: 110,
            },
            { label: 'Status', fieldName: 'Status', initialWidth: 100 },
            { label: 'Order', fieldName: 'orderNumber', initialWidth: 120 },
            { label: 'BAN', fieldName: 'banName', initialWidth: 130 },
            {
                label: 'Install Date', fieldName: 'InstallDate', type: 'date',
                initialWidth: 110,
            },
            { type: 'action', typeAttributes: { rowActions: ROW_ACTIONS } },
        ];
    }

    // ── Event handlers ────────────────────────────────────────────────────────

    handleSearch(event) {
        this.searchTerm = event.target.value;
    }

    handleCategoryFilter(event) {
        this.activeCategory = event.currentTarget.dataset.value;
    }

    handleStatusChange(event) {
        this.activeStatus = event.detail.value;
    }

    handleRowAction(event) {
        const { name } = event.detail.action;
        const row = event.detail.row;
        if (name === 'view') {
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: { recordId: row.Id, objectApiName: 'Asset', actionName: 'view' },
            });
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    _fmt(val, currency) {
        return new Intl.NumberFormat('en-US', {
            style: 'currency', currency: currency || 'USD', minimumFractionDigits: 2,
        }).format(val || 0);
    }
}