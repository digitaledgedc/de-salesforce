import { LightningElement, api } from "lwc";
import getMemoData from "@salesforce/apex/DealReviewMemoController.getMemoData";
import getQuoteLines from "@salesforce/apex/DealReviewMemoController.getQuoteLines";
import saveDraftFields from "@salesforce/apex/DealReviewMemoController.saveDraftFields";
import generateMemo from "@salesforce/apex/DealReviewMemoController.generateMemo";
import { CloseActionScreenEvent } from "lightning/actions";
import { ShowToastEvent } from "lightning/platformShowToastEvent";

export default class DeDealReviewMemo extends LightningElement {
    _recordId;
    _loaded = false;
    @api get recordId() { return this._recordId; }
    set recordId(value) {
        this._recordId = value;
        if (value && !this._loaded) { this._loaded = true; this.loadData(); }
    }

    connectedCallback() {
        if (this._recordId && !this._loaded) { this._loaded = true; this.loadData(); }
    }

    opp = {};
    quoteLines = [];
    missingFields = [];
    isLoading = true;
    isGenerating = false;
    hasUnsavedChanges = false;

    drNotes = "";
    drMarketBenchmark = "";
    drPricingJustification = "";
    drNrcScope = "";
    drNrcJustification = "";
    drOtherConsiderations = "";
    apiPct = null;
    pue = null;
    meteredPowerCharges = "";
    reservationRofr = null;
    availableQuotes = [];
    selectedQuoteId = "";
    selectedQuoteName = "";
    quoteLinesLoading = false;
    quoteMrc = null;
    quoteNrc = null;

    /* ── Accordion state ── */
    activeSection = "A";

    handleSectionToggle(event) {
        const section = event.currentTarget.dataset.section;
        this.activeSection = this.activeSection === section ? "" : section;
    }

    get sectionAClass() {
        return "sec-panel" + (this.activeSection === "A" ? " sec-panel-open" : "");
    }
    get sectionBTechClass() {
        return "sec-panel" + (this.activeSection === "B-Tech" ? " sec-panel-open" : "");
    }
    get sectionBCommClass() {
        return "sec-panel" + (this.activeSection === "B-Comm" ? " sec-panel-open" : "");
    }
    get sectionCClass() {
        return "sec-panel" + (this.activeSection === "C" ? " sec-panel-open" : "");
    }

    get meteredPowerOptions() {
        return [
            { label: "--None--", value: "" },
            { label: "Pass-through", value: "Pass-through" },
            { label: "Not Applicable", value: "Not Applicable" }
        ];
    }

    /* ── Brand bar ── */
    get accountName() { return this.opp.Account?.Name || ""; }
    get metaSummary() {
        const p = [];
        if (this.opp.Name) p.push(this.opp.Name);
        if (this.opp.Product_Interest__c) p.push(this.opp.Product_Interest__c);
        if (this.opp.Operation_Country__c) p.push(this.opp.Operation_Country__c);
        return p.length ? p.join(" \u00B7 ") : "";
    }
    get metaEnvelope() {
        const p = [];
        if (this.opp.Cabinets_Required__c) p.push(this.opp.Cabinets_Required__c + " cabs");
        if (this.opp.Power_kW__c) p.push(this.opp.Power_kW__c + " kW");
        if (this.opp.Contract_Term_Months__c) p.push(this.opp.Contract_Term_Months__c + " mo");
        return p.length ? p.join(" \u00B7 ") : "";
    }
    get hasMetaEnvelope() { return !!this.metaEnvelope; }
    get missingCountLabel() { return this.missingFields.length + " missing"; }
    get drStatus() { return this.opp.DR_Status__c || "Not Started"; }
    get statusClass() {
        const s = this.opp.DR_Status__c;
        if (s === "Approved") return "pill pill-good";
        if (s === "Rejected") return "pill pill-rose";
        if (s === "DR Required" || s === "Reviewing") return "pill pill-warn";
        return "pill pill-muted";
    }

    /* ── KPIs (driven by selected quote, not Opp fields) ── */
    get currency() { return this.opp.CurrencyIsoCode || "USD"; }
    get hasQuoteSelected() { return this.quoteMrc != null; }

