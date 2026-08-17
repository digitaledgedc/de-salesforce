import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue, updateRecord } from 'lightning/uiRecordApi';
import { CloseActionScreenEvent } from 'lightning/actions';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

import ID_FIELD     from '@salesforce/schema/Account.Id';
import PHASE_FIELD  from '@salesforce/schema/Account.Finance_Approval_Phase__c';
import DNB_NUMBER   from '@salesforce/schema/Account.D_B_Number__c';
import DNB_RATING   from '@salesforce/schema/Account.DnB_Rating__c';
import DNB_DATE     from '@salesforce/schema/Account.DnB_Check_Date__c';
import TAX_ID       from '@salesforce/schema/Account.Tax_ID__c';
import LEGAL_ENTITY from '@salesforce/schema/Account.Legal_Entity_Name__c';
import LOCAL_ENTITY from '@salesforce/schema/Account.Local_Entity_Name__c';
import REG_ADDRESS  from '@salesforce/schema/Account.Registered_Address__c';
import LOCAL_LANG   from '@salesforce/schema/Account.Local_Language__c';
import LOCAL_ADDR   from '@salesforce/schema/Account.Local_Registered_Office_Address__c';
import KYC_STATUS   from '@salesforce/schema/Account.KYC_Status__c';
import OP_COUNTRY   from '@salesforce/schema/Account.Operation_Country__c';
import SEGMENT      from '@salesforce/schema/Account.Segment__c';
import SUB_SEGMENT  from '@salesforce/schema/Account.Sub_Segment__c';
import PAY_TERMS    from '@salesforce/schema/Account.Payment_Terms__c';
import CREDIT_MRC   from '@salesforce/schema/Account.Credit_Limit_MRC__c';
import CREDIT_NRC   from '@salesforce/schema/Account.Credit_Limit_NRC__c';
import TOTAL_Q_MRC  from '@salesforce/schema/Account.Total_Active_Quoted_MRC__c';
import TOTAL_Q_NRC  from '@salesforce/schema/Account.Total_Active_Quoted_NRC__c';
import KYC_TPI      from '@salesforce/schema/Account.KYC_TPI_Verified_Date__c';
import KYC_SANC     from '@salesforce/schema/Account.KYC_Sanctions_Verified_Date__c';
import KYC_BG       from '@salesforce/schema/Account.KYC_Background_Verified_Date__c';
import KYC_BY       from '@salesforce/schema/Account.KYC_Approved_By__c';
import KYC_DT       from '@salesforce/schema/Account.KYC_Approved_Date__c';
import KYC_LAST     from '@salesforce/schema/Account.KYC_Last_Review_Date__c';
import ENTITY_LOCK  from '@salesforce/schema/Account.Entity_Locked__c';
import FIN_DATE     from '@salesforce/schema/Account.Finance_Approved_Date__c';
import FIN_APPROVER from '@salesforce/schema/Account.Finance_Approver__c';
import FIN_REASON   from '@salesforce/schema/Account.Finance_Rejection_Reason__c';
import CONTRACTED   from '@salesforce/schema/Account.Contracted_MRC_USD__c';
import FIN_QUOTE    from '@salesforce/schema/Account.Finance_Originating_Quote__c';

import Q_NUMBER     from '@salesforce/schema/Quote.Quote_Number__c';
import Q_MRC        from '@salesforce/schema/Quote.Total_MRC_2__c';
import Q_NRC        from '@salesforce/schema/Quote.Total_NRC__c';

const FIELDS = [
    PHASE_FIELD, DNB_NUMBER, DNB_RATING, DNB_DATE, TAX_ID,
    LEGAL_ENTITY, LOCAL_ENTITY, REG_ADDRESS, LOCAL_LANG, KYC_STATUS,
    OP_COUNTRY, SEGMENT, SUB_SEGMENT, PAY_TERMS,
    CREDIT_MRC, CREDIT_NRC, TOTAL_Q_MRC, TOTAL_Q_NRC, CONTRACTED, FIN_QUOTE, LOCAL_ADDR
];

const QUOTE_FIELDS = [Q_NUMBER, Q_MRC, Q_NRC];

const DEFAULT_CREDIT = 15000;

export default class DeDnbCheck extends LightningElement {
    @api recordId;
    _record;
    saving = false;
    _quoteRecord;
    _sourceQuoteId;

