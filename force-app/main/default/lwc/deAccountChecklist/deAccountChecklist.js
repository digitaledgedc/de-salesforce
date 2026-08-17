import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import hasViewFinance from '@salesforce/customPermission/View_Finance_Components';

import FINANCE_APPROVAL from '@salesforce/schema/Account.Finance_Approval_Phase__c';
import KYC_STATUS        from '@salesforce/schema/Account.KYC_Status__c';
import OPERATION_COUNTRY from '@salesforce/schema/Account.Operation_Country__c';
import CREDIT_BLOCK      from '@salesforce/schema/Account.Credit_Block__c';
import ACCOUNT_MANAGER   from '@salesforce/schema/Account.Account_Manager__c';
import LEGAL_ENTITY      from '@salesforce/schema/Account.Legal_Entity_Name__c';
import REG_ADDRESS       from '@salesforce/schema/Account.Registered_Address__c';
import TAX_ID            from '@salesforce/schema/Account.Tax_ID__c';
import PAYMENT_TERMS     from '@salesforce/schema/Account.Payment_Terms__c';
import PREF_LANGUAGE     from '@salesforce/schema/Account.Preferred_Language__c';
import ACCOUNT_TYPE      from '@salesforce/schema/Account.Type';

const OPT_FIELDS = [
    FINANCE_APPROVAL, KYC_STATUS, OPERATION_COUNTRY, CREDIT_BLOCK, ACCOUNT_MANAGER,
    LEGAL_ENTITY, REG_ADDRESS, TAX_ID, PAYMENT_TERMS, PREF_LANGUAGE, ACCOUNT_TYPE
];

const STATUS_MAP = {
    blocker:  { icon: 'utility:warning', variant: 'error',   icoClass: 'ico ico-rose',    pillClass: 'pill pill-rose' },
    progress: { icon: 'utility:clock',   variant: 'warning', icoClass: 'ico ico-amber',   pillClass: 'pill pill-amber' },
    complete: { icon: 'utility:check',   variant: 'success', icoClass: 'ico ico-emerald', pillClass: 'pill pill-emerald' },
    na:       { icon: 'utility:dash',    variant: '',        icoClass: 'ico ico-slate',   pillClass: 'pill pill-slate' }
};

export default class DeAccountChecklist extends LightningElement {
    @api recordId;
    _record;
    hasError = false;

    @wire(getRecord, { recordId: '$recordId', optionalFields: OPT_FIELDS })
    wiredAccount({ data, error }) {
        if (data) { this.hasError = false; this._record = data; }
        else if (error) { this.hasError = true; this._record = null; }
    }

    get hasAccess() { return hasViewFinance; }
    get isLoaded() { return !!this._record; }

    /* ═══════════════════════════════════════════════════════════
     *  Unified item resolution — every check becomes one item
     *  with a status: blocker | progress | complete | na
     * ═══════════════════════════════════════════════════════════ */

    get _allItems() {
        if (!this._record) return [];
        const items = [
            this._field(LEGAL_ENTITY,      'Legal Entity',        'Required for vendor setup',      true),
            this._field(REG_ADDRESS,       'Registered Address',  'Required for invoicing',          true),
            this._field(TAX_ID,            'Tax ID',              'Required for tax compliance',     true),
            this._field(OPERATION_COUNTRY, 'Operation Country',   'Determines subsidiary and tax',   true),
            this._field(PAYMENT_TERMS,     'Payment Terms',       'Standard billing terms',          false),
            this._field(PREF_LANGUAGE,     'Language',            'Default for communications',      false),
            this._finance(),
            this._kyc(),
            this._credit()
        ];
        if (getFieldValue(this._record, ACCOUNT_TYPE) === 'Platform') {
            items.push(this._manager());
        }
        return items;
    }

    _field(ref, label, meta, required) {
        const v = getFieldValue(this._record, ref);
        if (v) return { key: label, label, meta, status: 'complete', value: this._trunc(v) };
        return required
            ? { key: label, label, meta, status: 'blocker', value: 'Missing' }
            : { key: label, label, meta, status: 'progress', value: 'Not set' };
    }

    _finance() {
        const v = getFieldValue(this._record, FINANCE_APPROVAL);
        const b = { key: 'finance', label: 'Finance Approval' };
        switch (v) {
            case 'Approved':     return { ...b, meta: 'Finance review complete',   status: 'complete', value: 'Approved' };
            case 'Pending':      return { ...b, meta: 'Awaiting finance review',   status: 'progress', value: 'Pending' };
            case 'Rejected':     return { ...b, meta: 'Finance review failed',     status: 'blocker',  value: 'Rejected' };
            case 'Not Required': return { ...b, meta: 'Under contract threshold',  status: 'na',       value: 'Not required' };
            default:
                if (v) return { ...b, meta: v, status: 'progress', value: 'In review' };
                return { ...b, meta: 'Not yet initiated', status: 'progress', value: 'Pending' };
        }
    }

