/**
 * OdooOrderConfirmHandlerTest
 * IP-2 inbound endpoint: confirms Odoo's sale order + subscription line IDs
 * back onto the Order/OrderItems, and back-fills any IP-5-created Asset that's
 * still missing Odoo_Subscription_ID__c.
 */
@IsTest
private class OdooOrderConfirmHandlerTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = 'IP2 Confirm Test Account');
        insert acc;

        Product2 prod = new Product2(Name = 'IP2 Confirm Test Product', IsActive = true);
        insert prod;
        Id stdPbId = Test.getStandardPricebookId();
        insert new PricebookEntry(Pricebook2Id = stdPbId, Product2Id = prod.Id, UnitPrice = 100, IsActive = true);
        PricebookEntry pbe = [SELECT Id FROM PricebookEntry WHERE Pricebook2Id = :stdPbId AND Product2Id = :prod.Id LIMIT 1];

        Order ord = new Order(
            AccountId         = acc.Id,
            Status            = 'Draft',
            EffectiveDate     = Date.today(),
            Operation_Site__c = 'JKT1',
            Pricebook2Id      = stdPbId,
            Order_Type__c     = 'New Service'
        );
        insert ord;

        // A second, unrelated Order — used to prove the "belongs to this order"
        // security check skips items that don't actually belong to sf_order_id.
        Order otherOrd = new Order(
            AccountId         = acc.Id,
            Status            = 'Draft',
            EffectiveDate     = Date.today(),
            Operation_Site__c = 'JKT1',
            Pricebook2Id      = stdPbId,
            Order_Type__c     = 'New Service'
        );
        insert otherOrd;

        insert new List<OrderItem>{
            new OrderItem(OrderId = ord.Id, PricebookEntryId = pbe.Id, Quantity = 1, UnitPrice = 100),
            new OrderItem(OrderId = otherOrd.Id, PricebookEntryId = pbe.Id, Quantity = 1, UnitPrice = 100)
        };

        // IP-5 already created this Asset for the order, but subscription_id
        // hasn't arrived yet — IP-2 is expected to back-fill it.
        insert new Asset(Name = 'IP2 Confirm Test Asset', AccountId = acc.Id, Source_Order__c = ord.Id);
    }

    private static void callEndpoint(String jsonBody) {
        RestRequest req = new RestRequest();
        req.requestURI  = '/services/apexrest/de/orderconfirm';
        req.httpMethod  = 'POST';
        req.requestBody = Blob.valueOf(jsonBody);
        RestContext.request  = req;
        RestContext.response = new RestResponse();
    }

    @IsTest
    static void testMissingSfOrderId_Returns400() {
        callEndpoint('{"odoo_order_id": 7001}');

        Test.startTest();
        OdooOrderConfirmHandler.handlePost();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode, 'Missing sf_order_id should return 400');
        System.assert(RestContext.response.responseBody.toString().contains('sf_order_id is required'),
            'Error body should explain what is missing');
    }

    @IsTest
    static void testValidPayload_UpdatesOrderOrderItemsAndAsset() {
        Order ord   = [SELECT Id FROM Order ORDER BY CreatedDate ASC LIMIT 1];
        OrderItem oi = [SELECT Id FROM OrderItem WHERE OrderId = :ord.Id LIMIT 1];

        callEndpoint('{'
            + '"sf_order_id": "' + ord.Id + '",'
            + '"odoo_order_id": 7001,'
            + '"subscription_id": 8001,'
            + '"lines": [{'
            +   '"sf_orderitem_id": "' + oi.Id + '",'
            +   '"odoo_sub_line_id": 9001,'
            +   '"odoo_origin_line_id": 9101'
            + '}]'
            + '}');

        Test.startTest();
        OdooOrderConfirmHandler.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        System.assert(RestContext.response.responseBody.toString().contains('"updated_lines":1'),
            'Response should report exactly one updated line');

        Order updatedOrd = [SELECT Odoo_Order_ID__c, Odoo_Subscription_ID__c FROM Order WHERE Id = :ord.Id];
        System.assertEquals('7001', updatedOrd.Odoo_Order_ID__c, 'Odoo_Order_ID__c should be confirmed/set');
        System.assertEquals('8001', updatedOrd.Odoo_Subscription_ID__c, 'Odoo_Subscription_ID__c should be set');

        OrderItem updatedOi = [SELECT Odoo_Sub_Line_ID__c, Odoo_Origin_Line_ID__c FROM OrderItem WHERE Id = :oi.Id];
        System.assertEquals('9001', updatedOi.Odoo_Sub_Line_ID__c, 'Odoo_Sub_Line_ID__c should be set from the line payload');
        System.assertEquals('9101', updatedOi.Odoo_Origin_Line_ID__c, 'Odoo_Origin_Line_ID__c should be set from the line payload');

        Asset asset = [SELECT Odoo_Subscription_ID__c FROM Asset WHERE Source_Order__c = :ord.Id LIMIT 1];
        System.assertEquals('8001', asset.Odoo_Subscription_ID__c,
            'IP-5-created Asset with no subscription id yet should be back-filled by IP-2');
    }

    @IsTest
    static void testOrderItemNotBelongingToOrder_SkippedAndLogged() {
        Order ord = [SELECT Id FROM Order ORDER BY CreatedDate ASC LIMIT 1];
        // Grab the OrderItem that belongs to the OTHER order, then claim it in
        // the payload for THIS order — the ownership check should skip it.
        OrderItem wrongOi = [SELECT Id, OrderId FROM OrderItem WHERE OrderId != :ord.Id LIMIT 1];

        callEndpoint('{'
            + '"sf_order_id": "' + ord.Id + '",'
            + '"lines": [{'
            +   '"sf_orderitem_id": "' + wrongOi.Id + '",'
            +   '"odoo_sub_line_id": 9002'
            + '}]'
            + '}');

        Test.startTest();
        OdooOrderConfirmHandler.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        System.assert(RestContext.response.responseBody.toString().contains('"updated_lines":0'),
            'The mismatched OrderItem should be skipped, not counted as updated');

        OrderItem stillUnchanged = [SELECT Odoo_Sub_Line_ID__c FROM OrderItem WHERE Id = :wrongOi.Id];
        System.assertEquals(null, stillUnchanged.Odoo_Sub_Line_ID__c,
            'OrderItem belonging to a different Order must not be updated');

        Integer errorCount = [SELECT COUNT() FROM DE_Integration_Error__c WHERE IP_Reference__c = 'IP-2'];
        System.assertEquals(1, errorCount, 'A mismatched OrderItem should be logged as an integration error');
    }

    @IsTest
    static void testEmptyLines_OrderStillUpdated_ZeroLinesReported() {
        Order ord = [SELECT Id FROM Order ORDER BY CreatedDate ASC LIMIT 1];

        callEndpoint('{"sf_order_id": "' + ord.Id + '", "odoo_order_id": 7002, "lines": []}');

        Test.startTest();
        OdooOrderConfirmHandler.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        System.assert(RestContext.response.responseBody.toString().contains('"updated_lines":0'));

        Order updatedOrd = [SELECT Odoo_Order_ID__c FROM Order WHERE Id = :ord.Id];
        System.assertEquals('7002', updatedOrd.Odoo_Order_ID__c,
            'The Order itself should still be confirmed even with an empty lines array');
    }

    @IsTest
    static void testMalformedJson_Returns500() {
        callEndpoint('{not valid json');

        Test.startTest();
        OdooOrderConfirmHandler.handlePost();
        Test.stopTest();

        System.assertEquals(500, RestContext.response.statusCode, 'Malformed JSON should be caught and return 500');
    }
}