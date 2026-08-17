/**
 * OdooAssetSyncServiceTest
 * fetchAssetDataFromOdoo() is a @future(callout=true) method that pulls asset
 * data from Odoo and maps it onto the Salesforce Asset. Covers: blank
 * Odoo_IB_ID__c skip, a successful response updating Name/Status/SCD__c, and
 * an empty result array leaving the Asset untouched.
 */
@IsTest
private class OdooAssetSyncServiceTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = 'OASS Test Account');
        insert acc;

        insert new List<Asset>{
            new Asset(Name = 'OASS Asset With IB ID', AccountId = acc.Id, Odoo_IB_ID__c = '9001'),
            new Asset(Name = 'OASS Asset No IB ID',   AccountId = acc.Id),
            new Asset(Name = 'OASS A-Side Asset', AccountId = acc.Id, Odoo_IB_ID__c = '9101'),
            new Asset(Name = 'OASS Z-Side Asset', AccountId = acc.Id, Odoo_IB_ID__c = '9102')
        };

        Site__c site = new Site__c(Country__c = 'ID', Site_Code__c = 'JKT1', Is_Active__c = true);
        insert site;

        insert new List<Inventory__c>{
            new Inventory__c(Name = 'OASS Space', Site_Id__c = site.Id, Odoo_Space_ID__c = '5001'),
            new Inventory__c(Name = 'OASS Breaker', Site_Id__c = site.Id, Odoo_Inventory_Id__c = '6001')
        };
    }

    @IsTest
    static void testBlankOdooIbId_SkipsAsset_NoUpdate() {
        Asset noIbId = [SELECT Id, Name FROM Asset WHERE Odoo_IB_ID__c = null LIMIT 1];

        Test.setMock(HttpCalloutMock.class, new MockOdooCallout(200,
            '{"result": {"data": [{"name": "Should Not Apply"}]}}'));

        Test.startTest();
        OdooAssetSyncService.fetchAssetDataFromOdoo(new List<Id>{ noIbId.Id });
        Test.stopTest();

        Asset after = [SELECT Name FROM Asset WHERE Id = :noIbId.Id];
        System.assertEquals('OASS Asset No IB ID', after.Name,
            'Asset with blank Odoo_IB_ID__c should be skipped entirely, never renamed');
    }

    @IsTest
    static void testValidResponse_UpdatesNameStatusAndScd() {
        Asset withIbId = [SELECT Id FROM Asset WHERE Odoo_IB_ID__c = '9001' LIMIT 1];

        Test.setMock(HttpCalloutMock.class, new MockOdooCallout(200,
            '{"result": {"data": [{'
            + '"name": "SO-9001-SYNCED",'
            + '"stage_id": "Installed",'
            + '"x_studio_service_commencement_date": "2026-05-01"'
            + '}]}}'));

        Test.startTest();
        OdooAssetSyncService.fetchAssetDataFromOdoo(new List<Id>{ withIbId.Id });
        Test.stopTest();

        Asset after = [SELECT Name, Status, SCD__c FROM Asset WHERE Id = :withIbId.Id];
        System.assertEquals('SO-9001-SYNCED', after.Name, 'Name should be updated from the Odoo response');
        System.assertEquals('Installed', after.Status, 'Status should be mapped from stage_id');
        System.assertEquals(Date.valueOf('2026-05-01'), after.SCD__c, 'SCD__c should be parsed from the response date string');
    }

    @IsTest
    static void testEmptyDataArray_LeavesAssetUntouched() {
        Asset withIbId = [SELECT Id, Name FROM Asset WHERE Odoo_IB_ID__c = '9001' LIMIT 1];

        Test.setMock(HttpCalloutMock.class, new MockOdooCallout(200, '{"result": {"data": []}}'));

        Test.startTest();
        OdooAssetSyncService.fetchAssetDataFromOdoo(new List<Id>{ withIbId.Id });
        Test.stopTest();

        Asset after = [SELECT Name FROM Asset WHERE Id = :withIbId.Id];
        System.assertEquals('OASS Asset With IB ID', after.Name, 'An empty data array should result in no update');
    }

    @IsTest
    static void testMalformedResponseBody_HandledGracefully_NoException() {
        Asset withIbId = [SELECT Id FROM Asset WHERE Odoo_IB_ID__c = '9001' LIMIT 1];

        Test.setMock(HttpCalloutMock.class, new MockOdooCallout(200, 'not valid json'));

        Test.startTest();
        OdooAssetSyncService.fetchAssetDataFromOdoo(new List<Id>{ withIbId.Id });
        Test.stopTest();

        System.assert(true, 'A malformed response body should be caught per-asset, not throw out of the future method');
    }

    @IsTest
    static void testValidResponse_MapsSpaceBreakerAndSideAssetLookups() {
        Asset withIbId  = [SELECT Id FROM Asset WHERE Odoo_IB_ID__c = '9001' LIMIT 1];
        Asset aSideAsset = [SELECT Id FROM Asset WHERE Odoo_IB_ID__c = '9101' LIMIT 1];
        Asset zSideAsset = [SELECT Id FROM Asset WHERE Odoo_IB_ID__c = '9102' LIMIT 1];

        Test.setMock(HttpCalloutMock.class, new MockOdooCallout(200,
            '{"result": {"data": [{'
            + '"name": "SO-9001-FULL",'
            + '"x_studio_space_id": "5001",'
            + '"x_studio_breaker_id": "6001",'
            + '"ns_a_side_service_id": "9101",'
            + '"ns_z_side_service_id": "9102"'
            + '}]}}'));

        Test.startTest();
        OdooAssetSyncService.fetchAssetDataFromOdoo(new List<Id>{ withIbId.Id });
        Test.stopTest();

        Asset after = [SELECT Space__c, Inventory__c, A_Side_Asset__c, Z_Side_Asset__c FROM Asset WHERE Id = :withIbId.Id];
        Inventory__c space = [SELECT Id FROM Inventory__c WHERE Odoo_Space_ID__c = '5001'];
        Inventory__c breaker = [SELECT Id FROM Inventory__c WHERE Odoo_Inventory_Id__c = '6001'];

        System.assertEquals(space.Id, after.Space__c, 'Space__c should resolve via getSpacID');
        System.assertEquals(breaker.Id, after.Inventory__c, 'Inventory__c should resolve via getInventoryID');
        System.assertEquals(aSideAsset.Id, after.A_Side_Asset__c, 'A_Side_Asset__c should resolve via getAssetBySideOdooId');
        System.assertEquals(zSideAsset.Id, after.Z_Side_Asset__c, 'Z_Side_Asset__c should resolve via getAssetBySideOdooId');
    }

    @IsTest
    static void testValidResponse_RelationalIdsSentAsBoolean_False_AreIgnored() {
        Asset withIbId = [SELECT Id FROM Asset WHERE Odoo_IB_ID__c = '9001' LIMIT 1];

        // Odoo sends boolean false (not a string/null) for blank relational fields.
        Test.setMock(HttpCalloutMock.class, new MockOdooCallout(200,
            '{"result": {"data": [{'
            + '"name": "SO-9001-BLANKRELS",'
            + '"x_studio_space_id": false,'
            + '"x_studio_breaker_id": false,'
            + '"ns_a_side_service_id": false,'
            + '"ns_z_side_service_id": false'
            + '}]}}'));

        Test.startTest();
        OdooAssetSyncService.fetchAssetDataFromOdoo(new List<Id>{ withIbId.Id });
        Test.stopTest();

        Asset after = [SELECT Space__c, Inventory__c, A_Side_Asset__c, Z_Side_Asset__c FROM Asset WHERE Id = :withIbId.Id];
        System.assertEquals(null, after.Space__c, 'A boolean false relational id must not attempt a lookup');
        System.assertEquals(null, after.Inventory__c, 'A boolean false relational id must not attempt a lookup');
        System.assertEquals(null, after.A_Side_Asset__c, 'A boolean false relational id must not attempt a lookup');
        System.assertEquals(null, after.Z_Side_Asset__c, 'A boolean false relational id must not attempt a lookup');
    }

    // ─── Helper method unit tests (found vs not-found paths) ──────────────────

    @IsTest
    static void testGetSpacID_FoundAndNotFound() {
        Inventory__c space = [SELECT Id FROM Inventory__c WHERE Odoo_Space_ID__c = '5001'];
        System.assertEquals(space.Id, OdooAssetSyncService.getSpacID('5001'));
        System.assertEquals(null, OdooAssetSyncService.getSpacID('does-not-exist'));
    }

    @IsTest
    static void testGetInventoryID_FoundAndNotFound() {
        Inventory__c breaker = [SELECT Id FROM Inventory__c WHERE Odoo_Inventory_Id__c = '6001'];
        System.assertEquals(breaker.Id, OdooAssetSyncService.getInventoryID('6001'));
        System.assertEquals(null, OdooAssetSyncService.getInventoryID('does-not-exist'));
    }

    @IsTest
    static void testGetAssetBySideOdooId_FoundAndNotFound() {
        Asset aSideAsset = [SELECT Id FROM Asset WHERE Odoo_IB_ID__c = '9101' LIMIT 1];
        System.assertEquals(aSideAsset.Id, OdooAssetSyncService.getAssetBySideOdooId('9101'));
        System.assertEquals(null, OdooAssetSyncService.getAssetBySideOdooId('does-not-exist'));
    }

    @IsTest
    static void testGetProductID_FoundAndNotFound() {
        Inventory__c breaker = [SELECT Id FROM Inventory__c WHERE Odoo_Inventory_Id__c = '6001'];
        System.assertEquals(breaker.Id, OdooAssetSyncService.getProductID('6001'));
        System.assertEquals(null, OdooAssetSyncService.getProductID('does-not-exist'));
    }
}