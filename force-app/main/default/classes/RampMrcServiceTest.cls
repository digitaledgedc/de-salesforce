/**
 * RampMrcServiceTest
 * getSteadyStateMRC() returns the summed MRC of a ramp quote's FINAL (highest)
 * phase, or null when the quote has no ramp lines at all.
 */
@IsTest
private class RampMrcServiceTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = 'RMS Test Account');
        insert acc;

        Opportunity opp = new Opportunity(
            Name      = 'RMS Test Opp',
            AccountId = acc.Id,
            StageName = '1-Suspect',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;

        Id stdPbId = Test.getStandardPricebookId();
        Product2 prod = new Product2(Name = 'RMS Test Product', IsActive = true);
        insert prod;
        insert new PricebookEntry(Pricebook2Id = stdPbId, Product2Id = prod.Id, UnitPrice = 100, IsActive = true);
        PricebookEntry pbe = [SELECT Id FROM PricebookEntry WHERE Pricebook2Id = :stdPbId AND Product2Id = :prod.Id LIMIT 1];

        // MRC_Amount__c is a formula (UnitPrice * Quantity * (1 - Discount), forced
        // to 0 for NRC) — not directly settable, so drive it via UnitPrice/Quantity.
        // Ramp quote: phase 1 has two MRC lines (1000 + 500 = 1500), phase 2 has
        // one MRC line (2000) plus one NRC line that must be ignored entirely.
        Quote rampQuote = new Quote(Name = 'RMS Ramp Quote', OpportunityId = opp.Id, Pricebook2Id = stdPbId, Status = 'Draft');
        insert rampQuote;
        insert new List<QuoteLineItem>{
            new QuoteLineItem(QuoteId = rampQuote.Id, Product2Id = prod.Id, PricebookEntryId = pbe.Id,
                               Quantity = 1, UnitPrice = 1000, Charge_Type__c = 'MRC', Ramp_Phase__c = 1),
            new QuoteLineItem(QuoteId = rampQuote.Id, Product2Id = prod.Id, PricebookEntryId = pbe.Id,
                               Quantity = 1, UnitPrice = 500, Charge_Type__c = 'MRC', Ramp_Phase__c = 1),
            new QuoteLineItem(QuoteId = rampQuote.Id, Product2Id = prod.Id, PricebookEntryId = pbe.Id,
                               Quantity = 1, UnitPrice = 2000, Charge_Type__c = 'MRC', Ramp_Phase__c = 2),
            new QuoteLineItem(QuoteId = rampQuote.Id, Product2Id = prod.Id, PricebookEntryId = pbe.Id,
                               Quantity = 1, UnitPrice = 999, Charge_Type__c = 'NRC', Ramp_Phase__c = 2)
        };

        // Non-ramp quote: ordinary MRC line, no Ramp_Phase__c at all.
        Quote flatQuote = new Quote(Name = 'RMS Flat Quote', OpportunityId = opp.Id, Pricebook2Id = stdPbId, Status = 'Draft');
        insert flatQuote;
        insert new QuoteLineItem(
            QuoteId = flatQuote.Id, Product2Id = prod.Id, PricebookEntryId = pbe.Id,
            Quantity = 1, UnitPrice = 300, Charge_Type__c = 'MRC'
        );
    }

    // A Quote_Name_Auto-style flow may rename Quote.Name on save, so distinguish
    // by creation order (ramp inserted first) rather than querying by Name.
    private static Id rampQuoteId() {
        return [SELECT Id FROM Quote ORDER BY CreatedDate ASC LIMIT 1][0].Id;
    }

    private static Id flatQuoteId() {
        return [SELECT Id FROM Quote ORDER BY CreatedDate ASC LIMIT 1 OFFSET 1][0].Id;
    }

    @IsTest
    static void testRampQuote_ReturnsSumOfFinalPhaseOnly() {
        RampMrcService.Request req = new RampMrcService.Request();
        req.quoteId = rampQuoteId();

        Test.startTest();
        List<RampMrcService.Result> results =
            RampMrcService.getSteadyStateMRC(new List<RampMrcService.Request>{ req });
        Test.stopTest();

        System.assertEquals(1, results.size(), 'One result per request');
        System.assertEquals(2000, results[0].steadyStateMRC,
            'Should be phase 2 total (2000) — the highest phase — not phase 1 (1500) or the NRC line');
    }

    @IsTest
    static void testFlatQuote_WithNoRampPhases_ReturnsNull() {
        RampMrcService.Request req = new RampMrcService.Request();
        req.quoteId = flatQuoteId();

        Test.startTest();
        List<RampMrcService.Result> results =
            RampMrcService.getSteadyStateMRC(new List<RampMrcService.Request>{ req });
        Test.stopTest();

        System.assertEquals(null, results[0].steadyStateMRC,
            'A quote with no ramp-phase MRC lines should return null so callers fall back to gross Total_MRC');
    }

    @IsTest
    static void testNullQuoteIdInRequest_ReturnsNullResult_NoException() {
        RampMrcService.Request req = new RampMrcService.Request();
        req.quoteId = null;

        Test.startTest();
        List<RampMrcService.Result> results =
            RampMrcService.getSteadyStateMRC(new List<RampMrcService.Request>{ req });
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Still returns one result even for a null quoteId');
        System.assertEquals(null, results[0].steadyStateMRC, 'Null quoteId should resolve to a null result, not throw');
    }

    @IsTest
    static void testBulkMixedRequests_EachResolvesIndependently() {
        RampMrcService.Request rampReq = new RampMrcService.Request();
        rampReq.quoteId = rampQuoteId();
        RampMrcService.Request flatReq = new RampMrcService.Request();
        flatReq.quoteId = flatQuoteId();

        Test.startTest();
        List<RampMrcService.Result> results = RampMrcService.getSteadyStateMRC(
            new List<RampMrcService.Request>{ rampReq, flatReq }
        );
        Test.stopTest();

        System.assertEquals(2, results.size(), 'Bulk call should return one result per request, in order');
        System.assertEquals(2000, results[0].steadyStateMRC, 'First result should be the ramp quote steady-state');
        System.assertEquals(null, results[1].steadyStateMRC, 'Second result should be null for the flat quote');
    }

    @IsTest
    static void testEmptyRequestList_ReturnsEmptyResults() {
        Test.startTest();
        List<RampMrcService.Result> results = RampMrcService.getSteadyStateMRC(new List<RampMrcService.Request>());
        Test.stopTest();

        System.assertEquals(0, results.size(), 'Empty input should return an empty result list, not throw');
    }
}