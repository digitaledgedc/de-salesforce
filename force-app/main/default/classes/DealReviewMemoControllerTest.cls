@IsTest
private class DealReviewMemoControllerTest {

    // Full-copy divergence note: VR_OPP_21_Site_Required_At_Quote requires
    // Target_Site__c once StageName reaches '3-Quote', and
    // VR_OPP_20_CurrencyMatchesSubsidiary requires CurrencyIsoCode to be the
    // country's local currency or USD. Every Opportunity created below at
    // '3-Quote'+ explicitly sets Target_Site__c and CurrencyIsoCode='USD' to
    // satisfy both rules regardless of org default currency.

    private static Account makeAccount(String name) {
        Account acc = new Account(
            Name = name,
            Status__c = 'Active',
            Operation_Country__c = 'Korea'
        );
        insert acc;
        return acc;
    }

    private static Site__c makeSite(String code) {
        Site__c site = new Site__c(
            Name = code,
            Site_Code__c = code,
            Country__c = 'KR'
        );
        insert site;
        return site;
    }

    @IsTest
    static void testGetMemoData_Positive() {
        Account acc = makeAccount('Test Customer');
        Site__c site = makeSite('SITE01');

        Opportunity opp = new Opportunity(
            Name = 'Test Deal',
            AccountId = acc.Id,
            StageName = '3-Quote',
            CloseDate = Date.today().addMonths(3),
            CurrencyIsoCode = 'USD',
            Operation_Country__c = 'Korea',
            Target_Site__c = site.Id,
            Power_kW__c = 500,
            Contract_Term_Months__c = 36,
            MRC__c = 50000,
            NRC__c = 10000,
            DR_Notes__c = 'Test deal review summary'
        );
        insert opp;

        Id stdPbId = Test.getStandardPricebookId();
        Quote q = new Quote(Name = 'Test Quote', OpportunityId = opp.Id, Pricebook2Id = stdPbId);
        insert q;

        Test.startTest();
        DealReviewMemoController.MemoData data = DealReviewMemoController.getMemoData(opp.Id);
        Test.stopTest();

        Assert.isNotNull(data.opp, 'Opportunity should be returned');
        Assert.areEqual(opp.Id, data.opp.Id, 'Opportunity id should match');
        Assert.areEqual(1, data.availableQuotes.size(), 'Should have 1 available quote in Draft status');
        Assert.areEqual(String.valueOf(q.Id), data.availableQuotes[0].quoteId, 'Quote id should match');
        Assert.isTrue(data.availableQuotes[0].label.endsWith('(Draft)'), 'Label should include Draft status');
        Assert.isNotNull(data.missingFields, 'Missing-field list should be initialized');
    }

    @IsTest
    static void testGetMemoData_ViaQuoteId() {
        Account acc = makeAccount('Quote Path Customer');
        Site__c site = makeSite('SITE02');

        Opportunity opp = new Opportunity(
            Name = 'Quote Path Deal',
            AccountId = acc.Id,
            StageName = '3-Quote',
            CloseDate = Date.today().addMonths(2),
            CurrencyIsoCode = 'USD',
            Operation_Country__c = 'Korea',
            Target_Site__c = site.Id,
            Power_kW__c = 200,
            Contract_Term_Months__c = 24,
            DR_Notes__c = 'Summary'
        );
        insert opp;

        Id stdPbId = Test.getStandardPricebookId();
        Quote q = new Quote(Name = 'Launch Quote', OpportunityId = opp.Id, Pricebook2Id = stdPbId);
        insert q;

        Test.startTest();
        DealReviewMemoController.MemoData data = DealReviewMemoController.getMemoData(q.Id);
        Test.stopTest();

        Assert.areEqual(opp.Id, data.opp.Id, 'Should resolve the Opportunity linked to the Quote');
    }

