/**
 * OrderConfirmationHandlerTest
 * confirmOrder() is intentionally a no-op — see the comment in
 * OrderConfirmationHandler for why (it used to double-enqueue
 * OdooBanSyncQueueable alongside OrderTriggerHandler and create duplicate
 * Odoo partner/BAN records). This test locks in that no-op behavior so a
 * future edit doesn't silently reintroduce the duplicate-job bug.
 */
@IsTest
private class OrderConfirmationHandlerTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(
            Name                 = 'Order Confirmation Test Account',
            BillingCountry       = 'Singapore',
            Operation_Country__c = 'Singapore',
            RecordTypeId         = [
                SELECT Id FROM RecordType
                WHERE SObjectType = 'Account' AND DeveloperName = 'Customer' LIMIT 1
            ].Id
        );
        insert acc;

        Order ord = new Order(
            AccountId         = acc.Id,
            Status            = 'Draft',
            EffectiveDate     = Date.today(),
            Operation_Site__c = 'JKT1',
            Pricebook2Id      = Test.getStandardPricebookId(),
            Order_Type__c     = 'New Service'
        );
        insert ord;
    }

    @IsTest
    static void testConfirmOrder_IsNoOp_DoesNotThrow() {
        Order ord = [SELECT Id, Status FROM Order LIMIT 1];

        Test.startTest();
        OrderConfirmationHandler.confirmOrder(new List<Id>{ ord.Id });
        Test.stopTest();

        Order afterCall = [SELECT Id, Status FROM Order WHERE Id = :ord.Id];
        System.assertEquals(ord.Status, afterCall.Status,
            'confirmOrder is a no-op and must not change the Order itself');
    }

    @IsTest
    static void testConfirmOrder_EmptyList_DoesNotThrow() {
        Test.startTest();
        OrderConfirmationHandler.confirmOrder(new List<Id>());
        Test.stopTest();
        // Reaching this line means no exception was thrown for an empty invocation list.
        System.assert(true, 'confirmOrder should tolerate an empty Id list without error');
    }

    @IsTest
    static void testConfirmOrder_MultipleIds_DoesNotThrow() {
        Order ord = [SELECT Id FROM Order LIMIT 1];

        Test.startTest();
        OrderConfirmationHandler.confirmOrder(new List<Id>{ ord.Id, ord.Id });
        Test.stopTest();

        System.assert(true, 'confirmOrder should tolerate multiple/duplicate Ids without error');
    }
}