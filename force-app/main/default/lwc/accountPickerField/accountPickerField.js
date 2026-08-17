import { LightningElement, api, track } from 'lwc';
import searchAccounts from '@salesforce/apex/DealHealthPanelController.searchAccounts';
import createAccount  from '@salesforce/apex/DealHealthPanelController.createAccount';

export default class AccountPickerField extends LightningElement {
    @api label          = 'Account';
    @api recordTypeName = '';   // filter search to this RT DeveloperName
    @api allowCreate    = false; // show "+ Create" option

    _selectedAccountId = '';
    _selectedName      = '';

    @api
    get selectedAccountId() { return this._selectedAccountId; }
    set selectedAccountId(v) { this._selectedAccountId = v || ''; }

    @track searchTerm = '';
    @track results    = [];
    @track isLoading  = false;
    @track error;
    @track _creating  = false;

    _timeout;

    get hasResults()        { return this.results.length > 0; }
    get selectedName()      { return this._selectedName; }
    get showCreateOption()  {
        return this.allowCreate && this.searchTerm.length >= 2 && !this.isLoading && !this._creating;
    }

    handleSearch(event) {
        this.searchTerm = event.target.value;
        clearTimeout(this._timeout);
        this.results = [];
        if (this.searchTerm.length < 2) return;

        this._timeout = setTimeout(() => {
            this.isLoading = true;
            searchAccounts({ searchTerm: this.searchTerm, recordTypeName: this.recordTypeName || '' })
                .then(data => {
                    this.results   = data;
                    this.isLoading = false;
                    this.error     = undefined;
                })
                .catch(err => {
                    this.error     = err.body?.message || 'Search failed.';
                    this.isLoading = false;
                });
        }, 300);
    }

    handlePick(event) {
        const id   = event.currentTarget.dataset.id;
        const name = event.currentTarget.dataset.name;
        this._selectedAccountId = id;
        this._selectedName      = name;
        this.searchTerm         = '';
        this.results            = [];
    }

    async handleCreate() {
        if (!this.searchTerm) return;
        this._creating = true;
        try {
            const id = await createAccount({
                name:           this.searchTerm,
                recordTypeName: this.recordTypeName || '',
            });
            this._selectedAccountId = id;
            this._selectedName      = this.searchTerm;
            this.searchTerm         = '';
            this.results            = [];
            this.error              = undefined;
        } catch (err) {
            this.error = err?.body?.message
                || err?.body?.output?.errors?.[0]?.message
                || err?.message
                || 'Create failed.';
        } finally {
            this._creating = false;
        }
    }

    handleClear() {
        this._selectedAccountId = '';
        this._selectedName      = '';
        this.searchTerm         = '';
    }

    @api validate() {
        return { isValid: true };
    }
}