    @IsTest
    static void testGetMemoData_QuoteNotFound_Throws() {
        Account acc = makeAccount('Deleted Quote Customer');
        Site__c site = makeSite('SITE03');

        Opportunity opp = new Opportunity(
            Name = 'Deleted Quote Deal',
            AccountId = acc.Id,
            StageName = '3-Quote',
            CloseDate = Date.today().addMonths(2),
            CurrencyIsoCode = 'USD',
            Operation_Country__c = 'Korea',
            Target_Site__c = site.Id,
            Power_kW__c = 200,
            Contract_Term_Months__c = 24,
            DR_Notes__c = 'Summary'
        );
        insert opp;

        Id stdPbId = Test.getStandardPricebookId();
        Quote q = new Quote(Name = 'Temp Quote', OpportunityId = opp.Id, Pricebook2Id = stdPbId);
        insert q;
        Id deletedQuoteId = q.Id;
        delete q;

        Test.startTest();
        try {
            DealReviewMemoController.getMemoData(deletedQuoteId);
            Assert.fail('Expected AuraHandledException for a Quote that no longer exists');
        } catch (AuraHandledException e) {
            Assert.isTrue(true, 'AuraHandledException correctly thrown for missing Quote');
        }
        Test.stopTest();
    }

    @IsTest
    static void testGetMemoData_OppNotFound_Throws() {
        Account acc = makeAccount('Deleted Opp Customer');
        Opportunity opp = new Opportunity(
            Name = 'Temp Opp',
            AccountId = acc.Id,
            StageName = '2-Prospect',
            CloseDate = Date.today().addMonths(1)
        );
        insert opp;
        Id deletedOppId = opp.Id;
        delete opp;

        Test.startTest();
        try {
            DealReviewMemoController.getMemoData(deletedOppId);
            Assert.fail('Expected AuraHandledException for a missing Opportunity');
        } catch (AuraHandledException e) {
            Assert.isTrue(true, 'AuraHandledException correctly thrown for missing Opportunity');
        }
        Test.stopTest();
    }

    @IsTest
    static void testGetMemoData_MissingFields() {
        Opportunity opp = new Opportunity(
            Name = 'Incomplete Deal',
            StageName = '2-Prospect',
            CloseDate = Date.today().addMonths(3),
            CurrencyIsoCode = 'USD'
        );
        insert opp;

        Test.startTest();
        DealReviewMemoController.MemoData data = DealReviewMemoController.getMemoData(opp.Id);
        Test.stopTest();

        Assert.areEqual(6, data.missingFields.size(), 'All six tracked fields should be missing');
        Assert.isTrue(data.missingFields.contains('Account'), 'Account should be flagged missing');
        Assert.isTrue(data.missingFields.contains('Country'), 'Country should be flagged missing');
        Assert.isTrue(data.missingFields.contains('Site'), 'Site should be flagged missing');
        Assert.isTrue(data.missingFields.contains('Power (kW)'), 'Power should be flagged missing');
        Assert.isTrue(data.missingFields.contains('Contract Tenure'), 'Contract Tenure should be flagged missing');
        Assert.isTrue(data.missingFields.contains('Deal Review Summary'), 'Deal Review Summary should be flagged missing');
    }

    @IsTest
    static void testGetMemoData_NoActiveQuotes() {
        Account acc = makeAccount('Rejected Quote Customer');
        Site__c site = makeSite('SITE04');

        Opportunity opp = new Opportunity(
            Name = 'Rejected Quote Deal',
            AccountId = acc.Id,
            StageName = '3-Quote',
            CloseDate = Date.today().addMonths(3),
            CurrencyIsoCode = 'USD',
            Operation_Country__c = 'Korea',
            Target_Site__c = site.Id,
            Power_kW__c = 500,
            Contract_Term_Months__c = 36,
            DR_Notes__c = 'Summary'
        );
        insert opp;

        Id stdPbId = Test.getStandardPricebookId();
        Quote q = new Quote(Name = 'Rejected Quote', OpportunityId = opp.Id, Pricebook2Id = stdPbId, Status = 'Rejected');
        insert q;

        Test.startTest();
        DealReviewMemoController.MemoData data = DealReviewMemoController.getMemoData(opp.Id);
        Test.stopTest();

        Assert.areEqual(0, data.availableQuotes.size(), 'No available quotes when all are rejected');
    }

