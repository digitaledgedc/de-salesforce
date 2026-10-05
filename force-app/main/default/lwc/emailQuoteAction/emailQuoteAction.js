import { LightningElement, api, wire, track } from 'lwc';
import { ShowToastEvent }              from 'lightning/platformShowToastEvent';
import { CloseActionScreenEvent }      from 'lightning/actions';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { refreshApex }                 from '@salesforce/apex';  // ← ADDED
import DE_LOGO                         from '@salesforce/resourceUrl/DE_Logo';

import getQuoteDefaults   from '@salesforce/apex/EmailQuoteController.getQuoteDefaults';
import getLineItemCount   from '@salesforce/apex/EmailQuoteController.getLineItemCount'; // FB-739 fix — fresh, non-cached product count
import getTermsOptions    from '@salesforce/apex/EmailQuoteController.getTermsOptions';
import saveTermsToQuote   from '@salesforce/apex/EmailQuoteController.saveTermsToQuote';
import saveSpecialNotes   from '@salesforce/apex/EmailQuoteController.saveSpecialNotes';
import saveBindingToQuote from '@salesforce/apex/EmailQuoteController.saveBindingToQuote';
import sendQuotePdf       from '@salesforce/apex/EmailQuoteController.sendQuotePdf';
import searchAccounts     from '@salesforce/apex/TermsAndConditionController.searchAccounts';
import createTandCRecord  from '@salesforce/apex/TermsAndConditionController.createTandCRecord';

export default class EmailQuoteAction extends LightningElement {
    @api recordId;

    // Header logo — same DE_Logo static resource used by DE_QuoteTemplate VF page
    logoUrl = DE_LOGO;

    // ── UI state ────────────────────────────────────────────────────
    @track isLoading    = true;
    @track isSending    = false;
    @track hasError     = false;
    @track errorMessage = '';

    // ── Email fields ────────────────────────────────────────────────
    @track toEmail  = '';
    @track ccEmail  = '';
    @track subject  = '';
    @track body     = '';

    // ── Read-only info (from Quote defaults) ────────────────────────
    @track company          = '';   // DE_Entity__r.Name (Subsidiary)
    @track customer         = '';
    @track quoteType        = '';   // Quote_Type__c raw value
    @track subscriptionMgmt = '';   // derived display label
    @track orderNumber      = '';   // Opportunity_Number__c
    @track quoteNumber      = '';   // Quote_Number__c
    @track lineItemCount    = 0;    // FB-739 — number of products on the quote

    // ── Special Notes ───────────────────────────────────────────────
    @track specialNotes            = '';
    @track specialNotesSaving      = false;
    @track specialNotesSaveStatus  = '';
    @track specialNotesSaveIsError = false;

    // ── Terms & Conditions ──────────────────────────────────────────
    @track isLoadingTerms     = true;
    @track termsOptions       = [];
    @track selectedTermsLabel = '';
    @track selectedTermsHtml  = '';
    @track termsSaveStatus    = '';
    @track termsSaveIsError   = false;

    // ── Binding ─────────────────────────────────────────────────────
    @track isBinding     = true;
    @track bindingSaving = false;
    @track languageCode  = 'en_US';

    // ── PDF preview iframe ──────────────────────────────────────────
    @track iframeUrl = '';

    // ── New T&C creation modal ───────────────────────────────────────
    @track showNtcModal           = false;
    @track ntcName                = '';
    @track ntcSubscription        = 'Creation';
    @track ntcTermsText           = '';
    @track ntcSelectedCustomers   = [];
    @track ntcSelectedCompanies   = [];
    @track ntcCustomerSearch      = '';
    @track ntcCompanySearch       = '';
    @track ntcCustomerResults     = [];
    @track ntcCompanyResults      = [];
    @track showNtcCustomerDrop    = false;
    @track showNtcCompanyDrop     = false;
    @track ntcError               = '';
    @track ntcSaving              = false;

    _ntcCustomerTimer;
    _ntcCompanyTimer;

    // ── Private ─────────────────────────────────────────────────────
    _financeApprovalPhase = '';
    _defaultsLoaded       = false;
    _termsMap             = {};

