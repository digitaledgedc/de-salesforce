import { LightningElement, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import userGreetinng           from '@salesforce/apex/GreetingUser.getCurrentUserInfo';
import updateLightDarkMode     from '@salesforce/apex/GreetingUser.updateDarkLightModeForUser';
import searchAccounts          from '@salesforce/apex/TermsAndConditionController.searchAccounts';
import createTermsAndCondition from '@salesforce/apex/TermsAndConditionController.createTermsAndCondition';

// ─── Profile Link Config ───────────────────────────────────────────────────
const PROFILE_LINKS = {
    'DE Finance': {
        userGuide:      'https://gokarya.app.box.com/s/60dpgszz2milvb7ejoqd4gkncerqwb9t/file/2256959296218',
        referenceVideo: 'https://www.loom.com/share/c438efd5b18f4f3b86c655fc8b9e0f88',
        generalLink:    '',
        generalLabel:   'Release note'
    },
    'System Administrator': {
        userGuide:      'https://gokarya.app.box.com/s/60dpgszz2milvb7ejoqd4gkncerqwb9t/file/2256875300697',
        referenceVideo: 'https://www.loom.com/share/5b2be52ba790457ab68916aaef5fc8c9',
        generalLink:    '',
        generalLabel:   'Release note'
    },
    'DE Sales Support': {
        userGuide:      'https://gokarya.app.box.com/s/60dpgszz2milvb7ejoqd4gkncerqwb9t/file/2256960406965',
        referenceVideo: 'https://www.loom.com/share/b2331263193a4d9d8c65b187e3d42cc9',
        generalLink:    '',
        generalLabel:   'Release note'
    },
    'DE Capacity Manager': {
        userGuide:      'https://gokarya.app.box.com/s/60dpgszz2milvb7ejoqd4gkncerqwb9t/file/2256883180087',
        referenceVideo: 'https://www.loom.com/share/0a415aa64cc844de8100bd731720e1a8',
        generalLink:    '',
        generalLabel:   'Release note'
    },
    'DE Manager': {
        userGuide:      'https://gokarya.app.box.com/s/60dpgszz2milvb7ejoqd4gkncerqwb9t/file/2256960406965',
        referenceVideo: 'https://www.loom.com/share/b2331263193a4d9d8c65b187e3d42cc9',
        generalLink:    '',
        generalLabel:   'Release note'
    },
    'DE AE': {
        userGuide:      'https://gokarya.app.box.com/s/60dpgszz2milvb7ejoqd4gkncerqwb9t/file/2256960406965',
        referenceVideo: 'https://www.loom.com/share/b2331263193a4d9d8c65b187e3d42cc9',
        generalLink:    '',
        generalLabel:   'Release note'
    }
};
// ──────────────────────────────────────────────────────────────────────────

export default class UserGoodMorningComponent extends LightningElement {
    @track error;
    @track firstName;
    @track greeting;
    @track spinner    = true;
    @track contactId;
    @track profileName;

    toggleButtonn = false;

    // ── T&C modal state ──────────────────────────────────────────────────
    @track showTCModal          = false;
    @track tcName               = '';
    @track tcSubscription       = 'Creation';
    @track tcTermsText          = '';
    @track selectedCustomers    = [];
    @track selectedCompanies    = [];
    @track customerSearch       = '';
    @track companySearch        = '';
    @track customerResults      = [];
    @track companyResults       = [];
    @track showCustomerDropdown = false;
    @track showCompanyDropdown  = false;
    @track tcError              = '';
    @track tcSaving             = false;

    _customerTimer;
    _companyTimer;

    // ── Wire ─────────────────────────────────────────────────────────────

    @wire(userGreetinng)
    wireuser({ error, data }) {
        if (error) {
            this.error   = error;
            this.spinner = false;
        } else if (data) {
            this.firstName     = data.firstName;
            this.greeting      = data.greeting;
            this.contactId     = data.contactId;
            this.profileName   = data.profileName;
            this.toggleButtonn = (data.componentMode === 'Dark');
            this.spinner       = false;
        }
    }

    // ── Profile link getters ──────────────────────────────────────────────

    get _profileLinks()     { return PROFILE_LINKS[this.profileName] || {}; }
    get userGuideLink()     { return this._profileLinks.userGuide      || null; }
    get referenceVideoLink(){ return this._profileLinks.referenceVideo || null; }
    get generalLink()       { return this._profileLinks.generalLink    || null; }
    get generalLinkLabel()  { return this._profileLinks.generalLabel   || 'General Link'; }

    // ── Guards ────────────────────────────────────────────────────────────

    get isAdmin() { return this.profileName === 'System Administrator'; }

    // ── Card / component classes ──────────────────────────────────────────

    get cardClass() {
        return `slds-card mainCard ${this.toggleButtonn ? 'darkCard' : 'lightCard'}`;
    }
    get welcomeTextClass() {
        return `welcomeText ${this.toggleButtonn ? 'textWhite' : 'textDark'}`;
    }
    get greetingClass() {
        return `greetingText ${this.toggleButtonn ? 'textWhite' : 'textDark'}`;
    }
    get linksClass() {
        return `linksText ${this.toggleButtonn ? 'textWhite' : 'textDark'}`;
    }
    get lineClass() {
        return `line ${this.toggleButtonn ? 'lineDark' : 'lineLight'}`;
    }
    get linkColorClass() {
        return this.toggleButtonn ? 'linkColordark' : 'linkColorlight';
    }
    get tcBtnClass() {
        return this.toggleButtonn ? 'slds-button vendorBtnDark' : 'slds-button vendorBtnLight';
    }

    // ── Modal dynamic classes ─────────────────────────────────────────────

    get tcModalClass() {
        return `tcModal ${this.toggleButtonn ? 'tcModalDark' : 'tcModalLight'}`;
    }
    get inputClass() {
        return `tcInput ${this.toggleButtonn ? 'tcModalDark' : 'tcModalLight'}`;
    }
    get selectClass() {
        return `tcSelect ${this.toggleButtonn ? 'tcModalDark' : 'tcModalLight'}`;
    }
    get lookupInputClass() {
        return `tcLookupInput ${this.toggleButtonn ? 'tcModalDark' : 'tcModalLight'}`;
    }
    get textareaClass() {
        return `tcTextarea ${this.toggleButtonn ? 'tcModalDark' : 'tcModalLight'}`;
    }
    get dropdownClass() {
        return `tcDropdown ${this.toggleButtonn ? 'tcDropdownDark' : 'tcDropdownLight'}`;
    }
    get tcSubmitBtnClass() {
        return this.tcSaving ? 'tcSubmitBtn' : 'tcSubmitBtn';
    }

    // ── Select option helpers ─────────────────────────────────────────────

    get isCreation()   { return this.tcSubscription === 'Creation'; }
    get isChangeOrder(){ return this.tcSubscription === 'Change Order'; }
    get isRenewal()    { return this.tcSubscription === 'Renewal'; }

    // ── Pill helpers ──────────────────────────────────────────────────────

    get hasSelectedCustomers() { return this.selectedCustomers.length > 0; }
    get hasSelectedCompanies() { return this.selectedCompanies.length > 0; }

    // ── Toggle (dark/light) ───────────────────────────────────────────────

    changeToggle() {
        this.toggleButtonn = !this.toggleButtonn;
        this.updateMode(this.toggleButtonn ? 'Dark' : 'Light');
    }

    updateMode(selectedMode) {
        updateLightDarkMode({ mode: selectedMode })
            .catch(err => {
                // eslint-disable-next-line no-console
                console.error('Error updating mode:', err);
            });
    }

    // ── Modal open / close ────────────────────────────────────────────────

    openTCModal() {
        this._resetModalState();
        this.showTCModal = true;
    }

    closeTCModal() {
        this.showTCModal = false;
        this._resetModalState();
    }

    handleBackdropClick() {
        if (!this.tcSaving) this.closeTCModal();
    }

    _resetModalState() {
        this.tcName               = '';
        this.tcSubscription       = 'Creation';
        this.tcTermsText          = '';
        this.selectedCustomers    = [];
        this.selectedCompanies    = [];
        this.customerSearch       = '';
        this.companySearch        = '';
        this.customerResults      = [];
        this.companyResults       = [];
        this.showCustomerDropdown = false;
        this.showCompanyDropdown  = false;
        this.tcError              = '';
        this.tcSaving             = false;
    }

    // ── Field handlers ────────────────────────────────────────────────────

    handleTcNameChange(event)       { this.tcName         = event.target.value; }
    handleTermsTextChange(event)    { this.tcTermsText     = event.target.value; }

    handleSubscriptionChange(event) {
        this.tcSubscription = event.target.value;
    }

    // ── Customer search ───────────────────────────────────────────────────

    handleCustomerSearch(event) {
        this.customerSearch = event.target.value;
        clearTimeout(this._customerTimer);
        if (!this.customerSearch.trim()) {
            this.customerResults      = [];
            this.showCustomerDropdown = false;
            return;
        }
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._customerTimer = setTimeout(() => {
            searchAccounts({ searchTerm: this.customerSearch })
                .then(results => {
                    const taken = new Set(this.selectedCustomers.map(a => a.id));
                    this.customerResults      = results.filter(r => !taken.has(r.id));
                    this.showCustomerDropdown = true;
                })
                .catch(() => { this.showCustomerDropdown = false; });
        }, 300);
    }

    handleCustomerFocus() {
        if (this.customerSearch.trim() && this.customerResults.length) {
            this.showCustomerDropdown = true;
        }
    }

    handleCustomerBlur() {
        // delay so onmousedown on dropdown item fires before blur hides it
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => { this.showCustomerDropdown = false; }, 200);
    }

    // ── Company search ────────────────────────────────────────────────────

    handleCompanySearch(event) {
        this.companySearch = event.target.value;
        clearTimeout(this._companyTimer);
        if (!this.companySearch.trim()) {
            this.companyResults      = [];
            this.showCompanyDropdown = false;
            return;
        }
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._companyTimer = setTimeout(() => {
            searchAccounts({ searchTerm: this.companySearch })
                .then(results => {
                    const taken = new Set(this.selectedCompanies.map(a => a.id));
                    this.companyResults      = results.filter(r => !taken.has(r.id));
                    this.showCompanyDropdown = true;
                })
                .catch(() => { this.showCompanyDropdown = false; });
        }, 300);
    }

    handleCompanyFocus() {
        if (this.companySearch.trim() && this.companyResults.length) {
            this.showCompanyDropdown = true;
        }
    }

    handleCompanyBlur() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => { this.showCompanyDropdown = false; }, 200);
    }

    // ── Select / remove pills ─────────────────────────────────────────────

    selectAccount(event) {
        const id    = event.currentTarget.dataset.id;
        const name  = event.currentTarget.dataset.name;
        const field = event.currentTarget.dataset.field;

        if (field === 'customer') {
            if (!this.selectedCustomers.find(a => a.id === id)) {
                this.selectedCustomers = [...this.selectedCustomers, { id, name }];
            }
            this.customerSearch       = '';
            this.customerResults      = [];
            this.showCustomerDropdown = false;
        } else {
            if (!this.selectedCompanies.find(a => a.id === id)) {
                this.selectedCompanies = [...this.selectedCompanies, { id, name }];
            }
            this.companySearch       = '';
            this.companyResults      = [];
            this.showCompanyDropdown = false;
        }
    }

    removePill(event) {
        const id    = event.currentTarget.dataset.id;
        const field = event.currentTarget.dataset.field;
        if (field === 'customer') {
            this.selectedCustomers = this.selectedCustomers.filter(a => a.id !== id);
        } else {
            this.selectedCompanies = this.selectedCompanies.filter(a => a.id !== id);
        }
    }

    // ── Submit ────────────────────────────────────────────────────────────

    submitTC() {
        this.tcError = '';
        if (!this.tcName || !this.tcName.trim()) {
            this.tcError = 'Name is required.';
            return;
        }

        const customerStr = this.selectedCustomers.map(a => a.name).join(',');
        const companyStr  = this.selectedCompanies.map(a => a.name).join(',');

        this.tcSaving = true;
        createTermsAndCondition({
            tcName:                 this.tcName.trim(),
            termsText:              this.tcTermsText,
            customer:               customerStr,
            company:                companyStr,
            subscriptionManagement: this.tcSubscription
        })
            .then(() => {
                this.tcSaving = false;
                this.closeTCModal();
                this.dispatchEvent(new ShowToastEvent({
                    title:   'Submitted',
                    message: 'Terms & Conditions submitted. It will appear in the dropdown once approved.',
                    variant: 'success'
                }));
            })
            .catch(err => {
                this.tcSaving = false;
                this.tcError  = err?.body?.message || 'Could not submit. Please try again.';
            });
    }
}