    /* ─── Phase 1: D&B ─── */
    duns = '';
    rating = '';
    checkDate = null;
    taxId = '';
    legalEntity = '';
    localEntity = '';
    regAddress = '';
    notes = '';
    localAddress = '';

    /* ─── Phase 2: KYC ─── */
    kycTpiDone = false;
    kycSanctionsDone = false;
    kycBackgroundDone = false;
    kycNotes = '';
    kycRejectReason = '';

    /* ─── Phase 3: Credit ─── */
    creditMRC = DEFAULT_CREDIT;
    creditNRC = DEFAULT_CREDIT;

    /* ─── Confirm screen ─── */
    dnbConfirmed = false;
    kycProceedAnyway = false;

    /* ─── Internal view state ─── */
    _view = 'loading'; // loading | dnb | dnb-confirm | kyc | kyc-warn | credit | terminal

    @wire(getRecord, { recordId: '$recordId', fields: FIELDS })
    wiredAccount({ data, error }) {
        if (data) {
            this._record = data;
            const p = this.phase;
            // Pre-populate from account
            this.duns        = getFieldValue(data, DNB_NUMBER) || '';
            this.rating      = getFieldValue(data, DNB_RATING) || '';
            this.checkDate   = getFieldValue(data, DNB_DATE) || new Date().toISOString().slice(0, 10);
            this.taxId       = getFieldValue(data, TAX_ID) || '';
            this.legalEntity = getFieldValue(data, LEGAL_ENTITY) || '';
            this.localEntity = getFieldValue(data, LOCAL_ENTITY) || '';
            this.regAddress    = getFieldValue(data, REG_ADDRESS) || '';
            this.localAddress  = getFieldValue(data, LOCAL_ADDR) || '';

            this._sourceQuoteId = getFieldValue(data, FIN_QUOTE) || null;

            const existMRC = getFieldValue(data, CREDIT_MRC);
            const existNRC = getFieldValue(data, CREDIT_NRC);
            this.creditMRC = existMRC != null && existMRC > 0 ? existMRC : DEFAULT_CREDIT;
            this.creditNRC = existNRC != null && existNRC > 0 ? existNRC : DEFAULT_CREDIT;

            // Route to correct view
            if (!p || p === 'Not_Started' || p === 'DnB_Pending') {
                this._view = 'dnb';
            } else if (p === 'KYC_Pending') {
                const kyc = getFieldValue(data, KYC_STATUS);
                this._view = kyc === 'Approved' ? 'credit' : 'kyc';
            } else {
                this._view = 'terminal';
            }
        } else if (error) {
            this._view = 'terminal';
        }
    }

    @wire(getRecord, { recordId: '$_sourceQuoteId', fields: QUOTE_FIELDS })
    wiredQuote({ data }) {
        if (data) this._quoteRecord = data;
    }

    /* ─── Getters ─── */
    get isLoaded()     { return this._view !== 'loading'; }
    get phase()        { return this._record ? getFieldValue(this._record, PHASE_FIELD) : null; }
    get isDnb()        { return this._view === 'dnb'; }
    get isDnbConfirm() { return this._view === 'dnb-confirm'; }
    get isKyc()        { return this._view === 'kyc'; }
    get isKycWarn()    { return this._view === 'kyc-warn'; }
    get isCredit()     { return this._view === 'credit'; }
    get isTerminal()   { return this._view === 'terminal'; }

    get confirmSummaryRows() {
        const rows = [];
        if (this.taxId)       rows.push({ label: 'Tax ID', value: this.taxId });
        else                  rows.push({ label: 'Tax ID', value: 'MISSING', cls: 'confirm-missing' });
        if (this.regAddress)  rows.push({ label: 'Registered Address', value: this.regAddress });
        else                  rows.push({ label: 'Registered Address', value: 'MISSING', cls: 'confirm-missing' });
        if (this.duns)        rows.push({ label: 'DUNS Number', value: this.duns });
        if (this.rating)      rows.push({ label: 'D&B Rating', value: this.rating });
        if (this.legalEntity) rows.push({ label: 'Legal Entity', value: this.legalEntity });
        if (this.showLocalEntity && this.localEntity) rows.push({ label: 'Local Entity', value: this.localEntity });
        if (this.showLocalEntity && this.localAddress) rows.push({ label: 'Local Address', value: this.localAddress });
        const payTerms = this._record ? getFieldValue(this._record, PAY_TERMS) : null;
        if (payTerms) rows.push({ label: 'Payment Terms', value: payTerms });
        return rows;
    }

