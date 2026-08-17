/**
 * OdooAssetStatusHandlerTest
 * Tests for IP-2 inbound endpoint — subscription + lines array structure.
 * Event types: new_service, amendment, churn, renewal, suspension, resumption.
 */
@IsTest
private class OdooAssetStatusHandlerTest {

    // ─── Test data setup ──────────────────────────────────────────────────────────

    @TestSetup
    static void setup() {
        Account acc = new Account(
            Name                 = 'IP2 Test Account',
            BillingCountry       = 'Singapore',
            Operation_Country__c = 'Singapore',
            RecordTypeId         = [
                SELECT Id FROM RecordType
                WHERE SObjectType = 'Account' AND DeveloperName = 'Customer' LIMIT 1
            ].Id
        );
        insert acc;

        Id deEntityRtId = Schema.SObjectType.Account
            .getRecordTypeInfosByDeveloperName().get('DE_Entity').getRecordTypeId();
        Account sgEntity = new Account(
            Name = 'DE SG Pte Ltd',
            RecordTypeId = deEntityRtId
        );
        insert sgEntity;

        Product2 mrcProd = new Product2(
            Name        = 'Test Cabinet MRC',
            ProductCode = 'TESTIP2.RC',
            IsActive    = true
        );
        insert mrcProd;

        Product2 nrcProd = new Product2(
            Name        = 'Test Cabinet NRC',
            ProductCode = 'TESTIP2.NR',
            IsActive    = true
        );
        insert nrcProd;

        Id stdPbId = Test.getStandardPricebookId();
        insert new List<PricebookEntry>{
            new PricebookEntry(Pricebook2Id = stdPbId, Product2Id = mrcProd.Id,
                               UnitPrice = 1000.00, IsActive = true),
            new PricebookEntry(Pricebook2Id = stdPbId, Product2Id = nrcProd.Id,
                               UnitPrice = 1650.00, IsActive = true)
        };

        Order ord = new Order(
            AccountId         = acc.Id,
            Status            = 'Draft',
            EffectiveDate     = Date.today(),
            Operation_Site__c = 'JKT1',
            Pricebook2Id      = stdPbId,
            Order_Type__c     = 'New Service'
        );
        insert ord;

        PricebookEntry mrcPbe = [
            SELECT Id FROM PricebookEntry
            WHERE Pricebook2Id = :stdPbId AND Product2Id = :mrcProd.Id LIMIT 1
        ];
        OrderItem mrcItem = new OrderItem(
            OrderId          = ord.Id,
            PricebookEntryId = mrcPbe.Id,
            Quantity         = 2,
            UnitPrice        = 1000.00,
            Charge_Type__c   = 'MRC',
            Description      = 'Test Cabinet'
        );
        insert mrcItem;

        PricebookEntry nrcPbe = [
            SELECT Id FROM PricebookEntry
            WHERE Pricebook2Id = :stdPbId AND Product2Id = :nrcProd.Id LIMIT 1
        ];
        insert new OrderItem(
            OrderId                 = ord.Id,
            PricebookEntryId        = nrcPbe.Id,
            Quantity                = 2,
            UnitPrice               = 1650.00,
            Charge_Type__c          = 'NRC',
            Paired_MRC_OrderItem__c = mrcItem.Id,
            Description             = 'Test Cabinet NRC'
        );
    }

    // ─── HTTP routing ─────────────────────────────────────────────────────────────