    @IsTest
    static void testGenerateMemo_Positive() {
        Account acc = makeAccount('Generate Memo Customer');
        Site__c site = makeSite('SITE05');

        Opportunity opp = new Opportunity(
            Name = 'Generate Memo Deal',
            AccountId = acc.Id,
            StageName = '3-Quote',
            CloseDate = Date.today().addMonths(3),
            CurrencyIsoCode = 'USD',
            Operation_Country__c = 'Korea',
            Target_Site__c = site.Id,
            Power_kW__c = 500,
            Contract_Term_Months__c = 36,
            DR_Notes__c = 'Summary',
            DR_Status__c = 'Reviewing'
        );
        insert opp;

        Test.startTest();
        Id cvId = DealReviewMemoController.generateMemo(opp.Id);
        Test.stopTest();

        Assert.isNotNull(cvId, 'ContentVersion Id should be returned');
        ContentVersion cv = [SELECT Title FROM ContentVersion WHERE Id = :cvId];
        Assert.isTrue(cv.Title.contains('Deal Review Memo'), 'File title should contain Deal Review Memo');

        Opportunity updated = [SELECT DR_Status__c, DR_Required__c, DR_Requested_Date__c FROM Opportunity WHERE Id = :opp.Id];
        Assert.areEqual('DR Required', updated.DR_Status__c, 'DR Status should be set when not already Approved');
        Assert.areEqual(true, updated.DR_Required__c, 'DR Required should be true');
        Assert.areEqual(Date.today(), updated.DR_Requested_Date__c, 'DR Requested Date should default to today');
    }

    @IsTest
    static void testGenerateMemo_AlreadyApproved_SkipsStatusUpdate() {
        Account acc = makeAccount('Approved Memo Customer');
        Site__c site = makeSite('SITE06');

        Opportunity opp = new Opportunity(
            Name = 'Approved Memo Deal',
            AccountId = acc.Id,
            StageName = '3-Quote',
            CloseDate = Date.today().addMonths(3),
            CurrencyIsoCode = 'USD',
            Operation_Country__c = 'Korea',
            Target_Site__c = site.Id,
            Power_kW__c = 500,
            Contract_Term_Months__c = 36,
            DR_Notes__c = 'Summary',
            DR_Status__c = 'Approved',
            DR_Required__c = false
        );
        insert opp;

        Test.startTest();
        Id cvId = DealReviewMemoController.generateMemo(opp.Id);
        Test.stopTest();

        Assert.isNotNull(cvId, 'ContentVersion Id should still be returned');

        Opportunity updated = [SELECT DR_Status__c, DR_Required__c FROM Opportunity WHERE Id = :opp.Id];
        Assert.areEqual('Approved', updated.DR_Status__c, 'DR Status should remain unchanged when already Approved');
        Assert.areEqual(false, updated.DR_Required__c, 'DR Required should remain unchanged when already Approved');
    }

    @IsTest
    static void testGenerateMemo_OppNotFound_Throws() {
        Account acc = makeAccount('Deleted Generate Customer');
        Opportunity opp = new Opportunity(
            Name = 'Temp Generate Opp',
            AccountId = acc.Id,
            StageName = '2-Prospect',
            CloseDate = Date.today().addMonths(1)
        );
        insert opp;
        Id deletedOppId = opp.Id;
        delete opp;

        Test.startTest();
        try {
            DealReviewMemoController.generateMemo(deletedOppId);
            Assert.fail('Expected AuraHandledException for a missing Opportunity');
        } catch (AuraHandledException e) {
            Assert.isTrue(true, 'AuraHandledException correctly thrown for missing Opportunity');
        }
        Test.stopTest();
    }