    get hasConfirmWarnings() {
        return !this.taxId || !this.regAddress;
    }
    get showLocalEntity() { return this._record ? getFieldValue(this._record, LOCAL_LANG) : false; }
    get legalEntityColClass() { return this.showLocalEntity ? 'slds-col slds-size_1-of-2' : 'slds-col slds-size_1-of-1'; }

    get terminalMessage() {
        const p = this.phase;
        if (p === 'Approved') return 'This account has been fully approved. No further action required.';
        if (p === 'Legal_Review_Pending') return 'This account is pending Legal Review. Use the Legal Resolution action once legal review is complete.';
        if (p === 'Rejected_DnB') return 'This account was rejected at Customer Master Validation. Contact Sales Director to reset.';
        if (p === 'Rejected_KYC') return 'This account was rejected at KYC. Contact Sales Director to review.';
        return 'Finance Approval is not available for the current phase.';
    }

    get phaseLabel() {
        if (this.isDnb || this.isDnbConfirm) return 'Phase 1 of 3 - Customer Master Validation';
        if (this.isKyc || this.isKycWarn)     return 'Phase 2 of 3 - KYC Review';
        if (this.isCredit)                    return 'Phase 3 of 3 - Credit Decision';
        return '';
    }

    get sourceQuoteId() { return this._sourceQuoteId; }
    get sourceQuoteLabel() {
        if (!this._quoteRecord) return null;
        const qNum = getFieldValue(this._quoteRecord, Q_NUMBER);
        const qMrc = getFieldValue(this._quoteRecord, Q_MRC);
        const qNrc = getFieldValue(this._quoteRecord, Q_NRC);
        return qNum + ' - MRC ' + this._fmt(qMrc) + ' | NRC ' + this._fmt(qNrc);
    }
    get hasSourceQuote() { return !!this._quoteRecord && !!getFieldValue(this._quoteRecord, Q_NUMBER); }

    handleQuoteNav() {
        if (!this._sourceQuoteId) return;
        window.open('/' + this._sourceQuoteId, '_blank');
    }

    get contextRows() {
        if (!this._record) return [];
        const rows = [
            { label: 'Country',       value: getFieldValue(this._record, OP_COUNTRY) || '-' },
            { label: 'Payment Terms', value: getFieldValue(this._record, PAY_TERMS) || '-' },
        ];
        if (this.isCredit) {
            rows.push({ label: 'D&B Rating', value: (getFieldValue(this._record, DNB_RATING) || '-') + ' (checked ' + (getFieldValue(this._record, DNB_DATE) || '-') + ')' });
            rows.push({ label: 'Current Limits', value: 'MRC ' + this._fmt(getFieldValue(this._record, CREDIT_MRC)) + ' | NRC ' + this._fmt(getFieldValue(this._record, CREDIT_NRC)) });
        }
        return rows;
    }

    _fmt(v) { return v != null ? '$' + Number(v).toLocaleString() : '-'; }

    /* ─── Handlers: D&B ─── */
    handleDuns(e)   { this.duns = e.target.value; }
    handleRating(e) { this.rating = e.target.value; }
    handleDate(e)   { this.checkDate = e.target.value; }
    handleTaxId(e)       { this.taxId = e.target.value; }
    handleLegalEntity(e) { this.legalEntity = e.target.value; }
    handleLocalEntity(e) { this.localEntity = e.target.value; }
    handleRegAddress(e)  { this.regAddress = e.target.value; }
    handleNotes(e)       { this.notes = e.target.value; }
    handleLocalAddr(e)   { this.localAddress = e.target.value; }

    /* ─── Handlers: KYC ─── */
    handleKycTpi(e)         { this.kycTpiDone = e.target.checked; }
    handleKycSanctions(e)   { this.kycSanctionsDone = e.target.checked; }
    handleKycBackground(e)  { this.kycBackgroundDone = e.target.checked; }
    handleKycNotes(e)       { this.kycNotes = e.target.value; }
    handleKycRejectReason(e){ this.kycRejectReason = e.target.value; }

    /* ─── Handlers: Credit ─── */
    handleCreditMRC(e) { this.creditMRC = e.target.value; }
    handleCreditNRC(e) { this.creditNRC = e.target.value; }

    /* ─── Handlers: Confirm ─── */
    handleDnbConfirm(e)      { this.dnbConfirmed = e.target.checked; }
    handleKycProceedAnyway(e) { this.kycProceedAnyway = e.target.checked; }