    @IsTest
    static void testUnknownEventType_Returns400() {
        Map<String, Object> payload = new Map<String, Object>{
            'event_type'  => 'unknown_type',
            'odoo_sub_id' => 999,
            'lines'       => new List<Object>{
                new Map<String, Object>{ 'odoo_ib_id' => 999 }
            }
        };
        RestContext.request  = buildRequest(payload);
        RestContext.response = new RestResponse();

        Test.startTest();
        OdooAssetStatusHandler.handlePost();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode,
            'Unknown event_type should return 400');
    }

    @IsTest
    static void testMissingLines_Returns400() {
        Map<String, Object> payload = new Map<String, Object>{
            'event_type'  => 'amendment',
            'odoo_sub_id' => 2001
            // lines omitted
        };
        RestContext.request  = buildRequest(payload);
        RestContext.response = new RestResponse();

        Test.startTest();
        OdooAssetStatusHandler.handlePost();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode,
            'Missing lines array should return 400');
    }

    @IsTest
    static void testNewService_MissingSfOrderId_Returns422() {
        OrderItem mrcItem = [SELECT Id FROM OrderItem WHERE Charge_Type__c = 'MRC' LIMIT 1];

        Map<String, Object> payload = new Map<String, Object>{
            'event_type'  => 'new_service',
            'odoo_sub_id' => 2001,
            // sf_order_id omitted
            'lines'       => new List<Object>{
                new Map<String, Object>{
                    'odoo_ib_id'      => 1001,
                    'sf_orderitem_id' => String.valueOf(mrcItem.Id),
                    'mrr'             => 2000.00,
                    'quantity'        => 1
                }
            }
        };
        RestContext.request  = buildRequest(payload);
        RestContext.response = new RestResponse();

        Test.startTest();
        OdooAssetStatusHandler.handlePost();
        Test.stopTest();

        System.assertEquals(422, RestContext.response.statusCode,
            'new_service without sf_order_id should return 422');
    }

    // ─── new_service ──────────────────────────────────────────────────────────────

    @IsTest
    static void testNewService_CreatesAssetAndWritesSubLineId() {
        Order ord         = [SELECT Id FROM Order LIMIT 1];
        OrderItem mrcItem = [SELECT Id FROM OrderItem WHERE Charge_Type__c = 'MRC' LIMIT 1];

        OdooAssetStatusHandler.LineItem line = new OdooAssetStatusHandler.LineItem();
        line.odoo_ib_id      = 1001L;
        line.id              = 3001L;
        line.sf_orderitem_id = mrcItem.Id;
        line.mrr             = 2000.00;
        line.quantity        = 2;
        line.start_date      = String.valueOf(Date.today());
        line.ns_product_attribute_value = 'false'; // handler dereferences this field unconditionally

        OdooAssetStatusHandler.AssetEventPayload p = new OdooAssetStatusHandler.AssetEventPayload();
        p.event_type  = 'new_service';
        p.odoo_sub_id = 2001L;
        p.sf_order_id = ord.Id;
        p.lines       = new List<OdooAssetStatusHandler.LineItem>{ line };

        Test.startTest();
        List<Id> result = OdooAssetStatusHandler.handleNewService(p);
        Test.stopTest();

        System.assertEquals(1, result.size(), 'One Asset should be created');

        List<Asset> assets = [
            SELECT Id, MRC__c, NRC__c, Odoo_IB_ID__c, Odoo_Subscription_ID__c,
                   Asset_Lifecycle_Status__c, Source_OrderItem__c
            FROM Asset
            WHERE Source_OrderItem__c = :mrcItem.Id
        ];
        System.assertEquals(1,            assets.size(),                          'One Asset record expected');
        System.assertEquals(2000.00,      assets[0].MRC__c,                       'MRC should match mrr payload');
        System.assertEquals(3300.00,      assets[0].NRC__c,                       'NRC = 2 qty × 1650 unit price');
        System.assertEquals('1001',       assets[0].Odoo_IB_ID__c,                'Odoo IB ID should be stored');
        System.assertEquals('2001',       assets[0].Odoo_Subscription_ID__c,      'Odoo Sub ID should be stored');
        System.assertEquals('In Service', assets[0].Asset_Lifecycle_Status__c,    'Lifecycle status should be In Service');

        OrderItem updatedOi = [SELECT Odoo_Sub_Line_ID__c FROM OrderItem WHERE Id = :mrcItem.Id];
        System.assertEquals('3001', updatedOi.Odoo_Sub_Line_ID__c,
            'Sub line ID should be written back to OrderItem for IP-4 change orders');
    }

    @IsTest
    static void testNewService_MultiLine_CreatesTwoAssets() {
        Order ord         = [SELECT Id FROM Order LIMIT 1];
        OrderItem mrcItem = [SELECT Id FROM OrderItem WHERE Charge_Type__c = 'MRC' LIMIT 1];

        // Second product + OrderItem (no paired NRC — NRC will default to 0)
        Id stdPbId = Test.getStandardPricebookId();
        Product2 prod2 = new Product2(Name = 'Test Cabinet 2', IsActive = true);
        insert prod2;
        PricebookEntry pbe2 = new PricebookEntry(
            Pricebook2Id = stdPbId, Product2Id = prod2.Id,
            UnitPrice = 500.00, IsActive = true);
        insert pbe2;
        OrderItem mrcItem2 = new OrderItem(
            OrderId          = ord.Id,
            PricebookEntryId = pbe2.Id,
            Quantity         = 1,
            UnitPrice        = 500.00,
            Charge_Type__c   = 'MRC',
            Description      = 'Test Cabinet 2'
        );
        insert mrcItem2;

        OdooAssetStatusHandler.LineItem line1 = new OdooAssetStatusHandler.LineItem();
        line1.odoo_ib_id     = 1101L;
        line1.id             = 3101L;
        line1.sf_orderitem_id = mrcItem.Id;
        line1.mrr            = 2000.00;
        line1.quantity       = 2;
        line1.start_date     = String.valueOf(Date.today());
        line1.ns_product_attribute_value = 'false';

        OdooAssetStatusHandler.LineItem line2 = new OdooAssetStatusHandler.LineItem();
        line2.odoo_ib_id     = 1102L;
        line2.id             = 3102L;
        line2.sf_orderitem_id = mrcItem2.Id;
        line2.mrr            = 500.00;
        line2.quantity       = 1;
        line2.start_date     = String.valueOf(Date.today());
        line2.ns_product_attribute_value = 'false';

        OdooAssetStatusHandler.AssetEventPayload p = new OdooAssetStatusHandler.AssetEventPayload();
        p.event_type  = 'new_service';
        p.odoo_sub_id = 2101L;
        p.sf_order_id = ord.Id;
        p.lines       = new List<OdooAssetStatusHandler.LineItem>{ line1, line2 };

        Test.startTest();
        List<Id> result = OdooAssetStatusHandler.handleNewService(p);
        Test.stopTest();

        System.assertEquals(2, result.size(), 'Two Assets should be created for two lines');
        System.assertEquals(2,
            [SELECT COUNT() FROM Asset WHERE Odoo_Subscription_ID__c = '2101'],
            'Both Assets should carry the correct subscription ID');
    }

    @IsTest
    static void testNewService_ViaRestEndpoint_Returns200() {
        Order ord         = [SELECT Id FROM Order LIMIT 1];
        OrderItem mrcItem = [SELECT Id FROM OrderItem WHERE Charge_Type__c = 'MRC' LIMIT 1];

        Map<String, Object> payload = new Map<String, Object>{
            'event_type'  => 'new_service',
            'odoo_sub_id' => 2002,
            'sf_order_id' => String.valueOf(ord.Id),
            'lines'       => new List<Object>{
                new Map<String, Object>{
                    'odoo_ib_id'      => 1002,
                    'id'              => 3002,
                    'sf_orderitem_id' => String.valueOf(mrcItem.Id),
                    'mrr'             => 2000.00,
                    'quantity'         => 2,
                    'start_date'       => String.valueOf(Date.today()),
                    'ns_product_attribute_value' => 'false'
                }
            }
        };
        RestContext.request  = buildRequest(payload);
        RestContext.response = new RestResponse();

        Test.startTest();
        OdooAssetStatusHandler.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode,
            'Valid new_service payload should return 200');
        String body = RestContext.response.responseBody.toString();
        System.assert(body.contains('"processed":1'),    'Response body should report processed=1');
        System.assert(body.contains('"asset_ids"'),      'Response body should include asset_ids array');
    }

    @IsTest
    static void testNewService_MergeIbTask_SingleAssetWithQuantity() {
        Order ord = [SELECT Id FROM Order LIMIT 1];

        // Product with Merge_IB_Task__c = TRUE → one Asset carrying the full quantity
        Product2 mergeProd = new Product2(Name = 'Merge Cabinet', IsActive = true, Merge_IB_Task__c = true);
        insert mergeProd;
        PricebookEntry pbe = new PricebookEntry(Pricebook2Id = Test.getStandardPricebookId(),
            Product2Id = mergeProd.Id, UnitPrice = 900.00, IsActive = true);
        insert pbe;
        OrderItem mergeItem = new OrderItem(OrderId = ord.Id, PricebookEntryId = pbe.Id,
            Quantity = 5, UnitPrice = 900.00, Charge_Type__c = 'MRC', Description = 'Merge Cabinet');
        insert mergeItem;

        OdooAssetStatusHandler.LineItem line = new OdooAssetStatusHandler.LineItem();
        line.id                = 4001L;
        line.sf_orderitem_id   = mergeItem.Id;
        line.subscription_id   = 4100L;
        line.project_task_ids  = new List<Long>{ 8001L, 8002L, 8003L };
        line.mrr               = 900.00;
        line.quantity          = 5;
        line.start_date        = String.valueOf(Date.today());
        line.ns_product_attribute_value = 'false';

        OdooAssetStatusHandler.AssetEventPayload p = new OdooAssetStatusHandler.AssetEventPayload();
        p.event_type  = 'new_service';
        p.sf_order_id = ord.Id;
        p.lines       = new List<OdooAssetStatusHandler.LineItem>{ line };

        Test.startTest();
        List<Id> result = OdooAssetStatusHandler.handleNewService(p);
        Test.stopTest();

        System.assertEquals(1, result.size(), 'Merge mode should create exactly ONE Asset');
        Asset a = [SELECT Quantity, Odoo_IB_ID__c FROM Asset WHERE Source_OrderItem__c = :mergeItem.Id LIMIT 1];
        System.assertEquals(5, a.Quantity, 'Merged Asset should carry the full Odoo quantity');
        System.assertEquals('8001,8002,8003', a.Odoo_IB_ID__c, 'All task IDs should be combined on the single Asset');
    }

    // ─── amendment ───────────────────────────────────────────────────────────────

    @IsTest
    static void testAmendment_UpdatesAssetMrc() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Asset a = new Asset(
            Name                      = 'Amendment Test Asset',
            AccountId                 = acc.Id,
            Status                    = 'Installed',
            Asset_Lifecycle_Status__c = 'In Service',
            MRC__c                    = 1000.00,
            Quantity                  = 1,
            Odoo_IB_ID__c             = '5001',
            InstallDate               = Date.today()
        );
        insert a;

        OdooAssetStatusHandler.LineItem line = new OdooAssetStatusHandler.LineItem();
        line.odoo_ib_id  = 5001L;
        line.mrr         = 1500.00;
        line.quantity    = 2;
        line.ns_product_attribute_value = 'false';

        OdooAssetStatusHandler.AssetEventPayload p = new OdooAssetStatusHandler.AssetEventPayload();
        p.event_type  = 'amendment';
        p.odoo_sub_id = 2003L;
        p.lines       = new List<OdooAssetStatusHandler.LineItem>{ line };

        Test.startTest();
        List<Id> result = OdooAssetStatusHandler.handleAmendment(p);
        Test.stopTest();

        System.assertEquals(1, result.size(), 'One Asset should be updated');
        Asset updated = [SELECT MRC__c, Quantity FROM Asset WHERE Id = :a.Id];
        System.assertEquals(1500.00, updated.MRC__c,   'MRC should be updated to 1500');
        System.assertEquals(2,       updated.Quantity,  'Quantity should be updated to 2');
    }

    @IsTest
    static void testAmendment_AssetNotFound_Returns200WithZeroProcessed() {
        // Unmatched lines are logged to DE_Integration_Error__c — endpoint does not reject
        Map<String, Object> payload = new Map<String, Object>{
            'event_type'  => 'amendment',
            'odoo_sub_id' => 2004,
            'lines'       => new List<Object>{
                new Map<String, Object>{
                    'odoo_ib_id'  => 99999,
                    'mrr'         => 999.00
                }
            }
        };
        RestContext.request  = buildRequest(payload);
        RestContext.response = new RestResponse();

        Test.startTest();
        OdooAssetStatusHandler.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode,
            'Unmatched lines are logged, not rejected — endpoint returns 200');
        System.assert(
            RestContext.response.responseBody.toString().contains('"processed":0'),
            'Processed count should be 0 when no matching Assets exist');
    }

    // ─── churn ────────────────────────────────────────────────────────────────────

    @IsTest
    static void testChurn_TerminatesAsset() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Asset a = new Asset(
            Name                      = 'Churn Test Asset',
            AccountId                 = acc.Id,
            Status                    = 'Installed',
            Asset_Lifecycle_Status__c = 'In Service',
            MRC__c                    = 800.00,
            Quantity                  = 1,
            Odoo_IB_ID__c             = '6001',
            InstallDate               = Date.today()
        );
        insert a;

        OdooAssetStatusHandler.LineItem line = new OdooAssetStatusHandler.LineItem();
        line.odoo_ib_id = 6001L;
        line.termination_date = String.valueOf(Date.today());

        OdooAssetStatusHandler.AssetEventPayload p = new OdooAssetStatusHandler.AssetEventPayload();
        p.event_type = 'churn';
        p.lines      = new List<OdooAssetStatusHandler.LineItem>{ line };

        Test.startTest();
        List<Id> result = OdooAssetStatusHandler.handleChurn(p);
        Test.stopTest();

        System.assertEquals(1, result.size(), 'One Asset should be churned');
        Asset churned = [
            SELECT Asset_Lifecycle_Status__c, Status, Termination_Date__c
            FROM Asset WHERE Id = :a.Id
        ];
        System.assertEquals('Terminated', churned.Asset_Lifecycle_Status__c,
            'Asset lifecycle status should be Terminated');
        System.assertEquals('Closed',     churned.Status,
            'churn sets Asset Status to Closed');
        System.assertEquals(Date.today(), churned.Termination_Date__c,
            'Termination date should match payload');
    }

    // ─── renewal ─────────────────────────────────────────────────────────────────

    @IsTest
    static void testRenewal_UpdatesAsset() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Asset a = new Asset(
            Name                      = 'Renewal Test Asset',
            AccountId                 = acc.Id,
            Status                    = 'Installed',
            Asset_Lifecycle_Status__c = 'In Service',
            MRC__c                    = 700.00,
            Quantity                  = 1,
            Odoo_IB_ID__c             = '7001',
            InstallDate               = Date.today()
        );
        insert a;

        OdooAssetStatusHandler.LineItem line = new OdooAssetStatusHandler.LineItem();
        line.odoo_ib_id  = 7001L;
        line.mrr         = 750.00;
        line.start_date  = String.valueOf(Date.today().addYears(1));

        OdooAssetStatusHandler.AssetEventPayload p = new OdooAssetStatusHandler.AssetEventPayload();
        p.event_type  = 'renewal';
        p.odoo_sub_id = 9001L;
        p.lines       = new List<OdooAssetStatusHandler.LineItem>{ line };

        Test.startTest();
        List<Id> result = OdooAssetStatusHandler.handleRenewal(p);
        Test.stopTest();

        System.assertEquals(1, result.size(), 'One Asset should be renewed');
        Asset renewed = [
            SELECT MRC__c, Asset_Lifecycle_Status__c, Odoo_Subscription_ID__c
            FROM Asset WHERE Id = :a.Id
        ];
        System.assertEquals(750.00,       renewed.MRC__c,                   'MRC should be updated on renewal');
        System.assertEquals('In Service', renewed.Asset_Lifecycle_Status__c, 'Lifecycle should remain In Service');
        System.assertEquals('9001',       renewed.Odoo_Subscription_ID__c,  'Sub ID should be updated');
    }

    // ─── suspension ──────────────────────────────────────────────────────────────

    @IsTest
    static void testSuspension_SuspendsAsset() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Asset a = new Asset(
            Name                      = 'Suspension Test Asset',
            AccountId                 = acc.Id,
            Status                    = 'Installed',
            Asset_Lifecycle_Status__c = 'In Service',
            MRC__c                    = 900.00,
            Quantity                  = 1,
            Odoo_IB_ID__c             = '8001',
            InstallDate               = Date.today()
        );
        insert a;

        OdooAssetStatusHandler.LineItem line = new OdooAssetStatusHandler.LineItem();
        line.odoo_ib_id = 8001L;

        OdooAssetStatusHandler.AssetEventPayload p = new OdooAssetStatusHandler.AssetEventPayload();
        p.event_type = 'suspension';
        p.lines      = new List<OdooAssetStatusHandler.LineItem>{ line };

        Test.startTest();
        List<Id> result = OdooAssetStatusHandler.handleSuspension(p);
        Test.stopTest();

        System.assertEquals(1, result.size(), 'One Asset should be suspended');
        Asset suspended = [SELECT Asset_Lifecycle_Status__c, Status FROM Asset WHERE Id = :a.Id];
        System.assertEquals('Suspended', suspended.Asset_Lifecycle_Status__c,
            'Asset lifecycle status should be Suspended');
        System.assertEquals('Installed', suspended.Status,
            'Asset status should remain Installed — physically still present');
    }

    @IsTest
    static void testSuspension_ViaRestEndpoint_Returns200() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        insert new Asset(
            Name                      = 'Suspension REST Asset',
            AccountId                 = acc.Id,
            Status                    = 'Installed',
            Asset_Lifecycle_Status__c = 'In Service',
            MRC__c                    = 100.00,
            Quantity                  = 1,
            Odoo_IB_ID__c             = '8002',
            InstallDate               = Date.today()
        );

        Map<String, Object> payload = new Map<String, Object>{
            'event_type'  => 'suspension',
            'odoo_sub_id' => 2005,
            'lines'       => new List<Object>{
                new Map<String, Object>{ 'odoo_ib_id' => 8002 }
            }
        };
        RestContext.request  = buildRequest(payload);
        RestContext.response = new RestResponse();

        Test.startTest();
        OdooAssetStatusHandler.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode,
            'Valid suspension payload should return 200');
    }

    // ─── resumption ──────────────────────────────────────────────────────────────

    @IsTest
    static void testResumption_RestoresAsset() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Asset a = new Asset(
            Name                      = 'Resumption Test Asset',
            AccountId                 = acc.Id,
            Status                    = 'Installed',
            Asset_Lifecycle_Status__c = 'Suspended',
            MRC__c                    = 900.00,
            Quantity                  = 1,
            Odoo_IB_ID__c             = '9001',
            InstallDate               = Date.today()
        );
        insert a;

        OdooAssetStatusHandler.LineItem line = new OdooAssetStatusHandler.LineItem();
        line.odoo_ib_id = 9001L;

        OdooAssetStatusHandler.AssetEventPayload p = new OdooAssetStatusHandler.AssetEventPayload();
        p.event_type = 'resumption';
        p.lines      = new List<OdooAssetStatusHandler.LineItem>{ line };

        Test.startTest();
        List<Id> result = OdooAssetStatusHandler.handleResumption(p);
        Test.stopTest();

        System.assertEquals(1, result.size(), 'One Asset should be resumed');
        Asset resumed = [SELECT Asset_Lifecycle_Status__c FROM Asset WHERE Id = :a.Id];
        System.assertEquals('In Service', resumed.Asset_Lifecycle_Status__c,
            'Asset lifecycle status should be restored to In Service');
    }

    @IsTest
    static void testResumption_AssetNotFound_Returns200WithZeroProcessed() {
        Map<String, Object> payload = new Map<String, Object>{
            'event_type'  => 'resumption',
            'odoo_sub_id' => 2006,
            'lines'       => new List<Object>{
                new Map<String, Object>{ 'odoo_ib_id' => 99998 }
            }
        };
        RestContext.request  = buildRequest(payload);
        RestContext.response = new RestResponse();

        Test.startTest();
        OdooAssetStatusHandler.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode,
            'Unmatched lines are logged, not rejected — endpoint returns 200');
        System.assert(
            RestContext.response.responseBody.toString().contains('"processed":0'),
            'Processed count should be 0 when no matching Assets exist');
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────────

    private static RestRequest buildRequest(Map<String, Object> payload) {
        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf(JSON.serialize(payload));
        req.httpMethod  = 'POST';
        return req;
    }
}