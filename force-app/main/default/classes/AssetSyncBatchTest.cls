/**
 * AssetSyncBatchTest
 * Coverage for AssetSyncBatch (IP-2 daily Odoo Install Base → SF Asset sync).
 * Uses a URL-aware HttpCalloutMock to serve the asset-list and subscription-list
 * endpoints separately, plus direct unit tests of the JSON parse helpers.
 */
@IsTest
private class AssetSyncBatchTest {

    // Serves different bodies for the account.asset vs sale.subscription endpoints.
    private class OdooListMock implements HttpCalloutMock {
        private Integer statusCode;
        private String assetBody;
        private String subBody;
        OdooListMock(Integer statusCode, String assetBody, String subBody) {
            this.statusCode = statusCode;
            this.assetBody  = assetBody;
            this.subBody    = subBody;
        }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(statusCode);
            res.setBody(req.getEndpoint().contains('sale.subscription') ? subBody : assetBody);
            return res;
        }
    }

    @TestSetup
    static void setup() {
        OdooIntegrationSettings__c s = OdooIntegrationSettings__c.getOrgDefaults();
        s.IP2_Enabled__c = true;
        s.Environment__c = 'Sandbox';
        s.Base_URL__c    = 'https://test.odoo.example.com';
        s.Username__c    = 'u';
        s.Password__c    = 'p';
        upsert s;

        Account acc = new Account(Name = 'IB Sync Acct', Operation_Country__c = 'Singapore');
        insert acc;
        insert new BillingAccount__c(Account__c = acc.Id, Odoo_Partner_ID__c = '500',
            Invoice_Frequency__c = 'Monthly');

        insert new Product2(Name = 'IB Product', IsActive = true, Odoo_Product_ID__c = 100);

        Order ord = new Order(AccountId = acc.Id, Status = 'Draft', EffectiveDate = Date.today(),
            Pricebook2Id = Test.getStandardPricebookId(), Order_Type__c = 'New Service',
            Odoo_Order_ID__c = '9000', Order_Number__c = 'IBSYNC-1');
        insert ord;

        Site__c site = new Site__c(Name = 'IBS1', Site_Code__c = 'IBS1', Country__c = 'SG');
        insert site;
        Id spaceRt = Schema.SObjectType.Inventory__c.getRecordTypeInfosByDeveloperName().get('Inventory_Space').getRecordTypeId();
        Id brkRt   = Schema.SObjectType.Inventory__c.getRecordTypeInfosByDeveloperName().get('Inventory_Breaker').getRecordTypeId();
        insert new List<Inventory__c>{
            new Inventory__c(Name = 'IB Space', RecordTypeId = spaceRt, Odoo_Space_ID__c = 'S1', Status__c = 'Available', Site_Id__c = site.Id),
            new Inventory__c(Name = 'IB Breaker', RecordTypeId = brkRt, Odoo_Inventory_Id__c = 'B1', Status__c = 'Available', Site_Id__c = site.Id)
        };

        // A/Z-side asset referenced by the incoming IB record
        insert new Asset(Name = 'Side Asset', AccountId = acc.Id, Status = 'Installed',
            Quantity = 1, Odoo_IB_ID__c = 'SIDE1', InstallDate = Date.today());
    }

    private static String assetJson() {
        return JSON.serialize(new List<Object>{
            new Map<String, Object>{
                'id' => 7777, 'name' => 'Synced IB Asset', 'partner_id' => '500',
                'product_id' => 100, 'sale_order_id' => '9000', 'state' => 'in_service',
                'mrr' => 1234.50, 'start_date' => '2026-01-15',
                'x_studio_space_id' => 'S1', 'x_studio_breaker_id' => 'B1',
                'ns_a_side_service_id' => 'SIDE1', 'ns_z_side_service_id' => 'SIDE1',
                'x_studio_service_id' => 'SVC1', 'ns_customer_service_reference' => 'CSR1'
            }
        });
    }

    private static String subJson() {
        return JSON.serialize(new Map<String, Object>{
            'result' => new List<Object>{
                new Map<String, Object>{ 'id' => 8888, 'account_asset_id' => 7777 }
            }
        });
    }

    @IsTest
    static void batch_syncsAssetWithAllLookups() {
        Test.setMock(HttpCalloutMock.class, new OdooListMock(200, assetJson(), subJson()));
        Test.startTest();
        Database.executeBatch(new AssetSyncBatch());
        Test.stopTest();

        Asset a = [SELECT Name, AccountId, Product2Id, Source_Order__c, Asset_Lifecycle_Status__c,
                          Status, MRC__c, Odoo_Subscription_ID__c, Space__c, Inventory__c,
                          A_Side_Asset__c, Z_Side_Asset__c, Service_ID__c, Customer_Service_Reference__c
                   FROM Asset WHERE Odoo_IB_ID__c = '7777' LIMIT 1];
        System.assertEquals('Synced IB Asset', a.Name, 'Asset name should come from Odoo payload');
        System.assertNotEquals(null, a.AccountId, 'Account resolved via BillingAccount partner id');
        System.assertNotEquals(null, a.Product2Id, 'Product resolved via Odoo product id');
        System.assertNotEquals(null, a.Source_Order__c, 'Order resolved via Odoo order id');
        System.assertEquals('In Service', a.Asset_Lifecycle_Status__c, 'state in_service → In Service');
        System.assertEquals(1234.50, a.MRC__c, 'MRC mapped from mrr');
        System.assertEquals('8888', a.Odoo_Subscription_ID__c, 'Subscription id linked via account_asset_id');
        System.assertNotEquals(null, a.Space__c, 'Space resolved via Odoo_Space_ID__c');
        System.assertNotEquals(null, a.Inventory__c, 'Breaker resolved via Odoo_Inventory_Id__c');
        System.assertNotEquals(null, a.A_Side_Asset__c, 'A-side asset resolved');
    }

    @IsTest
    static void batch_disabled_noSync() {
        OdooIntegrationSettings__c s = OdooIntegrationSettings__c.getOrgDefaults();
        s.IP2_Enabled__c = false;
        upsert s;
        Test.setMock(HttpCalloutMock.class, new OdooListMock(200, assetJson(), subJson()));
        Test.startTest();
        Database.executeBatch(new AssetSyncBatch());
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM Asset WHERE Odoo_IB_ID__c = '7777'],
            'Disabled IP-2 should not sync any asset');
    }

    @IsTest
    static void batch_assetApiFailure_logsError() {
        Test.setMock(HttpCalloutMock.class, new OdooListMock(500, '', ''));
        Test.startTest();
        Database.executeBatch(new AssetSyncBatch());
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM Asset WHERE Odoo_IB_ID__c = '7777'],
            'A failed asset API call should sync nothing');
    }

    // ─── Parse-helper unit tests ─────────────────────────────────────────────────
    @IsTest
    static void parseResultList_handlesBothFormats() {
        System.assertEquals(1, AssetSyncBatch.parseResultList('[{"id":1}]').size(), 'Plain REST array');
        System.assertEquals(1, AssetSyncBatch.parseResultList('{"result":[{"id":2}]}').size(), 'JSON-RPC result wrapper');
        System.assertEquals(0, AssetSyncBatch.parseResultList('').size(), 'Empty string → empty list');
        System.assertEquals(0, AssetSyncBatch.parseResultList(null).size(), 'Null → empty list');
        System.assertEquals(0, AssetSyncBatch.parseResultList('not json').size(), 'Invalid JSON → empty list');
        System.assertEquals(0, AssetSyncBatch.parseResultList('{"foo":"bar"}').size(), 'No result key → empty list');
    }

    @IsTest
    static void parseSubscriptionMap_linksIbToSub() {
        Map<String, String> m = AssetSyncBatch.parseSubscriptionMap(
            '[{"id":8888,"account_asset_id":7777},{"id":9999,"ib_id":5555}]');
        System.assertEquals('8888', m.get('7777'), 'account_asset_id → sub id');
        System.assertEquals('9999', m.get('5555'), 'ib_id fallback → sub id');
        System.assertEquals(0, AssetSyncBatch.parseSubscriptionMap(null).size(), 'Null → empty');
    }
}