/**
 * DecommissionOdooInventoryQueueableTest
 *
 * Tests for DecommissionOdooInventoryQueueable (IP-3 SF->Odoo: archive an
 * Inventory record in Odoo when Status__c transitions to 'Decommissioned').
 * All Odoo callouts are mocked — no real callouts are made. Relies on the org's
 * existing OdooIntegrationSettings__c hierarchy custom setting default rather
 * than inserting a new one, since only a single org-default row is permitted.
 */
@IsTest
private class DecommissionOdooInventoryQueueableTest {

    private class OdooMock implements HttpCalloutMock {
        public Integer callCount = 0;
        public Set<String> failEndpointsContaining = new Set<String>();
        // Body-based matching lets us fail specific records even though every
        // Decommission callout shares the same endpoint (/api/v1/create_inventory) —
        // the differentiator (inventory_id) only appears in the JSON body.
        public Set<String> failBodyContaining = new Set<String>();

        public HttpResponse respond(HttpRequest req) {
            callCount++;
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            Boolean shouldFail = false;
            for (String frag : failEndpointsContaining) {
                if (req.getEndpoint().contains(frag)) {
                    shouldFail = true;
                    break;
                }
            }
            if (!shouldFail) {
                for (String frag : failBodyContaining) {
                    if (req.getBody() != null && req.getBody().contains(frag)) {
                        shouldFail = true;
                        break;
                    }
                }
            }
            if (shouldFail) {
                res.setBody('{"result": {"status": "error", "message": "Simulated Odoo failure"}}');
            } else {
                res.setBody('{"result": {"id": 1}}');
            }
            return res;
        }
    }

    private static Id spaceRecordTypeId() {
        return Schema.SObjectType.Inventory__c.getRecordTypeInfosByDeveloperName()
            .get('Inventory_Space').getRecordTypeId();
    }

    private static Id breakerRecordTypeId() {
        return Schema.SObjectType.Inventory__c.getRecordTypeInfosByDeveloperName()
            .get('Inventory_Breaker').getRecordTypeId();
    }

    private static Site__c makeSite(Decimal companyId) {
        Site__c site = new Site__c(Name = 'Test Site DOIQ', Site_Code__c = 'TSTDOIQ', Country__c = 'SG', Odoo_Company_ID__c = companyId);
        insert site;
        return site;
    }

    @IsTest
    static void testDecommissionSpaceSuccess() {
        Site__c site = makeSite(555);
        Inventory__c space = new Inventory__c(
            RecordTypeId = spaceRecordTypeId(), Site_Id__c = site.Id,
            Odoo_Space_ID__c = '9001', Status__c = 'Available'
        );
        insert space;

        OdooMock mock = new OdooMock();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        System.enqueueJob(new DecommissionOdooInventoryQueueable(new List<Id>{ space.Id }));
        Test.stopTest();

        Assert.areEqual(1, mock.callCount, 'Should make exactly one callout for the space');
        Inventory__c refreshed = [SELECT Last_Synced__c, Odoo_Sync_Payload__c, Odoo_Sync_Error__c FROM Inventory__c WHERE Id = :space.Id];
        Assert.isNotNull(refreshed.Last_Synced__c, 'Successful decommission should stamp Last_Synced__c');
        Assert.isTrue(refreshed.Odoo_Sync_Payload__c.contains('decommission'), 'Payload should record the decommission event type');
        Assert.isTrue(refreshed.Odoo_Sync_Payload__c.contains('company_id'), 'Payload should include company_id when the site has one');
        Assert.isNull(refreshed.Odoo_Sync_Error__c, 'No sync error expected on success');
        Assert.areEqual(0, [SELECT COUNT() FROM DE_Integration_Error__c]);
    }

    @IsTest
    static void testDecommissionBreakerSuccess() {
        Site__c site = makeSite(null);
        Inventory__c breaker = new Inventory__c(
            RecordTypeId = breakerRecordTypeId(), Site_Id__c = site.Id,
            Odoo_Inventory_Id__c = '9002', Status__c = 'Available'
        );
        insert breaker;

        OdooMock mock = new OdooMock();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        System.enqueueJob(new DecommissionOdooInventoryQueueable(new List<Id>{ breaker.Id }));
        Test.stopTest();

        Assert.isTrue(mock.callCount >= 1, 'Should make at least one callout for the breaker');
        Inventory__c refreshed = [SELECT Last_Synced__c, Odoo_Sync_Payload__c, Odoo_Sync_Error__c FROM Inventory__c WHERE Id = :breaker.Id];
        Assert.isNotNull(refreshed.Last_Synced__c, 'Successful decommission should stamp Last_Synced__c');
        Assert.isTrue(refreshed.Odoo_Sync_Payload__c.contains('breaker'), 'Payload should record the breaker inventory_type');
        Assert.isNull(refreshed.Odoo_Sync_Error__c, 'No sync error expected on success');
    }

