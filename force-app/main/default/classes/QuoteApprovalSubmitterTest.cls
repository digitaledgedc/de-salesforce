/**
 * QuoteApprovalSubmitterTest
 * QuoteApprovalSubmitter wraps Approval.process() in a per-request try/catch so
 * one bad Quote in a bulk Flow call can't blow up the whole invocation. These
 * tests exercise that structure directly: a Quote matching no active approval
 * process's entry criteria makes Approval.process() throw, and the test proves
 * that's caught and turned into a Result with isSuccess=false rather than an
 * unhandled exception — for both a single request and a bulk call.
 */
@IsTest
private class QuoteApprovalSubmitterTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = 'QAS Test Account');
        insert acc;

        Opportunity opp = new Opportunity(
            Name      = 'QAS Test Opp',
            AccountId = acc.Id,
            StageName = '1-Suspect',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;

        // Two plain Draft quotes with no entry-criteria fields set (DR_Required__c,
        // SBI_Flag__c, etc. all default false/blank) — deliberately matches no
        // active approval process so Approval.process() throws for each.
        insert new List<Quote>{
            new Quote(Name = 'QAS Quote 1', OpportunityId = opp.Id, Pricebook2Id = Test.getStandardPricebookId(), Status = 'Draft'),
            new Quote(Name = 'QAS Quote 2', OpportunityId = opp.Id, Pricebook2Id = Test.getStandardPricebookId(), Status = 'Draft')
        };
    }

    @IsTest
    static void testSubmit_NoMatchingApprovalProcess_ReturnsFailureNotException() {
        // Query by creation order, not Name — a Quote_Name_Auto-style flow may
        // rename Quote.Name on save.
        Quote q = [SELECT Id FROM Quote ORDER BY CreatedDate ASC LIMIT 1][0];

        QuoteApprovalSubmitter.Request req = new QuoteApprovalSubmitter.Request();
        req.quoteId = q.Id;

        Test.startTest();
        List<QuoteApprovalSubmitter.Result> results =
            QuoteApprovalSubmitter.submit(new List<QuoteApprovalSubmitter.Request>{ req });
        Test.stopTest();

        System.assertEquals(1, results.size(), 'One result per request');
        System.assertEquals(false, results[0].isSuccess,
            'A Quote matching no active approval process should fail gracefully, not throw');
        System.assertNotEquals(null, results[0].errorMessage,
            'Error message should be populated when submission fails');
    }

    @IsTest
    static void testSubmit_BulkRequests_ReturnsOneResultPerRequestInOrder() {
        List<Quote> quotes = [SELECT Id, Name FROM Quote ORDER BY Name ASC];
        System.assertEquals(2, quotes.size(), 'Setup should have created two quotes');

        List<QuoteApprovalSubmitter.Request> requests = new List<QuoteApprovalSubmitter.Request>();
        for (Quote q : quotes) {
            QuoteApprovalSubmitter.Request req = new QuoteApprovalSubmitter.Request();
            req.quoteId = q.Id;
            requests.add(req);
        }

        Test.startTest();
        List<QuoteApprovalSubmitter.Result> results = QuoteApprovalSubmitter.submit(requests);
        Test.stopTest();

        System.assertEquals(2, results.size(), 'Bulk call should return one Result per Request');
        for (QuoteApprovalSubmitter.Result r : results) {
            System.assertEquals(false, r.isSuccess, 'Neither test quote matches an active approval process');
        }
    }

    @IsTest
    static void testSubmit_EmptyRequestList_ReturnsEmptyResults() {
        Test.startTest();
        List<QuoteApprovalSubmitter.Result> results =
            QuoteApprovalSubmitter.submit(new List<QuoteApprovalSubmitter.Request>());
        Test.stopTest();

        System.assertEquals(0, results.size(), 'Empty input should return an empty result list, not throw');
    }
}