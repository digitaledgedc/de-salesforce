/**
 * DeFinanceDashboardControllerTest
 *
 * Full behavior coverage for DeFinanceDashboardController (>90% target):
 *  - getPendingItems() / getHistoricalItems(): Special Instructions (incl. Credit Limit
 *    credit-exposure math), Account finance approvals, BAN approvals, country
 *    normalization, and the auto-expire-stale-credit-limit-SI side effect.
 *  - getActiveQuotesForAccount() positive/negative.
 *  - getCurrencyRates().
 *  - updateCreditLimits / approveCreditLimitQuote / approveCreditLimitRequest /
 *    rejectCreditLimitRequest / acknowledgeInstruction: positive DML, negative DML
 *    (DmlException -> AuraHandledException), and negative FLS (insufficient
 *    permissions -> AuraHandledException), each via a dedicated in-test runAs user.
 *  - acknowledgeInstruction's Quote-lock interplay: a linked Quote already locked when
 *    the method runs gets transparently unlocked, updated, and re-locked afterward.
 *  - approveCreditLimitRequest's second FLS guard (Account editable but Special
 *    Instruction not), independent of the first guard.
 *  - getUserCountries(): System Administrator bypass, DE_Finance_All super-queue
 *    bypass, per-country queue mapping, and the no-membership empty-list case.
 *  - Bulk path: 200+ Special Instructions to exercise the LIMIT 200 cap and sort().
 *
 * All test data (Accounts, Quotes, Special Instructions, BillingAccounts, Users,
 * Groups) is created in-test. No SeeAllData, no real callouts, no org-specific users.
 */
@isTest
private class DeFinanceDashboardControllerTest {

    // ─── Record type / profile lookups (always visible to Apex tests) ───

    private static Id customerRecordTypeId() {
        return [SELECT Id FROM RecordType WHERE SObjectType = 'Account' AND DeveloperName = 'Customer' LIMIT 1].Id;
    }

    private static Id deEntityRecordTypeId() {
        return [SELECT Id FROM RecordType WHERE SObjectType = 'Account' AND DeveloperName = 'DE_Entity' LIMIT 1].Id;
    }

    private static Id sbiRecordTypeId() {
        return [SELECT Id FROM RecordType WHERE SObjectType = 'Special_Instruction__c'
                AND DeveloperName = 'Special_Billing_Instruction' LIMIT 1].Id;
    }

    private static Id standardUserProfileId() {
        return [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1].Id;
    }

    private static Id minimumAccessProfileId() {
        return [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1].Id;
    }

    // ─── Data builders ───

    private static Account createDeEntity(String name, String operationCountry) {
        Account a = new Account(
            Name = name,
            RecordTypeId = deEntityRecordTypeId(),
            Operation_Country__c = operationCountry
        );
        insert a;
        return a;
    }

    private static Account createCustomerAccount(String name, String operationCountry, Id deEntityId) {
        Account a = new Account(
            Name = name,
            RecordTypeId = customerRecordTypeId(),
            Operation_Country__c = operationCountry,
            DE_Entity__c = deEntityId,
            Tax_ID__c = 'TEST-TAX-' + String.valueOf(Math.abs(Crypto.getRandomInteger())),
            D_B_Number__c = String.valueOf(Math.abs(Crypto.getRandomInteger())).left(9)
        );
        insert a;
        return a;
    }

