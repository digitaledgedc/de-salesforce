// dealHealthPanel.js  -  v8: full MEDDPICC 8-circle panel, toggle forms, all fields wired to Opportunity
import { LightningElement, api, wire, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { encodeDefaultFieldValues } from 'lightning/pageReferenceUtils';
import { refreshApex } from '@salesforce/apex';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getDealHealth                  from '@salesforce/apex/DealHealthPanelController.getDealHealth';
import getAccountContacts             from '@salesforce/apex/DealHealthPanelController.getAccountContacts';
import createContactRole              from '@salesforce/apex/DealHealthPanelController.createContactRole';
import createContactAndRole           from '@salesforce/apex/DealHealthPanelController.createContactAndRole';
import updateContactRoleAndEngagement from '@salesforce/apex/DealHealthPanelController.updateContactRoleAndEngagement';
import updateMetrics                  from '@salesforce/apex/DealHealthPanelController.updateMetrics';
import updateDecisionCriteria         from '@salesforce/apex/DealHealthPanelController.updateDecisionCriteria';
import updateDecisionProcess          from '@salesforce/apex/DealHealthPanelController.updateDecisionProcess';
import updatePaperProcess             from '@salesforce/apex/DealHealthPanelController.updatePaperProcess';
import updatePain                     from '@salesforce/apex/DealHealthPanelController.updatePain';
import updateCompetition              from '@salesforce/apex/DealHealthPanelController.updateCompetition';
import updateMeddpiccStatusField      from '@salesforce/apex/DealHealthPanelController.updateMeddpiccStatusField';
import updateContactReportsTo         from '@salesforce/apex/DealHealthPanelController.updateContactReportsTo';
import searchAccounts                 from '@salesforce/apex/DealHealthPanelController.searchAccounts';
import createAccount                  from '@salesforce/apex/DealHealthPanelController.createAccount';
import deleteContactRole              from '@salesforce/apex/DealHealthPanelController.deleteContactRole';
import canViewInternalTab             from '@salesforce/apex/DealHealthPanelController.canViewInternalTab';

// All 8 MEDDPICC qualification components
// contentField = the Long Text or Lookup field that must also be non-empty for the circle to light up
// contentHint  = short label used in guidance text ("Add [contentHint]")
const MEDDPICC_ITEMS = [
    { id: 'M', letter: 'M', label: 'Metrics', shortLabel: 'Metrics', field: 'MEDDPICC_Metrics_Status__c', contentField: 'MEDDPICC_Metrics__c', contentHint: 'notes',
      desc: `Metrics are the quantifiable measures of value that your solution delivers to the customer. They translate features into business outcomes the customer cares about.`,
      titleHelp: `Metrics must be customer-validated, not vendor-invented. The customer must agree that these are the numbers that matter to their business - cost per kW, ROU, uptime %, latency, scalability or disaster recovery?`,
      statusHelp: `MEDDPICC confidence level for Metrics. 2 - Known and Confirmed means the customer has agreed on specific, quantified success measures for this deal.` },
    { id: 'E', letter: 'E', label: 'Economic Buyer', shortLabel: 'Econ. Buyer', field: 'MEDDPICC_Economic_Buyer_Status__c', contentField: 'MEDDPICC_Economic_Buyer__c', contentHint: 'contact',
      desc: `The Economic Buyer is the person who holds the budget and has the authority to make the final go/no-go decision. They can approve spend, accelerate deals, or kill them. It is critical to understand the EB’s priorities, as they are often broader and may differ from those of your day-to-day contacts.`,
      titleHelp: `The Economic Buyer is the person who holds the budget and has the authority to make the final go/no-go decision. They can approve spend, accelerate deals, or kill them. It is critical to understand the EB’s priorities, as they are often broader and may differ from those of your day-to-day contacts.`,
      statusHelp: `MEDDPICC confidence level for Economic Buyer. 2 - Known and Confirmed means you have met and engaged the person who controls the budget for this deal.` },
    { id: 'D1', letter: 'D', label: 'Decision Criteria', shortLabel: 'Dec. Criteria', field: 'MEDDPICC_Decision_Criteria_Status__c', contentField: 'MEDDPICC_Decision_Criteria__c', contentHint: 'notes',
      desc: `Decision Criteria are the standards and requirements the customer uses to evaluate and compare solutions. There are 4 types: Business, Technical, Commercial, and Political. If you don't know the criteria, you can't shape them in your favor. Your Champion can help you influence the criteria early.`,
      titleHelp: `Decision Criteria are the standards and requirements the customer uses to evaluate and compare solutions. There are 4 types: Business, Technical, Commercial, and Political. If you don't know the criteria, you can't shape them in your favor. Your Champion can help you influence the criteria early.`,
      statusHelp: `MEDDPICC confidence level for Decision Criteria. 2 - Known and Confirmed means you have the customer's documented evaluation criteria.` },
    { id: 'D2', letter: 'D', label: 'Decision Process', shortLabel: 'Dec. Process', field: 'MEDDPICC_Decision_Process_Status__c', contentField: 'MEDDPICC_Decision_Process__c', contentHint: 'notes',
      desc: `The Decision Process is the series of steps, stakeholders, and timeline the customer will follow to go from evaluation to a final decision. "We'll review this internally" is NOT a process - you need specifics. Hidden steps and unknown stakeholders cause deals to stall or die.`,
      titleHelp: `The Decision Process is the series of steps, stakeholders, and timeline the customer will follow to go from evaluation to a final decision. "We'll review this internally" is NOT a process - you need specifics. Hidden steps and unknown stakeholders cause deals to stall or die.`,
      statusHelp: `MEDDPICC confidence level for Decision Process. 2 - Known and Confirmed means you have mapped all steps, approvers, and timing to close.` },
    { id: 'P', letter: 'P', label: 'Paper Process', shortLabel: 'Paper Proc.', field: 'MEDDPICC_Paper_Process_Status__c', contentField: 'MEDDPICC_Paper_Process__c', contentHint: 'notes',
      desc: `The Paper Process is everything that happens between a decision being made and the contract being signed. It covers legal review, procurement, approvals, and execution. This is where deals die or slip quarter after quarter. If you don't proactively manage it, internal bureaucracy will manage it for you.`,
      titleHelp: `The Paper Process is everything that happens between a decision being made and the contract being signed. It covers legal review, procurement, approvals, and execution. This is where deals die or slip quarter after quarter. If you don't proactively manage it, internal bureaucracy will manage it for you.`,
      statusHelp: `MEDDPICC confidence level for Paper Process. 2 - Known and Confirmed means you have a complete map of all steps and estimated timelines to get the SOF fully executed.` },
    { id: 'I', letter: 'I', label: 'Identify Pain', shortLabel: 'Identify Pain', field: 'MEDDPICC_Pain_Status__c', contentField: 'MEDDPICC_Pain__c', contentHint: 'notes',
      desc: `Identify Pain is the process of identifying, indicating, and implicating pain. It means uncovering not just the surface problem, but the deeper business consequences if the problem is not solved. The sequence is: Why Change → Why Now → Why You.`,
      titleHelp: ``,
      statusHelp: `MEDDPICC confidence level for Identify Pain. 2 - Known and Confirmed means the customer has explicitly articulated the pain and agreed it is the primary driver for this deal.` },
    { id: 'C1', letter: 'C', label: 'Champion', shortLabel: 'Champion', field: 'MEDDPICC_Champion_Status__c', contentField: 'MEDDPICC_Champion__c', contentHint: 'contact',
      desc: `A Champion has PIC - Power, Influence, and Credibility within the customer's organization. They actively sell on your behalf internally because your solution helps them achieve their goals. A true Champion fights for you even when you're not in the room. Without a Champion, you're relying on hope, not strategy.`,
      titleHelp: `Who is actively selling this deal internally on your behalf? What is their personal stake in it succeeding, and do they have access to the Economic Buyer?`,
      statusHelp: `MEDDPICC confidence level for Champion. 2 - Known and Confirmed means you have met them and they have actively supported your deal.` },
    { id: 'C2', letter: 'C', label: 'Competition', shortLabel: 'Competition', field: 'MEDDPICC_Competition_Status__c', contentField: 'MEDDPICC_Competition__c', contentHint: 'notes',
      desc: `Competition is any competing person, vendor, initiative, or the status quo that threatens to win the deal instead of you. If you don't know who or what you're competing against, you can't position effectively. The #1 competitor is almost always the status quo (doing nothing). Competition shapes how you differentiate and what stories you tell.`,
      titleHelp: `Competition is any competing person, vendor, initiative, or the status quo that threatens to win the deal instead of you. If you don't know who or what you're competing against, you can't position effectively. The #1 competitor is almost always the status quo (doing nothing). Competition shapes how you differentiate and what stories you tell.`,
      statusHelp: `MEDDPICC confidence level for Competition. 2 - Known and Confirmed means you have verified who the competitors are and have a clear counter-strategy.` },
];

// Stakeholder roles tracked via OCR - drives E and C1 bubble fill
const KEY_ROLES = [
    { value: 'Economic Buyer', short: 'Economic Buyer', letter: 'E', hint: 'CFO / Budget Owner' },
    { value: 'Champion',       short: 'Champion',       letter: 'C', hint: 'Internal Champion'  },
];

const ROLE_OPTIONS = [
    'Business User','Champion','Decision Maker','Economic Buyer','Economic Decision Maker',
    'Evaluator','Executive Sponsor','Influencer','Technical Buyer','Other',
].map(v => ({ label: v, value: v }));

const ENGAGEMENT_MAP = {
    'Not Yet Contacted': { color: '#9CA3AF', bg: '#F3F4F6', label: 'Not Contacted' },
    'In Discussion':     { color: '#D97706', bg: '#FFFBEB', label: 'In Discussion' },
    'Supportive':        { color: '#059669', bg: '#ECFDF5', label: 'Supportive'    },
    'Neutral':           { color: '#6B7280', bg: '#F9FAFB', label: 'Neutral'       },
    'Resistant':         { color: '#DC2626', bg: '#FEF2F2', label: 'Resistant'     },
};

const MEDDPICC_STATUS_OPTIONS = [
    { label: 'Unknown',               value: '0 - Unknown'               },
    { label: 'Known but Unconfirmed', value: '1 - Known but Unconfirmed' },
    { label: 'Known and Confirmed',   value: '2 - Known and Confirmed'   },
];

const METRIC_CATEGORY_OPTIONS = [
    'Revenue Growth','Cost Reduction','Risk Mitigation','Compliance',
    'Productivity','Customer Experience','Scalability','Time to Market',
    'Competitive Advantage','Digital Transformation',
].map(v => ({ label: v, value: v }));

const DC_OPTIONS = [
    'Price / Commercial Terms','Technical Fit','Vendor Stability',
    'Implementation Timeline','References / Track Record','Compliance & Security',
    'Support Model','Scalability','Integration Capability','Innovation & Roadmap',
].map(v => ({ label: v, value: v }));

const DP_STAGES = [
    'RFP / RFI','Internal Evaluation','Shortlisting','Procurement Review',
    'Legal Review','Finance Approval','Board / Executive Sign-off','Final Decision',
].map(v => ({ label: v, value: v }));

const PP_STEPS = [
    'Procurement Review','Legal / MSA Negotiation','Security Review','Vendor Onboarding',
    'PO Creation','DocuSign Routing','Finance Approval','IT Approval','Fiscal Year Cutoff Check',
].map(v => ({ label: v, value: v }));

const AVATAR_COLORS = ['#2563EB','#7C3AED','#DC2626','#D97706','#0891B2','#059669','#C026D3'];

function normalizeMeddpiccStatus(value) {
    return (value ?? '').replace(/^[0-2]\s-\s/, '');
}

function meddpiccStatusScore(value) {
    const status = normalizeMeddpiccStatus(value);
    if (status === 'Known and Confirmed') return 2;
    if (status === 'Known but Unconfirmed') return 1;
    return 0;
}

function meddpiccStatusOptionValue(value) {
    const status = normalizeMeddpiccStatus(value);
    if (status === 'Known and Confirmed') return '2 - Known and Confirmed';
    if (status === 'Known but Unconfirmed') return '1 - Known but Unconfirmed';
    return status === 'Unknown' ? '0 - Unknown' : (value ?? '');
}

export default class DealHealthPanel extends NavigationMixin(LightningElement) {

    @api recordId;

    // ── Internal tab visibility (profile-gated) ────────────────────────
    @track _canViewInternal = false;

    @wire(canViewInternalTab)
    _wireCanViewInternal({ data }) {
        if (data !== undefined) this._canViewInternal = data;
    }

    get showInternalTab() { return this._canViewInternal; }

    // ── Mode toggle ──────────────────────────────────────────────────
    @track _mode               = 'external';
    @track _showSP2            = false;
    @track _showSP3            = false;
    @track _dealTeamCollapsed   = true;
    @track _bookingCollapsed    = true;
    @track _forecastCollapsed   = true;
    @track _meddpiccCollapsed   = false;

    get isExternal() { return this._mode === 'external'; }
    get isInternal() { return this._mode === 'internal'; }
    get btnExtClass() { return `dhp-mode-btn${this._mode === 'external' ? ' dhp-mode-btn--on' : ''}`; }
    get btnIntClass() { return `dhp-mode-btn${this._mode === 'internal' ? ' dhp-mode-btn--on' : ''}`; }

    handleModeExt() { this._mode = 'external'; this._closeAllForms(); }
    handleModeInt() { if (!this._canViewInternal) return; this._mode = 'internal'; this._closeAllForms(); }
    handleToggleDealTeam()   { this._dealTeamCollapsed  = !this._dealTeamCollapsed; }
    handleToggleBooking()    { this._bookingCollapsed   = !this._bookingCollapsed; }
    handleToggleForecast()   { this._forecastCollapsed  = !this._forecastCollapsed; }
    handleToggleMeddpicc()   { this._meddpiccCollapsed  = !this._meddpiccCollapsed; }
    get dealTeamChevron()    { return this._dealTeamCollapsed  ? '▸' : '▾'; }
    get bookingChevron()     { return this._bookingCollapsed   ? '▸' : '▾'; }
    get forecastChevron()    { return this._forecastCollapsed  ? '▸' : '▾'; }
    get meddpiccChevron()    { return this._meddpiccCollapsed  ? '▸' : '▾'; }

    // ── SP local pct state (auto-fill + real-time commission) ────────
    @track _sp1Split = null;
    @track _sp1QR    = null;
    @track _sp2Split = null;
    @track _sp2QR    = null;
    @track _sp3Split = null;
    @track _sp3QR    = null;

    // ── Booking local state (real-time commission metrics) ────────────
    @track _localBookingAmt = null;
    @track _localCommPct    = null;

    _syncSpPcts() {
        this._sp1Split        = this._opp?.SP1_Split_Pct__c       ?? null;
        this._sp1QR           = this._opp?.SP1_QR_Pct__c          ?? null;
        this._sp2Split        = this._opp?.SP2_Split_Pct__c       ?? null;
        this._sp2QR           = this._opp?.SP2_QR_Pct__c          ?? null;
        this._sp3Split        = this._opp?.SP3_Split_Pct__c       ?? null;
        this._sp3QR           = this._opp?.SP3_QR_Pct__c          ?? null;
        this._localBookingAmt = this._opp?.Booking_Amount__c      ?? null;
        this._localCommPct    = this._opp?.Commission_Pct__c      ?? null;
    }

    // ── SP visibility ────────────────────────────────────────────────
    get showSP2()    { return this._showSP2  || !!this._opp?.Salesperson_2__c; }
    get showSP3()    { return this._showSP3  || !!this._opp?.Salesperson_3__c; }
    get showAddSP2() { return !this.showSP2; }
    get showAddSP3() { return this.showSP2 && !this.showSP3; }

    handleShowSP2() {
        this._showSP2 = true;
        if (this._sp2Split == null) {
            // Auto-fill: equal split between SP1 and SP2
            this._sp1Split = 50;
            this._sp1QR    = this._sp1QR ?? 50;
            this._sp2Split = 50;
            this._sp2QR    = 50;
        }
    }

    handleShowSP3() {
        this._showSP3 = true;
        if (this._sp3Split == null) {
            // Auto-fill: equal three-way split
            this._sp1Split = 34;
            this._sp1QR    = 34;
            this._sp2Split = 33;
            this._sp2QR    = 33;
            this._sp3Split = 33;
            this._sp3QR    = 33;
        }
    }

    handleSP1SplitChange(e) { this._sp1Split = Number(e.detail.value); }
    handleSP1QRChange(e)    { this._sp1QR    = Number(e.detail.value); }
    handleSP2SplitChange(e) { this._sp2Split = Number(e.detail.value); }
    handleSP2QRChange(e)    { this._sp2QR    = Number(e.detail.value); }
    handleSP3SplitChange(e) { this._sp3Split = Number(e.detail.value); }
    handleSP3QRChange(e)    { this._sp3QR    = Number(e.detail.value); }

    handleBookingAmountChange(e) { this._localBookingAmt = Number(e.detail.value) || null; }
    handleCommPctChange(e)       { this._localCommPct    = Number(e.detail.value) || null; }

    // ── Per-rep commission metrics (shown inside each SP block) ──────
    // Quota Credit  = Booking Amount × rep's QR%   → their quota contribution
    // Commission    = Booking Amount × rep's Split% × deal Commission%
    _perRepMetrics(splitPct, qrPct) {
        if (!this._opp) return null;
        const base = this._localBookingAmt ?? this._opp?.Booking_Amount__c
                   ?? this._opp?.MRC__c;
        const commPct  = this._localCommPct ?? this._opp?.Commission_Pct__c ?? 100;
        const currency = this._opp?.CurrencyIsoCode || 'USD';
        const fmt = amt => new Intl.NumberFormat('en-US', {
            style: 'currency', currency, maximumFractionDigits: 0
        }).format(Math.round(amt));
        if (!base) {
            return { quotaCredit: null, commEligible: null, hint: 'Set MRC or Booking Amount' };
        }
        const missing = [];
        if (qrPct == null)    missing.push('QR %');
        if (splitPct == null) missing.push('Split %');
        return {
            quotaCredit:  qrPct    != null ? fmt(base * qrPct    / 100) : null,
            commEligible: splitPct != null ? fmt(base * splitPct / 100 * commPct / 100) : null,
            hint:         missing.length ? `Set ${missing.join(' and ')}` : null,
        };
    }
    get sp1Metrics() {
        return this._perRepMetrics(
            this._sp1Split ?? this._opp?.SP1_Split_Pct__c,
            this._sp1QR    ?? this._opp?.SP1_QR_Pct__c
        );
    }
    get sp2Metrics() {
        return this._perRepMetrics(
            this._sp2Split ?? this._opp?.SP2_Split_Pct__c,
            this._sp2QR    ?? this._opp?.SP2_QR_Pct__c
        );
    }
    get sp3Metrics() {
        return this._perRepMetrics(
            this._sp3Split ?? this._opp?.SP3_Split_Pct__c,
            this._sp3QR    ?? this._opp?.SP3_QR_Pct__c
        );
    }

    // ── Commission display ───────────────────────────────────────────
    _commLine(pct) {
        if (!pct) return null;
        const mrc      = this._opp?.MRC__c;
        const nrc      = this._opp?.NRC__c;
        const currency = this._opp?.CurrencyIsoCode || 'USD';
        const method   = this._opp?.Commission_Payout_Method__c;
        if (!mrc && !nrc) return `${pct}% split`;
        const fmt = (amt) => new Intl.NumberFormat('en-US', {
            style: 'currency', currency, maximumFractionDigits: 0
        }).format(Math.round(amt));
        const mrcAmt = mrc ? `${fmt(mrc * pct / 100)}/mo` : null;
        if (method === 'Upfront') {
            const nrcPart = nrc ? ` + ${fmt(nrc * pct / 100)} NRC` : '';
            return mrcAmt ? `${pct}% → ${mrcAmt} MRC${nrcPart} (upfront)` : `${pct}% split`;
        }
        if (method === 'Back-End') {
            return mrcAmt ? `${pct}% → ${mrcAmt} (back-end)` : `${pct}% split`;
        }
        return mrcAmt ? `${pct}% → ${mrcAmt}` : `${pct}% split`;
    }
    // Commission lines read from live tracked state so display updates as user types
    get sp1CommLine()      { return this._commLine(this._sp1Split ?? this._opp?.SP1_Split_Pct__c); }
    get sp2CommLine()      { return this._commLine(this._sp2Split ?? this._opp?.SP2_Split_Pct__c); }
    get sp3CommLine()      { return this._commLine(this._sp3Split ?? this._opp?.SP3_Split_Pct__c); }
    get splitTotal()       {
        return (this._sp1Split ?? this._opp?.SP1_Split_Pct__c ?? 0)
             + (this._sp2Split ?? this._opp?.SP2_Split_Pct__c ?? 0)
             + (this._sp3Split ?? this._opp?.SP3_Split_Pct__c ?? 0);
    }
    get splitTotalLabel()  {
        const t = this.splitTotal;
        if (!t) return null;
        return `Splits total ${t}%${t === 100 ? ' ✓' : ''}`;
    }
    get splitTotalClass()  {
        return this.splitTotal === 100
            ? 'dhp-split-total dhp-split-total--ok'
            : 'dhp-split-total dhp-split-total--warn';
    }

    handleFileUpload() { this._toast('Uploaded', 'Document attached to deal.', 'success'); }

    // ── Wire ─────────────────────────────────────────────────────────
    @track _wiredHealth;
    @track _opp;
    @track _roles = [];
    @track _allContacts = [];
    _accountContacts = [];

    @wire(getDealHealth, { opportunityId: '$recordId' })
    _wireHealth(result) {
        this._wiredHealth = result;
        if (result.data) {
            this._opp   = result.data.opp;
            this._roles = result.data.roles || [];
            this._syncSpPcts();
            this._syncMeddpiccLookups();
            this._mergeContacts();
        }
    }

    // Proactively write Economic_Buyer__c / Champion__c when they were set via flow
    // (the flow creates the OCR but doesn't update the lookup field on Opportunity).
    _syncMeddpiccLookups() {
        const updates = [];
        const eb = this._roles.find(r => r.Role === 'Economic Buyer');
        if (eb?.ContactId && !this._opp?.MEDDPICC_Economic_Buyer__c) {
            updates.push({ fieldName: 'MEDDPICC_Economic_Buyer__c', status: eb.ContactId });
        }
        const champ = this._roles.find(r => r.Role === 'Champion');
        if (champ?.ContactId && !this._opp?.MEDDPICC_Champion__c) {
            updates.push({ fieldName: 'MEDDPICC_Champion__c', status: champ.ContactId });
        }
        if (updates.length === 0) return;
        Promise.all(updates.map(u => updateMeddpiccStatusField({ opportunityId: this.recordId, ...u })))
            .then(() => {
                refreshApex(this._wiredHealth);
                getRecordNotifyChange([{ recordId: this.recordId }]);
            })
            .catch(err => {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Contact role sync failed',
                    message: err.body?.message ?? 'Could not sync contact roles to opportunity fields.',
                    variant: 'error'
                }));
            });
    }

    @wire(getAccountContacts, { opportunityId: '$recordId' })
    _wireContacts({ data, error }) {
        if (data) {
            this._accountContacts = data.map(c => ({
                label: c.Name + (c.Title ? ` · ${c.Title}` : ''),
                value: c.Id,
            }));
        } else if (error) {
            this._accountContacts = [];
        }
        this._mergeContacts();
    }

    /** Merge account contacts with contacts already in Contact Roles. */
    _mergeContacts() {
        const map = new Map();
        this._accountContacts.forEach(c => map.set(c.value, c));
        (this._roles || []).forEach(r => {
            if (r.ContactId && !map.has(r.ContactId)) {
                const name = r.Contact?.Name || 'Unknown';
                map.set(r.ContactId, {
                    label: name + (r.Contact?.Title ? ` · ${r.Contact.Title}` : ''),
                    value: r.ContactId,
                });
            }
        });
        this._allContacts = [...map.values()].sort((a, b) => a.label.localeCompare(b.label));
    }

    // ── Header ───────────────────────────────────────────────────────
    get stageName()     { return this._opp?.StageName ?? '-'; }
    get ownerName()     { return this._opp?.Owner?.Name ?? '-'; }
    get ownerInitials() {
        return (this._opp?.Owner?.Name ?? 'OW')
            .split(' ').map(w => w[0] || '').join('').toUpperCase().slice(0, 2);
    }

    // ── MEDDPICC score ───────────────────────────────────────────────
    // All 8 dimensions score 0-2 from their status picklist:
    //   Known but Unconfirmed = 1, Known and Confirmed = 2, else 0.
    // Economic Buyer & Champion additionally require the person to actually be on
    //   the deal — i.e. a matching OpportunityContactRole. Remove the stakeholder
    //   and the dimension goes to 0 / grey even if the status still says Confirmed.
    //   The lookup field is NOT consulted (it is never cleared, so it goes stale).
    // Max score = 8 dims x 2 = 16.

    // EB & Champion only: is the person still on the deal as a contact role?
    _meddpiccRolePresent(item) {
        const roleKey = item.id === 'E' ? 'Economic Buyer' : 'Champion';
        return this._roles.some(r => r.Role === roleKey);
    }

    _meddpiccBothFilled(item) {
        const scored = meddpiccStatusScore(this._opp?.[item.field]) > 0;
        if (item.id === 'E' || item.id === 'C1') {
            return scored && this._meddpiccRolePresent(item);
        }
        return scored;
    }

    get meddpiccScore() {
        return MEDDPICC_ITEMS.reduce((total, item) => (
            this._meddpiccBothFilled(item)
                ? total + meddpiccStatusScore(this._opp?.[item.field])
                : total
        ), 0);
    }

    get donutLabel() { return `${this.meddpiccScore}/16`; }
    get donutArcStyle() {
        const circ  = 97;
        const score = this.meddpiccScore;
        const fill  = Math.round((score / 16) * circ);
        const p     = score / 16;
        const color = p >= 0.875 ? '#34D399' : p >= 0.5 ? '#38BDF8' : score > 0 ? '#FB923C' : 'rgba(255,255,255,0.2)';
        return `stroke:${color};stroke-dasharray:${fill} ${circ};`;
    }

    // ── MEDDPICC items (used by score chips) ─────────────────────────
    get meddpiccItems() {
        return MEDDPICC_ITEMS.map(item => {
            const val           = this._opp?.[item.field] ?? '';
            const score         = this._meddpiccBothFilled(item) ? meddpiccStatusScore(val) : 0;
            const isConfirmed   = score === 2;
            const isUnconfirmed = score === 1;
            const letterColor   = isConfirmed ? '#059669' : isUnconfirmed ? '#D97706' : '#9CA3AF';
            const chipBg        = isConfirmed ? '#D1FAE5' : isUnconfirmed ? '#FEF3C7' : '#F3F4F6';
            return { ...item, val, chipStyle: `color:${letterColor};background:${chipBg};`, tooltip: `${item.label}: ${normalizeMeddpiccStatus(val) || 'Not Set'}` };
        });
    }
    get meddpiccPriority()    { const g = this.meddpiccItems.find(i => !this._meddpiccBothFilled(i)); return g ? `Next: qualify ${g.label}` : null; }
    get hasMeddpiccPriority() { return !!this.meddpiccPriority; }

    // ── 8-circle MEDDPICC bubble row ─────────────────────────────────
    // Colour comes from the status picklist: Known and Confirmed (2) = green,
    //   Known but Unconfirmed (1) = orange, else empty.
    // EB/Champion additionally need a matching contact role — remove the person
    //   from the deal and the bubble empties regardless of the leftover status.
    //   The lookup field is never read.
    get meddpiccBubbles() {
        const roleIdxMap = {};
        this._roles.forEach((r, i) => { roleIdxMap[r.Role] = i; });

        return MEDDPICC_ITEMS.map(item => {
            const statusVal     = this._opp?.[item.field] ?? '';
            const isContactItem = item.id === 'E' || item.id === 'C1';
            // Gated score: 0 for EB/Champion once the contact role is gone.
            const statusScore   = this._meddpiccBothFilled(item) ? meddpiccStatusScore(statusVal) : 0;
            const isConfirmed   = statusScore === 2;
            const isUnconfirmed = statusScore === 1;
            const statusActive  = meddpiccStatusScore(statusVal) > 0;
            let bubbleStyle, wrapClass, hoverLabel;

            // Content fill check — drives the guidance text.
            // EB/Champion: the contact role IS the content; the lookup is ignored.
            let contentFilled;
            if (isContactItem) {
                contentFilled = this._meddpiccRolePresent(item);
            } else {
                contentFilled = !!(this._opp?.[item.contentField]);
            }

            // Guidance text: what's still needed to score this dimension
            let guidance, guidanceClass;
            if (contentFilled && statusActive) {
                guidance = '';
                guidanceClass = '';
            } else if (!contentFilled && !statusActive) {
                guidance = `Add ${item.contentHint} + status`;
                guidanceClass = 'shp-guidance shp-guidance--missing';
            } else if (!contentFilled) {
                guidance = `Add ${item.contentHint}`;
                guidanceClass = 'shp-guidance shp-guidance--missing';
            } else {
                guidance = 'Set status';
                guidanceClass = 'shp-guidance shp-guidance--missing';
            }

            // Colour: from status, but already zeroed above for EB/Champion with no contact role.
            if (isConfirmed) {
                bubbleStyle = 'background:#059669;color:#fff;box-shadow:0 2px 8px #05996944;';
                wrapClass   = 'shp-bubble shp-bubble--filled';
            } else if (isUnconfirmed) {
                bubbleStyle = 'background:#D97706;color:#fff;box-shadow:0 2px 8px #D9770644;';
                wrapClass   = 'shp-bubble shp-bubble--filled';
            } else {
                bubbleStyle = 'background:transparent;color:#9CA3AF;';
                wrapClass   = 'shp-bubble shp-bubble--empty';
            }

            // Hover: EB/Champion name the stakeholder from the contact role when there is one.
            if (isContactItem) {
                const roleKey = item.id === 'E' ? 'Economic Buyer' : 'Champion';
                const idx     = roleIdxMap[roleKey] ?? -1;
                const match   = idx >= 0 ? this._roles[idx] : null;
                if (match) {
                    const eng  = ENGAGEMENT_MAP[match.Engagement_Status__c ?? 'Not Yet Contacted'];
                    hoverLabel = `${match.Contact?.Name ?? ''} · ${eng.label}`;
                } else {
                    hoverLabel = `Add ${item.label}`;
                }
            } else {
                hoverLabel = `${item.label}: ${normalizeMeddpiccStatus(statusVal) || 'Not Set'}`;
            }
            return { ...item, statusVal, bubbleStyle, wrapClass, hoverLabel, guidance, guidanceClass };
        });
    }

    // ── MEDDPICC help text + descriptions (driven by MEDDPICC_ITEMS) ──
    get _activeContentId() {
        if (this._showMetricForm) return 'M';
        if (this._showD1Form)     return 'D1';
        if (this._showD2Form)     return 'D2';
        if (this._showPForm)      return 'P';
        if (this._showIForm)      return 'I';
        if (this._showC2Form)     return 'C2';
        return null;
    }
    _meddById(id) { return MEDDPICC_ITEMS.find(i => i.id === id) || null; }
    get activeFormDesc()       { const i = this._meddById(this._activeContentId); return i ? i.desc : ''; }
    get activeFormTitleHelp()  { const i = this._meddById(this._activeContentId); return i ? i.titleHelp : ''; }
    get activeFormStatusHelp() { const i = this._meddById(this._activeContentId); return i ? i.statusHelp : ''; }
    get _activeStakeId() {
        const role = this._addRole || this._popupRole;
        if (role === 'Economic Buyer') return 'E';
        if (role === 'Champion')       return 'C1';
        return null;
    }
    get activeStakeDesc()       { const i = this._meddById(this._activeStakeId); return i ? i.desc : ''; }
    get activeStakeTitleHelp() { const i = this._meddById(this._activeStakeId); return i ? i.titleHelp : ''; }
    get activeStakeStatusHelp() { const i = this._meddById(this._activeStakeId); return i ? i.statusHelp : ''; }

    // ── Coverage badge (E and C1 OCR coverage) ───────────────────────
    get roleCoverage() {
        return KEY_ROLES.map(kr => {
            const roleIdx    = this._roles.findIndex(r => r.Role === kr.value);
            const match      = roleIdx >= 0 ? this._roles[roleIdx] : null;
            const covered    = !!match;
            const eng        = ENGAGEMENT_MAP[match?.Engagement_Status__c ?? 'Not Yet Contacted'];
            const avatarColor = AVATAR_COLORS[roleIdx >= 0 ? roleIdx % AVATAR_COLORS.length : 0];
            return {
                ...kr,
                id: kr.value, covered,
                displayText: kr.letter,
                hoverLabel:  covered ? `${match.Contact?.Name ?? ''} · ${eng.label}` : `Add ${kr.short} - ${kr.hint}`,
                bubbleStyle: covered ? `background:${avatarColor};color:#fff;box-shadow:0 2px 8px ${avatarColor}44;` : 'background:transparent;color:#9CA3AF;',
                wrapClass:   `shp-bubble${covered ? ' shp-bubble--filled' : ' shp-bubble--empty'}`,
            };
        });
    }
    get coveredCount()  { return this.roleCoverage.filter(r => r.covered).length; }
    get coverageLabel() { return `${this.coveredCount}/${KEY_ROLES.length} covered`; }
    get coverageClass() {
        const p = this.coveredCount / KEY_ROLES.length;
        return p === 1 ? 'shp-cov-badge shp-cov-badge--full' : p > 0 ? 'shp-cov-badge shp-cov-badge--mid' : 'shp-cov-badge shp-cov-badge--low';
    }

    // ── Unified MEDDPICC bubble click ────────────────────────────────
    handleMeddpiccBubbleClick(e) {
        const id = e.currentTarget.dataset.id;

        // E and C1 - stakeholder role bubbles
        if (id === 'E' || id === 'C1') {
            const roleKey = id === 'E' ? 'Economic Buyer' : 'Champion';
            const match   = this._roles.find(r => r.Role === roleKey);
            if (match) {
                this._closeAllForms();
                const meddpiccFieldMap = { 'Economic Buyer': 'MEDDPICC_Economic_Buyer_Status__c', 'Champion': 'MEDDPICC_Champion_Status__c' };
                const statusField = meddpiccFieldMap[roleKey];
                this._popupRole                = roleKey;
                this._popupRoleId              = match.Id;
                this._popupContactId           = match.ContactId;
                this._popupContactName         = match.Contact?.Name  ?? '';
                this._popupContactTitle        = match.Contact?.Title ?? '';
                this._popupRoleVal             = match.Role                 ?? '';
                this._popupEngVal              = match.Engagement_Status__c ?? 'Not Yet Contacted';
                this._popupMeddpiccStatusField = statusField;
                this._popupMeddpiccStatus      = this._opp?.[statusField] ?? '';
            } else {
                this._closeAllForms();
                this._addRole         = roleKey;
                this._addMeddpiccStatusField = DealHealthPanel._MEDDPICC_ROLE_FIELD_MAP[roleKey] || '';
                this._addMeddpiccStatus      = '';
                this._addContactId    = '';
                this._addContactLabel = '';
                this._addStatus       = 'Not Yet Contacted';
                this._showNewContact  = false;
                this._contactSelected = false;
                this._cptSearch       = '';
                this.showAddForm      = true;
            }
            return;
        }

        // Content bubbles - toggle form; auto-save if already open
        const formMap = { M: '_showMetricForm', D1: '_showD1Form', D2: '_showD2Form', P: '_showPForm', I: '_showIForm', C2: '_showC2Form' };
        const saveMap = { M: () => this.handleSaveMetric(), D1: () => this.handleSaveD1(), D2: () => this.handleSaveD2(), P: () => this.handleSaveP(), I: () => this.handleSaveI(), C2: () => this.handleSaveC2() };
        const formKey = formMap[id];
        if (!formKey) return;
        const wasOpen = this[formKey];
        if (wasOpen) {
            // clicking the bubble while the form is open saves then closes
            saveMap[id]();
            return;
        }
        this._closeAllForms();
        this._initMeddpiccForm(id);
        this[formKey] = true;
    }

    _closeAllForms() {
        this.showAddForm     = false;
        this._popupRole      = '';
        this._showMetricForm = false;
        this._showD1Form     = false;
        this._showD2Form     = false;
        this._showPForm      = false;
        this._showIForm      = false;
        this._showC2Form     = false;
    }

    _initMeddpiccForm(id) {
        if (id === 'M') {
            const catStr = this._opp?.Metric_Category__c ?? '';
            this._metricCategories = catStr ? catStr.split(';').map(s => s.trim()).filter(Boolean) : [];
            this._metricDesc   = this._opp?.MEDDPICC_Metrics__c        ?? '';
            this._metricStatus = meddpiccStatusOptionValue(this._opp?.MEDDPICC_Metrics_Status__c);
        } else if (id === 'D1') {
            const optStr = this._opp?.Decision_Criteria_Options__c ?? '';
            this._d1Options = optStr ? optStr.split(';').map(s => s.trim()).filter(Boolean) : [];
            this._d1Desc    = this._opp?.MEDDPICC_Decision_Criteria__c        ?? '';
            this._d1Status  = meddpiccStatusOptionValue(this._opp?.MEDDPICC_Decision_Criteria_Status__c);
        } else if (id === 'D2') {
            const stagesStr = this._opp?.Decision_Process_Stages__c ?? '';
            this._d2Stages = stagesStr ? stagesStr.split(';').map(s => s.trim()).filter(Boolean) : [];
            this._d2Desc   = this._opp?.MEDDPICC_Decision_Process__c        ?? '';
            this._d2Status = meddpiccStatusOptionValue(this._opp?.MEDDPICC_Decision_Process_Status__c);
        } else if (id === 'P') {
            const stepsStr = this._opp?.Paper_Process_Steps__c ?? '';
            this._pSteps  = stepsStr ? stepsStr.split(';').map(s => s.trim()).filter(Boolean) : [];
            this._pDesc   = this._opp?.MEDDPICC_Paper_Process__c        ?? '';
            this._pStatus = meddpiccStatusOptionValue(this._opp?.MEDDPICC_Paper_Process_Status__c);
        } else if (id === 'I') {
            this._iDesc   = this._opp?.MEDDPICC_Pain__c        ?? '';
            this._iStatus = meddpiccStatusOptionValue(this._opp?.MEDDPICC_Pain_Status__c);
        } else if (id === 'C2') {
            this._c2AccountId   = this._opp?.Competitor_Account__c        ?? '';
            this._c2AccountName = this._opp?.Competitor_Account__r?.Name  ?? '';
            this._c2AccountSelected = !!this._opp?.Competitor_Account__c;
            this._c2AccountSearch   = '';
            this._c2AccountResults  = [];
            this._c2Desc   = this._opp?.MEDDPICC_Competition__c        ?? '';
            this._c2Status = meddpiccStatusOptionValue(this._opp?.MEDDPICC_Competition_Status__c);
        }
    }

    // ── Add form ──────────────────────────────────────────────────────
    @track showAddForm           = false;
    @track _addContactId         = '';
    @track _addContactLabel      = '';
    @track _addRole              = '';
    @track _addStatus            = 'Not Yet Contacted';
    @track _addMeddpiccStatus    = '';
    @track _addMeddpiccStatusField = '';
    @track _addReportsToId       = '';
    @track _saving               = false;
    @track _contactSelected      = false;
    @track _showNewContact       = false;
    @track _ncFirst = '';
    @track _ncLast  = '';
    @track _ncTitle = '';
    @track _ncEmail = '';
    @track _cptSearch = '';

    static _MEDDPICC_ROLE_FIELD_MAP = { 'Economic Buyer': 'MEDDPICC_Economic_Buyer_Status__c', 'Champion': 'MEDDPICC_Champion_Status__c' };
    static _MEDDPICC_ROLE_LOOKUP_MAP = { 'Economic Buyer': 'MEDDPICC_Economic_Buyer__c', 'Champion': 'MEDDPICC_Champion__c' };

    get showAddMeddpiccStatus()    { return !!DealHealthPanel._MEDDPICC_ROLE_FIELD_MAP[this._addRole]; }
    get addMeddpiccStatusLabel()   { return this._addRole ? `${this._addRole} Status` : 'Status'; }
    get reportsToOptions()         {
        const opts = [{ label: '-- None --', value: '' }];
        this._allContacts.forEach(c => {
            if (c.value !== this._addContactId) opts.push(c);
        });
        return opts;
    }

    get cptSearch()           { return this._cptSearch; }
    get cptFilteredContacts() {
        if (!this._cptSearch || this._cptSearch.length < 2) return [];
        const q = this._cptSearch.toLowerCase();
        return this._allContacts.filter(c => c.label.toLowerCase().includes(q)).slice(0, 20);
    }
    get cptHasResults()     { return this.cptFilteredContacts.length > 0; }
    get cptNoResults()      { return this._cptSearch.length >= 2 && !this.cptHasResults; }
    get cptShowHint()       { return this._cptSearch.length < 2; }
    get showPickedContact() { return this._contactSelected && !this._showNewContact; }
    get showRoleField()     { return !this._addRole; }
    get addFormTitle()      { return this._addRole ? `Adding: ${this._addRole}` : 'Add Stakeholder'; }
    get roleOptions()       { return ROLE_OPTIONS; }
    get statusOptions()     { return Object.keys(ENGAGEMENT_MAP).map(k => ({ label: k, value: k })); }
    get addRole()           { return this._addRole; }
    get addStatus()         { return this._addStatus; }
    get ncFirst()           { return this._ncFirst; }
    get ncLast()            { return this._ncLast; }
    get ncTitle()           { return this._ncTitle; }
    get ncEmail()           { return this._ncEmail; }
    get saveDisabled() {
        if (this._saving) return true;
        if (this._showNewContact) return !this._ncLast || !this._addRole;
        return !this._addContactId || !this._addRole;
    }
    get saveBtnLabel() { return this._saving ? 'Saving...' : 'Add to Deal'; }

    handleCptSearch(e)    { this._cptSearch = e.detail.value; }
    handlePickContact(e)  {
        this._addContactId    = e.currentTarget.dataset.id;
        this._addContactLabel = e.currentTarget.dataset.label;
        this._contactSelected = true;
        this._cptSearch       = '';
    }
    handleClearContact()  {
        this._addContactId = ''; this._addContactLabel = '';
        this._contactSelected = false; this._showNewContact = false; this._cptSearch = '';
        this._ncFirst = ''; this._ncLast = ''; this._ncTitle = ''; this._ncEmail = '';
    }
    handleAddOpen() {
        this._addRole = ''; this._addContactId = ''; this._addContactLabel = '';
        this._addStatus = 'Not Yet Contacted'; this._showNewContact = false;
        this._contactSelected = false; this._cptSearch = '';
        this._closeAllForms();
        this.showAddForm = true;
    }
    handleAddCancel()         { this.showAddForm = false; this._resetForm(); }
    handleNewContactMode()    { this._showNewContact = true; this._contactSelected = true; this._addContactId = ''; }
    handleAddRoleChange(e) {
        this._addRole = e.detail.value;
        const newField = DealHealthPanel._MEDDPICC_ROLE_FIELD_MAP[this._addRole] || '';
        if (newField !== this._addMeddpiccStatusField) {
            this._addMeddpiccStatus = '';
        }
        this._addMeddpiccStatusField = newField;
    }
    handleAddStatusChange(e)          { this._addStatus = e.detail.value; }
    handleAddMeddpiccStatusChange(e)  { this._addMeddpiccStatus = e.detail.value; }
    handleAddReportsToChange(e)       { this._addReportsToId = e.detail.value; }
    handleNcFirstChange(e)    { this._ncFirst = e.detail.value; }
    handleNcLastChange(e)     { this._ncLast  = e.detail.value; }
    handleNcTitleChange(e)    { this._ncTitle = e.detail.value; }
    handleNcEmailChange(e)    { this._ncEmail = e.detail.value; }

    async handleSaveAdd() {
        if (this.saveDisabled) return;
        this._saving = true;
        try {
            let resolvedContactId = this._addContactId;
            if (this._showNewContact) {
                resolvedContactId = await createContactAndRole({
                    opportunityId: this.recordId, accountId: this._opp?.AccountId,
                    firstName: this._ncFirst, lastName: this._ncLast,
                    title: this._ncTitle, email: this._ncEmail,
                    role: this._addRole, engagementStatus: this._addStatus,
                });
            } else {
                await createContactRole({
                    opportunityId: this.recordId, contactId: this._addContactId,
                    role: this._addRole, engagementStatus: this._addStatus,
                });
            }
            if (this._addMeddpiccStatusField && this._addMeddpiccStatus) {
                await updateMeddpiccStatusField({ opportunityId: this.recordId, fieldName: this._addMeddpiccStatusField, status: this._addMeddpiccStatus });
            }
            const lookupField = DealHealthPanel._MEDDPICC_ROLE_LOOKUP_MAP[this._addRole];
            if (lookupField && resolvedContactId) {
                await updateMeddpiccStatusField({ opportunityId: this.recordId, fieldName: lookupField, status: resolvedContactId });
            }
            if (this._addReportsToId && resolvedContactId) {
                await updateContactReportsTo({ contactId: resolvedContactId, reportsToId: this._addReportsToId });
            }
            this.showAddForm = false;
            this._resetForm();
            await refreshApex(this._wiredHealth);
            getRecordNotifyChange([{ recordId: this.recordId }]);
            this._toast('Stakeholder added', '', 'success');
        } catch (err) {
            this._toast('Error', err.body?.message ?? 'Could not add stakeholder.', 'error');
        } finally {
            this._saving = false;
        }
    }

    // ── Bubble popup (view/edit existing stakeholder) ─────────────────
    @track _popupRole              = '';
    @track _popupRoleId            = '';
    @track _popupContactId         = '';
    @track _popupContactName       = '';
    @track _popupContactTitle      = '';
    @track _popupRoleVal           = '';
    @track _popupEngVal            = '';
    @track _popupMeddpiccStatus    = '';
    @track _popupMeddpiccStatusField = '';
    @track _popupSaving            = false;

    get showBubblePopup()            { return !!this._popupRole; }
    get popupTitle()                 { return this._popupRole ? `Edit: ${this._popupRole}` : ''; }
    get popupMeddpiccStatusLabel()   { return this._popupRole ? `${this._popupRole} Status` : 'Status'; }
    get popupAvatarStyle()  {
        const idx   = this._roles.findIndex(r => r.Id === this._popupRoleId);
        const color = AVATAR_COLORS[idx >= 0 ? idx % AVATAR_COLORS.length : 0];
        return `background:${color};`;
    }
    get popupInitials()     {
        return (this._popupContactName || '').split(' ').map(w => w[0] || '').join('').toUpperCase().slice(0, 2) || '??';
    }
    get popupContactName()  { return this._popupContactName; }
    get popupContactTitle() { return this._popupContactTitle; }
    get popupSaveDisabled() { return this._popupSaving || !this._popupRoleVal; }
    get popupSaveLabel()    { return this._popupSaving ? 'Saving...' : 'Save'; }

    handlePopupClose()                  { this._popupRole = ''; this._popupRoleId = ''; this._popupMeddpiccStatus = ''; this._popupMeddpiccStatusField = ''; this._popupSaving = false; }
    handlePopupRoleChange(e)            { this._popupRoleVal = e.detail.value; }
    handlePopupEngChange(e)             { this._popupEngVal  = e.detail.value; }
    handlePopupMeddpiccStatusChange(e)  { this._popupMeddpiccStatus = e.detail.value; }

    async handlePopupSave() {
        if (this.popupSaveDisabled) return;
        this._popupSaving = true;
        try {
            await updateContactRoleAndEngagement({
                roleId: this._popupRoleId, role: this._popupRoleVal, engagementStatus: this._popupEngVal,
                opportunityId: this.recordId, meddpiccStatusField: this._popupMeddpiccStatusField, meddpiccStatus: this._popupMeddpiccStatus
            });
            if (this._popupMeddpiccStatusField) {
                this._patchLocalOpp({ [this._popupMeddpiccStatusField]: this._popupMeddpiccStatus || null });
            }
            // Role changed AWAY from Economic Buyer / Champion — retire the old dimension
            // so it does not keep scoring for someone who no longer holds that role.
            if (this._popupRole && this._popupRole !== this._popupRoleVal) {
                await this._clearMeddpiccDimension(this._popupRole);
            }
            const lookupField = DealHealthPanel._MEDDPICC_ROLE_LOOKUP_MAP[this._popupRoleVal];
            if (lookupField && this._popupContactId) {
                await updateMeddpiccStatusField({ opportunityId: this.recordId, fieldName: lookupField, status: this._popupContactId });
            }
            this._popupRole = ''; this._popupRoleId = ''; this._popupMeddpiccStatus = ''; this._popupMeddpiccStatusField = '';
            await refreshApex(this._wiredHealth);
            getRecordNotifyChange([{ recordId: this.recordId }]);
            this._toast('Updated', 'Stakeholder updated.', 'success');
        } catch (err) {
            this._toast('Error', err.body?.message ?? 'Update failed.', 'error');
        } finally {
            this._popupSaving = false;
        }
    }

    handlePopupLogTask() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage', attributes: { objectApiName: 'Task', actionName: 'new' },
            state: { defaultFieldValues: encodeDefaultFieldValues({ WhoId: this._popupContactId, WhatId: this.recordId, Subject: `Follow up with ${this._popupContactName}` }) }
        });
        this.handlePopupClose();
    }

    handlePopupEmail() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage', attributes: { objectApiName: 'Task', actionName: 'new' },
            state: { defaultFieldValues: encodeDefaultFieldValues({ WhoId: this._popupContactId, WhatId: this.recordId, Subject: `Email: ${this._popupContactName}`, TaskSubtype: 'Email' }) }
        });
        this.handlePopupClose();
    }

    async handlePopupDelete(e) {
        const id = e.currentTarget.dataset.roleId;
        const removedRole = this._popupRoleVal || this._popupRole;
        try {
            await deleteContactRole({ roleId: id });
            // Removing an Economic Buyer / Champion must also retire the dimension:
            // reset its status and clear the stale lookup, so the formula field agrees
            // with the panel instead of reporting a person who is off the deal.
            await this._clearMeddpiccDimension(removedRole);
            this._popupRole = ''; this._popupRoleId = '';
            await refreshApex(this._wiredHealth);
            getRecordNotifyChange([{ recordId: this.recordId }]);
            this._toast('Removed', 'Stakeholder removed from deal.', 'success');
        } catch (err) {
            this._toast('Error', err.body?.message ?? 'Could not remove.', 'error');
        }
    }

    // Reset the MEDDPICC status + lookup for an EB/Champion role that is no longer
    // on the deal. No-op for every other role. Skipped if another contact still
    // holds the same role on this opportunity.
    async _clearMeddpiccDimension(role) {
        const statusField = DealHealthPanel._MEDDPICC_ROLE_FIELD_MAP[role];
        const lookupField = DealHealthPanel._MEDDPICC_ROLE_LOOKUP_MAP[role];
        if (!statusField) return;
        const stillHeld = (this._roles ?? []).some(r => r.Role === role && r.Id !== this._popupRoleId);
        if (stillHeld) return;
        await updateMeddpiccStatusField({ opportunityId: this.recordId, fieldName: statusField, status: '0 - Unknown' });
        await updateMeddpiccStatusField({ opportunityId: this.recordId, fieldName: lookupField, status: '' });
        this._patchLocalOpp({ [statusField]: '0 - Unknown', [lookupField]: null });
    }

    // ── MEDDPICC forms - shared options ──────────────────────────────
    get meddpiccStatusOptions() { return MEDDPICC_STATUS_OPTIONS; }

    // ── M - Metrics ───────────────────────────────────────────────────
    @track _showMetricForm   = false;
    @track _metricCategories = [];
    @track _metricDesc       = '';
    @track _metricStatus     = '';
    @track _metricSaving     = false;

    get showMetricForm()        { return this._showMetricForm; }
    get metricCategoryOptions() { return METRIC_CATEGORY_OPTIONS; }
    get metricStatusOptions()   { return MEDDPICC_STATUS_OPTIONS; }
    get metricSaveBtnLabel()    { return this._metricSaving ? 'Saving...' : 'Save Metrics'; }
    get metricSaveDisabled()    { return this._metricSaving; }

    handleMetricCancel()         { this._showMetricForm = false; }
    handleMetricCatChange(e)     { this._metricCategories = e.detail.value; }
    handleMetricDescChange(e)    { this._metricDesc   = e.detail.value; }
    handleMetricStatusChange(e)  { this._metricStatus = e.detail.value; }

    async handleSaveMetric() {
        if (this.metricSaveDisabled) return;
        this._metricSaving = true;
        try {
            await updateMetrics({ opportunityId: this.recordId, category: this._metricCategories.join(';'), description: this._metricDesc, status: this._metricStatus });
            this._patchLocalOpp({ Metric_Category__c: this._metricCategories.join(';') || null, MEDDPICC_Metrics__c: this._metricDesc || null, MEDDPICC_Metrics_Status__c: this._metricStatus || null });
            this._showMetricForm = false;
            await refreshApex(this._wiredHealth);
            getRecordNotifyChange([{ recordId: this.recordId }]);
            this._toast('Metrics saved', '', 'success');
        } catch (err) {
            this._toast('Error', err.body?.message ?? 'Save failed.', 'error');
        } finally {
            this._metricSaving = false;
        }
    }

    // ── D1 - Decision Criteria ────────────────────────────────────────
    @track _showD1Form = false;
    @track _d1Options  = [];
    @track _d1Desc     = '';
    @track _d1Status   = '';
    @track _d1Saving   = false;

    get showD1Form()        { return this._showD1Form; }
    get d1OptionsOptions()  { return DC_OPTIONS; }
    get d1SaveBtnLabel()    { return this._d1Saving ? 'Saving...' : 'Save Decision Criteria'; }
    get d1SaveDisabled()    { return this._d1Saving; }

    handleD1Cancel()         { this._showD1Form = false; }
    handleD1OptionsChange(e) { this._d1Options = e.detail.value; }
    handleD1DescChange(e)    { this._d1Desc   = e.detail.value; }
    handleD1StatusChange(e)  { this._d1Status = e.detail.value; }

    async handleSaveD1() {
        if (this.d1SaveDisabled) return;
        this._d1Saving = true;
        try {
            await updateDecisionCriteria({ opportunityId: this.recordId, options: this._d1Options.join(';'), description: this._d1Desc, status: this._d1Status });
            this._patchLocalOpp({ Decision_Criteria_Options__c: this._d1Options.join(';') || null, MEDDPICC_Decision_Criteria__c: this._d1Desc || null, MEDDPICC_Decision_Criteria_Status__c: this._d1Status || null });
            this._showD1Form = false;
            await refreshApex(this._wiredHealth);
            getRecordNotifyChange([{ recordId: this.recordId }]);
            this._toast('Decision Criteria saved', '', 'success');
        } catch (err) {
            this._toast('Error', err.body?.message ?? 'Save failed.', 'error');
        } finally {
            this._d1Saving = false;
        }
    }

    // ── D2 - Decision Process ─────────────────────────────────────────
    @track _showD2Form = false;
    @track _d2Stages   = [];
    @track _d2Desc     = '';
    @track _d2Status   = '';
    @track _d2Saving   = false;

    get showD2Form()        { return this._showD2Form; }
    get d2StagesOptions()   { return DP_STAGES; }
    get d2SaveBtnLabel()    { return this._d2Saving ? 'Saving...' : 'Save Decision Process'; }
    get d2SaveDisabled()    { return this._d2Saving; }

    handleD2Cancel()          { this._showD2Form = false; }
    handleD2StagesChange(e)   { this._d2Stages = e.detail.value; }
    handleD2DescChange(e)     { this._d2Desc   = e.detail.value; }
    handleD2StatusChange(e)   { this._d2Status = e.detail.value; }

    async handleSaveD2() {
        if (this.d2SaveDisabled) return;
        this._d2Saving = true;
        try {
            await updateDecisionProcess({ opportunityId: this.recordId, stages: this._d2Stages.join(';'), description: this._d2Desc, status: this._d2Status });
            this._patchLocalOpp({ Decision_Process_Stages__c: this._d2Stages.join(';') || null, MEDDPICC_Decision_Process__c: this._d2Desc || null, MEDDPICC_Decision_Process_Status__c: this._d2Status || null });
            this._showD2Form = false;
            await refreshApex(this._wiredHealth);
            getRecordNotifyChange([{ recordId: this.recordId }]);
            this._toast('Decision Process saved', '', 'success');
        } catch (err) {
            this._toast('Error', err.body?.message ?? 'Save failed.', 'error');
        } finally {
            this._d2Saving = false;
        }
    }

    // ── P - Paper Process ─────────────────────────────────────────────
    @track _showPForm = false;
    @track _pSteps    = [];
    @track _pDesc     = '';
    @track _pStatus   = '';
    @track _pSaving   = false;

    get showPForm()       { return this._showPForm; }
    get pStepsOptions()   { return PP_STEPS; }
    get pSaveBtnLabel()   { return this._pSaving ? 'Saving...' : 'Save Paper Process'; }
    get pSaveDisabled()   { return this._pSaving; }

    handlePCancel()        { this._showPForm = false; }
    handlePStepsChange(e)  { this._pSteps  = e.detail.value; }
    handlePDescChange(e)   { this._pDesc   = e.detail.value; }
    handlePStatusChange(e) { this._pStatus = e.detail.value; }

    async handleSaveP() {
        if (this.pSaveDisabled) return;
        this._pSaving = true;
        try {
            await updatePaperProcess({ opportunityId: this.recordId, steps: this._pSteps.join(';'), description: this._pDesc, status: this._pStatus });
            this._patchLocalOpp({ Paper_Process_Steps__c: this._pSteps.join(';') || null, MEDDPICC_Paper_Process__c: this._pDesc || null, MEDDPICC_Paper_Process_Status__c: this._pStatus || null });
            this._showPForm = false;
            await refreshApex(this._wiredHealth);
            getRecordNotifyChange([{ recordId: this.recordId }]);
            this._toast('Paper Process saved', '', 'success');
        } catch (err) {
            this._toast('Error', err.body?.message ?? 'Save failed.', 'error');
        } finally {
            this._pSaving = false;
        }
    }

    // ── I - Identify Pain ─────────────────────────────────────────────
    @track _showIForm = false;
    @track _iDesc     = '';
    @track _iStatus   = '';
    @track _iSaving   = false;

    get showIForm()       { return this._showIForm; }
    get iSaveBtnLabel()   { return this._iSaving ? 'Saving...' : 'Save Identify Pain'; }
    get iSaveDisabled()   { return this._iSaving; }

    handleICancel()        { this._showIForm = false; }
    handleIDescChange(e)   { this._iDesc   = e.detail.value; }
    handleIStatusChange(e) { this._iStatus = e.detail.value; }

    async handleSaveI() {
        if (this.iSaveDisabled) return;
        this._iSaving = true;
        try {
            await updatePain({ opportunityId: this.recordId, description: this._iDesc, status: this._iStatus });
            this._patchLocalOpp({ MEDDPICC_Pain__c: this._iDesc || null, MEDDPICC_Pain_Status__c: this._iStatus || null });
            this._showIForm = false;
            await refreshApex(this._wiredHealth);
            getRecordNotifyChange([{ recordId: this.recordId }]);
            this._toast('Identify Pain saved', '', 'success');
        } catch (err) {
            this._toast('Error', err.body?.message ?? 'Save failed.', 'error');
        } finally {
            this._iSaving = false;
        }
    }

    // ── C2 - Competition ──────────────────────────────────────────────
    @track _showC2Form          = false;
    @track _c2AccountId         = '';
    @track _c2AccountName       = '';
    @track _c2AccountSearch     = '';
    @track _c2AccountResults    = [];
    @track _c2AccountSelected   = false;
    @track _c2Desc              = '';
    @track _c2Status            = '';
    @track _c2Saving            = false;
    @track _c2ShowNewAccount    = false;
    @track _c2NewAccountName    = '';

    get showC2Form()              { return this._showC2Form; }
    get c2SaveBtnLabel()          { return this._c2Saving ? 'Saving...' : 'Save Competition'; }
    get c2SaveDisabled()          { return this._c2Saving; }
    get c2AccountSearch()         { return this._c2AccountSearch; }
    get c2AccountHasResults()     { return this._c2AccountResults.length > 0; }
    get c2AccountNoResults()      { return this._c2AccountSearch.length >= 2 && !this.c2AccountHasResults && !this._c2Saving && !this._c2ShowNewAccount; }
    get c2AccountShowHint()       { return this._c2AccountSearch.length < 2 && !this._c2AccountSelected && !this._c2ShowNewAccount; }
    get c2ShowPickedAccount()     { return this._c2AccountSelected; }
    get c2ShowNewAccountForm()    { return this._c2ShowNewAccount; }
    get c2ShowSearch()            { return !this._c2AccountSelected && !this._c2ShowNewAccount; }

    handleC2Cancel()        { this._showC2Form = false; }
    handleC2DescChange(e)   { this._c2Desc   = e.detail.value; }
    handleC2StatusChange(e) { this._c2Status = e.detail.value; }

    handleC2AccountSearch(e) {
        this._c2AccountSearch = e.detail.value;
        if (this._c2AccountSearch.length >= 2) {
            searchAccounts({ searchTerm: this._c2AccountSearch, recordTypeName: 'Competitor' })
                .then(results => {
                    this._c2AccountResults = (results || []).map(a => ({ label: a.Name, value: a.Id }));
                })
                .catch(err => {
                    this._c2AccountResults = [];
                    this.dispatchEvent(new ShowToastEvent({
                        title: 'Account search failed',
                        message: err.body?.message ?? 'Could not search competitor accounts.',
                        variant: 'error'
                    }));
                });
        } else {
            this._c2AccountResults = [];
        }
    }

    handlePickC2Account(e) {
        this._c2AccountId       = e.currentTarget.dataset.id;
        this._c2AccountName     = e.currentTarget.dataset.label;
        this._c2AccountSelected = true;
        this._c2AccountSearch   = '';
        this._c2AccountResults  = [];
    }

    handleClearC2Account() {
        this._c2AccountId       = '';
        this._c2AccountName     = '';
        this._c2AccountSelected = false;
        this._c2ShowNewAccount  = false;
        this._c2NewAccountName  = '';
        this._c2AccountSearch   = '';
        this._c2AccountResults  = [];
    }

    handleNewCompetitorMode() {
        this._c2ShowNewAccount  = true;
        this._c2NewAccountName  = this._c2AccountSearch;
        this._c2AccountSearch   = '';
        this._c2AccountResults  = [];
    }

    handleC2NewNameChange(e) {
        this._c2NewAccountName = e.detail.value;
    }

    async handleSaveC2() {
        if (this.c2SaveDisabled) return;
        this._c2Saving = true;
        try {
            let competitorId = this._c2AccountId || null;
            if (this._c2ShowNewAccount && this._c2NewAccountName) {
                competitorId = await createAccount({
                    name: this._c2NewAccountName,
                    recordTypeName: 'Competitor'
                });
            }
            await updateCompetition({
                opportunityId:      this.recordId,
                competitorAccountId: competitorId,
                description:        this._c2Desc,
                status:             this._c2Status,
            });
            this._patchLocalOpp({ MEDDPICC_Competition__c: this._c2Desc || null, MEDDPICC_Competition_Status__c: this._c2Status || null, Competitor_Account__c: competitorId });
            this._showC2Form = false;
            this._c2ShowNewAccount = false;
            this._c2NewAccountName = '';
            await refreshApex(this._wiredHealth);
            getRecordNotifyChange([{ recordId: this.recordId }]);
            this._toast('Competition saved', '', 'success');
        } catch (err) {
            this._toast('Error', err.body?.message ?? 'Save failed.', 'error');
        } finally {
            this._c2Saving = false;
        }
    }

    // ── Internal: record-edit-form handlers ──────────────────────────
    _autoSaveTimer;
    handleInternalFieldChange(e) {
        // Debounce: wait 400 ms after last change before submitting.
        // Per-field onchange handlers on each input-field update tracked state for live display.
        clearTimeout(this._autoSaveTimer);
        this._autoSaveTimer = setTimeout(() => {
            const form = this.template.querySelector('lightning-record-edit-form');
            if (form) form.submit();
        }, 400);
    }
    handleInternalSaveSuccess() {
        return refreshApex(this._wiredHealth);
    }

    // ── Helpers ───────────────────────────────────────────────────────
    _resetForm() {
        this._addContactId = ''; this._addContactLabel = '';
        this._addRole = ''; this._addStatus = 'Not Yet Contacted';
        this._addMeddpiccStatus = ''; this._addMeddpiccStatusField = '';
        this._addReportsToId = '';
        this._showNewContact = false; this._contactSelected = false; this._cptSearch = '';
        this._ncFirst = ''; this._ncLast = ''; this._ncTitle = ''; this._ncEmail = '';
    }

    /** Optimistic local update - ensures score reacts immediately after save,
     *  bypassing any refreshApex caching lag. */
    _patchLocalOpp(fields) {
        if (!this._opp) return;
        try {
            const patched = JSON.parse(JSON.stringify(this._opp));
            Object.assign(patched, fields);
            this._opp = patched;
        } catch (_) { /* refreshApex will reconcile */ }
    }

    _toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}