    @IsTest
    static void testDecommissionFailureCreatesErrorRecord() {
        Site__c site = makeSite(555);
        Inventory__c space = new Inventory__c(
            RecordTypeId = spaceRecordTypeId(), Site_Id__c = site.Id,
            Odoo_Space_ID__c = '9003', Status__c = 'Available'
        );
        insert space;

        OdooMock mock = new OdooMock();
        mock.failEndpointsContaining.add('create_inventory');
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        System.enqueueJob(new DecommissionOdooInventoryQueueable(new List<Id>{ space.Id }));
        Test.stopTest();

        Inventory__c refreshed = [SELECT Odoo_Sync_Error__c, Last_Synced__c FROM Inventory__c WHERE Id = :space.Id];
        Assert.isNotNull(refreshed.Odoo_Sync_Error__c, 'Failed decommission should record the sync error');
        Assert.isNull(refreshed.Last_Synced__c, 'Last_Synced__c should not be stamped on failure');

        List<DE_Integration_Error__c> errors = [
            SELECT Error_Message__c, IP_Reference__c, Status__c, Record_Id__c, Request_Payload__c
            FROM DE_Integration_Error__c
        ];
        Assert.areEqual(1, errors.size(), 'Failed decommission should create exactly one error record');
        Assert.isTrue(errors[0].Error_Message__c.contains('Failed to decommission'), 'Error message: ' + errors[0].Error_Message__c);
        Assert.areEqual('IP-3', errors[0].IP_Reference__c);
        Assert.areEqual('Open', errors[0].Status__c);
        Assert.areEqual(String.valueOf(space.Id), errors[0].Record_Id__c);
        Assert.isNotNull(errors[0].Request_Payload__c, 'Error record should carry the outbound payload for debugging');
    }

    @IsTest
    static void testSkipWhenNoOdooId() {
        Site__c site = makeSite(null);
        Inventory__c spaceNoId = new Inventory__c(
            RecordTypeId = spaceRecordTypeId(), Site_Id__c = site.Id,
            Odoo_Space_ID__c = null, Status__c = 'Available'
        );
        insert spaceNoId;

        OdooMock mock = new OdooMock();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        System.enqueueJob(new DecommissionOdooInventoryQueueable(new List<Id>{ spaceNoId.Id }));
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM DE_Integration_Error__c]);
    }

    @IsTest
    static void testMixedSuccessAndFailureBulk() {
        Site__c site = makeSite(555);
        List<Inventory__c> spaces = new List<Inventory__c>();
        for (Integer i = 0; i < 5; i++) {
            spaces.add(new Inventory__c(
                RecordTypeId = spaceRecordTypeId(), Site_Id__c = site.Id,
                Odoo_Space_ID__c = String.valueOf(6000 + i), Status__c = 'Available'
            ));
        }
        insert spaces;

        OdooMock mock = new OdooMock();
        // Fail only the callouts whose payload carries inventory_id 6003 or 6004 —
        // every Decommission callout shares the same endpoint, so the failure has
        // to be keyed off the JSON body to get genuinely mixed success/failure.
        mock.failBodyContaining.add('"inventory_id":6003');
        mock.failBodyContaining.add('"inventory_id":6004');
        Test.setMock(HttpCalloutMock.class, mock);

        List<Id> ids = new List<Id>();
        for (Inventory__c sp : spaces) ids.add(sp.Id);

        Test.startTest();
        System.enqueueJob(new DecommissionOdooInventoryQueueable(ids));
        Test.stopTest();

        Assert.areEqual(5, mock.callCount, 'Should attempt a callout for every record with an Odoo id');
        Assert.areEqual(2, [SELECT COUNT() FROM DE_Integration_Error__c], 'Only the 2 targeted records should fail and log an error');

        Integer successCount = [SELECT COUNT() FROM Inventory__c WHERE Id IN :ids AND Last_Synced__c != null];
        Integer failureCount = 0;
        for (Inventory__c inv : [SELECT Odoo_Sync_Error__c FROM Inventory__c WHERE Id IN :ids]) {
            if (inv.Odoo_Sync_Error__c != null) {
                failureCount++;
            }
        }
        Assert.areEqual(3, successCount, '3 of 5 records should have synced successfully');
        Assert.areEqual(2, failureCount, '2 of 5 records should have a recorded sync error');
    }

    @IsTest
    static void testBulkOver100DefersRemaining() {
        Site__c site = makeSite(null);
        List<Inventory__c> spaces = new List<Inventory__c>();
        for (Integer i = 0; i < 105; i++) {
            spaces.add(new Inventory__c(
                RecordTypeId = spaceRecordTypeId(), Site_Id__c = site.Id,
                Odoo_Space_ID__c = String.valueOf(7000 + i), Status__c = 'Available'
            ));
        }
        insert spaces;

        List<Id> ids = new List<Id>();
        for (Inventory__c sp : spaces) ids.add(sp.Id);

        OdooMock mock = new OdooMock();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        System.enqueueJob(new DecommissionOdooInventoryQueueable(ids));
        Test.stopTest();

        Assert.areEqual(100, mock.callCount, 'Should stop making callouts once the 100-callout governor cap is hit');
        Integer processedCount = [SELECT COUNT() FROM Inventory__c WHERE Id IN :ids AND Last_Synced__c != null];
        Integer deferredCount = [SELECT COUNT() FROM Inventory__c WHERE Id IN :ids AND Last_Synced__c = null];
        Assert.areEqual(100, processedCount, 'Exactly 100 records should have been processed in this transaction');
        Assert.areEqual(5, deferredCount, 'The remaining 5 records should be deferred (no follow-up job runs during a test)');
    }
}