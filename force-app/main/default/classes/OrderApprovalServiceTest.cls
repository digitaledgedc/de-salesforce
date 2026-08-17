@IsTest
private class OrderApprovalServiceTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = 'Test Account OAS');
        insert acc;
    }

    @IsTest
    static void testSubmitForApproval_nullSkips() {
        Test.startTest();
        OrderApprovalService.submitForApproval(null);
        OrderApprovalService.submitForApproval(new List<OrderApprovalService.SubmitRequest>());
        Test.stopTest();
        System.assert(true, 'Null and empty requests handled gracefully');
    }

    @IsTest
    static void testSubmitForApproval_nullOrderIdSkips() {
        OrderApprovalService.SubmitRequest req = new OrderApprovalService.SubmitRequest();
        req.orderId = null;
        req.comments = 'Test comment';

        Test.startTest();
        OrderApprovalService.submitForApproval(new List<OrderApprovalService.SubmitRequest>{ req });
        Test.stopTest();

        System.assert(true, 'Null orderId skipped without error');
    }

    @IsTest
    static void testSubmitForApproval_success() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test Account OAS' LIMIT 1];
        Id currentUserId = UserInfo.getUserId();

        Order ord = new Order(
            AccountId      = acc.Id,
            EffectiveDate  = Date.today(),
            Status         = 'Draft',
            Pricebook2Id   = Test.getStandardPricebookId(),
            Country_Manager__c = currentUserId
        );
        insert ord;

        // Set Status to Pending Approval to satisfy entry criteria
        ord.Status = 'Pending Approval';
        update ord;

        OrderApprovalService.SubmitRequest req = new OrderApprovalService.SubmitRequest();
        req.orderId  = ord.Id;
        req.comments = 'Unit test approval submission';

        Test.startTest();
        OrderApprovalService.submitForApproval(new List<OrderApprovalService.SubmitRequest>{ req });
        Test.stopTest();

        // Verify that an approval work item was created for the current user (Country Manager)
        List<ProcessInstanceWorkitem> workItems = [
            SELECT Id, ActorId
            FROM ProcessInstanceWorkitem
            WHERE ProcessInstance.TargetObjectId = :ord.Id
        ];
        System.assertEquals(1, workItems.size(), 'One approval work item should be created');
        System.assertEquals(currentUserId, workItems[0].ActorId, 'Work item should be assigned to the Country Manager');
    }
}