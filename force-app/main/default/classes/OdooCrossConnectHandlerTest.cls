/**
 * OdooCrossConnectHandlerTest
 * IP-6: Tests for inbound cross-connect provisioning events from Odoo.
 * Covers: Order creation, direct Account lookup via Odoo_Partner_ID__c,
 * missing partner_id 400, account not found warning + error log,
 * all payload fields mapped to Order, BAN resolution (currency + activation),
 * Opportunity creation (site/country resolution, order_number, MRC/NRC rollup),
 * Charge_Type__c derivation for order lines, and blank-vs-absent date handling.
 */
@IsTest
private class OdooCrossConnectHandlerTest {

    @TestSetup
    static void setup() {
        Id customerRt = [
            SELECT Id FROM RecordType
            WHERE SObjectType = 'Account' AND DeveloperName = 'Customer' LIMIT 1
        ].Id;

        Account acc = new Account(
            Name                 = 'IP6 Test Customer',
            BillingCountry       = 'Singapore',
            Operation_Country__c = 'Singapore',
            Odoo_Partner_ID__c   = 7777,
            RecordTypeId         = customerRt
        );
        insert acc;

        Account noBanAcc = new Account(
            Name                 = 'IP6 Test Customer No BAN',
            BillingCountry       = 'Indonesia',
            Operation_Country__c = 'Indonesia',
            Odoo_Partner_ID__c   = 7778,
            RecordTypeId         = customerRt
        );
        insert noBanAcc;

        // Site used for Opportunity creation (Target_Site__c / Operation_Country__c
        // resolution — VR_OPP_21_Site_Required_At_Quote requires both from 5-Won onward).
        insert new Site__c(
            Name         = 'IP6 Test Site',
            Site_Code__c = 'IP6TEST1',
            Country__c   = 'ID' // Country_Name__c formula resolves this to 'Indonesia'
        );

        // BAN in IDR, linked to the primary test Account — resolved via ns_ban_id.
        insert new BillingAccount__c(
            Name             = 'IP6 Test BAN',
            Account__c       = acc.Id,
            Odoo_BAN_ID__c   = 5501,
            CurrencyIsoCode  = 'IDR'
        );

        // Products for line/Charge_Type__c coverage. RC product has Charge_Type__c set
        // explicitly; NR product leaves it blank to exercise the .RC/.NR suffix fallback.
        Product2 rc = new Product2(Name = 'IP6 Test Cross Connect', ProductCode = 'IP6TST.RC',
            IsActive = true, Charge_Type__c = 'MRC');
        Product2 nr = new Product2(Name = 'IP6 Test Cross Connect Install', ProductCode = 'IP6TST.NR',
            IsActive = true);
        insert new List<Product2>{ rc, nr };

        Id stdPbId = Test.getStandardPricebookId();
        update new Pricebook2(Id = stdPbId, IsActive = true);
        insert new List<PricebookEntry>{
            new PricebookEntry(Pricebook2Id = stdPbId, Product2Id = rc.Id,
                UnitPrice = 0, IsActive = true, CurrencyIsoCode = 'IDR'),
            new PricebookEntry(Pricebook2Id = stdPbId, Product2Id = nr.Id,
                UnitPrice = 0, IsActive = true, CurrencyIsoCode = 'IDR')
        };
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

    // ─── BAN resolves: currency + BillingAccount__c set, Order activated ────

    @IsTest
    static void testBanFound_OrderActivatedWithCurrency() {
        callEndpoint('{'
            + '"partner_id": 7777,'
            + '"ns_ban_id": 5501,'
            + '"odoo_order_id": 15900,'
            + '"site_code": "IP6TEST1",'
            + '"lines": [{"odoo_line_id": 1, "product_code": "IP6TST.RC", "quantity": 1.0, "unit_price": 100.0}]'
            + '}');

        Test.startTest();
        OdooCrossConnectHandler.handlePost();
        Test.stopTest();

        String body = RestContext.response.responseBody.toString();
        System.assertEquals(200, RestContext.response.statusCode,
            'Expected a clean 200 response, got: ' + body);
        System.assert(body.contains('"order_status":"Activated"'), 'Order should be activated when BAN resolves');
        System.assert(body.contains('"currency":"IDR"'), 'Response currency should reflect the BAN');

        Order ord = [SELECT Status, CurrencyIsoCode, BillingAccount__c FROM Order WHERE Odoo_Order_ID__c = '15900'];
        System.assertEquals('Activated', ord.Status);
        System.assertEquals('IDR', ord.CurrencyIsoCode);
        System.assertNotEquals(null, ord.BillingAccount__c);
    }

    // ─── BAN not found: Order created but stays Draft, warning logged ───────

    @IsTest
    static void testBanNotFound_OrderStaysDraft() {
        callEndpoint('{'
            + '"partner_id": 7778,'
            + '"ns_ban_id": 999999,'
            + '"odoo_order_id": 15901,'
            + '"site_code": "IP6TEST1"'
            + '}');

        Test.startTest();
        OdooCrossConnectHandler.handlePost();
        Test.stopTest();

        String body = RestContext.response.responseBody.toString();
        System.assert(body.contains('"order_status":"Draft"'), 'Order should stay Draft when BAN is unresolved');

        Order ord = [SELECT Status, BillingAccount__c FROM Order WHERE Odoo_Order_ID__c = '15901'];
        System.assertEquals('Draft', ord.Status);
        System.assertEquals(null, ord.BillingAccount__c);

        List<DE_Integration_Error__c> errors = [
            SELECT Error_Message__c FROM DE_Integration_Error__c WHERE IP_Reference__c = 'IP-6'
        ];
        Integer matching = 0;
        for (DE_Integration_Error__c e : errors) {
            if (e.Error_Message__c != null && e.Error_Message__c.contains('ns_ban_id')) matching++;
        }
        System.assertEquals(1, matching, 'BAN-not-found warning should be logged');
    }

    // ─── Opportunity created when site_code resolves to a Site__c ──────────

    @IsTest
    static void testOpportunityCreated_WhenSiteResolves() {
        callEndpoint('{'
            + '"partner_id": 7777,'
            + '"odoo_order_id": 16000,'
            + '"site_code": "IP6TEST1",'
            + '"order_number": "IP6-TEST-NUM-001"'
            + '}');

        Test.startTest();
        OdooCrossConnectHandler.handlePost();
        Test.stopTest();

        String body = RestContext.response.responseBody.toString();
        System.assert(body.contains('opportunity_id'), 'Response should include opportunity_id');

        Order ord = [SELECT OpportunityId, Order_Number__c FROM Order WHERE Odoo_Order_ID__c = '16000'];
        System.assertNotEquals(null, ord.OpportunityId, 'Order should be linked to an Opportunity');
        System.assertEquals('IP6-TEST-NUM-001', ord.Order_Number__c);

        Opportunity opp = [
            SELECT StageName, ForecastCategoryName, Target_Site__c, Operation_Country__c, Opportunity_Number__c
            FROM Opportunity WHERE Id = :ord.OpportunityId
        ];
        System.assertEquals('5-Won', opp.StageName);
        System.assertEquals('Closed', opp.ForecastCategoryName);
        System.assertNotEquals(null, opp.Target_Site__c);
        System.assertEquals('Indonesia', opp.Operation_Country__c);
        System.assertEquals('IP6-TEST-NUM-001', opp.Opportunity_Number__c);
    }

    // ─── Opportunity skipped (not an error) when site_code has no Site__c match ─

    @IsTest
    static void testOpportunitySkipped_WhenSiteNotFound() {
        callEndpoint('{'
            + '"partner_id": 7777,'
            + '"odoo_order_id": 16001,'
            + '"site_code": "NOSUCHSITE"'
            + '}');

        Test.startTest();
        OdooCrossConnectHandler.handlePost();
        Test.stopTest();

        Order ord = [SELECT OpportunityId FROM Order WHERE Odoo_Order_ID__c = '16001'];
        System.assertEquals(null, ord.OpportunityId, 'No Opportunity should be linked when site_code has no match');

        List<DE_Integration_Error__c> errors = [
            SELECT Error_Message__c FROM DE_Integration_Error__c WHERE IP_Reference__c = 'IP-6'
        ];
        Integer matching = 0;
        for (DE_Integration_Error__c e : errors) {
            if (e.Error_Message__c != null && e.Error_Message__c.contains('NOSUCHSITE')) matching++;
        }
        System.assertEquals(1, matching, 'Site-not-found warning should be logged');
    }

    // ─── Charge_Type__c derivation + MRC/NRC rollup onto the Opportunity ────

    @IsTest
    static void testChargeTypeAndMrcNrcRollup() {
        callEndpoint('{'
            + '"partner_id": 7777,'
            + '"ns_ban_id": 5501,'
            + '"odoo_order_id": 16100,'
            + '"site_code": "IP6TEST1",'
            + '"lines": ['
                + '{"odoo_line_id": 1, "product_code": "IP6TST.RC", "quantity": 2.0, "unit_price": 1000.0},'
                + '{"odoo_line_id": 2, "product_code": "IP6TST.NR", "quantity": 1.0, "unit_price": 500.0}'
            + ']'
            + '}');

        Test.startTest();
        OdooCrossConnectHandler.handlePost();
        Test.stopTest();

        Order ord = [SELECT Id, Total_MRC__c, Total_NRC__c, OpportunityId FROM Order WHERE Odoo_Order_ID__c = '16100'];

        Map<String, String> chargeTypeByCode = new Map<String, String>();
        for (OrderItem oi : [SELECT Product2.ProductCode, Charge_Type__c FROM OrderItem WHERE OrderId = :ord.Id]) {
            chargeTypeByCode.put(oi.Product2.ProductCode, oi.Charge_Type__c);
        }
        System.assertEquals('MRC', chargeTypeByCode.get('IP6TST.RC'),
            'RC line should be MRC (explicit Product2.Charge_Type__c)');
        System.assertEquals('NRC', chargeTypeByCode.get('IP6TST.NR'),
            'NR line should be NRC (suffix fallback — product has no Charge_Type__c set)');

        System.assertEquals(2000, ord.Total_MRC__c, 'Order Total_MRC__c should sum the MRC line (2 x 1000)');
        System.assertEquals(500, ord.Total_NRC__c, 'Order Total_NRC__c should sum the NRC line');

        Opportunity opp = [SELECT MRC__c, NRC__c FROM Opportunity WHERE Id = :ord.OpportunityId];
        System.assertEquals(2000, opp.MRC__c, 'Opportunity MRC__c should mirror the Order rollup');
        System.assertEquals(500, opp.NRC__c, 'Opportunity NRC__c should mirror the Order rollup');
    }

    // ─── x_studio_contract_end_date: blank string treated as absent, not invalid ─

    @IsTest
    static void testContractEndDate_BlankStringTreatedAsAbsent() {
        callEndpoint('{'
            + '"partner_id": 7777,'
            + '"odoo_order_id": 16200,'
            + '"site_code": "IP6TEST1",'
            + '"x_studio_contract_end_date": ""'
            + '}');

        Test.startTest();
        OdooCrossConnectHandler.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        Order ord = [SELECT Contract_End_Date__c FROM Order WHERE Odoo_Order_ID__c = '16200'];
        System.assertEquals(null, ord.Contract_End_Date__c,
            'Blank string should be treated as absent, not passed to Date.valueOf');
    }

    // ─── x_studio_contract_end_date real value flows to Order + Opportunity ─

    @IsTest
    static void testContractEndDate_RealValue() {
        callEndpoint('{'
            + '"partner_id": 7777,'
            + '"odoo_order_id": 16201,'
            + '"site_code": "IP6TEST1",'
            + '"x_studio_contract_end_date": "2030-01-15"'
            + '}');

        Test.startTest();
        OdooCrossConnectHandler.handlePost();
        Test.stopTest();

        Order ord = [SELECT Contract_End_Date__c, OpportunityId FROM Order WHERE Odoo_Order_ID__c = '16201'];
        System.assertEquals(Date.valueOf('2030-01-15'), ord.Contract_End_Date__c);

        Opportunity opp = [SELECT Contract_End_Date__c FROM Opportunity WHERE Id = :ord.OpportunityId];
        System.assertEquals(Date.valueOf('2030-01-15'), opp.Contract_End_Date__c);
    }

    // ─── x_studio_service_request_date takes precedence over the legacy rdd key ─

    @IsTest
    static void testServiceRequestDatePreferredOverRdd() {
        callEndpoint('{'
            + '"partner_id": 7777,'
            + '"odoo_order_id": 16300,'
            + '"site_code": "IP6TEST1",'
            + '"rdd": "2026-01-01",'
            + '"x_studio_service_request_date": "2026-06-15"'
            + '}');

        Test.startTest();
        OdooCrossConnectHandler.handlePost();
        Test.stopTest();

        Order ord = [SELECT EffectiveDate, RDD__c FROM Order WHERE Odoo_Order_ID__c = '16300'];
        System.assertEquals(Date.valueOf('2026-06-15'), ord.EffectiveDate,
            'x_studio_service_request_date should win over the legacy rdd key');
        System.assertEquals(Date.valueOf('2026-06-15'), ord.RDD__c);
    }
}