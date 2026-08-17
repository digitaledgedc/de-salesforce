import { LightningElement, api, wire, track } from 'lwc';
import { FlowAttributeChangeEvent } from 'lightning/flowSupport';
import getAccountContacts           from '@salesforce/apex/DealHealthPanelController.getAccountContacts';
import createContactForOpportunity  from '@salesforce/apex/DealHealthPanelController.createContactForOpportunity';
import updateContactReportsTo       from '@salesforce/apex/DealHealthPanelController.updateContactReportsTo';

export default class ContactPickerTable extends LightningElement {
    @api opportunityId;

    // ── Flow outputs ─────────────────────────────────────────────────────────
    @track _selectedContactId = '';
    @api
    get selectedContactId() { return this._selectedContactId; }
    set selectedContactId(v) { this._selectedContactId = v || ''; }

    @track _selectedRole = '';
    @api
    get selectedRole() { return this._selectedRole; }
    set selectedRole(v) { this._selectedRole = v || ''; }

    @track _selectedEngagementStatus = 'Not Yet Contacted';
    @api
    get selectedEngagementStatus() { return this._selectedEngagementStatus; }
    set selectedEngagementStatus(v) { this._selectedEngagementStatus = v || 'Not Yet Contacted'; }

    // ── Contact list ─────────────────────────────────────────────────────────
    @track _contacts   = [];
    @track searchTerm  = '';
    @track isLoading   = true;
    @track errorMessage;

    @wire(getAccountContacts, { opportunityId: '$opportunityId' })
    wiredContacts({ data, error }) {
        this.isLoading = false;
        if (data) {
            this._contacts = data;
        } else if (error) {
            this.errorMessage = error.body ? error.body.message : 'Failed to load contacts.';
        }
    }

    get filteredContacts() {
        const term = (this.searchTerm || '').toLowerCase().trim();
        const src = term
            ? this._contacts.filter(c =>
                (c.Name  || '').toLowerCase().includes(term) ||
                (c.Title || '').toLowerCase().includes(term) ||
                (c.Email || '').toLowerCase().includes(term))
            : [];

        return src.map(c => {
            const selected = c.Id === this._selectedContactId;
            return {
                Id:           c.Id,
                Name:         c.Name,
                titleDisplay: c.Title || '—',
                emailDisplay: c.Email || '—',
                rowClass:     'cpt-row' + (selected ? ' cpt-row--sel' : ''),
                radioClass:   'cpt-radio' + (selected ? ' cpt-radio--checked' : '')
            };
        });
    }

    get hasSearchTerm()   { return (this.searchTerm || '').trim().length > 0; }
    get hasContacts()     { return this.filteredContacts.length > 0; }
    get showRoleSection() { return !!this._selectedContactId && !this.showCreateForm; }

    // ── Role & Status options ────────────────────────────────────────────────
    get roleOptions() {
        return [
            { label: '— Select Role —',         value: '' },
            { label: 'Economic Buyer',           value: 'Economic Buyer' },
            { label: 'Champion',                 value: 'Champion' },
            { label: 'Decision Maker',           value: 'Decision Maker' },
            { label: 'Executive Sponsor',        value: 'Executive Sponsor' },
            { label: 'Technical Buyer',          value: 'Technical Buyer' },
            { label: 'Evaluator',                value: 'Evaluator' },
            { label: 'Influencer',               value: 'Influencer' },
            { label: 'Business User',            value: 'Business User' },
            { label: 'Economic Decision Maker',  value: 'Economic Decision Maker' },
            { label: 'Other',                    value: 'Other' }
        ];
    }

    get engagementStatusOptions() {
        return [
            { label: 'Not Yet Contacted', value: 'Not Yet Contacted' },
            { label: 'In Discussion',     value: 'In Discussion' },
            { label: 'Supportive',        value: 'Supportive' },
            { label: 'Neutral',           value: 'Neutral' },
            { label: 'Resistant',         value: 'Resistant' }
        ];
    }

    // ── Inline contact creation state ────────────────────────────────────────
    @track showCreateForm    = false;
    @track isCreating        = false;
    @track createError       = '';
    @track newFirstName      = '';
    @track newLastName       = '';
    @track newTitle          = '';
    @track newEmail          = '';
    @track newReportsToId    = '';
    @track newContactCreated = false;
    @track createdContactName = '';