    @IsTest
    static void testSaveDraftFields_Positive() {
        Account acc = makeAccount('Save Draft Customer');
        Opportunity opp = new Opportunity(
            Name = 'Save Draft Deal',
            AccountId = acc.Id,
            StageName = '2-Prospect',
            CloseDate = Date.today().addMonths(3),
            CurrencyIsoCode = 'USD'
        );
        insert opp;

        Map<String, Object> fields = new Map<String, Object>{
            'DR_Notes__c' => 'Updated deal notes',
            'DR_Market_Benchmark__c' => 'Market benchmark data',
            'DR_Pricing_Justification__c' => 'Pricing justification',
            'DR_NRC_Scope__c' => 'NRC scope of works',
            'DR_NRC_Justification__c' => 'NRC justification',
            'DR_Other_Considerations__c' => 'Other considerations',
            'API__c' => '3.5%',
            'PUE__c' => 1.35,
            'Metered_Power_Charges__c' => 'Pass-through',
            'Reservation_ROFR_kW__c' => 200
        };

        Test.startTest();
        DealReviewMemoController.saveDraftFields(opp.Id, JSON.serialize(fields));
        Test.stopTest();

        Opportunity updated = [
            SELECT DR_Notes__c, DR_Market_Benchmark__c, DR_Pricing_Justification__c,
                   DR_NRC_Scope__c, DR_NRC_Justification__c, DR_Other_Considerations__c,
                   API__c, PUE__c, Metered_Power_Charges__c, Reservation_ROFR_kW__c
            FROM Opportunity WHERE Id = :opp.Id
        ];
        Assert.areEqual('Updated deal notes', updated.DR_Notes__c, 'DR_Notes__c should be updated');
        Assert.areEqual('Market benchmark data', updated.DR_Market_Benchmark__c, 'DR_Market_Benchmark__c should be updated');
        Assert.areEqual('Pricing justification', updated.DR_Pricing_Justification__c, 'DR_Pricing_Justification__c should be updated');
        Assert.areEqual('NRC scope of works', updated.DR_NRC_Scope__c, 'DR_NRC_Scope__c should be updated');
        Assert.areEqual('NRC justification', updated.DR_NRC_Justification__c, 'DR_NRC_Justification__c should be updated');
        Assert.areEqual('Other considerations', updated.DR_Other_Considerations__c, 'DR_Other_Considerations__c should be updated');
        Assert.areEqual('3.5%', updated.API__c, 'API__c should be updated');
        Assert.areEqual(1.35, updated.PUE__c, 'PUE__c should be updated');
        Assert.areEqual('Pass-through', updated.Metered_Power_Charges__c, 'Metered_Power_Charges__c should be updated');
        Assert.areEqual(200, updated.Reservation_ROFR_kW__c, 'Reservation_ROFR_kW__c should be updated');
    }

    @IsTest
    static void testSaveDraftFields_EmptyFieldsMap_NoOp() {
        Account acc = makeAccount('Empty Draft Customer');
        Opportunity opp = new Opportunity(
            Name = 'Empty Draft Deal',
            AccountId = acc.Id,
            StageName = '2-Prospect',
            CloseDate = Date.today().addMonths(3),
            CurrencyIsoCode = 'USD',
            DR_Notes__c = 'Original notes'
        );
        insert opp;

        Map<String, Object> fields = new Map<String, Object>();

        Test.startTest();
        DealReviewMemoController.saveDraftFields(opp.Id, JSON.serialize(fields));
        Test.stopTest();

        Opportunity updated = [SELECT DR_Notes__c FROM Opportunity WHERE Id = :opp.Id];
        Assert.areEqual('Original notes', updated.DR_Notes__c, 'No field should change when the fields map is empty');
    }

    @IsTest
    static void testSaveDraftFields_OppNotFound_Throws() {
        Account acc = makeAccount('Deleted Draft Customer');
        Opportunity opp = new Opportunity(
            Name = 'Temp Draft Opp',
            AccountId = acc.Id,
            StageName = '2-Prospect',
            CloseDate = Date.today().addMonths(1)
        );
        insert opp;
        Id deletedOppId = opp.Id;
        delete opp;

        Map<String, Object> fields = new Map<String, Object>{ 'DR_Notes__c' => 'Should fail' };

        Test.startTest();
        try {
            DealReviewMemoController.saveDraftFields(deletedOppId, JSON.serialize(fields));
            Assert.fail('Expected a DmlException when updating a deleted Opportunity');
        } catch (DmlException e) {
            Assert.isTrue(true, 'DmlException correctly thrown for missing Opportunity');
        }
        Test.stopTest();
    }

