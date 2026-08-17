@IsTest
private class PricebookRequestTriggerHandlerTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(
            Name = 'PBR Handler Test Co',
            Operation_Country__c = 'Singapore',
            Tax_ID__c = 'T12345678X'
        );
        insert acc;

        // Activate standard pricebook in test context
        update new Pricebook2(Id = Test.getStandardPricebookId(), IsActive = true);

        Product2 prod = new Product2(
            Name        = 'PBR Test Product',
            IsActive    = true,
            ProductCode = 'PBR-TEST-001'
        );
        insert prod;

        PricebookEntry stdPbe = new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(),
            Product2Id   = prod.Id,
            UnitPrice    = 100,
            IsActive     = true
        );
        insert stdPbe;

        Pricebook_Request__c req = new Pricebook_Request__c(
            Account__c  = acc.Id,
            Status__c   = 'Draft',
            Currency__c = 'USD'
        );
        insert req;

        Pricebook_Request_Line__c line = new Pricebook_Request_Line__c(
            Pricebook_Request__c = req.Id,
            Product2__c          = prod.Id,
            Unit_Price__c        = 80,
            Name                 = 'PBR Test Product'
        );
        insert line;
    }

    @IsTest
    static void testStatusApproved_materializePricebook() {
        Pricebook_Request__c req = [SELECT Id, Status__c FROM Pricebook_Request__c LIMIT 1];

        Test.startTest();
        req.Status__c = 'Approved';
        update req;
        Test.stopTest();

        Pricebook_Request__c updated = [
            SELECT Pricebook2__c FROM Pricebook_Request__c WHERE Id = :req.Id
        ];
        System.assertNotEquals(null, updated.Pricebook2__c,
            'Approved request should have a Pricebook2 materialized');

        List<PricebookEntry> entries = [
            SELECT UnitPrice, Product2Id
            FROM PricebookEntry
            WHERE Pricebook2Id = :updated.Pricebook2__c
        ];
        System.assertEquals(1, entries.size(), 'New pricebook should have 1 entry');
        System.assertEquals(80, entries[0].UnitPrice, 'Entry price should match request line');
    }

    @IsTest
    static void testStatusChange_nonApproval_noMaterialize() {
        Pricebook_Request__c req = [SELECT Id FROM Pricebook_Request__c LIMIT 1];

        Test.startTest();
        req.Status__c = 'Pending Approval';
        update req;
        Test.stopTest();

        Pricebook_Request__c updated = [
            SELECT Pricebook2__c FROM Pricebook_Request__c WHERE Id = :req.Id
        ];
        System.assertEquals(null, updated.Pricebook2__c,
            'Non-approval status change should not materialize pricebook');
    }

    @IsTest
    static void testAlreadyApproved_noDoubleMaterialize() {
        Pricebook_Request__c req = [SELECT Id FROM Pricebook_Request__c LIMIT 1];

        // First approval
        req.Status__c = 'Approved';
        update req;

        Pricebook_Request__c afterFirst = [
            SELECT Pricebook2__c FROM Pricebook_Request__c WHERE Id = :req.Id
        ];
        Id firstPb = afterFirst.Pricebook2__c;

        Test.startTest();
        // Re-update — Status stays Approved, handler should skip (old == new)
        req.Approval_Notes__c = 'Updated notes';
        update req;
        Test.stopTest();

        Pricebook_Request__c afterSecond = [
            SELECT Pricebook2__c FROM Pricebook_Request__c WHERE Id = :req.Id
        ];
        System.assertEquals(firstPb, afterSecond.Pricebook2__c,
            'Re-updating an already-approved request should not create a second pricebook');
    }
}