    private static Quote createQuote(Account acct, Decimal mrc, String status, Id deEntityId) {
        Opportunity opp = new Opportunity(
            Name = 'Opp for ' + acct.Name,
            AccountId = acct.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;

        Quote q = new Quote(
            Name = 'Quote for ' + acct.Name,
            OpportunityId = opp.Id,
            Total_MRC_2__c = mrc,
            Status = status,
            DE_Entity__c = deEntityId
        );
        insert q;
        return [SELECT Id, Quote_Number__c, Total_MRC_2__c, Total_NRC__c, CurrencyIsoCode, Status, AccountId
                FROM Quote WHERE Id = :q.Id];
    }

    private static Special_Instruction__c createSI(String type, String status, Id quoteId, Id accountId, String country) {
        Special_Instruction__c si = new Special_Instruction__c(
            RecordTypeId = sbiRecordTypeId(),
            Type__c = type,
            Status__c = status,
            Quote__c = quoteId,
            Account__c = accountId,
            Country__c = country,
            Description__c = 'Test SI - ' + type
        );
        insert si;
        return si;
    }

    private static User createUser(Id profileId, String aliasSeed) {
        String uniq = String.valueOf(Crypto.getRandomInteger()).right(6) + System.currentTimeMillis();
        User u = new User(
            Username = 'defintest.' + uniq + '@deforge.invalid.test',
            LastName = 'Test' + aliasSeed,
            Email = 'defintest.' + uniq + '@deforge.invalid.test',
            Alias = (aliasSeed + uniq).left(8),
            CommunityNickname = 'nick' + uniq,
            TimeZoneSidKey = 'America/Los_Angeles',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            ProfileId = profileId
        );
        insert u;
        return u;
    }


    // ═══════════════════════════════════════════════════════════════════
    // getPendingItems()
    // ═══════════════════════════════════════════════════════════════════

    @isTest
    static void testGetPendingItems_CreditLimitSI_ComputesExposureAndBreach() {
        Account deEntity = createDeEntity('SG Entity', 'Singapore');
        Account cust = createCustomerAccount('Breach Co', 'Singapore', deEntity.Id);
        cust.Credit_Limit_MRC__c = 1000;
        cust.Credit_Limit_NRC__c = 500;
        cust.Total_Active_Quoted_MRC__c = 1500; // over MRC limit
        cust.Total_Active_Quoted_NRC__c = 100;  // under NRC limit
        cust.Overdue_90_Days__c = 200;          // also overdue
        update cust;

        Quote q = createQuote(cust, 1500, 'Draft', deEntity.Id);
        Special_Instruction__c si = createSI('Credit Limit', 'Pending', q.Id, cust.Id, null);

        Special_Instruction__c other = createSI('Security Deposit Required', 'Pending', null, null, 'SG');

        Test.startTest();
        List<DeFinanceDashboardController.FinanceItem> items = DeFinanceDashboardController.getPendingItems();
        Test.stopTest();

        Map<Id, DeFinanceDashboardController.FinanceItem> byId = new Map<Id, DeFinanceDashboardController.FinanceItem>();
        for (DeFinanceDashboardController.FinanceItem fi : items) byId.put(fi.id, fi);

        Assert.isTrue(byId.containsKey(si.Id), 'Credit Limit SI should be in pending items.');
        DeFinanceDashboardController.FinanceItem creditFi = byId.get(si.Id);
        Assert.areEqual('Credit Limit', creditFi.itemType, 'Credit Limit SIs get their own itemType.');
        Assert.areEqual(1000, creditFi.creditLimitMrc, 'creditLimitMrc should mirror the Account field.');
        Assert.areEqual(1500, creditFi.mrc, 'mrc shown is the triggering quote MRC.');
        Assert.areEqual(1500, creditFi.acctTotalMrc, 'acctTotalMrc reflects Account cumulative total.');
        Assert.areEqual(500, creditFi.overMrc, 'overMrc = total - limit when over.');
        Assert.areEqual(0, creditFi.overNrc, 'overNrc = 0 when under the NRC limit.');
        Assert.isTrue(creditFi.breachReason.contains('MRC'), 'breachReason should flag the MRC breach.');
        Assert.isTrue(creditFi.breachReason.contains('Overdue 90+'), 'breachReason should flag overdue balance.');
        Assert.areEqual('Singapore', creditFi.country, 'Country comes from the DE Entity operation country.');

        Assert.isTrue(byId.containsKey(other.Id), 'Non-credit SI should also be in pending items.');
        DeFinanceDashboardController.FinanceItem otherFi = byId.get(other.Id);
        Assert.areEqual('Special Instruction', otherFi.itemType, 'Non-Credit-Limit type maps to Special Instruction.');
        Assert.areEqual('Singapore', otherFi.country, 'SG country code should normalize to Singapore.');
        Assert.isNull(otherFi.creditLimitMrc, 'No credit exposure math for non-credit SIs.');
    }

    @isTest
    static void testGetPendingItems_ExpireStaleCreditLimitSI_AutoResolvesAndExcludesFromResults() {
        Account deEntity = createDeEntity('JP Entity', 'Japan');
        Account cust = createCustomerAccount('Cleared Co', 'Japan', deEntity.Id);
        cust.Credit_Limit_MRC__c = 1000;
        cust.Credit_Limit_NRC__c = 1000;
        cust.Total_Active_Quoted_MRC__c = 200; // well under limit
        cust.Total_Active_Quoted_NRC__c = 100;
        cust.Overdue_90_Days__c = 0;
        update cust;

        Quote q = createQuote(cust, 200, 'Draft', deEntity.Id);
        Special_Instruction__c si = createSI('Credit Limit', 'Pending', q.Id, cust.Id, null);

        Test.startTest();
        List<DeFinanceDashboardController.FinanceItem> items = DeFinanceDashboardController.getPendingItems();
        Test.stopTest();

        for (DeFinanceDashboardController.FinanceItem fi : items) {
            Assert.areNotEqual(si.Id, fi.id, 'Auto-expired SI must not appear as a pending item anymore.');
        }

        Special_Instruction__c after = [SELECT Status__c, Resolution_Notes__c FROM Special_Instruction__c WHERE Id = :si.Id];
        Assert.areEqual('Expired', after.Status__c, 'Cleared credit-limit SI should auto-expire.');
        Assert.isTrue(after.Resolution_Notes__c.contains('Auto-resolved'), 'Resolution note should explain the auto-expiry.');
    }

    @isTest
    static void testGetPendingItems_CustomerApprovalAndBanApproval() {
        Account deEntity = createDeEntity('KR Entity', 'Korea');
        Account cust = createCustomerAccount('Approval Co', 'Singapore', deEntity.Id);
        cust.Finance_Approval_Phase__c = 'DnB_Pending';
        cust.Finance_Approval_Phase_Changed__c = Date.today();
        update cust;

        Quote q = createQuote(cust, 300, 'Draft', deEntity.Id);

        BillingAccount__c ban = new BillingAccount__c(
            Account__c = cust.Id,
            DE_Entity__c = deEntity.Id,
            Status__c = 'Pending Approval',
            Invoice_Frequency__c = 'Monthly',
            Source_Quote__c = q.Id,
            BAN_Number__c = 'BAN-TEST-001'
        );
        insert ban;

        Test.startTest();
        List<DeFinanceDashboardController.FinanceItem> items = DeFinanceDashboardController.getPendingItems();
        Test.stopTest();

        Map<Id, DeFinanceDashboardController.FinanceItem> byId = new Map<Id, DeFinanceDashboardController.FinanceItem>();
        for (DeFinanceDashboardController.FinanceItem fi : items) byId.put(fi.id, fi);

        Assert.isTrue(byId.containsKey(cust.Id), 'Account in approval pipeline should be a pending item.');
        DeFinanceDashboardController.FinanceItem acctFi = byId.get(cust.Id);
        Assert.areEqual('Customer Approval', acctFi.itemType, 'Approval-phase accounts map to Customer Approval.');
        Assert.areEqual('D&B In Progress', acctFi.label, 'DnB_Pending should map to its friendly label.');
        Assert.areEqual('Korea', acctFi.country, 'Country should prefer the DE Entity operation country (FB-809).');

        Assert.isTrue(byId.containsKey(ban.Id), 'Pending BAN should be a pending item.');
        DeFinanceDashboardController.FinanceItem banFi = byId.get(ban.Id);
        Assert.areEqual('BAN Approval', banFi.itemType, 'Pending BillingAccount maps to BAN Approval.');
        Assert.areEqual('New BAN', banFi.label, 'New pending BANs get the New BAN label.');
        Assert.isTrue(banFi.description.contains('Monthly'), 'Description should surface the invoice frequency.');
        Assert.areEqual('Korea', banFi.country, 'BAN country comes from its DE Entity.');
    }

    @isTest
    static void testGetPendingItems_ExcludedApprovalPhasesAreNotReturned() {
        Account deEntity = createDeEntity('CN Entity', 'China');
        Account approved = createCustomerAccount('Already Approved Co', 'China', deEntity.Id);
        approved.Finance_Approval_Phase__c = 'Approved';
        update approved;

        Test.startTest();
        List<DeFinanceDashboardController.FinanceItem> items = DeFinanceDashboardController.getPendingItems();
        Test.stopTest();

        for (DeFinanceDashboardController.FinanceItem fi : items) {
            Assert.areNotEqual(approved.Id, fi.id, 'Accounts already Approved must be excluded from the pending pipeline.');
        }
    }

    @isTest
    static void testGetPendingItems_CountryNormalization_BlankAndUnmappedValues() {
        Special_Instruction__c blankCountrySi = createSI('Billing Mode Change', 'Pending', null, null, null);
        Special_Instruction__c unmappedCountrySi = createSI('Billing Mode Change', 'Pending', null, null, 'Vietnam');

        Test.startTest();
        List<DeFinanceDashboardController.FinanceItem> items = DeFinanceDashboardController.getPendingItems();
        Test.stopTest();

        Map<Id, DeFinanceDashboardController.FinanceItem> byId = new Map<Id, DeFinanceDashboardController.FinanceItem>();
        for (DeFinanceDashboardController.FinanceItem fi : items) byId.put(fi.id, fi);

        Assert.areEqual('', byId.get(blankCountrySi.Id).country, 'A blank country should normalize to an empty string, not null.');
        Assert.areEqual('Vietnam', byId.get(unmappedCountrySi.Id).country, 'An unmapped country value should pass through unchanged.');
    }

    @isTest
    static void testGetPendingItems_BulkVolume_RespectsTwoHundredLimit() {
        List<Special_Instruction__c> bulkRecords = new List<Special_Instruction__c>();
        Id sbiRt = sbiRecordTypeId();
        for (Integer i = 0; i < 210; i++) {
            bulkRecords.add(new Special_Instruction__c(
                RecordTypeId = sbiRt,
                Type__c = 'Security Deposit Required',
                Status__c = 'Pending',
                Country__c = 'SG',
                Description__c = 'Bulk SI ' + i
            ));
        }
        insert bulkRecords;

        Test.startTest();
        List<DeFinanceDashboardController.FinanceItem> items = DeFinanceDashboardController.getPendingItems();
        Test.stopTest();

        Assert.areEqual(200, items.size(), 'SOQL LIMIT 200 should cap the number of pending items returned.');
        for (DeFinanceDashboardController.FinanceItem fi : items) {
            Assert.areEqual('Singapore', fi.country, 'All bulk items should normalize SG -> Singapore.');
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // getHistoricalItems()
    // ═══════════════════════════════════════════════════════════════════

    @isTest
    static void testGetHistoricalItems_AcknowledgedCreditLimitSI() {
        Account deEntity = createDeEntity('ID Entity', 'Indonesia');
        Account cust = createCustomerAccount('Historical Co', 'Indonesia', deEntity.Id);
        cust.Credit_Limit_MRC__c = 1000;
        cust.Credit_Limit_NRC__c = 1000;
        cust.Total_Active_Quoted_MRC__c = 1200;
        cust.Total_Active_Quoted_NRC__c = 100;
        update cust;

        Quote q = createQuote(cust, 1200, 'Approved', deEntity.Id);
        Special_Instruction__c si = createSI('Credit Limit', 'Acknowledged', q.Id, cust.Id, null);
        si.Acknowledged_By__c = UserInfo.getUserId();
        si.Acknowledged_Date__c = Datetime.now();
        si.Resolution_Notes__c = 'Approved after review';
        update si;

        Test.startTest();
        List<DeFinanceDashboardController.FinanceItem> items = DeFinanceDashboardController.getHistoricalItems();
        Test.stopTest();

        Map<Id, DeFinanceDashboardController.FinanceItem> byId = new Map<Id, DeFinanceDashboardController.FinanceItem>();
        for (DeFinanceDashboardController.FinanceItem fi : items) byId.put(fi.id, fi);

        Assert.isTrue(byId.containsKey(si.Id), 'Acknowledged SI should appear in historical items.');
        DeFinanceDashboardController.FinanceItem fi = byId.get(si.Id);
        Assert.areEqual('Acknowledged', fi.status, 'Status should reflect the SI status.');
        Assert.areEqual('Approved after review', fi.resolutionNotes, 'Resolution notes should be surfaced.');
        Assert.areEqual(200, fi.overMrc, 'Credit exposure math also applies to historical Credit Limit SIs.');
        Assert.areEqual(-1L, fi.agingMinutes, 'Historical items use the -1 sentinel aging value.');
    }

    @isTest
    static void testGetHistoricalItems_ApprovedAndRejectedAccountsAndActiveBan() {
        Account deEntity = createDeEntity('PH Entity', 'Philippines');

        Account approved = createCustomerAccount('Approved Historical Co', 'Philippines', deEntity.Id);
        approved.Finance_Approval_Phase__c = 'Approved';
        approved.Finance_Approved_Date__c = Date.today();
        update approved;

        Account rejectedDnb = createCustomerAccount('Rejected DnB Co', 'Philippines', deEntity.Id);
        rejectedDnb.Finance_Approval_Phase__c = 'Rejected_DnB';
        update rejectedDnb;

        Account rejectedKyc = createCustomerAccount('Rejected KYC Co', 'Philippines', deEntity.Id);
        rejectedKyc.Finance_Approval_Phase__c = 'Rejected_KYC';
        update rejectedKyc;

        BillingAccount__c activeBan = new BillingAccount__c(
            Account__c = approved.Id,
            DE_Entity__c = deEntity.Id,
            Status__c = 'Active',
            Invoice_Frequency__c = 'Quarterly',
            BAN_Number__c = 'BAN-ACTIVE-001'
        );
        insert activeBan;

        Test.startTest();
        List<DeFinanceDashboardController.FinanceItem> items = DeFinanceDashboardController.getHistoricalItems();
        Test.stopTest();

        Map<Id, DeFinanceDashboardController.FinanceItem> byId = new Map<Id, DeFinanceDashboardController.FinanceItem>();
        for (DeFinanceDashboardController.FinanceItem fi : items) byId.put(fi.id, fi);

        Assert.areEqual('Approved', byId.get(approved.Id).label, 'Approved phase maps to Approved label.');
        Assert.areEqual('Rejected - D&B', byId.get(rejectedDnb.Id).label, 'Rejected_DnB maps to its friendly label.');
        Assert.areEqual('Rejected - KYC', byId.get(rejectedKyc.Id).label, 'Rejected_KYC maps to its friendly label.');

        Assert.isTrue(byId.containsKey(activeBan.Id), 'Active BAN should appear as a historical item.');
        Assert.areEqual('BAN-ACTIVE-001', byId.get(activeBan.Id).label, 'Active BAN label falls back to its BAN number.');
    }

    @isTest
    static void testGetHistoricalItems_OrphanedCreditLimitSI_NullSafeExposureAndFields() {
        // Credit Limit SI with no linked Quote and no linked Account exercises the
        // null-safe branches in getHistoricalItems' field mapping AND the
        // applyCreditExposure(fi, null) early-return (Account__r == null).
        Special_Instruction__c orphan = createSI('Credit Limit', 'Rejected', null, null, null);

        Test.startTest();
        List<DeFinanceDashboardController.FinanceItem> items = DeFinanceDashboardController.getHistoricalItems();
        Test.stopTest();

        Map<Id, DeFinanceDashboardController.FinanceItem> byId = new Map<Id, DeFinanceDashboardController.FinanceItem>();
        for (DeFinanceDashboardController.FinanceItem fi : items) byId.put(fi.id, fi);

        Assert.isTrue(byId.containsKey(orphan.Id), 'Orphaned Credit Limit SI should still appear in historical items.');
        DeFinanceDashboardController.FinanceItem fi = byId.get(orphan.Id);
        Assert.areEqual('', fi.accountName, 'Missing Account should fall back to empty string, not null.');
        Assert.areEqual('', fi.quoteNumber, 'Missing Quote should fall back to empty string, not null.');
        Assert.areEqual('', fi.country, 'Missing Quote/Country should normalize to an empty string.');
        Assert.isNull(fi.currencyCode, 'With no Quote and no Account, currencyCode should be null.');
        Assert.isNull(fi.creditLimitMrc, 'With no Account, creditLimitMrc should be null.');
        Assert.isNull(fi.acctTotalMrc, 'applyCreditExposure should no-op (early return) when Account is null.');
        Assert.isNull(fi.breachReason, 'No exposure math should run without an Account, so breachReason stays null.');
        Assert.areEqual(-1L, fi.agingMinutes, 'Historical items use the -1 sentinel aging value.');
    }

    @isTest
    static void testGetHistoricalItems_ActiveBanWithNullFields_UsesFallbackLabelAndDescription() {
        Account anyEntity = createDeEntity('BAN Fallback Entity', 'Singapore');
        BillingAccount__c ban = new BillingAccount__c(
            Account__c = anyEntity.Id,
            Status__c = 'Active',
            // Invoice_Frequency__c has an org-level default value ('Monthly',
            // defaultedOnCreate) that auto-populates it when the field is simply
            // omitted from the insert. Explicitly assigning null overrides that
            // default so the record actually reaches the controller's 'N/A'
            // fallback branch. BAN_Number__c has no default, so omitting it is fine.
            Invoice_Frequency__c = null
        );
        insert ban;

        Test.startTest();
        List<DeFinanceDashboardController.FinanceItem> items = DeFinanceDashboardController.getHistoricalItems();
        Test.stopTest();

        Map<Id, DeFinanceDashboardController.FinanceItem> byId = new Map<Id, DeFinanceDashboardController.FinanceItem>();
        for (DeFinanceDashboardController.FinanceItem fi : items) byId.put(fi.id, fi);

        Assert.isTrue(byId.containsKey(ban.Id), 'Active BAN with no BAN_Number__c should still appear in historical items.');
        DeFinanceDashboardController.FinanceItem fi = byId.get(ban.Id);
        Assert.areEqual('Approved', fi.label, 'Null BAN_Number__c should fall back to the Approved label.');
        Assert.isTrue(fi.description.contains('N/A'), 'Null Invoice_Frequency__c should fall back to N/A in the description.');
    }

    // ═══════════════════════════════════════════════════════════════════
    // getActiveQuotesForAccount()
    // ═══════════════════════════════════════════════════════════════════

    @isTest
    static void testGetActiveQuotesForAccount_ReturnsOnlyActiveStatusesSortedByMrcDesc() {
        Account deEntity = createDeEntity('TH Entity', 'Thailand');
        Account cust = createCustomerAccount('Quote Co', 'Thailand', deEntity.Id);

        Quote lowMrc = createQuote(cust, 200, 'Draft', deEntity.Id);
        Quote highMrc = createQuote(cust, 900, 'Approved', deEntity.Id);
        Quote rejected = createQuote(cust, 5000, 'Rejected', deEntity.Id);

        Test.startTest();
        List<DeFinanceDashboardController.ActiveQuoteInfo> active =
            DeFinanceDashboardController.getActiveQuotesForAccount(cust.Id);
        Test.stopTest();

        Assert.areEqual(2, active.size(), 'Only Draft/In Review/Approved/Presented quotes should be returned.');
        Assert.areEqual(highMrc.Id, active[0].quoteId, 'Highest MRC quote should sort first.');
        Assert.areEqual(lowMrc.Id, active[1].quoteId, 'Lower MRC quote should sort second.');
        for (DeFinanceDashboardController.ActiveQuoteInfo info : active) {
            Assert.areNotEqual(rejected.Id, info.quoteId, 'Rejected quotes must be excluded.');
        }
    }

    @isTest
    static void testGetActiveQuotesForAccount_NoQuotes_ReturnsEmptyList() {
        Account deEntity = createDeEntity('MY Entity', 'Malaysia');
        Account cust = createCustomerAccount('No Quotes Co', 'Malaysia', deEntity.Id);

        Test.startTest();
        List<DeFinanceDashboardController.ActiveQuoteInfo> active =
            DeFinanceDashboardController.getActiveQuotesForAccount(cust.Id);
        Test.stopTest();

        Assert.isTrue(active.isEmpty(), 'Account with no quotes should return an empty list, not an error.');
    }

    // ═══════════════════════════════════════════════════════════════════
    // getCurrencyRates()
    // ═══════════════════════════════════════════════════════════════════

    @isTest
    static void testGetCurrencyRates_ReturnsActiveCurrencyMap() {
        Test.startTest();
        Map<String, Decimal> rates = DeFinanceDashboardController.getCurrencyRates();
        Test.stopTest();

        Assert.isFalse(rates.isEmpty(), 'Org should have at least one active currency configured.');
        for (Decimal rate : rates.values()) {
            Assert.isTrue(rate > 0, 'Conversion rates should be positive.');
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // updateCreditLimits()
    // ═══════════════════════════════════════════════════════════════════

    @isTest
    static void testUpdateCreditLimits_Positive_UpdatesAccount() {
        Account deEntity = createDeEntity('HK Entity', 'Hong Kong');
        Account cust = createCustomerAccount('Limit Update Co', 'Hong Kong', deEntity.Id);

        Test.startTest();
        DeFinanceDashboardController.updateCreditLimits(cust.Id, 5000, 2500);
        Test.stopTest();

        Account after = [SELECT Credit_Limit_MRC__c, Credit_Limit_NRC__c FROM Account WHERE Id = :cust.Id];
        Assert.areEqual(5000, after.Credit_Limit_MRC__c, 'MRC limit should be updated.');
        Assert.areEqual(2500, after.Credit_Limit_NRC__c, 'NRC limit should be updated.');
    }

    @isTest
    static void testUpdateCreditLimits_DeletedAccount_ThrowsAuraHandledException() {
        Account deEntity = createDeEntity('SG2 Entity', 'Singapore');
        Account cust = createCustomerAccount('Deleted Co', 'Singapore', deEntity.Id);
        Id deletedId = cust.Id;
        delete cust;

        Test.startTest();
        Boolean threw = false;
        try {
            DeFinanceDashboardController.updateCreditLimits(deletedId, 100, 100);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Updating a deleted Account should surface as an AuraHandledException.');
    }

    @isTest
    static void testUpdateCreditLimits_InsufficientPermissions_ThrowsAuraHandledException() {
        Account deEntity = createDeEntity('JP2 Entity', 'Japan');
        Account cust = createCustomerAccount('Restricted Co', 'Japan', deEntity.Id);
        User restricted = createUser(minimumAccessProfileId(), 'minacc');

        Test.startTest();
        Boolean threw = false;
        System.runAs(restricted) {
            try {
                DeFinanceDashboardController.updateCreditLimits(cust.Id, 100, 100);
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        Test.stopTest();

        Assert.isTrue(threw, 'A profile without Account edit access should be blocked before any DML.');
    }

    // ═══════════════════════════════════════════════════════════════════
    // approveCreditLimitQuote()
    // ═══════════════════════════════════════════════════════════════════

    @isTest
    static void testApproveCreditLimitQuote_Positive_ApprovesQuote() {
        Account deEntity = createDeEntity('IN Entity', 'India');
        Account cust = createCustomerAccount('Quote Approve Co', 'India', deEntity.Id);
        Quote q = createQuote(cust, 400, 'Draft', deEntity.Id);

        Test.startTest();
        DeFinanceDashboardController.approveCreditLimitQuote(q.Id, 'Looks good');
        Test.stopTest();

        Quote after = [SELECT Credit_Finance_Approved__c FROM Quote WHERE Id = :q.Id];
        Assert.isTrue(after.Credit_Finance_Approved__c, 'Quote should be marked credit-approved.');
    }

    @isTest
    static void testApproveCreditLimitQuote_DeletedQuote_ThrowsAuraHandledException() {
        Account deEntity = createDeEntity('IN2 Entity', 'India');
        Account cust = createCustomerAccount('Quote Delete Co', 'India', deEntity.Id);
        Quote q = createQuote(cust, 400, 'Draft', deEntity.Id);
        Id deletedQuoteId = q.Id;
        delete q;

        Test.startTest();
        Boolean threw = false;
        try {
            DeFinanceDashboardController.approveCreditLimitQuote(deletedQuoteId, 'notes');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Approving a deleted Quote should surface as an AuraHandledException.');
    }

    @isTest
    static void testApproveCreditLimitQuote_InsufficientPermissions_ThrowsAuraHandledException() {
        Account deEntity = createDeEntity('MY2 Entity', 'Malaysia');
        Account cust = createCustomerAccount('Quote Restricted Co', 'Malaysia', deEntity.Id);
        Quote q = createQuote(cust, 400, 'Draft', deEntity.Id);
        User restricted = createUser(minimumAccessProfileId(), 'qmin');

        Test.startTest();
        Boolean threw = false;
        System.runAs(restricted) {
            try {
                DeFinanceDashboardController.approveCreditLimitQuote(q.Id, 'notes');
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        Test.stopTest();

        Assert.isTrue(threw, 'A profile without Quote edit access should be blocked before any DML.');
    }

    // ═══════════════════════════════════════════════════════════════════
    // approveCreditLimitRequest() — atomic Account + Quote + SI update
    // ═══════════════════════════════════════════════════════════════════

    @isTest
    static void testApproveCreditLimitRequest_Positive_UpdatesAllThreeRecords() {
        Account deEntity = createDeEntity('TH2 Entity', 'Thailand');
        Account cust = createCustomerAccount('Atomic Approve Co', 'Thailand', deEntity.Id);
        Quote q = createQuote(cust, 800, 'Draft', deEntity.Id);
        Special_Instruction__c si = createSI('Credit Limit', 'Pending', q.Id, cust.Id, null);

        Test.startTest();
        DeFinanceDashboardController.approveCreditLimitRequest(si.Id, cust.Id, q.Id, 3000, 1500);
        Test.stopTest();

        Account acctAfter = [SELECT Credit_Limit_MRC__c, Credit_Limit_NRC__c FROM Account WHERE Id = :cust.Id];
        Quote quoteAfter = [SELECT Credit_Finance_Approved__c FROM Quote WHERE Id = :q.Id];
        Special_Instruction__c siAfter = [SELECT Status__c, Acknowledged_By__c FROM Special_Instruction__c WHERE Id = :si.Id];

        Assert.areEqual(3000, acctAfter.Credit_Limit_MRC__c, 'Account MRC limit should be updated atomically.');
        Assert.areEqual(1500, acctAfter.Credit_Limit_NRC__c, 'Account NRC limit should be updated atomically.');
        Assert.isTrue(quoteAfter.Credit_Finance_Approved__c, 'Quote should be credit-approved atomically.');
        Assert.areEqual('Acknowledged', siAfter.Status__c, 'SI should be acknowledged atomically.');
        Assert.areEqual(UserInfo.getUserId(), siAfter.Acknowledged_By__c, 'Acknowledged_By should be the running user.');
    }

    @isTest
    static void testApproveCreditLimitRequest_InsufficientPermissions_ThrowsAuraHandledException() {
        Account deEntity = createDeEntity('PH2 Entity', 'Philippines');
        Account cust = createCustomerAccount('Atomic Restricted Co', 'Philippines', deEntity.Id);
        Quote q = createQuote(cust, 800, 'Draft', deEntity.Id);
        Special_Instruction__c si = createSI('Credit Limit', 'Pending', q.Id, cust.Id, null);
        User restricted = createUser(minimumAccessProfileId(), 'atomin');

        Test.startTest();
        Boolean threw = false;
        System.runAs(restricted) {
            try {
                DeFinanceDashboardController.approveCreditLimitRequest(si.Id, cust.Id, q.Id, 100, 100);
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        Test.stopTest();

        Assert.isTrue(threw, 'A profile without Account edit access should be blocked before any DML.');
    }

    @isTest
    static void testApproveCreditLimitRequest_SIInsufficientPermissions_AccountEditableButSINot() {
        // Exercises the SECOND FLS guard in approveCreditLimitRequest (the
        // Special_Instruction__c.isUpdateable() check right after the Account check
        // passes). Standard User can update Account (so the first guard passes) but
        // this org's deployed metadata grants no non-admin profile any
        // Special_Instruction__c object permission at all, so the second guard fires
        // before any DML runs.
        Account deEntity = createDeEntity('SG5 Entity', 'Singapore');
        Account cust = createCustomerAccount('SI Guard Co', 'Singapore', deEntity.Id);
        Quote q = createQuote(cust, 500, 'Draft', deEntity.Id);
        Special_Instruction__c si = createSI('Credit Limit', 'Pending', q.Id, cust.Id, null);
        User standard = createUser(standardUserProfileId(), 'siguard');

        Test.startTest();
        Boolean threw = false;
        System.runAs(standard) {
            try {
                DeFinanceDashboardController.approveCreditLimitRequest(si.Id, cust.Id, q.Id, 100, 100);
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        Test.stopTest();

        Assert.isTrue(threw, 'A profile with Account edit but no Special Instruction edit should be blocked at the second guard, before any DML.');
    }

    @isTest
    static void testApproveCreditLimitRequest_DeletedQuote_ThrowsAuraHandledException() {
        // Account limit update (step 1) succeeds; the Quote update (step 2) fails
        // because the Quote no longer exists, exercising the catch(DmlException e)
        // block's friendlyDmlError(e, quoteId) overload inside approveCreditLimitRequest.
        Account deEntity = createDeEntity('SG3 Entity', 'Singapore');
        Account cust = createCustomerAccount('Atomic Deleted Quote Co', 'Singapore', deEntity.Id);
        Quote q = createQuote(cust, 700, 'Draft', deEntity.Id);
        Special_Instruction__c si = createSI('Credit Limit', 'Pending', q.Id, cust.Id, null);
        Id deletedQuoteId = q.Id;
        delete q;

        Test.startTest();
        Boolean threw = false;
        try {
            DeFinanceDashboardController.approveCreditLimitRequest(si.Id, cust.Id, deletedQuoteId, 2000, 1000);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'A DmlException from the deleted Quote update should surface as an AuraHandledException.');
    }

    // ═══════════════════════════════════════════════════════════════════
    // rejectCreditLimitRequest()
    // ═══════════════════════════════════════════════════════════════════

    @isTest
    static void testRejectCreditLimitRequest_Positive_RejectsSI() {
        Special_Instruction__c si = createSI('Credit Limit', 'Pending', null, null, 'SG');

        Test.startTest();
        DeFinanceDashboardController.rejectCreditLimitRequest(si.Id, 'Not enough documentation');
        Test.stopTest();

        Special_Instruction__c after = [SELECT Status__c, Finance_Notes__c, Acknowledged_By__c FROM Special_Instruction__c WHERE Id = :si.Id];
        Assert.areEqual('Rejected', after.Status__c, 'SI should be rejected.');
        Assert.areEqual('Not enough documentation', after.Finance_Notes__c, 'Finance notes should be persisted.');
        Assert.areEqual(UserInfo.getUserId(), after.Acknowledged_By__c, 'Acknowledged_By should be the running user.');
    }

    @isTest
    static void testRejectCreditLimitRequest_DeletedSI_ThrowsAuraHandledException() {
        Special_Instruction__c si = createSI('Credit Limit', 'Pending', null, null, 'SG');
        Id deletedId = si.Id;
        delete si;

        Test.startTest();
        Boolean threw = false;
        try {
            DeFinanceDashboardController.rejectCreditLimitRequest(deletedId, 'notes');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Rejecting a deleted SI should surface as an AuraHandledException.');
    }

    @isTest
    static void testRejectCreditLimitRequest_InsufficientPermissions_ThrowsAuraHandledException() {
        Special_Instruction__c si = createSI('Credit Limit', 'Pending', null, null, 'SG');
        User restricted = createUser(minimumAccessProfileId(), 'rejmin');

        Test.startTest();
        Boolean threw = false;
        System.runAs(restricted) {
            try {
                DeFinanceDashboardController.rejectCreditLimitRequest(si.Id, 'notes');
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        Test.stopTest();

        Assert.isTrue(threw, 'A profile without SI edit access should be blocked before any DML.');
    }

    // ═══════════════════════════════════════════════════════════════════
    // acknowledgeInstruction()
    // ═══════════════════════════════════════════════════════════════════

    @isTest
    static void testAcknowledgeInstruction_NonCreditType_AcknowledgesWithoutTouchingQuote() {
        Account deEntity = createDeEntity('CN2 Entity', 'China');
        Account cust = createCustomerAccount('Ack Co', 'China', deEntity.Id);
        Quote q = createQuote(cust, 250, 'Draft', deEntity.Id);
        Special_Instruction__c si = createSI('Billing Mode Change', 'Pending', q.Id, cust.Id, null);

        Test.startTest();
        DeFinanceDashboardController.acknowledgeInstruction(si.Id, 'All good');
        Test.stopTest();

        Special_Instruction__c siAfter = [SELECT Status__c, Finance_Notes__c FROM Special_Instruction__c WHERE Id = :si.Id];
        Quote quoteAfter = [SELECT Credit_Finance_Approved__c FROM Quote WHERE Id = :q.Id];

        Assert.areEqual('Acknowledged', siAfter.Status__c, 'SI should be acknowledged.');
        Assert.areEqual('All good', siAfter.Finance_Notes__c, 'Finance notes should persist.');
        Assert.isFalse(quoteAfter.Credit_Finance_Approved__c, 'Non-credit SIs must not touch quote credit approval.');
    }

    @isTest
    static void testAcknowledgeInstruction_CreditLimitType_AlsoApprovesLinkedQuote() {
        Account deEntity = createDeEntity('ID2 Entity', 'Indonesia');
        Account cust = createCustomerAccount('Ack Credit Co', 'Indonesia', deEntity.Id);
        Quote q = createQuote(cust, 600, 'Draft', deEntity.Id);
        Special_Instruction__c si = createSI('Credit Limit', 'Pending', q.Id, cust.Id, null);

        Test.startTest();
        DeFinanceDashboardController.acknowledgeInstruction(si.Id, 'Credit cleared');
        Test.stopTest();

        Special_Instruction__c siAfter = [SELECT Status__c FROM Special_Instruction__c WHERE Id = :si.Id];
        Quote quoteAfter = [SELECT Credit_Finance_Approved__c FROM Quote WHERE Id = :q.Id];

        Assert.areEqual('Acknowledged', siAfter.Status__c, 'SI should be acknowledged.');
        Assert.isTrue(quoteAfter.Credit_Finance_Approved__c, 'Credit Limit SIs also flip Quote.Credit_Finance_Approved__c.');
    }

    @isTest
    static void testAcknowledgeInstruction_NoLinkedQuote_StillAcknowledges() {
        Special_Instruction__c si = createSI('Security Deposit Required', 'Pending', null, null, 'SG');

        Test.startTest();
        DeFinanceDashboardController.acknowledgeInstruction(si.Id, 'Reviewed, no quote attached');
        Test.stopTest();

        Special_Instruction__c after = [SELECT Status__c FROM Special_Instruction__c WHERE Id = :si.Id];
        Assert.areEqual('Acknowledged', after.Status__c, 'SIs without a linked quote should still acknowledge cleanly.');
    }

    @isTest
    static void testAcknowledgeInstruction_CreditLimitType_QuoteLockedBeforehand_UnlocksUpdatesAndRelocks() {
        // If the linked Quote is already under an approval-process lock when
        // acknowledgeInstruction runs, the method should transparently unlock it,
        // perform the SI + Quote updates, and then re-lock the Quote afterward
        // (the quoteLocked branch).
        Account deEntity = createDeEntity('SG6 Entity', 'Singapore');
        Account cust = createCustomerAccount('Locked Quote Co', 'Singapore', deEntity.Id);
        Quote q = createQuote(cust, 900, 'Draft', deEntity.Id);
        Special_Instruction__c si = createSI('Credit Limit', 'Pending', q.Id, cust.Id, null);

        Approval.lock(new List<Id>{ q.Id });
        Assert.isTrue(Approval.isLocked(q.Id), 'Precondition: the quote should be locked before acknowledgeInstruction runs.');

        Test.startTest();
        DeFinanceDashboardController.acknowledgeInstruction(si.Id, 'Cleared while locked');
        Test.stopTest();

        Special_Instruction__c siAfter = [SELECT Status__c FROM Special_Instruction__c WHERE Id = :si.Id];
        Quote quoteAfter = [SELECT Credit_Finance_Approved__c FROM Quote WHERE Id = :q.Id];

        Assert.areEqual('Acknowledged', siAfter.Status__c, 'SI should still be acknowledged even though its linked quote started out locked.');
        Assert.isTrue(quoteAfter.Credit_Finance_Approved__c, 'Quote should still get credit-approved after being transiently unlocked.');
        Assert.isTrue(Approval.isLocked(q.Id), 'Quote should be re-locked once the update completes (the quoteLocked relock branch).');
    }

    @isTest
    static void testAcknowledgeInstruction_InsufficientPermissions_ThrowsAuraHandledException() {
        Special_Instruction__c si = createSI('Security Deposit Required', 'Pending', null, null, 'SG');
        User restricted = createUser(minimumAccessProfileId(), 'ackmin');

        Test.startTest();
        Boolean threw = false;
        System.runAs(restricted) {
            try {
                DeFinanceDashboardController.acknowledgeInstruction(si.Id, 'notes');
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        Test.stopTest();

        Assert.isTrue(threw, 'A profile without SI edit access should be blocked before any DML.');
    }

    // ═══════════════════════════════════════════════════════════════════
    // getUserCountries()
    // ═══════════════════════════════════════════════════════════════════

    @isTest
    static void testGetUserCountries_SystemAdministrator_ReturnsAllCountries() {
        User admin = createUser([SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1].Id, 'sysadm');

        Test.startTest();
        List<String> countries;
        System.runAs(admin) {
            countries = DeFinanceDashboardController.getUserCountries();
        }
        Test.stopTest();

        Assert.areEqual(11, countries.size(), 'System Administrator should get access to every DE country.');
        Assert.isTrue(countries.contains('Singapore'), 'Full country list should include Singapore.');
    }

    @isTest
    static void testGetUserCountries_FinanceAllSuperQueue_ReturnsAllCountries() {
        Group financeAll = new Group(Name = 'DE Finance All Test', DeveloperName = 'DE_Finance_All', Type = 'Regular');
        insert financeAll;

        User standard = createUser(standardUserProfileId(), 'finall');
        insert new GroupMember(GroupId = financeAll.Id, UserOrGroupId = standard.Id);

        Test.startTest();
        List<String> countries;
        System.runAs(standard) {
            countries = DeFinanceDashboardController.getUserCountries();
        }
        Test.stopTest();

        Assert.areEqual(11, countries.size(), 'DE_Finance_All members should get access to every DE country.');
    }

    @isTest
    static void testGetUserCountries_CountryQueueMember_ReturnsMappedCountries() {
        Group sgQueue = [SELECT Id FROM Group WHERE DeveloperName = 'DE_SG_Country_Finance' LIMIT 1];
        Group jpQueue = [SELECT Id FROM Group WHERE DeveloperName = 'DE_JP_Country_Finance' LIMIT 1];

        User standard = createUser(standardUserProfileId(), 'ctryq');
        insert new List<GroupMember>{
            new GroupMember(GroupId = sgQueue.Id, UserOrGroupId = standard.Id),
            new GroupMember(GroupId = jpQueue.Id, UserOrGroupId = standard.Id)
        };

        Test.startTest();
        List<String> countries;
        System.runAs(standard) {
            countries = DeFinanceDashboardController.getUserCountries();
        }
        Test.stopTest();

        Assert.areEqual(2, countries.size(), 'User should only get countries for the queues they belong to.');
        Assert.isTrue(countries.contains('Singapore'), 'DE_SG_Country_Finance maps to Singapore.');
        Assert.isTrue(countries.contains('Japan'), 'DE_JP_Country_Finance maps to Japan.');
    }

    @isTest
    static void testGetUserCountries_NoMemberships_ReturnsEmptyList() {
        User standard = createUser(standardUserProfileId(), 'nomemb');

        Test.startTest();
        List<String> countries;
        System.runAs(standard) {
            countries = DeFinanceDashboardController.getUserCountries();
        }
        Test.stopTest();

        Assert.isTrue(countries.isEmpty(), 'User with no relevant group membership should get an empty country list.');
    }
}