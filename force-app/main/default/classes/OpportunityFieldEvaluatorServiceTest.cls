@IsTest
private class OpportunityFieldEvaluatorServiceTest {

    @TestSetup
    static void setupData() {
        Account acc = new Account(Name = 'Test Account');
        insert acc;

        Opportunity opp = new Opportunity(
            Name = 'Test Opportunity',
            AccountId = acc.Id,
            StageName = '1-Suspect',
            CloseDate = Date.today().addMonths(3)
        );
        insert opp;
    }

    @IsTest
    static void testFieldIsBlank() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];

        OpportunityFieldEvaluatorService.EvalRequest req = new OpportunityFieldEvaluatorService.EvalRequest();
        req.opportunityId = opp.Id;
        req.fieldApiName = 'Description';

        Test.startTest();
        List<OpportunityFieldEvaluatorService.EvalResult> results =
            OpportunityFieldEvaluatorService.evaluateFields(
                new List<OpportunityFieldEvaluatorService.EvalRequest>{ req }
            );
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Expected exactly one result for a single request');
        System.assertEquals(true, results[0].isFieldBlank, 'Expected isFieldBlank=true for a blank Description field');
    }

    @IsTest
    static void testFieldIsNotBlank() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        opp.Description = 'Test description';
        update opp;

        OpportunityFieldEvaluatorService.EvalRequest req = new OpportunityFieldEvaluatorService.EvalRequest();
        req.opportunityId = opp.Id;
        req.fieldApiName = 'Description';

        Test.startTest();
        List<OpportunityFieldEvaluatorService.EvalResult> results =
            OpportunityFieldEvaluatorService.evaluateFields(
                new List<OpportunityFieldEvaluatorService.EvalRequest>{ req }
            );
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Expected exactly one result for a single request');
        System.assertEquals(false, results[0].isFieldBlank, 'Expected isFieldBlank=false when Description has a value');
        System.assertEquals('Test description', results[0].fieldValueString, 'Expected fieldValueString to match the updated Description value');
    }

    @IsTest
    static void testInvalidFieldName() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];

        OpportunityFieldEvaluatorService.EvalRequest req = new OpportunityFieldEvaluatorService.EvalRequest();
        req.opportunityId = opp.Id;
        req.fieldApiName = 'NonExistentField__c';

        Test.startTest();
        List<OpportunityFieldEvaluatorService.EvalResult> results =
            OpportunityFieldEvaluatorService.evaluateFields(
                new List<OpportunityFieldEvaluatorService.EvalRequest>{ req }
            );
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Expected exactly one result even for an invalid field name');
        System.assertEquals(true, results[0].isFieldBlank, 'Expected isFieldBlank=true when field does not exist in schema');
    }

    @IsTest
    static void testEmptyInput() {
        Test.startTest();
        List<OpportunityFieldEvaluatorService.EvalResult> results =
            OpportunityFieldEvaluatorService.evaluateFields(
                new List<OpportunityFieldEvaluatorService.EvalRequest>()
            );
        Test.stopTest();

        System.assertEquals(0, results.size(), 'Expected empty result list when input list is empty');
    }

    @IsTest
    static void testNullInput() {
        Test.startTest();
        List<OpportunityFieldEvaluatorService.EvalResult> results =
            OpportunityFieldEvaluatorService.evaluateFields(null);
        Test.stopTest();

        System.assertEquals(0, results.size(), 'Expected empty result list when input is null');
    }
}