    handleCancel() { this.dispatchEvent(new CloseActionScreenEvent()); }

    /* ═══ D&B ACTIONS ═══ */
    handleDnbApprove() {
        if (!this._validateSection('dnb')) return;
        this._view = 'dnb-confirm';
    }

    handleDnbConfirmProceed() {
        if (!this.dnbConfirmed) {
            this._toast('Required', 'Please confirm you have validated the customer master record.', 'warning');
            return;
        }
        this._saveDnb('KYC_Pending');
    }

    handleDnbConfirmBack() { this._view = 'dnb'; }

    async handleDnbReject() {
        await this._saveDnb('Rejected_DnB');
        this._toast('Rejected', 'Customer master validation rejected.', 'warning');
    }

    async handleDnbSave() {
        if (!this._validateSection('dnb')) return;
        await this._saveDnbFields();
        this._toast('Saved', 'D&B fields saved.', 'success');
    }

    async _saveDnb(phase) {
        this.saving = true;
        try {
            const fields = {};
            fields[ID_FIELD.fieldApiName]      = this.recordId;
            fields[DNB_NUMBER.fieldApiName]    = this.duns;
            fields[DNB_RATING.fieldApiName]    = this.rating;
            fields[DNB_DATE.fieldApiName]      = this.checkDate;
            fields[TAX_ID.fieldApiName]        = this.taxId;
            fields[LEGAL_ENTITY.fieldApiName]  = this.legalEntity;
            fields[LOCAL_ENTITY.fieldApiName]  = this.localEntity;
            fields[REG_ADDRESS.fieldApiName]   = this.regAddress;
            fields[LOCAL_ADDR.fieldApiName]    = this.localAddress;
            fields[PHASE_FIELD.fieldApiName]   = phase;
            await updateRecord({ fields });
            if (phase === 'KYC_Pending') {
                this._toast('Approved', 'Customer master validated. Proceeding to KYC.', 'success');
                this._view = 'kyc';
            } else {
                this.dispatchEvent(new CloseActionScreenEvent());
            }
        } catch (err) {
            this._toast('Error', this._errMsg(err), 'error');
        } finally { this.saving = false; }
    }

    async _saveDnbFields() {
        this.saving = true;
        try {
            const fields = {};
            fields[ID_FIELD.fieldApiName]      = this.recordId;
            fields[DNB_NUMBER.fieldApiName]    = this.duns;
            fields[DNB_RATING.fieldApiName]    = this.rating;
            fields[DNB_DATE.fieldApiName]      = this.checkDate;
            fields[TAX_ID.fieldApiName]        = this.taxId;
            fields[LEGAL_ENTITY.fieldApiName]  = this.legalEntity;
            fields[LOCAL_ENTITY.fieldApiName]  = this.localEntity;
            fields[REG_ADDRESS.fieldApiName]   = this.regAddress;
            fields[PHASE_FIELD.fieldApiName]   = 'DnB_Pending';
            await updateRecord({ fields });
            this.dispatchEvent(new CloseActionScreenEvent());
        } catch (err) {
            this._toast('Error', this._errMsg(err), 'error');
        } finally { this.saving = false; }
    }

    /* ═══ KYC ACTIONS ═══ */
    handleKycApprove() {
        if (!this.kycTpiDone || !this.kycSanctionsDone || !this.kycBackgroundDone) {
            this._view = 'kyc-warn';
            return;
        }
        this._saveKyc('approve');
    }

    handleKycWarnProceed() {
        if (!this.kycProceedAnyway) {
            this._toast('Required', 'Please confirm you want to proceed without all checks.', 'warning');
            return;
        }
        this._saveKyc('approve');
    }

    handleKycWarnBack() { this._view = 'kyc'; }

    async handleKycReject() {
        if (!this.kycRejectReason.trim()) {
            this._toast('Required', 'Please provide a rejection reason.', 'warning');
            return;
        }
        this.saving = true;
        try {
            const fields = {};
            fields[ID_FIELD.fieldApiName]      = this.recordId;
            fields[PHASE_FIELD.fieldApiName]   = 'Legal_Review_Pending';
            fields[KYC_STATUS.fieldApiName]    = 'Rejected';
            fields[FIN_REASON.fieldApiName]    = this.kycRejectReason;
            await updateRecord({ fields });
            this._toast('KYC Rejected', 'Sent to Legal Review.', 'warning');
            this.dispatchEvent(new CloseActionScreenEvent());
        } catch (err) {
            this._toast('Error', this._errMsg(err), 'error');
        } finally { this.saving = false; }
    }