    get kpiHeadline() {
        if (this.hasQuoteSelected) return this.fmtNum(this.quoteMrc);
        return "\u2014";
    }
    get kpiHeadlineSub() {
        if (this.hasQuoteSelected) return "MRC from selected quote";
        return "Select a quote";
    }
    get kpiHeadlineSubClass() {
        return this.hasQuoteSelected ? "kpi-sub" : "kpi-sub kpi-sub-warn";
    }

    get kpiMrc() {
        if (this.hasQuoteSelected) return this.fmtNum(this.quoteMrc);
        return "";
    }
    get kpiMrcHasValue() { return this.hasQuoteSelected; }
    get kpiMrcSub() {
        if (this.hasQuoteSelected) return "Recurring total";
        return "Select a quote";
    }
    get kpiMrcClass() {
        return this.hasQuoteSelected ? "kpi" : "kpi kpi-muted-left";
    }

    get kpiNrc() {
        if (this.hasQuoteSelected) return this.fmtNum(this.quoteNrc);
        return "\u2014";
    }
    get kpiNrcSub() {
        if (this.hasQuoteSelected) return "One-time from quote";
        return "Select a quote";
    }
    get kpiNrcSubClass() {
        return this.hasQuoteSelected ? "kpi-sub" : "kpi-sub kpi-sub-warn";
    }
    get kpiNrcClass() {
        return this.hasQuoteSelected ? "kpi" : "kpi kpi-muted-left";
    }

    /* ── Section hints (shown in collapsed header) ── */
    get basicInfoHint() {
        const p = [];
        if (this.opp.Customer_Type__c) p.push(this.opp.Customer_Type__c);
        if (this.opp.Operation_Country__c) p.push(this.opp.Operation_Country__c);
        if (this.opp.Target_Site__r?.Name) p.push(this.opp.Target_Site__r.Name);
        return p.join(" \u00B7 ") || "Read-only";
    }

    /* ── Per-section missing counts ── */
    get sectionAMissing() {
        let n = 0;
        if (!this.opp.DE_Entity__c) n++;
        if (!this.opp.GoLive_Target_Date__c) n++;
        return n;
    }
    get sectionAMissingLabel() { return this.sectionAMissing + " incomplete"; }
    get hasSectionAMissing() { return this.sectionAMissing > 0; }

    get sectionBTechMissing() {
        let n = 0;
        if (this.opp.Power_Density__c == null) n++;
        if (!this.opp.Data_Hall__c && !this.opp.Floor__c) n++;
        if (this.opp.Capacity_kW__c == null) n++;
        return n;
    }
    get sectionBTechMissingLabel() { return this.sectionBTechMissing + " incomplete"; }
    get hasSectionBTechMissing() { return this.sectionBTechMissing > 0; }

    get sectionBCommMissing() {
        let n = 0;
        if (this.opp.Quote_MRC__c == null) n++;
        return n;
    }
    get sectionBCommMissingLabel() { return this.sectionBCommMissing + " incomplete"; }
    get hasSectionBCommMissing() { return this.sectionBCommMissing > 0; }

    get sectionCMissing() {
        let n = 0;
        if (!this.drNotes) n++;
        return n;
    }
    get sectionCMissingLabel() { return this.sectionCMissing + " incomplete"; }
    get hasSectionCMissing() { return this.sectionCMissing > 0; }

    /* ── Column A: Basic Info ── */
    get customerType() { return this.opp.Customer_Type__c || ""; }
    get countrySite() {
        const c = this.opp.Operation_Country__c || "";
        const s = this.opp.Target_Site__r?.Name || "";
        return [c, s].filter(Boolean).join(" \u00B7 ");
    }
    get productInterest() { return this.opp.Product_Interest__c || ""; }
    get ownerName() { return this.opp.Owner?.Name || ""; }
    get contractingEntity() { return this.opp.DE_Entity__r?.Name || ""; }
    get hasContractingEntity() { return !!this.opp.DE_Entity__c; }
    get contractingEntityFldClass() { return this.opp.DE_Entity__c ? "fld" : "fld fld-warn"; }