    _kyc() {
        const v = getFieldValue(this._record, KYC_STATUS);
        const b = { key: 'kyc', label: 'KYC' };
        switch (v) {
            case 'Approved':    return { ...b, meta: 'Screening complete',           status: 'complete', value: 'Approved' };
            case 'In Progress': return { ...b, meta: 'Sanctions + ownership check',  status: 'progress', value: 'In progress' };
            case 'Rejected':    return { ...b, meta: 'Screening failed',             status: 'blocker',  value: 'Rejected' };
            case 'Not Started': return { ...b, meta: 'Sanctions + ownership check',  status: 'progress', value: 'Not started' };
            default:
                if (v) return { ...b, meta: v, status: 'progress', value: 'In review' };
                return { ...b, meta: 'Sanctions + ownership check', status: 'progress', value: 'Not started' };
        }
    }

    _credit() {
        const v = getFieldValue(this._record, CREDIT_BLOCK);
        if (v === true) return { key: 'credit', label: 'Credit Block', meta: 'Outstanding credit hold', status: 'blocker', value: 'Blocked' };
        return { key: 'credit', label: 'Credit Block', meta: 'No outstanding holds', status: 'complete', value: 'Clear' };
    }

    _manager() {
        const v = getFieldValue(this._record, ACCOUNT_MANAGER);
        if (v) return { key: 'manager', label: 'Account Manager', meta: 'Primary relationship owner', status: 'complete', value: 'Assigned' };
        return { key: 'manager', label: 'Account Manager', meta: 'Needs assignment', status: 'progress', value: 'Unassigned' };
    }

    _trunc(s) { return s && s.length > 18 ? s.substring(0, 16) + '\u2026' : s; }

    /* ═══════════════════════════════════════════════════════════
     *  Status-grouped sections with UI enrichment
     * ═══════════════════════════════════════════════════════════ */

    _enrich(item) {
        const m = STATUS_MAP[item.status] || STATUS_MAP.progress;
        return { ...item, icon: m.icon, variant: m.variant, icoClass: m.icoClass, pillClass: m.pillClass };
    }

    get blockerItems()  { return this._allItems.filter(i => i.status === 'blocker').map(i => this._enrich(i)); }
    get progressItems() { return this._allItems.filter(i => i.status === 'progress').map(i => this._enrich(i)); }
    get completeItems() { return this._allItems.filter(i => i.status === 'complete' || i.status === 'na').map(i => this._enrich(i)); }

    get blockerCount()  { return this.blockerItems.length; }
    get progressCount() { return this.progressItems.length; }
    get completeCount() { return this.completeItems.length; }
    get totalCount()    { return this._allItems.length; }

    get hasBlockers()  { return this.blockerCount > 0; }
    get hasProgress()  { return this.progressCount > 0; }
    get hasComplete()  { return this.completeCount > 0; }

    /* ═══════════════════════════════════════════════════════════
     *  Summary ring, pill, headline
     * ═══════════════════════════════════════════════════════════ */

    get readinessPercent() {
        return this.totalCount ? Math.round((this.completeCount / this.totalCount) * 100) : 0;
    }

    get ringStyle() {
        const pct = this.readinessPercent;
        let color;
        if (pct >= 75) color = '#0e7c44';
        else if (pct >= 50) color = '#b8860b';
        else color = '#c0334a';
        return `--ring-pct: ${pct}%; --ring-color: ${color}`;
    }

    get statusPillClass() {
        if (this.hasBlockers) return 'sp sp-rose';
        if (this.hasProgress) return 'sp sp-amber';
        return 'sp sp-emerald';
    }

    get statusPillLabel() {
        if (this.hasBlockers) return 'Not ready';
        if (this.hasProgress) return 'In progress';
        return 'Ready';
    }

    get summaryHeadline() {
        if (this.hasBlockers) {
            const n = this.blockerCount;
            return `${n} blocker${n > 1 ? 's' : ''} stop${n === 1 ? 's' : ''} this account from going live.`;
        }
        if (this.hasProgress) {
            const n = this.progressCount;
            return `On track \u2014 ${n} item${n > 1 ? 's' : ''} in progress.`;
        }
        return 'This account is fully ready.';
    }

    get footerText() {
        if (this.hasBlockers) return `Resolve ${this.blockerCount} blocker${this.blockerCount > 1 ? 's' : ''} to proceed.`;
        if (this.hasProgress) return `${this.progressCount} item${this.progressCount > 1 ? 's' : ''} pending.`;
        return 'All checks passed.';
    }
}