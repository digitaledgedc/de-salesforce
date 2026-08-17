/**
 * OdooCrossConnectHandlerTest
 * IP-6: Tests for inbound cross-connect provisioning events from Odoo.
 * Covers: Order creation, direct Account lookup via Odoo_Partner_ID__c,
 * missing partner_id 400, account not found warning + error log,
 * all payload fields mapped to Order.
 */
@IsTest
private class OdooCrossConnectHandlerTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(
            Name                 = 'IP6 Test Customer',
            BillingCountry       = 'Singapore',
            Operation_Country__c = 'Singapore',
            Odoo_Partner_ID__c   = 7777,
            RecordTypeId         = [
                SELECT Id FROM RecordType
                WHERE SObjectType = 'Account' AND DeveloperName = 'Customer' LIMIT 1
            ].Id
        );
        insert acc;
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    private static void callEndpoint(String jsonBody) {
        RestRequest req = new RestRequest();
        req.requestURI  = '/services/apexrest/de/crossconnect';
        req.httpMethod  = 'POST';
        req.requestBody = Blob.valueOf(jsonBody);
        RestContext.request  = req;
        RestContext.response = new RestResponse();
    }

    // ─── Success: Order created with all fields ─────────────────────────────

    @IsTest
    static void testSuccess_OrderCreated() {
        callEndpoint('{'
            + '"partner_id": 7777,'
            + '"odoo_order_id": 15800,'
            + '"site_code": "SIN1",'
            + '"cross_connect_type": "SMF",'
            + '"remote_entity_name": "AWS",'
            + '"remote_entity_type": "Cloud",'
            + '"port_speed": "10G",'
            + '"mrc": 850.00,'
            + '"rdd": "2026-07-01",'
            + '"description": "DC3 to AWS Direct Connect"'
            + '}');

        Test.startTest();
        OdooCrossConnectHandler.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        String body = RestContext.response.responseBody.toString();
        System.assert(body.contains('"order_id"'), 'Response should contain order_id');
        System.assert(!body.contains('warning'), 'Should not contain warning');

        Account acc = [SELECT Id FROM Account WHERE Name = 'IP6 Test Customer'];
        List<Order> orders = [
            SELECT Status, EffectiveDate, Description,
                   Order_Type__c, Operation_Site__c, Odoo_Order_ID__c,
                   Integration_Status__c, RDD__c, AccountId
            FROM Order WHERE AccountId = :acc.Id
        ];
        System.assertEquals(1, orders.size(), 'One Order should be created');

        Order ord = orders[0];
        System.assertEquals('Draft', ord.Status);
        System.assertEquals(Date.valueOf('2026-07-01'), ord.EffectiveDate);
        System.assertEquals(Date.valueOf('2026-07-01'), ord.RDD__c);
        System.assertEquals('New Service', ord.Order_Type__c);
        System.assertEquals('SIN1', ord.Operation_Site__c);
        System.assertEquals('15800', ord.Odoo_Order_ID__c);
        System.assertEquals('Acknowledged', ord.Integration_Status__c);
        System.assert(ord.Description.contains('15800'), 'Description should contain Odoo order ID');
        System.assert(ord.Description.contains('SMF'), 'Description should contain cross-connect type');
        System.assert(ord.Description.contains('AWS'), 'Description should contain remote entity');
        System.assert(ord.Description.contains('10G'), 'Description should contain port speed');
        System.assert(ord.Description.contains('850'), 'Description should contain MRC');
    }

    // ─── Account not found → warning + error logged ─────────────────────────

    @IsTest
    static void testAccountNotFound_WarningAndErrorLogged() {
        callEndpoint('{'
            + '"partner_id": 99999,'
            + '"odoo_order_id": 15801,'
            + '"site_code": "JKT1",'
            + '"cross_connect_type": "MMF",'
            + '"port_speed": "1G",'
            + '"mrc": 250.00'
            + '}');

        Test.startTest();
        OdooCrossConnectHandler.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        String body = RestContext.response.responseBody.toString();
        System.assert(body.contains('warning'), 'Should return warning when account not found');
        System.assert(body.contains('Account not found'), 'Warning should mention account not found');

        List<DE_Integration_Error__c> errors = [
            SELECT Error_Message__c FROM DE_Integration_Error__c WHERE IP_Reference__c = 'IP-6'
        ];
        System.assertEquals(1, errors.size(), 'IP-6 error should be logged');
        System.assert(errors[0].Error_Message__c.contains('99999'),
            'Error should mention the partner_id');
    }

    // ─── Missing partner_id → 400 ───────────────────────────────────────────

    @IsTest
    static void testMissingPartnerId_Returns400() {
        callEndpoint('{'
            + '"odoo_order_id": 15802,'
            + '"site_code": "JKT1"'
            + '}');

        Test.startTest();
        OdooCrossConnectHandler.handlePost();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode);
        System.assert(RestContext.response.responseBody.toString().contains('partner_id is required'));
    }

    // ─── Minimal payload (only required fields) ─────────────────────────────

    @IsTest
    static void testMinimalPayload_Success() {
        callEndpoint('{"partner_id": 7777}');

        Test.startTest();
        OdooCrossConnectHandler.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        System.assert(RestContext.response.responseBody.toString().contains('order_id'));

        Account acc = [SELECT Id FROM Account WHERE Name = 'IP6 Test Customer'];
        List<Order> orders = [
            SELECT EffectiveDate FROM Order WHERE AccountId = :acc.Id
        ];
        System.assertEquals(1, orders.size());
        // No RDD → effective date should be today
        System.assertEquals(Date.today(), orders[0].EffectiveDate);
    }

    // ─── No Order created when account not found ────────────────────────────

    @IsTest
    static void testNoOrderWhenAccountNotFound() {
        callEndpoint('{"partner_id": 88888, "site_code": "SIN1"}');

        Test.startTest();
        OdooCrossConnectHandler.handlePost();
        Test.stopTest();

        Integer orderCount = [SELECT COUNT() FROM Order];
        System.assertEquals(0, orderCount, 'No Order should be created when account not found');
    }
}