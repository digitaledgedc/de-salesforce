import { LightningElement, api, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getExistingRoles       from '@salesforce/apex/DealHealthPanelController.getExistingRoles';
import updateEngagementStatus from '@salesforce/apex/DealHealthPanelController.updateEngagementStatus';
import updateContactRole      from '@salesforce/apex/DealHealthPanelController.updateContactRole';
import deleteContactRole      from '@salesforce/apex/DealHealthPanelController.deleteContactRole';

const STATUS_COLORS = {
    'Supportive':        { bg: '#D1FAE5', text: '#065F46' },
    'In Discussion':     { bg: '#FEF3C7', text: '#92400E' },
    'Neutral':           { bg: '#F3F4F6', text: '#374151' },
    'Resistant':         { bg: '#FEE2E2', text: '#991B1B' },
    'Not Yet Contacted': { bg: '#EDE9FE', text: '#5B21B6' }
};

const ROLE_OPTIONS = [
    'Business User','Decision Maker','Economic Buyer','Economic Decision Maker',
    'Evaluator','Executive Sponsor','Influencer','Technical Buyer','Other',
].map(v => ({ label: v, value: v }));

const ENG_OPTIONS = Object.keys(STATUS_COLORS).map(k => ({ label: k, value: k }));

export default class StakeholderListDisplay extends LightningElement {
    @api recordId;

    @track _editRoleId = null;
    @track _editEngId  = null;
    @track _editRoleVal = '';
    @track _editEngVal  = '';
    @track errorMessage;

    _wiredResult;

    @wire(getExistingRoles, { opportunityId: '$recordId' })
    wiredRoles(result) {
        this._wiredResult = result;
    }

    get isLoading() { return !this._wiredResult; }

    get rows() {
        const data = this._wiredResult?.data;
        if (!data) return [];
        return data.map(r => {
            const status = r.Engagement_Status__c || 'Not Yet Contacted';
            const colors = STATUS_COLORS[status] || STATUS_COLORS['Neutral'];
            const isEditingRole = this._editRoleId === r.Id;
            const isEditingEng  = this._editEngId  === r.Id;
            return {
                id:            r.Id,
                name:          r.Contact ? r.Contact.Name : '—',
                role:          r.Role || '—',
                status,
                isPrimary:     r.IsPrimary,
                pillStyle:     `background:${colors.bg};color:${colors.text};`,
                isEditingRole,
                isEditingEng,
                editRoleVal:   isEditingRole ? this._editRoleVal : r.Role,
                editEngVal:    isEditingEng  ? this._editEngVal  : status,
            };
        });
    }

    get hasRows()    { return this.rows.length > 0; }
    get roleOptions(){ return ROLE_OPTIONS; }
    get engOptions() { return ENG_OPTIONS; }

    // ── Role edit ──────────────────────────────────────────────────────
    handleEditRole(e) {
        const id = e.currentTarget.dataset.id;
        const row = (this._wiredResult?.data || []).find(r => r.Id === id);
        this._editRoleId  = id;
        this._editRoleVal = row?.Role || '';
        this._editEngId   = null;
    }

    async handleRoleChange(e) {
        const id  = e.currentTarget.dataset.id;
        const val = e.detail.value;
        try {
            await updateContactRole({ roleId: id, role: val });
            this._editRoleId = null;
            await refreshApex(this._wiredResult);
        } catch (err) {
            this.errorMessage = err.body?.message ?? 'Update failed.';
        }
    }

    handleCancelRole() { this._editRoleId = null; }

    // ── Engagement edit ───────────────────────────────────────────────
    handleEditEng(e) {
        const id = e.currentTarget.dataset.id;
        const row = (this._wiredResult?.data || []).find(r => r.Id === id);
        this._editEngId  = id;
        this._editEngVal = row?.Engagement_Status__c || 'Not Yet Contacted';
        this._editRoleId = null;
    }

    async handleEngChange(e) {
        const id  = e.currentTarget.dataset.id;
        const val = e.detail.value;
        try {
            await updateEngagementStatus({ roleId: id, status: val });
            this._editEngId = null;
            await refreshApex(this._wiredResult);
        } catch (err) {
            this.errorMessage = err.body?.message ?? 'Update failed.';
        }
    }

    handleCancelEng() { this._editEngId = null; }

    // ── Delete ────────────────────────────────────────────────────────
    async handleDelete(e) {
        const id = e.currentTarget.dataset.id;
        try {
            await deleteContactRole({ roleId: id });
            await refreshApex(this._wiredResult);
        } catch (err) {
            this.errorMessage = err.body?.message ?? 'Could not remove stakeholder.';
        }
    }
}