    async handleKycSave() {
        this.saving = true;
        try {
            const fields = {};
            fields[ID_FIELD.fieldApiName]      = this.recordId;
            fields[LEGAL_ENTITY.fieldApiName]  = this.legalEntity;
            fields[LOCAL_ENTITY.fieldApiName]  = this.localEntity;
            fields[REG_ADDRESS.fieldApiName]   = this.regAddress;
            fields[LOCAL_ADDR.fieldApiName]    = this.localAddress;
            fields[TAX_ID.fieldApiName]        = this.taxId;
            await updateRecord({ fields });
            this._toast('Saved', 'KYC data saved. Return later to complete.', 'success');
            this.dispatchEvent(new CloseActionScreenEvent());
        } catch (err) {
            this._toast('Error', this._errMsg(err), 'error');
        } finally { this.saving = false; }
    }

    async _saveKyc(action) {
        this.saving = true;
        const now = new Date().toISOString();
        const today = now.slice(0, 10);
        try {
            const fields = {};
            fields[ID_FIELD.fieldApiName]   = this.recordId;
            fields[KYC_STATUS.fieldApiName] = 'Approved';
            fields[KYC_BY.fieldApiName]     = null; // set by flow/trigger
            fields[KYC_DT.fieldApiName]     = today;
            fields[KYC_LAST.fieldApiName]   = today;
            fields[LEGAL_ENTITY.fieldApiName] = this.legalEntity;
            fields[LOCAL_ENTITY.fieldApiName] = this.localEntity;
            fields[REG_ADDRESS.fieldApiName]  = this.regAddress;
            fields[LOCAL_ADDR.fieldApiName]   = this.localAddress;
            fields[TAX_ID.fieldApiName]       = this.taxId;
            if (this.kycTpiDone)        fields[KYC_TPI.fieldApiName]  = now;
            if (this.kycSanctionsDone)  fields[KYC_SANC.fieldApiName] = now;
            if (this.kycBackgroundDone) fields[KYC_BG.fieldApiName]   = now;
            await updateRecord({ fields });
            this._toast('KYC Approved', 'Proceeding to Credit Decision.', 'success');
            this._view = 'credit';
        } catch (err) {
            this._toast('Error', this._errMsg(err), 'error');
        } finally { this.saving = false; }
    }

    /* ═══ CREDIT ACTIONS ═══ */
    async handleCreditApprove() {
        if (!this.creditMRC || !this.creditNRC) {
            this._toast('Required', 'Please set both MRC and NRC credit limits.', 'warning');
            return;
        }
        this.saving = true;
        try {
            const fields = {};
            fields[ID_FIELD.fieldApiName]      = this.recordId;
            fields[CREDIT_MRC.fieldApiName]    = this.creditMRC;
            fields[CREDIT_NRC.fieldApiName]    = this.creditNRC;
            fields[ENTITY_LOCK.fieldApiName]   = true;
            fields[PHASE_FIELD.fieldApiName]   = 'Approved';
            fields[FIN_DATE.fieldApiName]      = new Date().toISOString().slice(0, 10);
            fields[FIN_APPROVER.fieldApiName]  = null; // auto-set
            await updateRecord({ fields });
            this._toast('Approved', 'Finance approval complete. Account locked.', 'success');
            this.dispatchEvent(new CloseActionScreenEvent());
        } catch (err) {
            this._toast('Error', this._errMsg(err), 'error');
        } finally { this.saving = false; }
    }

    /* ═══ VALIDATION ═══ */
    _validateSection(section) {
        const inputs = this.template.querySelectorAll('lightning-input, lightning-textarea');
        let valid = true;
        inputs.forEach(inp => { if (!inp.reportValidity()) valid = false; });
        return valid;
    }

    /* ═══ UTILITY ═══ */
    _toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    _errMsg(err) {
        if (err?.body?.output?.errors?.length) {
            return err.body.output.errors.map(e => e.message).join('; ');
        }
        if (err?.body?.output?.fieldErrors) {
            const msgs = [];
            for (const fld of Object.keys(err.body.output.fieldErrors)) {
                for (const fe of err.body.output.fieldErrors[fld]) msgs.push(fe.message);
            }
            if (msgs.length) return msgs.join('; ');
        }
        if (err?.body?.message) return err.body.message;
        return 'An unexpected error occurred.';
    }
}