    get isExistingCustomer() { return this.opp.Account?.Status__c === "Active" ? "Yes" : "No"; }
    get isExistingChip() { return this.opp.Account?.Status__c === "Active"; }
    get creditCheck() { return this.opp.Account?.KYC_Status__c || "Not Completed"; }
    get creditCheckChip() {
        const s = this.opp.Account?.KYC_Status__c;
        return s === "Approved" || s === "Complete";
    }
    get rfsDate() {
        if (!this.opp.GoLive_Target_Date__c) return "";
        return new Date(this.opp.GoLive_Target_Date__c).toLocaleDateString("en-GB", {
            day: "2-digit", month: "short", year: "numeric"
        });
    }
    get hasRfsDate() { return !!this.opp.GoLive_Target_Date__c; }
    get rfsDateFldClass() { return this.opp.GoLive_Target_Date__c ? "fld" : "fld fld-warn"; }

    /* ── Section B-Tech ── */
    get powerKw() { return this.fmt(this.opp.Power_kW__c, "kW"); }
    get hasPower() { return this.opp.Power_kW__c != null; }
    get cabinets() { return this.fmt(this.opp.Cabinets_Required__c); }
    get hasCabinets() { return this.opp.Cabinets_Required__c != null; }
    get powerDensity() { return this.fmt(this.opp.Power_Density__c, "W/sqm"); }
    get hasPowerDensity() { return this.opp.Power_Density__c != null; }
    get powerDensityFldClass() { return this.opp.Power_Density__c != null ? "fld" : "fld fld-warn"; }
    get dataHall() {
        const dh = this.opp.Data_Hall__c || "";
        const fl = this.opp.Floor__c || "";
        return dh || fl ? `${dh}${dh && fl ? " / " : ""}${fl}` : "";
    }
    get hasDataHall() { return !!(this.opp.Data_Hall__c || this.opp.Floor__c); }
    get dataHallFldClass() { return this.hasDataHall ? "fld" : "fld fld-warn"; }
    get capacityKw() { return this.fmt(this.opp.Capacity_kW__c, "kW"); }
    get hasCapacity() { return this.opp.Capacity_kW__c != null; }
    get capacityFldClass() { return this.opp.Capacity_kW__c != null ? "fld" : "fld fld-warn"; }
    get techSummary() {
        const p = [];
        if (this.opp.Power_kW__c) p.push(this.opp.Power_kW__c + " kW");
        if (this.opp.Cabinets_Required__c) p.push(this.opp.Cabinets_Required__c + " cabs");
        return p.join(" \u00B7 ") || "Envelope";
    }

    /* ── Section B-Comm ── */
    get headlinePrice() { return this.fmtCurrency(this.opp.Quote_MRC__c); }
    get hasHeadlinePrice() { return this.opp.Quote_MRC__c != null; }
    get headlinePriceFldClass() { return this.opp.Quote_MRC__c != null ? "fld" : "fld fld-warn"; }
    get freeMonths() { return this.opp.Free_Months__c ? `${this.opp.Free_Months__c} months` : ""; }
    get hasFreeMonths() { return !!this.opp.Free_Months__c; }
    get contractTenure() {
        return this.opp.Contract_Term_Months__c ? `${this.opp.Contract_Term_Months__c} months` : "";
    }
    get renewalTerms() { return this.opp.Renewal_Type__c || ""; }
    get hasRenewalTerms() { return !!this.opp.Renewal_Type__c; }
    get rampSummary() {
        if (!this.opp.Is_Ramp_Deal__c) return "No";
        return `Yes - ${this.opp.Ramp_Phases__c || 0} phases`;
    }
    get totalMrc() { return this.fmtCurrency(this.opp.Total_Deal_MRC__c); }
    get totalNrc() { return this.fmtCurrency(this.opp.NRC__c); }
    get hasNrcBudget() { return this.opp.NRC_Budget_Approved__c != null; }
    get commSummary() {
        const p = [this.currency];
        if (this.opp.Contract_Term_Months__c) p.push(this.opp.Contract_Term_Months__c + " mo");
        return p.join(" \u00B7 ");
    }