    @IsTest
    static void testGetQuoteLines_Positive() {
        Account acc = makeAccount('Quote Lines Customer');
        Opportunity opp = new Opportunity(
            Name = 'Quote Lines Deal',
            AccountId = acc.Id,
            StageName = '2-Prospect',
            CloseDate = Date.today().addMonths(2),
            CurrencyIsoCode = 'USD'
        );
        insert opp;

        Id stdPbId = Test.getStandardPricebookId();
        Product2 prod = new Product2(Name = 'Colocation - 19" Cabinet', ProductCode = 'COL.CAB19', IsActive = true);
        insert prod;
        PricebookEntry pbe = new PricebookEntry(Pricebook2Id = stdPbId, Product2Id = prod.Id, UnitPrice = 1500, CurrencyIsoCode = 'USD', IsActive = true);
        insert pbe;

        Quote q = new Quote(Name = 'Quote Lines Quote', OpportunityId = opp.Id, Pricebook2Id = stdPbId);
        insert q;

        QuoteLineItem qli = new QuoteLineItem(
            QuoteId = q.Id, Product2Id = prod.Id, PricebookEntryId = pbe.Id,
            Quantity = 10, UnitPrice = 1500
        );
        insert qli;

        Test.startTest();
        List<QuoteLineItem> lines = DealReviewMemoController.getQuoteLines(q.Id);
        Test.stopTest();

        Assert.areEqual(1, lines.size(), 'Should have 1 quote line item');
        Assert.areEqual('COL.CAB19', lines[0].Product2.ProductCode, 'Product code should match');
    }

    @IsTest
    static void testGetQuoteLines_EmptyQuote() {
        Account acc = makeAccount('Empty Quote Lines Customer');
        Opportunity opp = new Opportunity(
            Name = 'Empty Quote Lines Deal',
            AccountId = acc.Id,
            StageName = '2-Prospect',
            CloseDate = Date.today().addMonths(2),
            CurrencyIsoCode = 'USD'
        );
        insert opp;

        Id stdPbId = Test.getStandardPricebookId();
        Quote q = new Quote(Name = 'No Lines Quote', OpportunityId = opp.Id, Pricebook2Id = stdPbId);
        insert q;

        Test.startTest();
        List<QuoteLineItem> lines = DealReviewMemoController.getQuoteLines(q.Id);
        Test.stopTest();

        Assert.areEqual(0, lines.size(), 'Quote with no lines should return an empty list');
    }

    @IsTest
    static void testGetQuoteLines_Bulk() {
        Account acc = makeAccount('Bulk Quote Lines Customer');
        Opportunity opp = new Opportunity(
            Name = 'Bulk Quote Lines Deal',
            AccountId = acc.Id,
            StageName = '2-Prospect',
            CloseDate = Date.today().addMonths(2),
            CurrencyIsoCode = 'USD'
        );
        insert opp;

        Id stdPbId = Test.getStandardPricebookId();
        Product2 prod = new Product2(Name = 'Bulk Product', ProductCode = 'BULK.001', IsActive = true);
        insert prod;
        PricebookEntry pbe = new PricebookEntry(Pricebook2Id = stdPbId, Product2Id = prod.Id, UnitPrice = 100, CurrencyIsoCode = 'USD', IsActive = true);
        insert pbe;

        Quote q = new Quote(Name = 'Bulk Quote', OpportunityId = opp.Id, Pricebook2Id = stdPbId);
        insert q;

        List<QuoteLineItem> lines = new List<QuoteLineItem>();
        for (Integer i = 0; i < 200; i++) {
            lines.add(new QuoteLineItem(
                QuoteId = q.Id, Product2Id = prod.Id, PricebookEntryId = pbe.Id,
                Quantity = 1, UnitPrice = 100
            ));
        }
        insert lines;

        Test.startTest();
        List<QuoteLineItem> result = DealReviewMemoController.getQuoteLines(q.Id);
        Test.stopTest();

        Assert.areEqual(200, result.size(), 'All 200 quote line items should be returned');
    }
}