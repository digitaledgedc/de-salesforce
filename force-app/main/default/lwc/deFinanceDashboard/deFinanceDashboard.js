import { LightningElement, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

import getPendingItems          from '@salesforce/apex/DeFinanceDashboardController.getPendingItems';
import getHistoricalItems       from '@salesforce/apex/DeFinanceDashboardController.getHistoricalItems';
import getUserCountries         from '@salesforce/apex/DeFinanceDashboardController.getUserCountries';
import acknowledgeInstruction   from '@salesforce/apex/DeFinanceDashboardController.acknowledgeInstruction';
import updateCreditLimits       from '@salesforce/apex/DeFinanceDashboardController.updateCreditLimits';
import approveCreditLimitQuote  from '@salesforce/apex/DeFinanceDashboardController.approveCreditLimitQuote';
import approveCreditLimitRequest from '@salesforce/apex/DeFinanceDashboardController.approveCreditLimitRequest';
import rejectCreditLimitRequest from '@salesforce/apex/DeFinanceDashboardController.rejectCreditLimitRequest';
import getActiveQuotesForAccount from '@salesforce/apex/DeFinanceDashboardController.getActiveQuotesForAccount';
import getCurrencyRates          from '@salesforce/apex/DeFinanceDashboardController.getCurrencyRates';

const TYPE_COLORS = {
    'Special Instruction': { bg: '#f6f0fe', color: '#7928ca', border: '#7928ca' },
    'Customer Approval':   { bg: '#fefaed', color: '#92400e', border: '#f5a623' },
    'Credit Limit':        { bg: '#fef0f0', color: '#e00',    border: '#e00' },
    'BAN Approval':        { bg: '#f0f7ff', color: '#0070f3', border: '#0070f3' }
};

export default class DeFinanceDashboard extends NavigationMixin(LightningElement) {

    @track _items = [];
    @track _historyItems = [];
    @track _loading = true;
    @track _typeFilter = 'All';
    @track _countryFilter = '';
    @track _searchTerm = '';
    @track _userCountries = [];
    @track _isAdmin = false;
    @track _viewMode = 'pending';
    @track _openSections = new Set();
    @track _expandedCreditId = null;
    @track _creditActiveQuotes = [];
    @track _creditQuotesLoading = false;
    @track _lastRefresh = null;
    @track _actionLoading = false;
    @track _fxRates = {};
    @track _entityFilter = '';
    _searchTimer;

    connectedCallback() { this._load(); }

    async _load() {
        this._loading = true;
        try {
            const [items, countries, fxRates] = await Promise.all([
                getPendingItems(),
                getUserCountries(),
                getCurrencyRates()
            ]);
            this._fxRates = fxRates || {};
            this._items = items.map(i => this._enrich(i));
            this._isAdmin = countries.length > 5; // Admin/super-user gets all 10 DE countries
            this._userCountries = countries;
            if (countries.length === 1) this._countryFilter = countries[0];
            this._lastRefresh = new Date();
        } catch (e) {
            this._toast('Error', e.body ? e.body.message : e.message, 'error');
        } finally { this._loading = false; }
    }

    _enrich(item) {
        const tc = TYPE_COLORS[item.itemType] || { bg: '#f5f5f5', color: '#555', border: '#d4d4d4' };
        const mins = item.agingMinutes || 0;
        let agingLabel;
        let agingCls = 'fdb-aging fdb-aging-green';

        if (mins < 0) {
            // Historical item — show date
            agingLabel = item.createdDate ? new Date(item.createdDate).toLocaleDateString() : '';
            agingCls = 'fdb-aging fdb-aging-done';
        } else if (mins < 60) {
            agingLabel = Math.round(mins) + 'm';
        } else if (mins < 1440) {
            agingLabel = Math.round(mins / 60) + 'h';
        } else if (mins < 7200) {
            // < 5 days — green
            agingLabel = Math.round(mins / 1440) + 'd';
        } else if (mins < 10080) {
            // 5-7 days — amber
            agingLabel = Math.round(mins / 1440) + 'd';
            agingCls = 'fdb-aging fdb-aging-amber';
        } else {
            // > 7 days — red
            agingLabel = Math.round(mins / 1440) + 'd';
            agingCls = 'fdb-aging fdb-aging-red';
        }

        // Currency-aware formatting
        const ccy = item.currencyCode || '';
        const fmtAmt = (v) => v != null ? (ccy ? ccy + ' ' : '') + Number(v).toLocaleString() : '';
        const mrcLabel = fmtAmt(item.mrc);
        const nrcLabel = fmtAmt(item.nrc);
        let valueLabel = mrcLabel || nrcLabel
            ? (mrcLabel ? 'MRC ' + mrcLabel : '') + (mrcLabel && nrcLabel ? ' | ' : '') + (nrcLabel ? 'NRC ' + nrcLabel : '')
            : '';
        // BAN approvals: show currency + frequency instead of empty amount
        if (item.itemType === 'BAN Approval' && !valueLabel && item.description) {
            valueLabel = item.description;
        }

        // Credit limit overage computation
        const isCreditLimit = item.itemType === 'Credit Limit';
        let creditLimitFmt = '';
        let creditOverFmt = '';
        let creditIsOver = false;
        let quotedMrcFmt = fmtAmt(item.mrc);
        let quotedNrcFmt = fmtAmt(item.nrc);
        if (isCreditLimit) {
            // Exposure and limits are both in the account's currency, supplied by Apex.
            // Never subtract the quote's total (quote currency) from the limit.
            const acctCcy = item.accountCurrencyCode || 'USD';
            const fmtAcct = (v) => acctCcy + ' ' + Number(Math.round(v || 0)).toLocaleString();

            const breaches = [];
            if ((item.overMrc || 0) > 0) breaches.push({ kind: 'MRC', limit: item.creditLimitMrc, over: item.overMrc });
            if ((item.overNrc || 0) > 0) breaches.push({ kind: 'NRC', limit: item.creditLimitNrc, over: item.overNrc });

            if (breaches.length) {
                creditLimitFmt = breaches.map(b => `${b.kind} limit: ${fmtAcct(b.limit)}`).join(' · ');
                creditOverFmt = 'Over by: ' + breaches.map(b => `${fmtAcct(b.over)} ${b.kind}`).join(' · ');
                creditIsOver = true;
            } else {
                creditLimitFmt = 'MRC limit: ' + fmtAcct(item.creditLimitMrc);
                // Limits are within range — the SI was raised on overdue balances.
                if (item.breachReason) {
                    creditOverFmt = item.breachReason;
                    creditIsOver = true;
                }
            }
        }

        // Row urgency — gentle background tint (amber 5-7d, red >7d)
        const rowBg = mins > 10080 ? 'rgba(220,38,38,0.04)' : mins > 7200 ? 'rgba(245,158,11,0.04)' : 'transparent';

        return {
            ...item,
            key: item.id,
            panelKey: item.id + '_panel',
            agingLabel,
            agingCls,
            valueLabel,
            hasQuote: !!item.quoteNumber,
            canAcknowledge: (item.itemType === 'Special Instruction') && item.status === 'Pending',
            isCreditLimit,
            canReview: isCreditLimit && item.status === 'Pending',
            isBanApproval: item.itemType === 'BAN Approval',
            creditLimitMrc: item.creditLimitMrc,
            creditLimitNrc: item.creditLimitNrc,
            accountCurrencyCode: item.accountCurrencyCode || ccy,
            creditLimitMrcFmt: item.creditLimitMrc != null ? Number(item.creditLimitMrc).toLocaleString() : '—',
            creditLimitNrcFmt: item.creditLimitNrc != null ? Number(item.creditLimitNrc).toLocaleString() : '—',
            quotedMrcFmt,
            quotedNrcFmt,
            quotedMrcRaw: item.mrc != null ? Number(item.mrc).toLocaleString() : '0',
            quotedNrcRaw: item.nrc != null ? Number(item.nrc).toLocaleString() : '0',
            creditLimitFmt,
            creditOverFmt,
            creditIsOver,
            trigQuoteMrcFmt: isCreditLimit && item.quoteMrc != null ? fmtAmt(item.quoteMrc) : '',
            trigQuoteNrcFmt: isCreditLimit && item.quoteNrc != null ? fmtAmt(item.quoteNrc) : '',
            trigQuoteUsdMrcFmt: (() => {
                if (!isCreditLimit || item.quoteMrc == null || ccy === 'USD') return '';
                const rate = this._fxRates[ccy];
                return rate && rate > 0 ? 'USD ' + Number(Math.round(item.quoteMrc / rate)).toLocaleString() : '';
            })(),
            trigQuoteUsdNrcFmt: (() => {
                if (!isCreditLimit || item.quoteNrc == null || ccy === 'USD') return '';
                const rate = this._fxRates[ccy];
                return rate && rate > 0 ? 'USD ' + Number(Math.round(item.quoteNrc / rate)).toLocaleString() : '';
            })(),
            hasTrigQuoteUsd: isCreditLimit && ccy !== 'USD' && ccy !== '' && this._fxRates[ccy] > 0,
            detailLabel: isCreditLimit
                ? 'Credit limit exceeded on ' + (item.quoteNumber || 'unknown quote')
                : (item.itemType === 'Special Instruction' && item.description ? item.description : item.label),
            resolutionNotes: item.resolutionNotes || '',
            hasResolutionNotes: !!item.resolutionNotes,
            rowStyle: `background:${rowBg}`,
            showCreditPanel: false
        };
    }

    /* ─── Getters ─── */
    get isPending()   { return this._viewMode === 'pending'; }
    get isHistory()   { return this._viewMode === 'history'; }
    get pendingToggleCls() { return 'fdb-toggle-btn' + (this.isPending ? ' fdb-toggle-on' : ''); }
    get historyToggleCls() { return 'fdb-toggle-btn' + (this.isHistory ? ' fdb-toggle-on' : ''); }
    get hasItems()    { return this.filteredItems.length > 0; }
    get totalCount()  { return this.filteredItems.length; }

    get lastRefreshLabel() {
        if (!this._lastRefresh) return '';
        const diff = Math.round((Date.now() - this._lastRefresh.getTime()) / 60000);
        if (diff < 1) return 'Just now';
        if (diff < 60) return diff + 'm ago';
        return Math.round(diff / 60) + 'h ago';
    }

    get groupedSections() {
        const items = this.filteredItems;
        const groups = {};
        const order = ['Special Instruction', 'Customer Approval', 'Credit Limit', 'BAN Approval'];
        const colors = { 'Special Instruction': '#7928ca', 'Customer Approval': '#f5a623', 'Credit Limit': '#e00', 'BAN Approval': '#0070f3' };
        items.forEach(i => {
            if (!groups[i.itemType]) groups[i.itemType] = [];
            groups[i.itemType].push(i);
        });
        return order
            .filter(t => groups[t] && groups[t].length > 0)
            .map(t => {
                const isOpen = this._openSections.has(t);
                return {
                    key: t,
                    title: t === 'Special Instruction' ? 'Special Instructions' : t === 'Customer Approval' ? 'Customer Approvals' : t === 'Credit Limit' ? 'Credit Limits' : 'BAN Approvals',
                    count: groups[t].length,
                    dotStyle: `background:${colors[t]}`,
                    borderStyle: `border-left-color:${colors[t]}`,
                    items: groups[t],
                    isOpen,
                    amountHeader: t === 'BAN Approval' ? 'Currency / Freq' : 'Amount',
                    chevronCls: 'fdb-chevron' + (isOpen ? ' fdb-chevron-open' : '')
                };
            });
    }

    get filteredItems() {
        let items = this.isPending ? this._items : this._historyItems;
        if (this._countryFilter) {
            items = items.filter(i => i.country === this._countryFilter);
        }
        if (this._entityFilter) {
            items = items.filter(i => i.entityName === this._entityFilter);
        }
        const q = (this._searchTerm || '').toLowerCase();
        if (q) {
            items = items.filter(i =>
                (i.accountName || '').toLowerCase().includes(q) ||
                (i.quoteNumber || '').toLowerCase().includes(q) ||
                (i.label || '').toLowerCase().includes(q)
            );
        }
        return items;
    }

    get countryPills() {
        if (this._userCountries.length <= 1) return [];
        const sorted = [...this._userCountries].sort();
        const pills = [{ value: '', label: 'All', cls: 'fdb-pill' + (!this._countryFilter ? ' fdb-pill-on' : '') }];
        sorted.forEach(c => { pills.push({ value: c, label: c, cls: 'fdb-pill' + (this._countryFilter === c ? ' fdb-pill-on' : '') }); });
        return pills;
    }
    get showCountryFilter() { return this.countryPills.length > 0; }

    get entityPills() {
        if (!this._countryFilter) return [];
        const items = this.isPending ? this._items : this._historyItems;
        const entities = [...new Set(
            items.filter(i => i.country === this._countryFilter && i.entityName)
                 .map(i => i.entityName)
        )].sort();
        if (entities.length < 2) return [];
        const pills = [{ value: '', label: 'All', cls: 'fdb-pill fdb-pill-sm' + (!this._entityFilter ? ' fdb-pill-on' : '') }];
        entities.forEach(e => {
            pills.push({ value: e, label: e, cls: 'fdb-pill fdb-pill-sm' + (this._entityFilter === e ? ' fdb-pill-on' : '') });
        });
        return pills;
    }
    get showEntityFilter() { return this.entityPills.length > 0; }

    get metrics() {
        const items = this.isPending ? this._items : this._historyItems;
        const si = items.filter(i => i.itemType === 'Special Instruction').length;
        const cust = items.filter(i => i.itemType === 'Customer Approval').length;
        const credit = items.filter(i => i.itemType === 'Credit Limit').length;
        const ban = items.filter(i => i.itemType === 'BAN Approval').length;
        return [
            { key: 'total', value: String(items.length), label: 'Total', cls: 'fdb-metric-v', wrapCls: 'fdb-metric fdb-metric-default' },
            { key: 'si', value: String(si), label: 'SI', cls: si > 0 ? 'fdb-metric-v fdb-v-purple' : 'fdb-metric-v', wrapCls: 'fdb-metric fdb-metric-purple' },
            { key: 'cust', value: String(cust), label: 'Customer', cls: cust > 0 ? 'fdb-metric-v fdb-v-amber' : 'fdb-metric-v', wrapCls: 'fdb-metric fdb-metric-amber' },
            { key: 'credit', value: String(credit), label: 'Credit', cls: credit > 0 ? 'fdb-metric-v fdb-v-red' : 'fdb-metric-v', wrapCls: 'fdb-metric fdb-metric-red' },
            { key: 'ban', value: String(ban), label: 'BAN', cls: ban > 0 ? 'fdb-metric-v fdb-v-blue' : 'fdb-metric-v', wrapCls: 'fdb-metric fdb-metric-blue' },
        ];
    }

    /* ─── Handlers ─── */
    handleTypePill(e)    { this._typeFilter = e.currentTarget.dataset.value; }
    handleCountryPill(e) { this._countryFilter = e.currentTarget.dataset.value; this._entityFilter = ''; }
    handleEntityPill(e)  { this._entityFilter = e.currentTarget.dataset.value; }

    handleSearch(e) {
        clearTimeout(this._searchTimer);
        const val = e.target.value;
        this._searchTimer = setTimeout(() => { this._searchTerm = val; }, 200);
    }

    handleSectionToggle(e) {
        const key = e.currentTarget.dataset.key;
        const next = new Set(this._openSections);
        next.has(key) ? next.delete(key) : next.add(key);
        this._openSections = next;
    }

    async handleViewToggle(e) {
        const view = e.currentTarget.dataset.view;
        if (view === this._viewMode) return;
        this._viewMode = view;
        if (view === 'history' && this._historyItems.length === 0) {
            this._loading = true;
            try {
                const items = await getHistoricalItems();
                this._historyItems = items.map(i => this._enrich(i));
            } catch (err) {
                this._toast('Error', err?.body?.message || err?.message || 'Failed to load history.', 'error');
            } finally { this._loading = false; }
        }
    }

    async handleRefresh() {
        this._expandedCreditId = null;
        this._creditActiveQuotes = [];
        if (this.isPending) {
            await this._load();
        } else {
            this._loading = true;
            try {
                const items = await getHistoricalItems();
                this._historyItems = items.map(i => this._enrich(i));
                this._lastRefresh = new Date();
            } catch (err) {
                this._toast('Error', err?.body?.message || err?.message || 'Failed to refresh.', 'error');
            } finally { this._loading = false; }
        }
    }

    handleRowClick(e) {
        const id = e.currentTarget.dataset.id;
        if (!id) return;
        const item = this._items.find(i => i.id === id);
        if (item && item.isCreditLimit && item.canReview) {
            this.handleCreditReview(e);
        } else {
            this.handleNav(e);
        }
    }

    handleNav(e) {
        e.stopPropagation();
        const id = e.currentTarget.dataset.id;
        if (id) {
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: { recordId: id, actionName: 'view' }
            });
        }
    }

    handleQuoteNav(e) {
        e.stopPropagation();
        const id = e.currentTarget.dataset.id;
        if (id) {
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: { recordId: id, actionName: 'view' }
            });
        }
    }

    handleStopProp(e) { e.stopPropagation(); }

    async handleAcknowledge(e) {
        e.stopPropagation();
        const id = e.currentTarget.dataset.id;
        this._actionLoading = true;
        try {
            await acknowledgeInstruction({ instructionId: id, notes: '' });
            this._items = this._items.filter(i => i.id !== id);
            this._toast('Acknowledged', 'Acknowledged successfully.', 'success');
        } catch (err) {
            this._toast('Error', err?.body?.message || err?.message || 'Could not acknowledge. Please try again.', 'error');
        } finally { this._actionLoading = false; }
    }

    /* ─── Credit Limit Review Panel ─── */

    async handleCreditReview(e) {
        e.stopPropagation();
        const id = e.currentTarget.dataset.id;
        // Toggle panel — close if already open
        if (this._expandedCreditId === id) {
            this._expandedCreditId = null;
            this._items = this._items.map(i => ({ ...i, showCreditPanel: false }));
            this._creditActiveQuotes = [];
            return;
        }
        // Open this panel, close any other
        this._expandedCreditId = id;
        this._items = this._items.map(i => ({ ...i, showCreditPanel: i.id === id }));
        const item = this._items.find(i => i.id === id);
        if (!item) return;
        this._creditQuotesLoading = true;
        try {
            const quotes = await getActiveQuotesForAccount({ accountId: item.accountId });
            this._creditActiveQuotes = quotes.map(q => {
                const s = (q.status || '').toLowerCase();
                const statusCls = 'fdb-status-pill' + (s === 'approved' ? ' fdb-status-approved' : s === 'draft' ? ' fdb-status-draft' : ' fdb-status-other');
                const isTrig = q.quoteId === item.quoteId;
                return {
                    ...q,
                    key: q.quoteId,
                    mrcFmt: q.mrc != null ? Number(q.mrc).toLocaleString() : '—',
                    nrcFmt: q.nrc != null ? Number(q.nrc).toLocaleString() : '—',
                    statusCls,
                    isTriggering: isTrig ? 'fdb-cpt-trigger-row' : ''
                };
            });
        } catch (err) {
            this._creditActiveQuotes = [];
            this._toast('Error', err?.body?.message || err?.message || 'Failed to load quotes.', 'error');
        } finally { this._creditQuotesLoading = false; }
    }

    async handleCreditApprove(e) {
        e.stopPropagation();
        const id = e.currentTarget.dataset.id;
        const accountId = e.currentTarget.dataset.account;
        const quoteId = e.currentTarget.dataset.quote;
        const mrcInput = this.template.querySelector('[data-field="limitMrc"]');
        const nrcInput = this.template.querySelector('[data-field="limitNrc"]');
        // Strip commas from formatted values before parsing
        const parseNum = (v) => v ? Number(String(v).replace(/,/g, '')) : null;
        const newMrc = mrcInput ? parseNum(mrcInput.value) : null;
        const newNrc = nrcInput ? parseNum(nrcInput.value) : null;

        if (newMrc == null || isNaN(newMrc) || newNrc == null || isNaN(newNrc)) {
            this._toast('Error', 'Please enter valid MRC and NRC limits.', 'error');
            return;
        }

        this._actionLoading = true;
        try {
            await approveCreditLimitRequest({
                instructionId: id, accountId, quoteId,
                newLimitMrc: newMrc, newLimitNrc: newNrc
            });
            this._items = this._items.filter(i => i.id !== id);
            this._expandedCreditId = null;
            this._creditActiveQuotes = [];
            this._toast('Approved', 'Credit limit approved and limits updated.', 'success');
        } catch (err) {
            this._toast('Error', err?.body?.message || err?.message || 'Could not approve. Please try again.', 'error');
        } finally { this._actionLoading = false; }
    }

    async handleCreditReject(e) {
        e.stopPropagation();
        const id = e.currentTarget.dataset.id;
        this._actionLoading = true;
        try {
            await rejectCreditLimitRequest({ instructionId: id, notes: '' });
            this._items = this._items.filter(i => i.id !== id);
            this._expandedCreditId = null;
            this._creditActiveQuotes = [];
            this._toast('Rejected', 'Credit limit request rejected.', 'success');
        } catch (err) {
            this._toast('Error', err?.body?.message || err?.message || 'Could not reject. Please try again.', 'error');
        } finally { this._actionLoading = false; }
    }

    get hasCreditActiveQuotes() { return this._creditActiveQuotes.length > 0; }
    get creditActiveQuoteCount() { return this._creditActiveQuotes.length; }

    get creditTotalsByCurrency() {
        const byCcy = {};
        this._creditActiveQuotes.forEach(q => {
            const ccy = q.currencyCode || 'USD';
            if (!byCcy[ccy]) byCcy[ccy] = { ccy, mrc: 0, nrc: 0 };
            byCcy[ccy].mrc += (q.mrc || 0);
            byCcy[ccy].nrc += (q.nrc || 0);
        });
        const rows = [];
        for (const t of Object.values(byCcy)) {
            rows.push({
                key: t.ccy,
                ccy: t.ccy,
                mrcFmt: Number(t.mrc).toLocaleString(),
                nrcFmt: Number(t.nrc).toLocaleString(),
                label: 'Total',
                rowClass: 'fdb-cpt-totals'
            });
            // Add USD equivalent row if currency is not USD
            if (t.ccy !== 'USD') {
                const rate = this._fxRates[t.ccy];
                if (rate && rate > 0) {
                    rows.push({
                        key: t.ccy + '_usd',
                        ccy: 'USD',
                        mrcFmt: Number(Math.round(t.mrc / rate)).toLocaleString(),
                        nrcFmt: Number(Math.round(t.nrc / rate)).toLocaleString(),
                        label: 'USD Equiv',
                        rowClass: 'fdb-cpt-totals fdb-cpt-usd-equiv'
                    });
                }
            }
        }
        // With mixed currencies the per-currency subtotals above can't be compared to the
        // limit. Add the combined USD figure — this is what the credit check evaluates.
        if (Object.keys(byCcy).length > 1) {
            let mrc = 0;
            let nrc = 0;
            let complete = true;
            for (const t of Object.values(byCcy)) {
                const rate = t.ccy === 'USD' ? 1 : this._fxRates[t.ccy];
                if (!rate || rate <= 0) { complete = false; break; }
                mrc += t.mrc / rate;
                nrc += t.nrc / rate;
            }
            if (complete) {
                rows.push({
                    key: 'combined_usd',
                    ccy: 'USD',
                    mrcFmt: Number(Math.round(mrc)).toLocaleString(),
                    nrcFmt: Number(Math.round(nrc)).toLocaleString(),
                    label: 'Total USD',
                    rowClass: 'fdb-cpt-totals fdb-cpt-usd-equiv'
                });
            }
        }
        return rows;
    }
    get hasMultipleCurrencies() {
        const ccys = new Set(this._creditActiveQuotes.map(q => q.currencyCode || 'USD'));
        return ccys.size > 1;
    }

    _toast(t, m, v) { this.dispatchEvent(new ShowToastEvent({ title: t, message: m, variant: v })); }
}