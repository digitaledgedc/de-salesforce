@IsTest
private class LeadTriggerHandlerTest {

    @IsTest
    static void testBeforeInsert_handlerRuns() {
        Lead ld = new Lead(
            FirstName = 'Test',
            LastName  = 'Handler Lead',
            Company   = 'Handler Test Co',
            Email     = 'handler.test@example.com',
            Status    = 'New'
        );

        Test.startTest();
        insert ld;
        Test.stopTest();

        Lead inserted = [SELECT Id, LastName FROM Lead WHERE Id = :ld.Id];
        System.assertEquals('Handler Lead', inserted.LastName,
            'Lead should be inserted through handler without error');
    }

    @IsTest
    static void testAfterInsert_handlerRuns() {
        List<Lead> leads = new List<Lead>();
        for (Integer i = 0; i < 5; i++) {
            leads.add(new Lead(
                FirstName = 'Bulk',
                LastName  = 'Lead ' + i,
                Company   = 'Bulk Test Co',
                Email     = 'bulk.lead' + i + '@example.com',
                Status    = 'New'
            ));
        }

        Test.startTest();
        insert leads;
        Test.stopTest();

        System.assertEquals(5, [SELECT COUNT() FROM Lead WHERE Company = 'Bulk Test Co'],
            'All 5 leads should be inserted through handler');
    }
}