    /* ── Quote picker ── */
    get quoteOptions() {
        const opts = [{ label: "-- Select Quote --", value: "" }];
        for (const q of this.availableQuotes) {
            opts.push({ label: q.label, value: q.quoteId });
        }
        return opts;
    }
    get isQuoteContext() { return this.recordId && this.recordId.startsWith("0Q0"); }
    get hasQuotes() { return this.availableQuotes.length > 0; }
    get quoteHint() {
        if (this.selectedQuoteName) return this.selectedQuoteName;
        if (this.availableQuotes.length) return this.availableQuotes.length + " quotes available";
        return "No quote linked";
    }

    /* ── Footer ── */
    get hasMissingFields() { return this.missingFields.length > 0; }
    get hasQuoteLines() { return this.quoteLines.length > 0; }

    get completionPct() {
        const checks = [
            this.opp.Customer_Type__c, this.opp.Operation_Country__c,
            this.opp.Product_Interest__c, this.opp.Owner?.Name,
            this.opp.DE_Entity__c, this.opp.GoLive_Target_Date__c,
            this.opp.Power_kW__c, this.opp.Cabinets_Required__c,
            this.opp.Power_Density__c, this.opp.Data_Hall__c || this.opp.Floor__c,
            this.opp.Capacity_kW__c, this.pue,
            this.opp.Quote_MRC__c, this.apiPct, this.meteredPowerCharges,
            this.opp.Contract_Term_Months__c, this.opp.Renewal_Type__c,
            this.opp.Total_Deal_MRC__c,
            this.drMarketBenchmark, this.drPricingJustification,
            this.drNrcScope, this.drNotes, this.drOtherConsiderations
        ];
        const filled = checks.filter(Boolean).length;
        return Math.round((filled / checks.length) * 100);
    }
    get completionPctLabel() { return this.completionPct + "%"; }
    get ringDasharray() { return (2 * Math.PI * 13).toFixed(2); }
    get ringDashoffset() {
        const circ = 2 * Math.PI * 13;
        return (circ * (1 - this.completionPct / 100)).toFixed(2);
    }
    get footerStrong() {
        const n = this.missingFields.length;
        if (n === 0) return "Ready";
        return n + " field" + (n > 1 ? "s" : "");
    }
    get footerDetail() {
        if (this.missingFields.length === 0) return " for review";
        return " away from a clean review \u00B7 " + this.missingFields.join(" \u00B7 ");
    }

    /* ── Data ── */
    async loadData() {
        this.isLoading = true;
        try {
            const data = await getMemoData({ oppId: this.recordId });
            this.opp = data.opp;
            this.availableQuotes = data.availableQuotes || [];
            this.quoteLines = [];
            this.selectedQuoteId = "";
            this.selectedQuoteName = "";
            this.missingFields = data.missingFields || [];

            // Auto-select quote when launched from a Quote page
            if (this.recordId && this.recordId.startsWith("0Q0")) {
                const match = this.availableQuotes.find(q => q.quoteId === this.recordId);
                if (match) {
                    this.selectedQuoteId = this.recordId;
                    this.selectedQuoteName = match.quoteName;
                    this._loadQuoteLines(this.recordId);
                }
            }

            this.drNotes = this.opp.DR_Notes__c || "";
            this.drMarketBenchmark = this.opp.DR_Market_Benchmark__c || "";
            this.drPricingJustification = this.opp.DR_Pricing_Justification__c || "";
            this.drNrcScope = this.opp.DR_NRC_Scope__c || "";
            this.drNrcJustification = this.opp.DR_NRC_Justification__c || "";
            this.drOtherConsiderations = this.opp.DR_Other_Considerations__c || "";
            this.apiPct = this.opp.API_Pct__c;
            this.pue = this.opp.PUE__c;
            this.meteredPowerCharges = this.opp.Metered_Power_Charges__c || "";
            this.reservationRofr = this.opp.Reservation_ROFR_kW__c;
        } catch (e) {
            this.showError("Failed to load deal data", e);
        } finally {
            this.isLoading = false;
        }
    }

