/**
 * CreateOdooInventoryQueueableTest
 * Covers the IP-3 create push (SF→Odoo) success write-back and the
 * "success but no id" branch, complementing the failure path already
 * exercised by the inventory trigger tests.
 */
@IsTest
private class CreateOdooInventoryQueueableTest {

    @TestSetup
    static void setup() {
        OdooIntegrationSettings__c s = OdooIntegrationSettings__c.getOrgDefaults();
        s.Environment__c = 'Sandbox';
        s.Base_URL__c    = 'https://test.odoo.example.com';
        s.Username__c    = 'u';
        s.Password__c    = 'p';
        upsert s;

        Site__c site = new Site__c(Name = 'CRE1', Site_Code__c = 'CRE1', Country__c = 'JP',
            Odoo_Site_ID__c = 42, Odoo_Company_ID__c = 9);
        insert site;
    }

    private static Inventory__c newSpace() {
        Id spaceRt = Schema.SObjectType.Inventory__c.getRecordTypeInfosByDeveloperName()
            .get('Inventory_Space').getRecordTypeId();
        Site__c site = [SELECT Id FROM Site__c WHERE Site_Code__c = 'CRE1' LIMIT 1];
        Inventory__c inv = new Inventory__c(Name = 'Create-Space', RecordTypeId = spaceRt,
            Status__c = 'Available', Space_Type__c = 'Cabinet', CabE_Count__c = 4,
            Total_Capacity_kVA__c = 10, Site_Id__c = site.Id);
        insert inv; // trigger auto-enqueues a create job; harmless (runs at stopTest, skips once synced)
        return inv;
    }

    @IsTest
    static void create_success_writesBackOdooId() {
        Inventory__c inv = newSpace();
        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new MockOdooCallout(200, '{"result":{"inventory_id":555}}'));
        new CreateOdooInventoryQueueable(new List<Id>{ inv.Id }).execute(null);
        Test.stopTest();

        Inventory__c synced = [SELECT Odoo_Space_ID__c, Odoo_Inventory_Id__c, Last_Synced__c, Odoo_Sync_Error__c
                               FROM Inventory__c WHERE Id = :inv.Id];
        System.assertEquals('555', synced.Odoo_Space_ID__c, 'Odoo id should be written back to Odoo_Space_ID__c');
        System.assertEquals('555', synced.Odoo_Inventory_Id__c, 'Odoo id should also populate Odoo_Inventory_Id__c');
        System.assertEquals(null, synced.Odoo_Sync_Error__c, 'Successful sync should clear the error');
        System.assertNotEquals(null, synced.Last_Synced__c, 'Last_Synced__c should be stamped');
    }

    @IsTest
    static void create_successWithoutId_recordsError() {
        Inventory__c inv = newSpace();
        Test.startTest();
        // 200 with a result but no inventory/space/breaker id → "success but no valid id" branch
        Test.setMock(HttpCalloutMock.class, new MockOdooCallout(200, '{"result":{"status":"ok"}}'));
        new CreateOdooInventoryQueueable(new List<Id>{ inv.Id }).execute(null);
        Test.stopTest();

        Inventory__c r = [SELECT Odoo_Sync_Error__c, Odoo_Space_ID__c FROM Inventory__c WHERE Id = :inv.Id];
        System.assertEquals(null, r.Odoo_Space_ID__c, 'No valid id → Odoo_Space_ID__c stays null');
        System.assertNotEquals(null, r.Odoo_Sync_Error__c, 'Missing id should record a sync error');
        System.assert([SELECT COUNT() FROM DE_Integration_Error__c WHERE IP_Reference__c = 'IP-3'] >= 1,
            'A missing-id response should log an IP-3 error');
    }

    @IsTest
    static void create_failure_recordsError() {
        Inventory__c inv = newSpace();
        Test.startTest();
        Test.setMock(HttpCalloutMock.class, MockOdooCallout.odooError());
        new CreateOdooInventoryQueueable(new List<Id>{ inv.Id }).execute(null);
        Test.stopTest();

        Inventory__c r = [SELECT Odoo_Sync_Error__c FROM Inventory__c WHERE Id = :inv.Id];
        System.assertNotEquals(null, r.Odoo_Sync_Error__c, 'Failed create should record the error on the record');
    }
}