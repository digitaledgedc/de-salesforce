import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import PHASE_FIELD from '@salesforce/schema/Account.Finance_Approval_Phase__c';
import hasViewFinance from '@salesforce/customPermission/View_Finance_Components';

const STEPS = [
    { value: 'Not_Started',          label: 'Not Started' },
    { value: 'DnB_Pending',          label: 'D&B Pending' },
    { value: 'KYC_Pending',          label: 'KYC Pending' },
    { value: 'Legal_Review_Pending', label: 'Legal Review' },
    { value: 'Approved',             label: 'Approved' }
];

const REJECTED = ['Rejected_DnB', 'Rejected_KYC'];

export default class DeAccountPath extends LightningElement {
    @api recordId;
    _phase;
    _record;
    hasError = false;

    @wire(getRecord, { recordId: '$recordId', optionalFields: [PHASE_FIELD] })
    wiredAccount({ data, error }) {
        if (data) {
            this._record = data;
            this._phase = getFieldValue(data, PHASE_FIELD);
            this.hasError = false;
        } else if (error) {
            this.hasError = true;
        }
    }

    get hasAccess() {
        return hasViewFinance;
    }

    get isLoaded() {
        return !!this._record;
    }

    get isRejected() {
        return REJECTED.includes(this._phase);
    }

    get rejectedLabel() {
        if (this._phase === 'Rejected_DnB') return 'Rejected \u2014 D&B';
        if (this._phase === 'Rejected_KYC') return 'Rejected \u2014 KYC';
        return 'Rejected';
    }

    get currentStep() {
        return this._phase || 'Not_Started';
    }

    get steps() {
        if (this.isRejected) return [];
        const current = this._phase || 'Not_Started';
        const currentIdx = STEPS.findIndex(s => s.value === current);
        return STEPS.map((step, idx) => ({
            ...step,
            isComplete: idx < currentIdx,
            isCurrent: idx === currentIdx,
            isActive: idx === currentIdx ? 'true' : 'false',
            class: idx < currentIdx ? 'slds-path__item slds-is-complete'
                 : idx === currentIdx ? 'slds-path__item slds-is-current slds-is-active'
                 : 'slds-path__item slds-is-incomplete'
        }));
    }
}