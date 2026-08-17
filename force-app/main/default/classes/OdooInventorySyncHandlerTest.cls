@IsTest
private class OdooInventorySyncHandlerTest {

    private static final String RT_SPACE   = 'Inventory_Space';
    private static final String RT_BREAKER = 'Inventory_Breaker';

    // ── Test Setup ────────────────────────────────────────────────────────────

    @TestSetup
    static void setup() {
        // ── Related objects for lookup resolution tests ──
        Site__c testSite = new Site__c(
            Site_Code__c = 'TST1', Odoo_Site_ID__c = 42, Country__c = 'JP'
        );
        insert testSite;

        Floor__c testFloor = new Floor__c(Name = 'Floor 9', Site__c = testSite.Id);
        insert testFloor;

        DataHall__c testHall = new DataHall__c(
            Name = 'TST1-09-01', Floor__c = testFloor.Id, Site__c = testSite.Id
        );
        insert testHall;

        Account testAccount = new Account(Name = 'Test Customer Corp', Odoo_Partner_ID__c = 319);
        insert testAccount;

        // ── Inventory records ──
        Id spaceRtId = Schema.SObjectType.Inventory__c.getRecordTypeInfosByDeveloperName()
            .get(RT_SPACE).getRecordTypeId();
        Id breakerRtId = Schema.SObjectType.Inventory__c.getRecordTypeInfosByDeveloperName()
            .get(RT_BREAKER).getRecordTypeId();

        List<Inventory__c> records = new List<Inventory__c>{
            new Inventory__c(
                Name = 'TYO3-6-2-S-001-0701',
                RecordTypeId = spaceRtId,
                Odoo_Space_ID__c = '32196',
                Status__c = 'Available',
                Site_Id__c = testSite.Id
            ),
            new Inventory__c(
                Name = 'OSA1-BRK-001',
                RecordTypeId = breakerRtId,
                // Breakers are looked up by Odoo_Inventory_Id__c (see handler.findByOdooId).
                Odoo_Inventory_Id__c = '3659',
                Status__c = 'Available',
                Site_Id__c = testSite.Id
            ),
            new Inventory__c(
                Name = 'JKT2-9-1-S-001',
                RecordTypeId = spaceRtId,
                Odoo_Space_ID__c = '50001',
                Status__c = 'Available',
                Site_Id__c = testSite.Id
            )
        };
        insert records;
    }

    // ── CREATE tests ──────────────────────────────────────────────────────────

    @IsTest
    static void testCreateSpace() {
        String body = JSON.serialize(new Map<String, Object>{
            'event_type'        => 'create',
            'model_type'        => 'ns.ns_space',
            'id'                => 99001,
            'ns_name'           => 'JKT2-TEST-SPACE-001',
            'ns_stage'          => 'available',
            'capacity_kva'      => 10.5,
            'ns_operation_site' => 42  // resolves Site_Id__c (now required on Inventory__c)
        });

        RestContext.request = buildRequest(body);
        RestContext.response = new RestResponse();

        Test.startTest();
        OdooInventorySyncHandler.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode, 'Expected 200 OK');
        Map<String, Object> resp = parseResponse();
        System.assertEquals('ok', resp.get('status'));
        System.assertNotEquals(null, resp.get('sf_inventory_id'));