    // ADDED — store full wire results so refreshApex can target them
    _wiredDefaultsResult;
    _wiredTermsResult;

    // ================================================================
    // Lifecycle
    // ================================================================

    connectedCallback() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        requestAnimationFrame(() => {
            let el = this.template.host;
            while (el) {
                if (el.classList && el.classList.contains('slds-modal__container')) {
                    el.style.maxWidth = '90vw';
                    el.style.width    = '90vw';
                    break;
                }
                el = el.parentNode || (el.host || null);
            }
        });

        // lightning-combobox renders a fixed-position dropdown that does NOT
        // reposition when a scroll container (this pane / the modal) scrolls,
        // so it "hangs" detached from its field. Close any open combobox on
        // scroll. Capture at window level catches the native modal's scroll
        // (light DOM); the form pane's own scroll is bound in renderedCallback
        // (window capture can't see scroll inside this component's shadow DOM).
        this._closeDropdownsOnScroll = () => {
            this.template.querySelectorAll('lightning-combobox').forEach(cb => {
                try { cb.blur(); } catch (e) { /* noop */ }
            });
        };
        window.addEventListener('scroll', this._closeDropdownsOnScroll, true);
    }

    renderedCallback() {
        // .eqa-body is the scroll region (both panes scroll together). Same
        // function reference → addEventListener is idempotent (no dupes).
        const scroller = this.template.querySelector('.eqa-body');
        if (scroller && this._closeDropdownsOnScroll) {
            scroller.addEventListener('scroll', this._closeDropdownsOnScroll, { passive: true });
        }
    }

    disconnectedCallback() {
        if (this._closeDropdownsOnScroll) {
            window.removeEventListener('scroll', this._closeDropdownsOnScroll, true);
        }
    }

    // ================================================================
    // Wire: Quote defaults
    // CHANGED — handler now receives full result object and stores it
    // ================================================================

    @wire(getQuoteDefaults, { quoteId: '$recordId' })
    wiredDefaults(result) {                          // ← CHANGED: full result not { data, error }
        this._wiredDefaultsResult = result;          // ← ADDED: store for refreshApex
        const { data, error } = result;

        if (data) {
            this._financeApprovalPhase = data.financeApprovalPhase || '';
            this.isBinding             = data.isBinding !== 'false';
            this.quoteType             = data.quoteType        || '';
            this.subscriptionMgmt      = data.subscriptionMgmt || '';
            this.company               = data.company          || '';
            this.customer              = data.accountName      || '';
            this.orderNumber           = data.orderNumber      || '';
            this.quoteNumber           = data.quoteNumber      || '';
            // FB-739 fix — the wired count is cacheable and goes stale when products are
            // added, so fetch a fresh non-cached count for an accurate Send gate/notice.
            getLineItemCount({ quoteId: this.recordId })
                .then(cnt => { this.lineItemCount = cnt || 0; })
                .catch(() => { this.lineItemCount = parseInt(data.lineItemCount, 10) || 0; });

            if (!this._defaultsLoaded) {
                this.toEmail      = data.toEmail      || '';
                this.ccEmail      = '';
                this.specialNotes = data.specialNotes || '';
                if (data.preferredLanguage) {
                    this.languageCode = data.preferredLanguage;
                }
                this._defaultsLoaded = true;
                this._buildSubjectAndBody();

                if (!this.isBinding) {
                    this._refreshNonBindingPreview();
                }
            }
            this.isLoading = false;
        } else if (error) {
            this.isLoading = false;
        }
    }

    // ================================================================
    // Wire: Terms & Conditions options
    // CHANGED — handler now receives full result object and stores it
    // ================================================================

    @wire(getTermsOptions, {
        quoteType:    '$quoteType',
        companyName:  '$company',
        customerName: '$customer',
        languageCode: '$languageCode'
    })
    wiredTerms(result) {                             // ← CHANGED: full result not { data, error }
        this._wiredTermsResult = result;             // ← ADDED: store for refreshApex
        const { data, error } = result;

        if (data) {
            this._termsMap = {};
            const mapped   = data.map(rec => {
                this._termsMap[rec.label] = {
                    html:             rec.termsText             || '',
                    subscriptionMgmt: rec.subscriptionManagement || ''
                };
                return { label: rec.label, value: rec.label };
            });
            this.termsOptions = [
                { label: '+ New Terms & Conditions', value: '__new_tandc__' },
                ...mapped
            ];
            this.isLoadingTerms = false;
        } else if (error) {
            this.isLoadingTerms = false;
            console.error('Failed to load T&C options', error);
        }
    }

    // ================================================================
    // Getters
    // ================================================================

    get showForm() {
        return !this.isLoading && !this.isSending;
    }

    get pdfUrl() {
        return this.recordId && !this.bindingSaving
            ? `/apex/DE_QuoteTemplate?id=${this.recordId}&lang=${this.languageCode}`
            : null;
    }

    get languageOptions() {
        return [
            { label: 'English', value: 'en_US' },
            { label: 'Japanese', value: 'ja' },
            { label: 'Korean', value: 'ko' },
            { label: 'Chinese', value: 'zh_CN' }
        ];
    }

    get showPreviewPlaceholder() {
        return this.isBinding && !this.iframeUrl;
    }

    get selectedTermsPreview() {
        if (!this.selectedTermsHtml) return '';
        const plain = this.selectedTermsHtml
            .replace(/<[^>]*>/g, ' ')
            .replace(/&nbsp;/g, ' ')
            .replace(/&amp;/g,  '&')
            .replace(/&lt;/g,   '<')
            .replace(/&gt;/g,   '>')
            .replace(/\s+/g,    ' ')
            .trim();
        return plain.length > 200 ? plain.substring(0, 200) + '…' : plain;
    }

    // FB-739 — drives the persistent "no products" notice so the user knows why Send is disabled
    get showNoProductsWarning() {
        return this.showForm && this.lineItemCount === 0;
    }

    get isSendDisabled() {
        if (this.lineItemCount === 0)     return true;   // FB-739 — no products → block send
        if (this.isSending)               return true;
        if (this.bindingSaving)            return true;
        if (this.termsSaveIsError)        return true;
        if (this.specialNotesSaveIsError) return true;
        if (this.isBinding && !this.selectedTermsLabel) return true;
        return false;
    }

    get termsSaveStatusClass() {
        return this.termsSaveIsError
            ? 'eqa-terms-status eqa-terms-status-error'
            : 'eqa-terms-status eqa-terms-status-success';
    }
    get termsSaveIcon() {
        return this.termsSaveIsError ? 'utility:error' : 'utility:success';
    }

    get specialNotesSaveStatusClass() {
        return this.specialNotesSaveIsError
            ? 'eqa-terms-status eqa-terms-status-error'
            : 'eqa-terms-status eqa-terms-status-success';
    }
    get specialNotesSaveIcon() {
        return this.specialNotesSaveIsError ? 'utility:error' : 'utility:success';
    }

    // ================================================================
    // Field handlers
    // ================================================================

    handleToChange(event)      { this.toEmail  = event.target.value; }
    handleCcChange(event)      { this.ccEmail  = event.target.value; }
    handleSubjectChange(event) { this.subject  = event.target.value; }
    handleBodyChange(event)    { this.body     = event.target.value; }

    handleLanguageChange(event) {
        const previousLanguage = this.languageCode;
        const nextLanguage     = event.detail.value;
        if (!nextLanguage || nextLanguage === previousLanguage) return;

        this.languageCode = nextLanguage;
        this.hasError     = false;
        this.errorMessage = '';

        // T&C templates are language-specific. When the language changes the
        // options list is re-fetched by the wire, so the previously-selected
        // template no longer applies — reset the picker to None and clear the
        // terms saved on the Quote so the re-rendered PDF doesn't keep the
        // old-language terms. The user must re-select in the new language.
        const hadTerms          = !!this.selectedTermsLabel;
        this.selectedTermsLabel = '';
        this.selectedTermsHtml  = '';
        this.termsSaveStatus    = '';
        this.termsSaveIsError   = false;

        if (this.isBinding) {
            // Don't auto-render in the new language. Clear the preview so the
            // "Select Terms & Conditions to preview the PDF" placeholder shows,
            // forcing the user to re-pick a T&C template in the new language.
            this.iframeUrl = '';
            if (hadTerms) {
                // Also clear the stale terms persisted on the Quote.
                saveTermsToQuote({ quoteId: this.recordId, termsHtml: '' })
                    .then(() => {
                        notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
                    })
                    .catch(err => {
                        this.termsSaveStatus  = err?.body?.message || 'Could not clear Terms & Conditions.';
                        this.termsSaveIsError = true;
                    });
            }
            return;
        }

        this._refreshNonBindingPreview(previousLanguage);
    }

    handleSpecialNotesChange(event) {
        this.specialNotes           = event.target.value;
        this.specialNotesSaveStatus = '';
    }

    handleSpecialNotesBlur() {
        this.specialNotesSaveStatus  = '';
        this.specialNotesSaveIsError = false;
        this.specialNotesSaving      = true;

        saveSpecialNotes({ quoteId: this.recordId, specialNotes: this.specialNotes })
            .then(() => {
                this.specialNotesSaving      = false;
                this.specialNotesSaveStatus  = 'Special Notes saved.';
                this.specialNotesSaveIsError = false;
                this.iframeUrl = this._buildIframeUrl();
                notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            })
            .catch(err => {
                this.specialNotesSaving      = false;
                this.specialNotesSaveStatus  = err?.body?.message || 'Could not save Special Notes.';
                this.specialNotesSaveIsError = true;
            });
    }

    // ================================================================
    // Binding toggle
    // CHANGED — refreshApex called after DML to bust cache on both wires
    // ================================================================

    handleBindingChange(event) {
        const newVal       = event.target.checked;
        this.isBinding     = newVal;
        this.bindingSaving = true;
        this.hasError      = false;
        this._buildSubjectAndBody();

        const terms = newVal ? '' : null;

        if (newVal) {
            this.selectedTermsLabel = '';
            this.selectedTermsHtml  = '';
            this.termsSaveStatus    = '';
        }

        saveBindingToQuote({
            quoteId: this.recordId,
            isBinding: newVal,
            termsHtml: terms,
            languageCode: this.languageCode
        })
            .then(() => {
                this.bindingSaving = false;
                this.iframeUrl     = newVal ? '' : this._buildIframeUrl();
                notifyRecordUpdateAvailable([{ recordId: this.recordId }]);

                // ADDED — bust cache on both wires after DML
                // wiredDefaults → re-fetches Is_Binding__c so next open is correct
                // wiredTerms    → re-fetches T&C list fresh
                return Promise.all([
                    refreshApex(this._wiredDefaultsResult),
                    refreshApex(this._wiredTermsResult)
                ]);
            })
            .catch(err => {
                this.bindingSaving = false;
                this.isBinding     = !newVal;
                this._buildSubjectAndBody(); // revert subject/body to match reverted isBinding
                this.hasError      = true;
                this.errorMessage = this._cleanError(err, 'Could not update binding status.');
            });
    }

    // ================================================================
    // Terms & Conditions selection
    // ================================================================

    handleTermsChange(event) {
        const selected = event.detail.value;

        if (selected === '__new_tandc__') {
            this.selectedTermsLabel = '';
            this.openNtcModal();
            return;
        }

        this.selectedTermsLabel = selected;

        const entry = (this._termsMap && this._termsMap[selected])
            ? this._termsMap[selected]
            : {};
        this.selectedTermsHtml = entry.html || '';
        this.termsSaveStatus   = '';
        this.termsSaveIsError  = false;

        if (!this.selectedTermsHtml) return;

        saveTermsToQuote({ quoteId: this.recordId, termsHtml: this.selectedTermsHtml })
            .then(() => {
                this.termsSaveStatus  = 'Terms & Conditions saved to quote.';
                this.termsSaveIsError = false;
                this.iframeUrl        = this._buildIframeUrl();
                notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            })
            .catch(err => {
                this.termsSaveStatus  = err?.body?.message || 'Could not save Terms & Conditions.';
                this.termsSaveIsError = true;
            });
    }

    // ================================================================
    // New T&C Modal — getters
    // ================================================================

    get ntcIsCreation()   { return this.ntcSubscription === 'Creation'; }
    get ntcIsChangeOrder(){ return this.ntcSubscription === 'Change Order'; }
    get ntcIsRenewal()    { return this.ntcSubscription === 'Renewal'; }
    get hasNtcCustomers() { return this.ntcSelectedCustomers.length > 0; }
    get hasNtcCompanies() { return this.ntcSelectedCompanies.length > 0; }
    get ntcSubscriptionOptions() {
        return [
            { label: 'Creation',     value: 'Creation' },
            { label: 'Change Order', value: 'Change Order' },
            { label: 'Renewal',      value: 'Renewal' },
            { label: 'Termination',      value: 'Termination' }
        ];
    }

    // ================================================================
    // New T&C Modal — open / close
    // ================================================================

    openNtcModal() {
        this.ntcName               = '';
        this.ntcSubscription       = this._mapSubToPicklist(this.subscriptionMgmt);
        this.ntcTermsText          = '';
        this.ntcSelectedCustomers  = this.customer ? [{ id: '_c0', name: this.customer }] : [];
        this.ntcSelectedCompanies  = this.company  ? [{ id: '_p0', name: this.company  }] : [];
        this.ntcCustomerSearch     = '';
        this.ntcCompanySearch      = '';
        this.ntcCustomerResults    = [];
        this.ntcCompanyResults     = [];
        this.showNtcCustomerDrop   = false;
        this.showNtcCompanyDrop    = false;
        this.ntcError              = '';
        this.ntcSaving             = false;
        this.showNtcModal          = true;
    }

    closeNtcModal() {
        this.showNtcModal = false;
    }

    handleNtcBackdropClick() {
        if (!this.ntcSaving) this.closeNtcModal();
    }

    _mapSubToPicklist(val) {
        const v = (val || '').toLowerCase();
        if (v.includes('change')) return 'Change Order';
        if (v.includes('renew'))  return 'Renewal';
        return 'Creation';
    }

    // ================================================================
    // New T&C Modal — field handlers
    // ================================================================

    handleNtcNameChange(event)         { this.ntcName         = event.detail.value; }
    handleNtcTermsTextChange(event)    { this.ntcTermsText     = event.detail.value; }
    handleNtcSubscriptionChange(event) { this.ntcSubscription  = event.detail.value; }

    // Customer search
    handleNtcCustomerSearch(event) {
        this.ntcCustomerSearch = event.target.value;
        clearTimeout(this._ntcCustomerTimer);
        if (!this.ntcCustomerSearch.trim()) {
            this.ntcCustomerResults  = [];
            this.showNtcCustomerDrop = false;
            return;
        }
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._ntcCustomerTimer = setTimeout(() => {
            searchAccounts({ searchTerm: this.ntcCustomerSearch })
                .then(results => {
                    const taken          = new Set(this.ntcSelectedCustomers.map(a => a.id));
                    this.ntcCustomerResults  = results.filter(r => !taken.has(r.id));
                    this.showNtcCustomerDrop = true;
                })
                .catch(() => { this.showNtcCustomerDrop = false; });
        }, 300);
    }

    handleNtcCustomerFocus() {
        if (this.ntcCustomerSearch.trim() && this.ntcCustomerResults.length) {
            this.showNtcCustomerDrop = true;
        }
    }

    handleNtcCustomerBlur() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => { this.showNtcCustomerDrop = false; }, 200);
    }

    // Company search
    handleNtcCompanySearch(event) {
        this.ntcCompanySearch = event.target.value;
        clearTimeout(this._ntcCompanyTimer);
        if (!this.ntcCompanySearch.trim()) {
            this.ntcCompanyResults  = [];
            this.showNtcCompanyDrop = false;
            return;
        }
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._ntcCompanyTimer = setTimeout(() => {
            searchAccounts({ searchTerm: this.ntcCompanySearch })
                .then(results => {
                    const taken         = new Set(this.ntcSelectedCompanies.map(a => a.id));
                    this.ntcCompanyResults  = results.filter(r => !taken.has(r.id));
                    this.showNtcCompanyDrop = true;
                })
                .catch(() => { this.showNtcCompanyDrop = false; });
        }, 300);
    }

    handleNtcCompanyFocus() {
        if (this.ntcCompanySearch.trim() && this.ntcCompanyResults.length) {
            this.showNtcCompanyDrop = true;
        }
    }

    handleNtcCompanyBlur() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => { this.showNtcCompanyDrop = false; }, 200);
    }

    // Select / remove pills
    selectNtcAccount(event) {
        const id    = event.currentTarget.dataset.id;
        const name  = event.currentTarget.dataset.name;
        const field = event.currentTarget.dataset.field;
        if (field === 'customer') {
            if (!this.ntcSelectedCustomers.find(a => a.id === id)) {
                this.ntcSelectedCustomers = [...this.ntcSelectedCustomers, { id, name }];
            }
            this.ntcCustomerSearch   = '';
            this.ntcCustomerResults  = [];
            this.showNtcCustomerDrop = false;
        } else {
            if (!this.ntcSelectedCompanies.find(a => a.id === id)) {
                this.ntcSelectedCompanies = [...this.ntcSelectedCompanies, { id, name }];
            }
            this.ntcCompanySearch   = '';
            this.ntcCompanyResults  = [];
            this.showNtcCompanyDrop = false;
        }
    }

    removeNtcPill(event) {
        const id    = event.currentTarget.dataset.id;
        const field = event.currentTarget.dataset.field;
        if (field === 'customer') {
            this.ntcSelectedCustomers = this.ntcSelectedCustomers.filter(a => a.id !== id);
        } else {
            this.ntcSelectedCompanies = this.ntcSelectedCompanies.filter(a => a.id !== id);
        }
    }

    // Submit
    submitNtc() {
        this.ntcError = '';
        if (!this.ntcName || !this.ntcName.trim()) {
            this.ntcError = 'Name is required.';
            return;
        }
        const customerStr = this.ntcSelectedCustomers.map(a => a.name).join(',');
        const companyStr  = this.ntcSelectedCompanies.map(a => a.name).join(',');

        this.ntcSaving = true;
        createTandCRecord({
            tandcName:               this.ntcName.trim(),
            termsText:               this.ntcTermsText,
            customerNames:           customerStr,
            companyNames:            companyStr,
            subscriptionManagement:  this.ntcSubscription
        })
            .then(() => {
                this.ntcSaving = false;
                this.closeNtcModal();
                this.dispatchEvent(new ShowToastEvent({
                    title:   'Submitted',
                    message: 'Terms & Conditions submitted for approval.',
                    variant: 'success'
                }));
            })
            .catch(err => {
                this.ntcSaving = false;
                this.ntcError  = err?.body?.message || 'Could not submit. Please try again.';
            });
    }

    // ================================================================
    // Send / Cancel
    // ================================================================

    handleCancel() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    handleSend() {
        // FB-739 fix — re-check the product count fresh (non-cached) at send time so a
        // quote that has products is never blocked by a stale cached count.
        getLineItemCount({ quoteId: this.recordId })
            .then(cnt => { this.lineItemCount = cnt || 0; this._doSend(!this.isBinding); })
            .catch(() => { this._doSend(!this.isBinding); });
    }

    _doSend(isNonBinding) {
        // ===== FB-739 START — block sending a quote with no products =====
        if (this.lineItemCount === 0) {
            this.hasError     = true;
            this.errorMessage = 'Cannot send this quote — no products have been added. Add at least one product before sending.';
            return;
        }
        // ===== FB-739 END =====
        if (!isNonBinding) {
            const phase = this._financeApprovalPhase;
            if (phase !== 'Approved' && phase !== 'Not_Required') {
                this.hasError     = true;
                const label       = phase ? phase.replace(/_/g, ' ') : 'Not Set';
                this.errorMessage =
                    'Cannot send quote — the Account\'s Finance Approval Phase is "' +
                    label + '". Finance Approval must be completed before sending quotes.';
                return;
            }
        }

        if (!isNonBinding && !this.selectedTermsLabel) {
            this.hasError     = true;
            this.errorMessage = 'Please select a Terms Template before sending a binding quote.';
            return;
        }

        if (!this.toEmail || !this.toEmail.includes('@')) {
            this.hasError     = true;
            this.errorMessage = 'Please enter a valid "To" email address.';
            return;
        }
        if (this.ccEmail) {
            const emailRe = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
            // Split on comma AND/OR whitespace — a user typing "a@x.com b@y.com" with just
            // a space should parse as two addresses, not fail as one malformed blob.
            const invalid = this.ccEmail.split(/[\s,]+/).map(e => e.trim()).filter(e => e && !emailRe.test(e));
            if (invalid.length > 0) {
                this.hasError     = true;
                this.errorMessage = 'Invalid CC address' + (invalid.length > 1 ? 'es' : '') + ': ' + invalid.join(', ');
                return;
            }
        }

        this.hasError  = false;
        this.isSending = true;

        sendQuotePdf({
            quoteId:      this.recordId,
            toAddress:    this.toEmail,
            ccAddress:    this.ccEmail,
            subject:      this.subject,
            body:         this.body,
            isNonBinding: isNonBinding,
            languageCode: this.languageCode
        })
            .then(() => {
                notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
                const msg = isNonBinding
                    ? 'Non-binding quote PDF sent. Quote marked as non-binding.'
                    : 'PDF sent. Quote status updated to Presented.';
                this.dispatchEvent(new ShowToastEvent({
                    title:   'Quote Sent',
                    message: msg,
                    variant: 'success'
                }));
                this.dispatchEvent(new CloseActionScreenEvent());
            })
            .catch(err => {
                this.isSending    = false;
                this.hasError     = true;
                this.errorMessage = this._cleanError(err, 'Could not send the quote. Please try again.');
            });
    }

    _cleanError(err, fallback) {
        const raw = err?.body?.message || err?.message || '';
        const vrMatch = raw.match(/FIELD_CUSTOM_VALIDATION_EXCEPTION,\s*(.+?)(?::\s*\[|$)/);
        return vrMatch ? vrMatch[1].trim() : (raw || fallback);
    }

    // ================================================================
    // Private helpers
    // ================================================================

    _refreshNonBindingPreview(previousLanguage = null) {
        // Non-binding terms are static localized labels assembled in Apex.
        // Save them first, then refresh the PDF in a separate request.
        this.bindingSaving = true;
        saveBindingToQuote({
            quoteId: this.recordId,
            isBinding: false,
            termsHtml: null,
            languageCode: this.languageCode
        })
            .then(() => {
                this.bindingSaving = false;
                this.iframeUrl     = this._buildIframeUrl();
                notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            })
            .catch(err => {
                this.bindingSaving = false;
                if (previousLanguage) this.languageCode = previousLanguage;
                this.hasError     = true;
                this.errorMessage = this._cleanError(
                    err,
                    'Could not update the PDF language.'
                );
            });
    }

    _buildSubjectAndBody() {
        const acct = this.customer   || '';
        const sub  = this.company    || '';
        const ord  = this.orderNumber || '';
        const qt   = this.quoteNumber || '';

        if (this.isBinding) {
            this.subject =
                `Binding Quote #${ord} | ${acct} – ${sub}`;
            this.body =
                `Hello ${acct},\n\n` +
                `Please find attached the binding quote from ${sub} for your review.\n\n` +
                `If everything is in order, kindly sign the attached document and return it to us to proceed with your order.\n\n` +
                `Should you have any questions or require further assistance, please feel free to reach out and reference Order Number #${ord}.`;
        } else {
            this.subject =
                `Quotation #${ord} | ${acct} – Digital Edge DC`;
            this.body =
                `Hello ${acct},\n\n` +
                `Please find attached the quotation from Digital Edge DC for your review.\n\n` +
                `Please note that this is a non-binding quotation for initial review. If the details align with your requirements and you would like to proceed, please let us know so we can prepare the final documentation.\n\n` +
                `Should you have any questions or require any adjustments, please feel free to reach out and reference Quotation Number #${qt}`;
        }
    }

    _buildIframeUrl() {
        return this.recordId
            ? `/apex/DE_QuoteTemplate?id=${this.recordId}&lang=${this.languageCode}&_ts=${Date.now()}`
            : '';
    }
}