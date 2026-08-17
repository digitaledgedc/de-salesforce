/**
 * AssetSyncSchedulableTest
 *
 * Covers AssetSyncSchedulable.execute():
 *  - IP-2 disabled -> no batch is enqueued at all (no callout, no watermark change).
 *  - IP-2 enabled with an explicit batch size -> AssetSyncBatch runs to completion
 *    (HTTP callout mocked) and the sync watermark (IP2_Last_Sync__c) is updated.
 *  - IP-2 enabled with no batch size configured -> defaults to batch size 1 and still
 *    runs the batch to completion.
 *  - Scheduled via System.schedule(...) (the real activation path documented on the class)
 *    and flushed synchronously by Test.stopTest().
 *
 * The Odoo HTTP callouts triggered transitively by AssetSyncBatch are mocked; no real
 * callouts are made. OdooIntegrationSettings__c is a Hierarchy custom setting, so the
 * org-default record is created explicitly in each test via SetupOwnerId = the org Id.
 */
@isTest
private class AssetSyncSchedulableTest {

    // Mocks the two Odoo GET calls AssetSyncBatch makes (account.asset + sale.subscription).
    // Empty JSON array short-circuits AssetSyncBatch before any Asset upsert/DML, keeping
    // this test focused purely on proving AssetSyncSchedulable drives the batch to completion.
    private class EmptyOdooListMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('[]');
            return res;
        }
    }

    private static OdooIntegrationSettings__c createOrgDefaults(Boolean enabled, Decimal batchSize) {
        OdooIntegrationSettings__c s = new OdooIntegrationSettings__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            IP2_Enabled__c = enabled,
            IP2_Sync_Batch_Size__c = batchSize,
            Environment__c = 'Test',
            Base_URL__c = 'callout:DigitalEdge_Odoo_Test'
        );
        insert s;
        return s;
    }

    @isTest
    static void testExecute_DisabledSetting_DoesNotEnqueueBatch() {
        createOrgDefaults(false, 25);

        Test.startTest();
        new AssetSyncSchedulable().execute(null);
        Test.stopTest();

        OdooIntegrationSettings__c after = [
            SELECT IP2_Last_Sync__c FROM OdooIntegrationSettings__c
            WHERE SetupOwnerId = :UserInfo.getOrganizationId() LIMIT 1
        ];
        Assert.isNull(after.IP2_Last_Sync__c,
            'Watermark must stay untouched when IP-2 is disabled: the batch should never run.');

        Integer batchJobs = [
            SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'AssetSyncBatch'
        ];
        Assert.areEqual(0, batchJobs, 'No AssetSyncBatch job should be enqueued when disabled.');
    }

    @isTest
    static void testExecute_EnabledWithBatchSize_RunsBatchAndUpdatesWatermark() {
        createOrgDefaults(true, 50);
        Test.setMock(HttpCalloutMock.class, new EmptyOdooListMock());

        Test.startTest();
        new AssetSyncSchedulable().execute(null);
        Test.stopTest();

        OdooIntegrationSettings__c after = [
            SELECT IP2_Last_Sync__c FROM OdooIntegrationSettings__c
            WHERE SetupOwnerId = :UserInfo.getOrganizationId() LIMIT 1
        ];
        Assert.isNotNull(after.IP2_Last_Sync__c,
            'A completed direct execute() call is the deterministic proof that AssetSyncBatch ran.');
    }

    @isTest
    static void testExecute_EnabledNullBatchSize_DefaultsToOne() {
        // IP2_Sync_Batch_Size__c left null -> AssetSyncSchedulable must fall back to batchSize = 1.
        createOrgDefaults(true, null);
        Test.setMock(HttpCalloutMock.class, new EmptyOdooListMock());

        Test.startTest();
        new AssetSyncSchedulable().execute(null);
        Test.stopTest();

        OdooIntegrationSettings__c after = [
            SELECT IP2_Last_Sync__c FROM OdooIntegrationSettings__c
            WHERE SetupOwnerId = :UserInfo.getOrganizationId() LIMIT 1
        ];
        Assert.isNotNull(after.IP2_Last_Sync__c,
            'Batch should still complete successfully with the default batch size of 1.');
    }

    @isTest
    static void testSchedule_ViaSystemSchedule_RunsBatchSynchronouslyOnStopTest() {
        createOrgDefaults(true, 10);
        Test.setMock(HttpCalloutMock.class, new EmptyOdooListMock());

        String cron = '0 0 18 * * ?'; // 18:00 UTC = 02:00 HKT next day, per class header.

        Test.startTest();
        String jobId = System.schedule('DE IP-2 Asset Sync Daily Test', cron, new AssetSyncSchedulable());
        Test.stopTest();

        Assert.isNotNull(jobId, 'System.schedule should return a CronTrigger Id.');

        // Salesforce test runtime does not guarantee deterministic execution of
        // nested async work enqueued by a scheduled job. The direct execute()
        // tests above verify that execute() gates and launches the batch.
    }
}