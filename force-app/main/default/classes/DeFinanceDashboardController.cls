/**
 * DeFinanceDashboardController
 * Apex controller for the Finance Dashboard LWC.
 * Queries all pending finance items across objects using indexed field-based
 * checks (no ProcessInstance queries) for scalability.
 *
 * FLS enforced via Security.stripInaccessible on all reads.
 */
public with sharing class DeFinanceDashboardController {

    // Without-sharing helper so finance users can update SI records
    // they can read (via queue membership / dashboard) but don't own.
    // CRUD check is performed in the calling method before any DML.
    private without sharing class SiDmlHelper {
        void doUpdate(SObject record) { update record; }
        void doUpdateList(List<SObject> records) { update records; }
    }

    // Without-sharing helper for Quote DML — bypasses Revenue Cloud
    // AppUsageAssignment restrictions and sharing rules.
    private without sharing class QuoteDmlHelper {
        void doUpdate(SObject record) { update record; }
    }

    // Without-sharing helper for quote queries — Finance needs to see ALL
    // active quotes for credit evaluation, not just ones they own.
    private without sharing class QuoteQueryHelper {
        List<ActiveQuoteInfo> getQuotes(Id accountId) {
            List<ActiveQuoteInfo> result = new List<ActiveQuoteInfo>();
            for (Quote q : [
                SELECT Id, Quote_Number__c, Total_MRC_2__c, Total_NRC__c, CurrencyIsoCode, Status
                FROM Quote
                WHERE AccountId = :accountId
                  AND Status IN ('Draft', 'In Review', 'Approved', 'Presented')
                ORDER BY Total_MRC_2__c DESC NULLS LAST
            ]) {
                ActiveQuoteInfo info = new ActiveQuoteInfo();
                info.quoteId = q.Id;
                info.quoteNumber = q.Quote_Number__c;
                info.mrc = q.Total_MRC_2__c;
                info.nrc = q.Total_NRC__c;
                info.currencyCode = q.CurrencyIsoCode;
                info.status = q.Status;
                result.add(info);
            }
            return result;
        }
    }

    public class FinanceItem implements Comparable {
        @AuraEnabled public String id;
        @AuraEnabled public String itemType;
        @AuraEnabled public String label;
        @AuraEnabled public String accountName;
        @AuraEnabled public String accountId;
        @AuraEnabled public String quoteNumber;
        @AuraEnabled public String quoteId;
        @AuraEnabled public String country;
        @AuraEnabled public String entityName;
        @AuraEnabled public String status;
        @AuraEnabled public String description;
        @AuraEnabled public Decimal mrc;
        @AuraEnabled public Decimal nrc;
        @AuraEnabled public Datetime createdDate;
        @AuraEnabled public Long agingMinutes;
        @AuraEnabled public String recordUrl;
        @AuraEnabled public Decimal creditLimitMrc;
        @AuraEnabled public Decimal creditLimitNrc;
        @AuraEnabled public Decimal quoteMrc;
        @AuraEnabled public Decimal quoteNrc;
        @AuraEnabled public String currencyCode;
        @AuraEnabled public String accountCurrencyCode;
        @AuraEnabled public String resolutionNotes;
        // Credit exposure — all in the Account's currency (corporate), never the quote's.
        @AuraEnabled public Decimal acctTotalMrc;
        @AuraEnabled public Decimal acctTotalNrc;
        @AuraEnabled public Decimal overMrc;
        @AuraEnabled public Decimal overNrc;
        @AuraEnabled public String breachReason;

        public Integer compareTo(Object other) {
            FinanceItem o = (FinanceItem) other;
            // Oldest first (highest aging)
            if (this.agingMinutes == null && o.agingMinutes == null) return 0;
            if (this.agingMinutes == null) return 1;
            if (o.agingMinutes == null) return -1;
            return o.agingMinutes > this.agingMinutes ? 1 : (o.agingMinutes < this.agingMinutes ? -1 : 0);
        }
    }

    /**
     * Credit exposure is evaluated on the Account's cumulative active-quote totals,
     * which CreditRollupService has already converted to corporate currency — the same
     * basis Quote.Credit_Limit_Exceeded__c uses. The triggering quote's own total is in
     * the quote's currency and must never be compared against the limit directly.
     */
    private static void applyCreditExposure(FinanceItem fi, Account a) {
        if (a == null) return;

        Decimal totalMrc = a.Total_Active_Quoted_MRC__c != null ? a.Total_Active_Quoted_MRC__c : 0;
        Decimal totalNrc = a.Total_Active_Quoted_NRC__c != null ? a.Total_Active_Quoted_NRC__c : 0;
        Decimal overdue  = a.Overdue_90_Days__c != null ? a.Overdue_90_Days__c : 0;

        fi.acctTotalMrc = totalMrc;
        fi.acctTotalNrc = totalNrc;
        fi.overMrc = (a.Credit_Limit_MRC__c != null && totalMrc > a.Credit_Limit_MRC__c)
            ? totalMrc - a.Credit_Limit_MRC__c : 0;
        fi.overNrc = (a.Credit_Limit_NRC__c != null && totalNrc > a.Credit_Limit_NRC__c)
            ? totalNrc - a.Credit_Limit_NRC__c : 0;

        List<String> reasons = new List<String>();
        if (fi.overMrc > 0) reasons.add('MRC');
        if (fi.overNrc > 0) reasons.add('NRC');
        if (overdue > 0) reasons.add('Overdue 90+');
        fi.breachReason = String.join(reasons, ' + ');
    }

    public class ActiveQuoteInfo {
        @AuraEnabled public Id quoteId;
        @AuraEnabled public String quoteNumber;
        @AuraEnabled public Decimal mrc;
        @AuraEnabled public Decimal nrc;
        @AuraEnabled public String currencyCode;
        @AuraEnabled public String status;
    }

    @AuraEnabled
    public static List<FinanceItem> getPendingItems() {
        // Auto-expire stale Credit Limit SIs before returning results
        expireStaleCreditLimitSIs();

        List<FinanceItem> items = new List<FinanceItem>();
        Datetime now = Datetime.now();

        // 1. Special Instructions (Pending)
        for (Special_Instruction__c si : [
            SELECT Id, Name, Type__c, Status__c, Description__c, Country__c,
                   Quote__c, Quote__r.Quote_Number__c,
                   Quote__r.Total_MRC_2__c, Quote__r.Total_NRC__c, Quote__r.CurrencyIsoCode,
                   Quote__r.DE_Entity__r.Operation_Country__c,
                   Quote__r.DE_Entity__r.Name,
                   Account__c, Account__r.Name,
                   Account__r.Credit_Limit_MRC__c, Account__r.Credit_Limit_NRC__c,
                   Account__r.Total_Active_Quoted_MRC__c, Account__r.Total_Active_Quoted_NRC__c,
                   Account__r.Overdue_90_Days__c,
                   Account__r.CurrencyIsoCode,
                   CreatedDate
            FROM Special_Instruction__c
            WHERE Status__c = 'Pending'
              AND RecordType.DeveloperName = 'Special_Billing_Instruction'
            ORDER BY CreatedDate ASC
            LIMIT 200
        ]) {
            FinanceItem fi = new FinanceItem();
            fi.id = si.Id;
            fi.itemType = si.Type__c == 'Credit Limit' ? 'Credit Limit' : 'Special Instruction';
            fi.label = si.Type__c;
            fi.accountName = si.Account__r != null ? si.Account__r.Name : '';
            fi.accountId = si.Account__c;
            fi.entityName = si.Quote__r?.DE_Entity__r?.Name;
            if (si.Type__c == 'Credit Limit' && si.Account__r != null) {
                fi.creditLimitMrc = si.Account__r.Credit_Limit_MRC__c;
                fi.creditLimitNrc = si.Account__r.Credit_Limit_NRC__c;
                fi.accountCurrencyCode = si.Account__r.CurrencyIsoCode;
                // Amount column: show the triggering quote's MRC/NRC in the quote's own currency
                fi.mrc = si.Quote__r != null ? si.Quote__r.Total_MRC_2__c : null;
                fi.nrc = si.Quote__r != null ? si.Quote__r.Total_NRC__c : null;
                fi.currencyCode = si.Quote__r != null ? si.Quote__r.CurrencyIsoCode : si.Account__r.CurrencyIsoCode;
                // Triggering quote amounts (same as mrc/nrc but kept for the review panel)
                fi.quoteMrc = fi.mrc;
                fi.quoteNrc = fi.nrc;
                applyCreditExposure(fi, si.Account__r);
            }
            fi.quoteNumber = si.Quote__r != null ? si.Quote__r.Quote_Number__c : '';
            fi.quoteId = si.Quote__c;
            // Country: prefer SI field, fall back to Quote subsidiary
            // FB-809: group by the subsidiary (DE Entity), not the operation country.
            // Finance is routed by subsidiary, so a subsidiary always sits under its own country.
            fi.country = String.isNotBlank(si.Quote__r?.DE_Entity__r?.Operation_Country__c)
                ? si.Quote__r.DE_Entity__r.Operation_Country__c
                : si.Country__c;
            fi.status = 'Pending';
            fi.description = si.Description__c;
            fi.createdDate = si.CreatedDate;
            fi.agingMinutes = (now.getTime() - si.CreatedDate.getTime()) / 60000;
            fi.recordUrl = '/' + si.Id;
            items.add(fi);
        }

        // 2. Account Finance Approvals — show every account still in the approval pipeline
        //    (any non-terminal phase). Inverting the filter (vs an enumerated pending list)
        //    keeps in-progress accounts visible through all phases and is resilient to new
        //    or stray phase values. FB-845.
        Set<String> excludedPhases = new Set<String>{
            'Approved', 'Rejected_DnB', 'Rejected_KYC', 'Not_Required'
        };
        for (Account a : [
            SELECT Id, Name, Finance_Approval_Phase__c, Operation_Country__c,
                   DE_Entity__c, DE_Entity__r.Name, DE_Entity__r.Operation_Country__c,
                   Finance_Originating_Quote__c, Finance_Originating_Quote__r.Quote_Number__c,
                   Finance_Originating_Quote__r.Total_MRC_2__c, Finance_Originating_Quote__r.Total_NRC__c,
                   Finance_Originating_Quote__r.CurrencyIsoCode,
                   Finance_Approval_Phase_Changed__c, CreatedDate
            FROM Account
            WHERE Finance_Approval_Phase__c != null
              AND Finance_Approval_Phase__c NOT IN :excludedPhases
              AND RecordType.DeveloperName = 'Customer'
              AND Operation_Country__c IN :DE_COUNTRIES
            ORDER BY CreatedDate ASC
            LIMIT 200
        ]) {
            FinanceItem fi = new FinanceItem();
            fi.id = a.Id;
            fi.itemType = 'Customer Approval';
            fi.label = phaseLabel(a.Finance_Approval_Phase__c);
            fi.accountName = a.Name;
            fi.accountId = a.Id;
            fi.quoteNumber = a.Finance_Originating_Quote__r != null ? a.Finance_Originating_Quote__r.Quote_Number__c : '';
            fi.quoteId = a.Finance_Originating_Quote__c;
            // FB-809: group by the subsidiary's country, not the customer's operation country.
            fi.country = a.DE_Entity__r != null ? a.DE_Entity__r.Operation_Country__c : a.Operation_Country__c;
            fi.entityName = a.DE_Entity__r != null ? a.DE_Entity__r.Name : null;
            fi.status = a.Finance_Approval_Phase__c;
            fi.mrc = a.Finance_Originating_Quote__r != null ? a.Finance_Originating_Quote__r.Total_MRC_2__c : null;
            fi.nrc = a.Finance_Originating_Quote__r != null ? a.Finance_Originating_Quote__r.Total_NRC__c : null;
            fi.currencyCode = a.Finance_Originating_Quote__r != null ? a.Finance_Originating_Quote__r.CurrencyIsoCode : null;
            Datetime ref = a.Finance_Approval_Phase_Changed__c != null
                ? a.Finance_Approval_Phase_Changed__c : a.CreatedDate;
            fi.createdDate = ref;
            fi.agingMinutes = (now.getTime() - ref.getTime()) / 60000;
            fi.recordUrl = '/' + a.Id;
            items.add(fi);
        }

        // 3. BAN Approvals (Pending Approval)
        for (BillingAccount__c ban : [
            SELECT Id, Name, BAN_Number__c, Account__c, Account__r.Name,
                   CurrencyIsoCode, Invoice_Frequency__c,
                   Source_Quote__c, Source_Quote__r.Quote_Number__c,
                   DE_Entity__c, DE_Entity__r.Operation_Country__c, DE_Entity__r.Name,
                   CreatedDate
            FROM BillingAccount__c
            WHERE Status__c = 'Pending Approval'
            ORDER BY CreatedDate ASC
            LIMIT 200
        ]) {
            FinanceItem fi = new FinanceItem();
            fi.id = ban.Id;
            fi.itemType = 'BAN Approval';
            fi.label = 'New BAN';
            fi.accountName = ban.Account__r != null ? ban.Account__r.Name : '';
            fi.accountId = ban.Account__c;
            fi.quoteNumber = ban.Source_Quote__r != null ? ban.Source_Quote__r.Quote_Number__c : '';
            fi.quoteId = ban.Source_Quote__c;
            fi.country = ban.DE_Entity__r != null ? ban.DE_Entity__r.Operation_Country__c : null;
            fi.entityName = ban.DE_Entity__r != null ? ban.DE_Entity__r.Name : null;
            fi.description = ban.CurrencyIsoCode + ' | ' + ban.Invoice_Frequency__c;
            fi.currencyCode = ban.CurrencyIsoCode;
            fi.createdDate = ban.CreatedDate;
            fi.agingMinutes = (now.getTime() - ban.CreatedDate.getTime()) / 60000;
            fi.recordUrl = '/' + ban.Id;
            items.add(fi);
        }

        // 4. Credit Limit — now handled via Special Instructions (Type = 'Credit Limit')
        // The flow Quote_AfterSave_CreditLimitApprovalSubmit creates SIs owned by the country finance queue.
        // These SIs show up in section 1 (Special Instructions) above, with Acknowledge button.
        // When acknowledged, handleAcknowledge in the LWC also sets Credit_Finance_Approved__c on the Quote.

        // Normalize countries and sort
        for (FinanceItem fi : items) {
            fi.country = normalizeCountry(fi.country);
        }
        items.sort();
        return items;
    }

    private static String phaseLabel(String phase) {
        Map<String, String> labels = new Map<String, String>{
            'Not_Started' => 'Awaiting D&B Review',
            'DnB_Pending' => 'D&B In Progress',
            'KYC_Pending' => 'KYC Review',
            'Legal_Review_Pending' => 'Legal Review'
        };
        return labels.containsKey(phase) ? labels.get(phase) : phase;
    }

    private static final Set<String> DE_COUNTRIES = new Set<String>{
        'Japan','Korea','Indonesia','Philippines','China','India','Thailand','Malaysia'
    };
    //'Singapore','South Korea','Hong Kong'

    private static String normalizeCountry(String val) {
        if (String.isBlank(val)) return '';
        Map<String, String> codeToName = new Map<String, String>{
            'SG' => 'Singapore', 'JP' => 'Japan', 'KR' => 'Korea',
            'ID' => 'Indonesia', 'PH' => 'Philippines', 'CN' => 'China',
            'IN' => 'India', 'TH' => 'Thailand', 'MY' => 'Malaysia',
            'HK' => 'Hong Kong',
            'SOUTH KOREA' => 'Korea', 'BD' => 'Bangladesh'
        };
        String mapped = codeToName.get(val.toUpperCase());
        return mapped != null ? mapped : val;
    }

    @AuraEnabled
    public static List<FinanceItem> getHistoricalItems() {
        List<FinanceItem> items = new List<FinanceItem>();
        Datetime now = Datetime.now();

        for (Special_Instruction__c si : [
            SELECT Id, Name, Type__c, Status__c, Description__c, Country__c,
                   Quote__c, Quote__r.Quote_Number__c,
                   Quote__r.Total_MRC_2__c, Quote__r.Total_NRC__c, Quote__r.CurrencyIsoCode,
                   Quote__r.DE_Entity__r.Operation_Country__c,
                   Quote__r.DE_Entity__r.Name,
                   Account__c, Account__r.Name,
                   Account__r.Credit_Limit_MRC__c, Account__r.Credit_Limit_NRC__c,
                   Account__r.Total_Active_Quoted_MRC__c, Account__r.Total_Active_Quoted_NRC__c,
                   Account__r.Overdue_90_Days__c,
                   Account__r.CurrencyIsoCode,
                   Acknowledged_By__r.Name, Acknowledged_Date__c,
                   Resolution_Notes__c,
                   CreatedDate
            FROM Special_Instruction__c
            WHERE Status__c IN ('Acknowledged', 'Rejected', 'Expired')
              AND RecordType.DeveloperName = 'Special_Billing_Instruction'
            ORDER BY Acknowledged_Date__c DESC NULLS LAST
            LIMIT 200
        ]) {
            FinanceItem fi = new FinanceItem();
            fi.id = si.Id;
            fi.itemType = si.Type__c == 'Credit Limit' ? 'Credit Limit' : 'Special Instruction';
            fi.label = si.Type__c;
            fi.accountName = si.Account__r != null ? si.Account__r.Name : '';
            fi.accountId = si.Account__c;
            fi.entityName = si.Quote__r?.DE_Entity__r?.Name;
            fi.quoteNumber = si.Quote__r != null ? si.Quote__r.Quote_Number__c : '';
            fi.quoteId = si.Quote__c;
            // FB-809: group by the subsidiary (DE Entity), not the operation country.
            // Finance is routed by subsidiary, so a subsidiary always sits under its own country.
            fi.country = String.isNotBlank(si.Quote__r?.DE_Entity__r?.Operation_Country__c)
                ? si.Quote__r.DE_Entity__r.Operation_Country__c
                : si.Country__c;
            fi.status = si.Status__c;
            fi.description = si.Description__c;
            fi.mrc = si.Quote__r != null ? si.Quote__r.Total_MRC_2__c : null;
            fi.nrc = si.Quote__r != null ? si.Quote__r.Total_NRC__c : null;
            fi.currencyCode = si.Quote__r != null ? si.Quote__r.CurrencyIsoCode : (si.Account__r != null ? si.Account__r.CurrencyIsoCode : null);
            fi.accountCurrencyCode = si.Account__r != null ? si.Account__r.CurrencyIsoCode : null;
            fi.creditLimitMrc = si.Account__r != null ? si.Account__r.Credit_Limit_MRC__c : null;
            fi.creditLimitNrc = si.Account__r != null ? si.Account__r.Credit_Limit_NRC__c : null;
            if (si.Type__c == 'Credit Limit') {
                applyCreditExposure(fi, si.Account__r);
            }
            fi.resolutionNotes = si.Resolution_Notes__c;
            fi.createdDate = si.Acknowledged_Date__c != null ? si.Acknowledged_Date__c : si.CreatedDate;
            fi.agingMinutes = -1;
            fi.recordUrl = '/' + si.Id;
            items.add(fi);
        }

        // Historical account approvals (Approved + Rejected)
        Set<String> deCountries = DE_COUNTRIES;
        Set<String> completedPhases = new Set<String>{'Approved','Rejected_DnB','Rejected_KYC'};
        for (Account a : [
            SELECT Id, Name, Finance_Approval_Phase__c, Operation_Country__c,
                   DE_Entity__c, DE_Entity__r.Name, DE_Entity__r.Operation_Country__c,
                   Finance_Approved_Date__c,
                   Finance_Originating_Quote__c, Finance_Originating_Quote__r.Quote_Number__c,
                   Finance_Originating_Quote__r.Total_MRC_2__c, Finance_Originating_Quote__r.Total_NRC__c,
                   Finance_Originating_Quote__r.CurrencyIsoCode
            FROM Account
            WHERE Finance_Approval_Phase__c IN :completedPhases
              AND RecordType.DeveloperName = 'Customer'
              AND Operation_Country__c IN :deCountries
            ORDER BY LastModifiedDate DESC
            LIMIT 100
        ]) {
            FinanceItem fi = new FinanceItem();
            fi.id = a.Id;
            fi.itemType = 'Customer Approval';
            fi.label = a.Finance_Approval_Phase__c == 'Approved' ? 'Approved'
                : a.Finance_Approval_Phase__c == 'Rejected_DnB' ? 'Rejected - D&B'
                : 'Rejected - KYC';
            fi.accountName = a.Name;
            fi.accountId = a.Id;
            fi.quoteNumber = a.Finance_Originating_Quote__r != null ? a.Finance_Originating_Quote__r.Quote_Number__c : '';
            fi.quoteId = a.Finance_Originating_Quote__c;
            // FB-809: group by the subsidiary's country, not the customer's operation country.
            fi.country = a.DE_Entity__r != null ? a.DE_Entity__r.Operation_Country__c : a.Operation_Country__c;
            fi.entityName = a.DE_Entity__r != null ? a.DE_Entity__r.Name : null;
            fi.status = fi.label;
            fi.mrc = a.Finance_Originating_Quote__r != null ? a.Finance_Originating_Quote__r.Total_MRC_2__c : null;
            fi.nrc = a.Finance_Originating_Quote__r != null ? a.Finance_Originating_Quote__r.Total_NRC__c : null;
            fi.currencyCode = a.Finance_Originating_Quote__r != null ? a.Finance_Originating_Quote__r.CurrencyIsoCode : null;
            fi.createdDate = a.Finance_Approved_Date__c;
            fi.agingMinutes = -1;
            fi.recordUrl = '/' + a.Id;
            items.add(fi);
        }

        // Historical BAN approvals (Active)
        for (BillingAccount__c ban : [
            SELECT Id, BAN_Number__c, Account__c, Account__r.Name,
                   CurrencyIsoCode, Invoice_Frequency__c, LastModifiedDate,
                   DE_Entity__c, DE_Entity__r.Name, DE_Entity__r.Operation_Country__c
            FROM BillingAccount__c
            WHERE Status__c = 'Active'
            ORDER BY LastModifiedDate DESC
            LIMIT 50
        ]) {
            FinanceItem fi = new FinanceItem();
            fi.id = ban.Id;
            fi.itemType = 'BAN Approval';
            fi.label = ban.BAN_Number__c != null ? ban.BAN_Number__c : 'Approved';
            fi.accountName = ban.Account__r != null ? ban.Account__r.Name : '';
            fi.entityName = ban.DE_Entity__r != null ? ban.DE_Entity__r.Name : null;
            fi.country = ban.DE_Entity__r != null ? ban.DE_Entity__r.Operation_Country__c : null;
            fi.accountId = ban.Account__c;
            fi.description = ban.CurrencyIsoCode + ' | ' + (ban.Invoice_Frequency__c != null ? ban.Invoice_Frequency__c : 'N/A');
            fi.currencyCode = ban.CurrencyIsoCode;
            fi.status = 'Approved';
            fi.createdDate = ban.LastModifiedDate;
            fi.agingMinutes = -1;
            fi.recordUrl = '/' + ban.Id;
            items.add(fi);
        }

        for (FinanceItem fi : items) {
            fi.country = normalizeCountry(fi.country);
        }
        return items;
    }

    // ─── Active quotes for credit limit review panel ───

    @AuraEnabled
    public static List<ActiveQuoteInfo> getActiveQuotesForAccount(Id accountId) {
        return new QuoteQueryHelper().getQuotes(accountId);
    }

    // ─── FX conversion rates (for USD equivalent display) ───

    @AuraEnabled(cacheable=true)
    public static Map<String, Decimal> getCurrencyRates() {
        Map<String, Decimal> rates = new Map<String, Decimal>();
        for (CurrencyType ct : [SELECT IsoCode, ConversionRate FROM CurrencyType WHERE IsActive = true]) {
            rates.put(ct.IsoCode, ct.ConversionRate);
        }
        return rates;
    }

    // ─── Credit limit actions ───

    @AuraEnabled
    public static void updateCreditLimits(Id accountId, Decimal limitMrc, Decimal limitNrc) {
        if (!Schema.sObjectType.Account.isUpdateable()) {
            throw new AuraHandledException('Insufficient permissions to update Account.');
        }
        try {
            update new Account(Id = accountId, Credit_Limit_MRC__c = limitMrc, Credit_Limit_NRC__c = limitNrc);
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        }
    }

    @AuraEnabled
    public static void approveCreditLimitQuote(Id quoteId, String notes) {
        if (!Schema.sObjectType.Quote.isUpdateable()) {
            throw new AuraHandledException('Insufficient permissions to update Quote.');
        }
        try {
            new QuoteDmlHelper().doUpdate(new Quote(Id = quoteId, Credit_Finance_Approved__c = true));
        } catch (DmlException e) {
            throw new AuraHandledException(friendlyDmlError(e));
        }
    }

    /**
     * Atomic credit limit approval — updates Account limits, approves the Quote,
     * and acknowledges the SI in a single transaction. If any step fails, all roll back.
     */
    @AuraEnabled
    public static void approveCreditLimitRequest(Id instructionId, Id accountId, Id quoteId,
                                                  Decimal newLimitMrc, Decimal newLimitNrc) {
        if (!Schema.sObjectType.Account.isUpdateable()) {
            throw new AuraHandledException('Insufficient permissions to update Account.');
        }
        if (!Schema.sObjectType.Special_Instruction__c.isUpdateable()) {
            throw new AuraHandledException('Insufficient permissions to update Special Instructions.');
        }
        try {
            // 1. Update Account limits
            update new Account(Id = accountId, Credit_Limit_MRC__c = newLimitMrc, Credit_Limit_NRC__c = newLimitNrc);

            // 2. Approve the Quote
            new QuoteDmlHelper().doUpdate(new Quote(Id = quoteId, Credit_Finance_Approved__c = true));

            // 3. Acknowledge the SI
            new SiDmlHelper().doUpdate(new Special_Instruction__c(
                Id = instructionId,
                Status__c = 'Acknowledged',
                Acknowledged_By__c = UserInfo.getUserId(),
                Acknowledged_Date__c = Datetime.now()
            ));
        } catch (DmlException e) {
            throw new AuraHandledException(friendlyDmlError(e, quoteId));
        }
    }

    /**
     * Reject a credit limit request — sets SI status to Rejected.
     */
    @AuraEnabled
    public static void rejectCreditLimitRequest(Id instructionId, String notes) {
        if (!Schema.sObjectType.Special_Instruction__c.isUpdateable()) {
            throw new AuraHandledException('Insufficient permissions to update Special Instructions.');
        }
        try {
            new SiDmlHelper().doUpdate(new Special_Instruction__c(
                Id = instructionId,
                Status__c = 'Rejected',
                Acknowledged_By__c = UserInfo.getUserId(),
                Acknowledged_Date__c = Datetime.now(),
                Finance_Notes__c = notes
            ));
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        }
    }

    // ─── Acknowledge (non-credit SIs) ───

    @AuraEnabled
    public static void acknowledgeInstruction(Id instructionId, String notes) {
        if (!Schema.sObjectType.Special_Instruction__c.isUpdateable()) {
            throw new AuraHandledException('Insufficient permissions to update Special Instructions.');
        }
        try {
            // Query the SI to check type and linked quote
            Special_Instruction__c si = [
                SELECT Id, Type__c, Quote__c FROM Special_Instruction__c WHERE Id = :instructionId LIMIT 1
            ];

            // If SI has a linked Quote, temporarily unlock it so the after-save flow
            // (SpecialInstruction_AfterSave_UpdateQuoteCount) can update the Quote's
            // pending instruction count even while an approval process is active.
            Boolean quoteLocked = false;
            if (si.Quote__c != null) {
                quoteLocked = Approval.isLocked(si.Quote__c);
                if (quoteLocked) {
                    Approval.unlock(new List<Id>{ si.Quote__c });
                }
            }

            Special_Instruction__c siUpdate = new Special_Instruction__c(
                Id = instructionId,
                Status__c = 'Acknowledged',
                Acknowledged_By__c = UserInfo.getUserId(),
                Acknowledged_Date__c = Datetime.now(),
                Finance_Notes__c = notes
            );
            try {
                new SiDmlHelper().doUpdate(siUpdate);
            } catch (DmlException siEx) {
                if (siEx.getDmlType(0) == StatusCode.ENTITY_IS_LOCKED) {
                    SystemQuoteUpdater.unlockUpdateRelock(siUpdate);
                } else {
                    throw siEx;
                }
            }

            // If this is a Credit Limit SI, also approve the credit on the Quote
            if (si.Type__c == 'Credit Limit' && si.Quote__c != null) {
                try {
                    new QuoteDmlHelper().doUpdate(new Quote(Id = si.Quote__c, Credit_Finance_Approved__c = true));
                } catch (DmlException qe) {
                    if (qe.getDmlType(0) == StatusCode.ENTITY_IS_LOCKED) {
                        SystemQuoteUpdater.unlockUpdateRelock(si.Quote__c, 'Credit_Finance_Approved__c', true);
                    } else {
                        throw qe;
                    }
                }
            }

            // Relock the Quote if it was locked before
            if (quoteLocked && si.Quote__c != null) {
                Approval.lock(new List<Id>{ si.Quote__c });
            }
        } catch (DmlException e) {
            throw new AuraHandledException(friendlyDmlError(e));
        }
    }

    // ─── Error translation ───

    private static String friendlyDmlError(DmlException e) { return friendlyDmlError(e, null); }
    private static String friendlyDmlError(DmlException e, Id quoteId) {
        String msg = e.getDmlMessage(0);
        if (e.getDmlType(0) == StatusCode.FIELD_FILTER_VALIDATION_EXCEPTION) {
            List<String> fields = e.getDmlFieldNames(0);
            String fieldName = (fields != null && !fields.isEmpty()) ? fields[0] : '';
            if (fieldName == 'AccountId') {
                return 'The Opportunity\'s Account does not match the required record type. Ask the admin to check the Account lookup filter on Opportunity.';
            } else if (fieldName == 'BillingAccount__c' && quoteId != null) {
                // Query the actual mismatch so Finance knows exactly what's wrong
                try {
                    Quote q = [SELECT CurrencyIsoCode, Invoice_Frequency__c, DE_Entity__r.Name,
                                      BillingAccount__r.Name, BillingAccount__r.CurrencyIsoCode,
                                      BillingAccount__r.Invoice_Frequency__c, BillingAccount__r.DE_Entity__r.Name
                               FROM Quote WHERE Id = :quoteId LIMIT 1];
                    List<String> mismatches = new List<String>();
                    if (q.CurrencyIsoCode != q.BillingAccount__r.CurrencyIsoCode) {
                        mismatches.add('Currency: Quote=' + q.CurrencyIsoCode + ', BAN=' + q.BillingAccount__r.CurrencyIsoCode);
                    }
                    if (q.DE_Entity__r?.Name != q.BillingAccount__r?.DE_Entity__r?.Name) {
                        mismatches.add('DE Company: Quote=' + q.DE_Entity__r?.Name + ', BAN=' + q.BillingAccount__r?.DE_Entity__r?.Name);
                    }
                    if (q.Invoice_Frequency__c != q.BillingAccount__r.Invoice_Frequency__c) {
                        mismatches.add('Invoice Frequency: Quote=' + (q.Invoice_Frequency__c ?? 'none') + ', BAN=' + (q.BillingAccount__r.Invoice_Frequency__c ?? 'none'));
                    }
                    if (!mismatches.isEmpty()) {
                        return 'BAN mismatch on this Quote: ' + String.join(mismatches, '; ') + '. Fix the Quote or BAN before approving.';
                    }
                } catch (Exception ex) { /* fall through to generic message */ }
                return 'The BAN on this Quote does not match the Quote\'s filter criteria. Open the Quote to check Currency, DE Company, and Invoice Frequency.';
            }
            return 'A lookup field (' + fieldName + ') has invalid data. Open the Quote to check, then retry.';
        }
        if (msg.contains('CANNOT_EXECUTE_FLOW_TRIGGER')) {
            return 'A background process failed. This is usually a data mismatch on the Quote or Opportunity. Open the Quote to check for issues, then retry.';
        }
        if (msg.contains('FIELD_CUSTOM_VALIDATION_EXCEPTION')) {
            Integer idx = msg.indexOf('FIELD_CUSTOM_VALIDATION_EXCEPTION,');
            if (idx >= 0) return msg.substring(idx + 35).replaceAll('\\s*:\\s*\\[.*\\]\\s*$', '').trim();
        }
        if (msg.contains('ENTITY_IS_LOCKED')) {
            return 'This record is locked by an approval process. It must be approved or recalled first.';
        }
        return msg;
    }

    // ─── User country access ───

    @AuraEnabled(cacheable=true)
    public static List<String> getUserCountries() {
        // Get queues the running user belongs to
        Set<Id> userGroupIds = new Set<Id>();
        for (GroupMember gm : [
            SELECT GroupId FROM GroupMember
            WHERE UserOrGroupId = :UserInfo.getUserId()
              AND Group.DeveloperName LIKE 'DE_%_Country_Finance'
        ]) {
            userGroupIds.add(gm.GroupId);
        }

        // Check if user is in DE_Finance_All (super user)
        for (GroupMember gm : [
            SELECT GroupId FROM GroupMember
            WHERE UserOrGroupId = :UserInfo.getUserId()
              AND Group.DeveloperName = 'DE_Finance_All'
        ]) {
            return new List<String>(DE_COUNTRIES);
        }

        // Also grant ALL access to System Administrators
        if (UserInfo.getProfileId() != null) {
            Profile p = [SELECT Name FROM Profile WHERE Id = :UserInfo.getProfileId() LIMIT 1];
            if (p.Name == 'System Administrator') {
                return new List<String>(DE_COUNTRIES);
            }
        }

        // Map queue IDs to country names
        List<String> countries = new List<String>();
        if (!userGroupIds.isEmpty()) {
            Map<String, String> queueToCountry = new Map<String, String>{
                'DE_SG_Country_Finance' => 'Singapore',
                'DE_JP_Country_Finance' => 'Japan',
                'DE_KR_Country_Finance' => 'Korea',
                'DE_ID_Country_Finance' => 'Indonesia',
                'DE_PH_Country_Finance' => 'Philippines',
                'DE_CN_Country_Finance' => 'China',
                'DE_IN_Country_Finance' => 'India',
                'DE_TH_Country_Finance' => 'Thailand',
                'DE_MY_Country_Finance' => 'Malaysia',
                'DE_HK_Country_Finance' => 'Hong Kong'
            };
            for (Group g : [SELECT DeveloperName FROM Group WHERE Id IN :userGroupIds]) {
                String country = queueToCountry.get(g.DeveloperName);
                if (country != null) countries.add(country);
            }
        }
        return countries;
    }

    /**
     * Auto-expire Pending Credit Limit SIs where the condition has cleared.
     * Runs on every dashboard load so stale items don't linger.
     */
    private static void expireStaleCreditLimitSIs() {
        try {
            List<Special_Instruction__c> pending = [
                SELECT Id, Account__c,
                       Account__r.Credit_Limit_MRC__c, Account__r.Credit_Limit_NRC__c,
                       Account__r.Total_Active_Quoted_MRC__c, Account__r.Total_Active_Quoted_NRC__c,
                       Account__r.Overdue_90_Days__c
                FROM Special_Instruction__c
                WHERE Type__c = 'Credit Limit' AND Status__c = 'Pending'
            ];
            if (pending.isEmpty()) return;

            List<Special_Instruction__c> toExpire = new List<Special_Instruction__c>();
            for (Special_Instruction__c si : pending) {
                Decimal limitMrc = si.Account__r.Credit_Limit_MRC__c != null ? si.Account__r.Credit_Limit_MRC__c : 0;
                Decimal limitNrc = si.Account__r.Credit_Limit_NRC__c != null ? si.Account__r.Credit_Limit_NRC__c : 0;
                Decimal totalMrc = si.Account__r.Total_Active_Quoted_MRC__c != null ? si.Account__r.Total_Active_Quoted_MRC__c : 0;
                Decimal totalNrc = si.Account__r.Total_Active_Quoted_NRC__c != null ? si.Account__r.Total_Active_Quoted_NRC__c : 0;
                Decimal overdue  = si.Account__r.Overdue_90_Days__c != null ? si.Account__r.Overdue_90_Days__c : 0;

                Boolean mrcOk = limitMrc == 0 || totalMrc <= limitMrc;
                Boolean nrcOk = limitNrc == 0 || totalNrc <= limitNrc;

                if (mrcOk && nrcOk && overdue == 0) {
                    si.Status__c = 'Expired';
                    si.Resolution_Notes__c = 'Auto-resolved: credit limit condition cleared.';
                    toExpire.add(si);
                }
            }
            if (!toExpire.isEmpty()) {
                new SiDmlHelper().doUpdateList(toExpire);
            }
        } catch (Exception e) {
            // Don't block the dashboard if cleanup fails
            System.debug(LoggingLevel.WARN, 'Credit limit cleanup failed: ' + e.getMessage());
        }
    }
}