        Inventory__c created = [
            SELECT Name, Status__c, Total_Capacity_kVA__c,
                   Odoo_Space_ID__c, RecordType.DeveloperName
            FROM Inventory__c
            WHERE Odoo_Space_ID__c = '99001'
            LIMIT 1
        ];
        System.assertEquals('JKT2-TEST-SPACE-001', created.Name);
        System.assertEquals('Available', created.Status__c);
        System.assertEquals(10.5, created.Total_Capacity_kVA__c);
        System.assertEquals(RT_SPACE, created.RecordType.DeveloperName);
    }

    @IsTest
    static void testCreateBreaker() {
        String body = JSON.serialize(new Map<String, Object>{
            'event_type'        => 'create',
            'model_type'        => 'ns.ns_breaker',
            'id'                => 99002,
            'ns_name'           => 'OSA1-BRK-TEST-001',
            'ns_stage'          => 'available',
            'ns_operation_site' => 42  // resolves required Site_Id__c
        });

        RestContext.request = buildRequest(body);
        RestContext.response = new RestResponse();

        Test.startTest();
        OdooInventorySyncHandler.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        // Breakers store the Odoo id in Odoo_Inventory_Id__c (not Odoo_Space_ID__c).
        Inventory__c created = [
            SELECT RecordType.DeveloperName, Status__c
            FROM Inventory__c
            WHERE Odoo_Inventory_Id__c = '99002'
        ];
        System.assertEquals(RT_BREAKER, created.RecordType.DeveloperName);
        System.assertEquals('Available', created.Status__c);
    }

    @IsTest
    static void testCreateIdempotent() {
        // Creating with an ID that already exists (SPC-32196 → integer 32196)
        // should update instead of duplicating. Only change Name (safe — no VR).
        String body = JSON.serialize(new Map<String, Object>{
            'event_type' => 'create',
            'model_type' => 'ns.ns_space',
            'id'         => 32196,
            'ns_name'    => 'TYO3-RENAMED'
        });

        RestContext.request = buildRequest(body);
        RestContext.response = new RestResponse();

        Test.startTest();
        OdooInventorySyncHandler.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        // Should NOT create a duplicate
        Integer cnt = [SELECT COUNT() FROM Inventory__c
                       WHERE Odoo_Space_ID__c IN ('32196', 'SPC-32196')];
        System.assertEquals(1, cnt, 'Expected no duplicate — idempotent create');

        Inventory__c updated = [
            SELECT Name, Status__c FROM Inventory__c
            WHERE Odoo_Space_ID__c = '32196'
        ];
        System.assertEquals('TYO3-RENAMED', updated.Name);
        System.assertEquals('Available', updated.Status__c, 'Status unchanged when ns_stage omitted');
    }

    // ── UPDATE tests ──────────────────────────────────────────────────────────

    @IsTest
    static void testUpdateByPrefixedId() {
        // Record has Odoo_Space_ID__c = 'BRK-3659'. Update with integer 3659.
        String body = JSON.serialize(new Map<String, Object>{
            'event_type'   => 'update',
            'model_type'   => 'ns.ns_breaker',
            'id'           => 3659,
            'ns_stage'     => 'installed',
            'capacity_kva' => 25.0
        });

        RestContext.request = buildRequest(body);
        RestContext.response = new RestResponse();

        Test.startTest();
        OdooInventorySyncHandler.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        // The 'update' event path maps ns_stage → Status__c only (it does not apply
        // capacity/other optional fields — those flow through create / idempotent-create).
        Inventory__c updated = [
            SELECT Status__c
            FROM Inventory__c
            WHERE Odoo_Inventory_Id__c = '3659'
        ];
        System.assertEquals('Installed', updated.Status__c);
    }

    @IsTest
    static void testUpdateByBareId() {
        // Record has Odoo_Space_ID__c = '50001' (no prefix). The 'update' event maps
        // ns_stage → Status__c (Name/capacity flow through create, not update).
        String body = JSON.serialize(new Map<String, Object>{
            'event_type' => 'update',
            'model_type' => 'ns.ns_space',
            'id'         => 50001,
            'ns_stage'   => 'installed'
        });

        RestContext.request = buildRequest(body);
        RestContext.response = new RestResponse();

        Test.startTest();
        OdooInventorySyncHandler.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        Inventory__c updated = [
            SELECT Status__c FROM Inventory__c
            WHERE Odoo_Space_ID__c = '50001'
        ];
        System.assertEquals('Installed', updated.Status__c, 'update event should map ns_stage to Status__c');
    }

    @IsTest
    static void testUpdateNotFound() {
        String body = JSON.serialize(new Map<String, Object>{
            'event_type' => 'update',
            'model_type' => 'ns.ns_space',
            'id'         => 99999
        });

        RestContext.request = buildRequest(body);
        RestContext.response = new RestResponse();

        Test.startTest();
        OdooInventorySyncHandler.handlePost();
        Test.stopTest();

        System.assertEquals(422, RestContext.response.statusCode);
        Map<String, Object> resp = parseResponse();
        String errMsg = (String) resp.get('error');
        System.assert(errMsg.contains('99999'), 'Error should reference the ID');
    }

    // ── DECOMMISSION tests ────────────────────────────────────────────────────

    @IsTest
    static void testDecommission() {
        // VR blocks Available → Decommissioned. Pre-set to Installed first.
        Inventory__c rec = [
            SELECT Id, Status__c FROM Inventory__c
            WHERE Odoo_Space_ID__c = '32196' LIMIT 1
        ];
        rec.Status__c = 'Installed';
        update rec;

        String body = JSON.serialize(new Map<String, Object>{
            'event_type' => 'decommission',
            'model_type' => 'ns.ns_space',
            'id'         => 32196
        });

        RestContext.request = buildRequest(body);
        RestContext.response = new RestResponse();

        Test.startTest();
        OdooInventorySyncHandler.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        Inventory__c updated = [
            SELECT Status__c FROM Inventory__c
            WHERE Odoo_Space_ID__c = '32196'
        ];
        System.assertEquals('Decommissioned', updated.Status__c);
    }

    @IsTest
    static void testDecommissionNotFound() {
        String body = JSON.serialize(new Map<String, Object>{
            'event_type' => 'decommission',
            'model_type' => 'ns.ns_breaker',
            'id'         => 88888
        });

        RestContext.request = buildRequest(body);
        RestContext.response = new RestResponse();

        Test.startTest();
        OdooInventorySyncHandler.handlePost();
        Test.stopTest();

        System.assertEquals(422, RestContext.response.statusCode);
    }

    // ── Validation / error tests ──────────────────────────────────────────────

    @IsTest
    static void testMissingEventType() {
        String body = JSON.serialize(new Map<String, Object>{
            'model_type' => 'ns.ns_space',
            'id'         => 12345
        });

        RestContext.request = buildRequest(body);
        RestContext.response = new RestResponse();

        Test.startTest();
        OdooInventorySyncHandler.handlePost();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode);
    }

    @IsTest
    static void testInvalidModelType() {
        String body = JSON.serialize(new Map<String, Object>{
            'event_type' => 'create',
            'model_type' => 'ns.ns_invalid',
            'id'         => 12345
        });

        RestContext.request = buildRequest(body);
        RestContext.response = new RestResponse();

        Test.startTest();
        OdooInventorySyncHandler.handlePost();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode);
    }

    @IsTest
    static void testMissingId() {
        String body = JSON.serialize(new Map<String, Object>{
            'event_type' => 'create',
            'model_type' => 'ns.ns_space'
        });

        RestContext.request = buildRequest(body);
        RestContext.response = new RestResponse();

        Test.startTest();
        OdooInventorySyncHandler.handlePost();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode);
    }

    @IsTest
    static void testUnknownEventType() {
        String body = JSON.serialize(new Map<String, Object>{
            'event_type' => 'explode',
            'model_type' => 'ns.ns_space',
            'id'         => 12345
        });

        RestContext.request = buildRequest(body);
        RestContext.response = new RestResponse();

        Test.startTest();
        OdooInventorySyncHandler.handlePost();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode);
    }

    @IsTest
    static void testUnknownStageDefaultsGracefully() {
        String body = JSON.serialize(new Map<String, Object>{
            'event_type'        => 'create',
            'model_type'        => 'ns.ns_space',
            'id'                => 99003,
            'ns_name'           => 'UNKNOWN-STAGE-TEST',
            'ns_stage'          => 'some_future_stage',
            'ns_operation_site' => 42  // resolves required Site_Id__c
        });

        RestContext.request = buildRequest(body);
        RestContext.response = new RestResponse();

        Test.startTest();
        OdooInventorySyncHandler.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        Inventory__c created = [
            SELECT Status__c FROM Inventory__c
            WHERE Odoo_Space_ID__c = '99003'
        ];
        System.assertEquals('Available', created.Status__c, 'Unknown stage should default to Available');
    }

    // ── Full-field tests (Space/Breaker export columns) ─────────────────────

    @IsTest
    static void testCreateSpaceWithFullFields() {
        String body = JSON.serialize(new Map<String, Object>{
            'event_type'        => 'create',
            'model_type'        => 'ns.ns_space',
            'id'                => 99010,
            'ns_name'           => 'TST1-9-1-S-001-0101',
            'ns_stage'          => 'installed',
            'capacity_kva'      => 20.0,
            'it_power_kva'      => 15.5,
            'rack_units'        => 4,
            'space_type'        => 'cabinet',
            'display_name'      => 'TST1-UNIT-0101',
            'other_name'        => 'Bay 101',
            'total_area'        => 2.5,
            'ns_operation_site' => 42,
            'ns_room_name'      => 'TST1-09-01',
            'ns_customer'       => 319
        });

        RestContext.request = buildRequest(body);
        RestContext.response = new RestResponse();

        Test.startTest();
        OdooInventorySyncHandler.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode, 'Expected 200 OK');

        Inventory__c created = [
            SELECT Name, Status__c, Total_Capacity_kVA__c, Total_IT_Power_kVA__c,
                   CabE_Count__c, Space_Type__c, Unit_Reference__c, Hall__c,
                   Total_Area_sqm__c, Site_Id__c, Data_Hall__c, Floor__c, Account__c,
                   RecordType.DeveloperName
            FROM Inventory__c
            WHERE Odoo_Space_ID__c = '99010'
        ];
        // Scalar fields
        System.assertEquals('TST1-9-1-S-001-0101', created.Name);
        System.assertEquals('Installed', created.Status__c);
        System.assertEquals(20.0, created.Total_Capacity_kVA__c);
        System.assertEquals(15.5, created.Total_IT_Power_kVA__c);
        System.assertEquals(4,    created.CabE_Count__c);
        System.assertEquals('Cabinet', created.Space_Type__c);
        System.assertEquals('TST1-UNIT-0101', created.Unit_Reference__c);
        System.assertEquals('Bay 101', created.Hall__c);
        System.assertEquals(2.5, created.Total_Area_sqm__c);
        System.assertEquals(RT_SPACE, created.RecordType.DeveloperName);

        // Lookup resolutions
        Site__c site = [SELECT Id FROM Site__c WHERE Site_Code__c = 'TST1'];
        System.assertEquals(site.Id, created.Site_Id__c, 'Site resolved by Odoo_Site_ID__c');

        DataHall__c hall = [SELECT Id FROM DataHall__c WHERE Name = 'TST1-09-01'];
        System.assertEquals(hall.Id, created.Data_Hall__c, 'DataHall resolved by Name+Site');

        Floor__c floor = [SELECT Id FROM Floor__c WHERE Name = 'Floor 9'];
        System.assertEquals(floor.Id, created.Floor__c, 'Floor derived from DataHall');

        Account acct = [SELECT Id FROM Account WHERE Odoo_Partner_ID__c = 319];
        System.assertEquals(acct.Id, created.Account__c, 'Account resolved by Odoo_Partner_ID__c');
    }

    @IsTest
    static void testCreateBreakerWithFullFields() {
        String body = JSON.serialize(new Map<String, Object>{
            'event_type'        => 'create',
            'model_type'        => 'ns.ns_breaker',
            'id'                => 99020,
            'ns_name'           => 'TST1-BRK-TEST-001',
            'ns_stage'          => 'available',
            'capacity_kva'      => 30.0,
            'parent_equipment'  => 'TST1-PDF-1-MAIN',
            'external_id'       => '__export__.ns_ns_breaker_99020',
            'ns_operation_site' => 42,
            'ns_customer'       => 319
        });

        RestContext.request = buildRequest(body);
        RestContext.response = new RestResponse();

        Test.startTest();
        OdooInventorySyncHandler.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);

        // external_id overwrites Odoo_Inventory_Id__c (handler.applyOptionalFields),
        // so the record is keyed by the external id, not the bare integer.
        Inventory__c created = [
            SELECT Name, Status__c, Total_Capacity_kVA__c, Breaker_Panel__c,
                   Odoo_Inventory_Id__c, Site_Id__c, Account__c,
                   RecordType.DeveloperName
            FROM Inventory__c
            WHERE Odoo_Inventory_Id__c = '__export__.ns_ns_breaker_99020'
        ];
        System.assertEquals(RT_BREAKER, created.RecordType.DeveloperName);
        System.assertEquals('TST1-BRK-TEST-001', created.Name);
        System.assertEquals(30.0, created.Total_Capacity_kVA__c);
        System.assertEquals('TST1-PDF-1-MAIN', created.Breaker_Panel__c);
        System.assertEquals('__export__.ns_ns_breaker_99020', created.Odoo_Inventory_Id__c);
        System.assertNotEquals(null, created.Site_Id__c, 'Site resolved');
        System.assertNotEquals(null, created.Account__c, 'Account resolved');
    }

    @IsTest
    static void testSpaceTypeMappingCage() {
        // Odoo space_type "cage" maps to the SF Space_Type__c restricted-picklist value "Cage".
        String body = JSON.serialize(new Map<String, Object>{
            'event_type'        => 'create',
            'model_type'        => 'ns.ns_space',
            'id'                => 99030,
            'ns_name'           => 'TST1-CAGE-01',
            'space_type'        => 'cage',
            'ns_operation_site' => 42  // resolves required Site_Id__c
        });

        RestContext.request = buildRequest(body);
        RestContext.response = new RestResponse();

        Test.startTest();
        OdooInventorySyncHandler.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        Inventory__c created = [
            SELECT Space_Type__c FROM Inventory__c WHERE Odoo_Space_ID__c = '99030'
        ];
        System.assertEquals('Cage', created.Space_Type__c, 'Odoo "cage" maps to SF "Cage"');
    }

    @IsTest
    static void testLookupNotFoundStillSucceeds() {
        // Non-matching room/customer IDs should not fail the request — just skip those
        // lookups. Site must still resolve (Site_Id__c is required on Inventory__c).
        String body = JSON.serialize(new Map<String, Object>{
            'event_type'        => 'create',
            'model_type'        => 'ns.ns_space',
            'id'                => 99040,
            'ns_name'           => 'ORPHAN-SPACE-001',
            'ns_operation_site' => 42,       // resolves (required)
            'ns_customer'       => 888888,   // unresolved → Account__c stays null
            'ns_room_name'      => 'NONEXISTENT-ROOM' // unresolved → Data_Hall__c stays null
        });

        RestContext.request = buildRequest(body);
        RestContext.response = new RestResponse();

        Test.startTest();
        OdooInventorySyncHandler.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode, 'Should succeed with partially unresolved lookups');
        Inventory__c created = [
            SELECT Site_Id__c, Data_Hall__c, Account__c FROM Inventory__c
            WHERE Odoo_Space_ID__c = '99040'
        ];
        System.assertNotEquals(null, created.Site_Id__c, 'Required site should resolve');
        System.assertEquals(null, created.Data_Hall__c, 'Unresolved room stays null');
        System.assertEquals(null, created.Account__c, 'Unresolved customer stays null');
    }

    @IsTest
    static void testCreateResolvesLookups() {
        // Site/room/customer/space_type/it_power resolve on the CREATE path via
        // applyOptionalFields. (Site_Id__c is a master-detail field — not writeable on
        // update — so lookup resolution is only valid on insert, done here with a new id.)
        String body = JSON.serialize(new Map<String, Object>{
            'event_type'        => 'create',
            'model_type'        => 'ns.ns_space',
            'id'                => 50002,
            'ns_name'           => 'TST1-RESOLVE-01',
            'ns_operation_site' => 42,
            'ns_room_name'      => 'TST1-09-01',
            'ns_customer'       => 319,
            'it_power_kva'      => 8.5,
            'space_type'        => 'cage'
        });

        RestContext.request = buildRequest(body);
        RestContext.response = new RestResponse();

        Test.startTest();
        OdooInventorySyncHandler.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        Inventory__c created = [
            SELECT Site_Id__c, Data_Hall__c, Floor__c, Account__c,
                   Total_IT_Power_kVA__c, Space_Type__c
            FROM Inventory__c
            WHERE Odoo_Space_ID__c = '50002'
        ];
        System.assertNotEquals(null, created.Site_Id__c, 'Site resolved on create');
        System.assertNotEquals(null, created.Data_Hall__c, 'DataHall resolved by name + site');
        System.assertNotEquals(null, created.Floor__c, 'Floor derived from DataHall');
        System.assertNotEquals(null, created.Account__c, 'Account resolved by Odoo_Partner_ID__c');
        System.assertEquals(8.5, created.Total_IT_Power_kVA__c);
        System.assertEquals('Cage', created.Space_Type__c);
    }

    // ── LockOdooSpacesQueueable prefix stripping ──────────────────────────────

    @IsTest
    static void testExtractOdooIntId() {
        System.assertEquals('32196', LockOdooSpacesQueueable.extractOdooIntId('SPC-32196'));
        System.assertEquals('3659',  LockOdooSpacesQueueable.extractOdooIntId('BRK-3659'));
        System.assertEquals('12345', LockOdooSpacesQueueable.extractOdooIntId('12345'));
        System.assertEquals(null,    LockOdooSpacesQueueable.extractOdooIntId(null));
        System.assertEquals(null,    LockOdooSpacesQueueable.extractOdooIntId(''));
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private static RestRequest buildRequest(String body) {
        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/de/inventory';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(body);
        return req;
    }

    private static Map<String, Object> parseResponse() {
        return (Map<String, Object>) JSON.deserializeUntyped(
            RestContext.response.responseBody.toString());
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  UpdateOdooInventoryQueueable (IP-3 SF→Odoo push) coverage.
    // ══════════════════════════════════════════════════════════════════════════

    private static Id spaceRtId() {
        return Schema.SObjectType.Inventory__c.getRecordTypeInfosByDeveloperName().get(RT_SPACE).getRecordTypeId();
    }
    private static Id breakerRtId() {
        return Schema.SObjectType.Inventory__c.getRecordTypeInfosByDeveloperName().get(RT_BREAKER).getRecordTypeId();
    }

    private static Site__c queueSite() {
        Site__c s = new Site__c(Site_Code__c = 'QUE1', Country__c = 'JP',
            Odoo_Site_ID__c = 77, Odoo_Company_ID__c = 9);
        insert s;
        return s;
    }

    private static void seedOdooSettings() {
        OdooIntegrationSettings__c s = OdooIntegrationSettings__c.getOrgDefaults();
        s.Username__c = 'test_user';
        s.Password__c = 'test_pass';
        s.Base_URL__c = 'https://test.odoo.example.com';
        s.Environment__c = 'Sandbox';
        upsert s;
    }

    @IsTest
    static void queueable_pushesSpaceAndBreaker_success() {
        Site__c site = queueSite();
        seedOdooSettings();
        Inventory__c space = new Inventory__c(Name = 'Q-SPACE', RecordTypeId = spaceRtId(),
            Odoo_Space_ID__c = '70001', Status__c = 'Available', Site_Id__c = site.Id);
        Inventory__c breaker = new Inventory__c(Name = 'Q-BRK', RecordTypeId = breakerRtId(),
            Odoo_Inventory_Id__c = '70002', Status__c = 'Installed', Site_Id__c = site.Id);
        insert new List<Inventory__c>{ space, breaker };

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, MockOdooCallout.success(555));
        new UpdateOdooInventoryQueueable(new List<Id>{ space.Id, breaker.Id }).execute(null);
        Test.stopTest();

        Inventory__c syncedSpace = [SELECT Last_Synced__c, Odoo_Sync_Error__c, Odoo_Sync_Payload__c
                                    FROM Inventory__c WHERE Id = :space.Id];
        System.assertNotEquals(null, syncedSpace.Last_Synced__c, 'Successful sync should stamp Last_Synced__c');
        System.assertEquals(null, syncedSpace.Odoo_Sync_Error__c, 'Success should clear the sync error');
        System.assert(String.isNotBlank(syncedSpace.Odoo_Sync_Payload__c), 'Payload should be stored on success');
    }

    @IsTest
    static void queueable_recordsFailure() {
        Site__c site = queueSite();
        seedOdooSettings();
        Inventory__c space = new Inventory__c(Name = 'Q-FAIL', RecordTypeId = spaceRtId(),
            Odoo_Space_ID__c = '70003', Status__c = 'Available', Site_Id__c = site.Id);
        insert space;

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, MockOdooCallout.odooError());
        new UpdateOdooInventoryQueueable(new List<Id>{ space.Id }).execute(null);
        Test.stopTest();

        Inventory__c failed = [SELECT Odoo_Sync_Error__c FROM Inventory__c WHERE Id = :space.Id];
        System.assertNotEquals(null, failed.Odoo_Sync_Error__c, 'Failed sync should record the error on the record');
        System.assert([SELECT COUNT() FROM DE_Integration_Error__c WHERE IP_Reference__c = 'IP-3'] >= 1,
            'A failed IP-3 push should log a DE_Integration_Error__c');
    }
}