    async handleQuoteSelect(event) {
        const qId = event.detail.value;
        this.selectedQuoteId = qId;
        if (!qId) {
            this.quoteLines = [];
            this.selectedQuoteName = "";
            this.quoteMrc = null;
            this.quoteNrc = null;
            return;
        }
        const match = this.availableQuotes.find(q => q.quoteId === qId);
        this.selectedQuoteName = match ? match.quoteName : "";
        await this._loadQuoteLines(qId);
    }

    async _loadQuoteLines(qId) {
        this.quoteLinesLoading = true;
        try {
            const qlis = await getQuoteLines({ quoteId: qId });
            this.quoteLines = (qlis || []).map((ql, i) => ({
                ...ql,
                idx: i + 1,
                productName: ql.Product2?.Name || "Unknown",
                productCode: ql.Product2?.ProductCode || "",
                productFamily: ql.Product2?.Family || "",
                chargeType: ql.Charge_Type__c || "",
                formattedUnit: this.formatNum(ql.UnitPrice),
                formattedTotal: this.formatNum(ql.TotalPrice)
            }));
            let mrc = 0, nrc = 0;
            for (const ql of this.quoteLines) {
                const tp = ql.TotalPrice || 0;
                const ct = ql.chargeType;
                if (ct === "NRC") { nrc += tp; }
                else { mrc += tp; }
            }
            this.quoteMrc = mrc;
            this.quoteNrc = nrc;
        } catch (e) {
            this.showError("Failed to load quote lines", e);
            this.quoteLines = [];
            this.quoteMrc = null;
            this.quoteNrc = null;
        } finally {
            this.quoteLinesLoading = false;
        }
    }

    handleFieldChange(event) {
        const field = event.target.dataset.field;
        this[field] = event.target.value;
        this.hasUnsavedChanges = true;
    }

    async handleSave() {
        this.isLoading = true;
        try {
            const fields = {
                DR_Notes__c: this.drNotes,
                DR_Market_Benchmark__c: this.drMarketBenchmark,
                DR_Pricing_Justification__c: this.drPricingJustification,
                DR_NRC_Scope__c: this.drNrcScope,
                DR_NRC_Justification__c: this.drNrcJustification,
                DR_Other_Considerations__c: this.drOtherConsiderations,
                API_Pct__c: this.apiPct ? parseFloat(this.apiPct) : null,
                PUE__c: this.pue ? parseFloat(this.pue) : null,
                Metered_Power_Charges__c: this.meteredPowerCharges,
                Reservation_ROFR_kW__c: this.reservationRofr ? parseFloat(this.reservationRofr) : null
            };
            await saveDraftFields({ oppId: this.recordId, fieldsJson: JSON.stringify(fields) });
            this.hasUnsavedChanges = false;
            await this.loadData();
            this.showToast("Saved", "Deal review fields updated", "success");
        } catch (e) {
            this.showError("Failed to save fields", e);
        } finally {
            this.isLoading = false;
        }
    }

    async handleGenerate() {
        if (this.hasUnsavedChanges) { await this.handleSave(); }
        this.isGenerating = true;
        try {
            await generateMemo({ oppId: this.recordId });
            this.showToast("Deal Review Memo Generated",
                "PDF attached to this Opportunity.", "success");
            this.dispatchEvent(new CloseActionScreenEvent());
        } catch (e) {
            this.showError("Failed to generate memo", e);
        } finally {
            this.isGenerating = false;
        }
    }

    handleClose() { this.dispatchEvent(new CloseActionScreenEvent()); }

    fmt(val, suffix) {
        if (val == null) return "";
        const num = Number(val).toLocaleString("en-US", { maximumFractionDigits: 2 });
        return suffix ? `${num} ${suffix}` : num;
    }
    fmtCurrency(val) {
        if (val == null) return "";
        return `${this.currency} ${Number(val).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
    }
    fmtNum(val) {
        if (val == null) return "0";
        return Number(val).toLocaleString("en-US", { minimumFractionDigits: 0, maximumFractionDigits: 0 });
    }
    formatNum(val) {
        if (val == null) return "0.00";
        return Number(val).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
    }
    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
    showError(prefix, error) {
        const msg = error?.body?.message || error?.message || "Unknown error";
        this.showToast(prefix, msg, "error");
    }
}