    get reportsToOptions() {
        const opts = [{ label: '— None —', value: '' }];
        this._contacts.forEach(c => {
            opts.push({ label: c.Name + (c.Title ? ` (${c.Title})` : ''), value: c.Id });
        });
        return opts;
    }

    // ── Handlers: existing contact selection ─────────────────────────────────
    handleSearch(e) {
        this.searchTerm = e.target.value;
        if (this.newContactCreated) {
            this.newContactCreated = false;
            this._selectedContactId = '';
            this._selectedRole = '';
            this._selectedEngagementStatus = 'Not Yet Contacted';
        }
    }

    handleRowClick(e) {
        this._selectedContactId        = e.currentTarget.dataset.id;
        this._selectedRole             = '';
        this._selectedEngagementStatus = 'Not Yet Contacted';
        this.dispatchEvent(new FlowAttributeChangeEvent('selectedContactId',        this._selectedContactId));
        this.dispatchEvent(new FlowAttributeChangeEvent('selectedRole',             this._selectedRole));
        this.dispatchEvent(new FlowAttributeChangeEvent('selectedEngagementStatus', this._selectedEngagementStatus));
    }

    handleRoleChange(e) {
        this._selectedRole = e.detail.value;
        this.dispatchEvent(new FlowAttributeChangeEvent('selectedRole', this._selectedRole));
    }

    handleEngagementChange(e) {
        this._selectedEngagementStatus = e.detail.value;
        this.dispatchEvent(new FlowAttributeChangeEvent('selectedEngagementStatus', this._selectedEngagementStatus));
    }

    // ── Handlers: inline contact creation ────────────────────────────────────
    handleShowCreateForm() {
        this.showCreateForm = true;
        this.createError    = '';
    }

    handleCancelCreate() {
        this.showCreateForm  = false;
        this.createError     = '';
        this.newFirstName    = '';
        this.newLastName     = '';
        this.newTitle        = '';
        this.newEmail        = '';
        this.newReportsToId  = '';
    }

    handleNewFieldChange(e) {
        this[e.currentTarget.dataset.field] = e.detail.value;
    }

    async handleCreateContact() {
        this.createError = '';
        if (!this.newLastName || !this.newLastName.trim()) {
            this.createError = 'Last Name is required.';
            return;
        }
        this.isCreating = true;
        try {
            const contactId = await createContactForOpportunity({
                opportunityId: this.opportunityId,
                firstName:     this.newFirstName  || null,
                lastName:      this.newLastName,
                title:         this.newTitle      || null,
                email:         this.newEmail      || null,
            });
            if (this.newReportsToId) {
                await updateContactReportsTo({ contactId, reportsToId: this.newReportsToId });
            }
            this._selectedContactId        = contactId;
            this._selectedRole             = '';
            this._selectedEngagementStatus = 'Not Yet Contacted';
            this.dispatchEvent(new FlowAttributeChangeEvent('selectedContactId',        this._selectedContactId));
            this.dispatchEvent(new FlowAttributeChangeEvent('selectedRole',             this._selectedRole));
            this.dispatchEvent(new FlowAttributeChangeEvent('selectedEngagementStatus', this._selectedEngagementStatus));
            this.createdContactName  = [this.newFirstName, this.newLastName].filter(Boolean).join(' ');
            this.newContactCreated   = true;
            this.showCreateForm      = false;
            this.newReportsToId      = '';
        } catch (err) {
            this.createError = (err.body && err.body.message) ? err.body.message : 'Failed to create contact.';
        } finally {
            this.isCreating = false;
        }
    }

    // ── Flow validation ──────────────────────────────────────────────────────
    @api validate() {
        if (this.showCreateForm) {
            return {
                isValid: false,
                errorMessage: 'Please finish creating the contact or click Cancel before continuing.'
            };
        }
        if (!this._selectedContactId) {
            return {
                isValid: false,
                errorMessage: 'Please select a contact or create a new one before continuing.'
            };
        }
        if (!this._selectedRole) {
            return {
                isValid: false,
                errorMessage: 'Please select a role for this stakeholder.'
            };
        }
        return { isValid: true };
    }
}