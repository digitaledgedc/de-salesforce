/**
 * AssetSyncSchedulable
 * Schedules AssetSyncBatch (IP-2) at 02:00 HKT daily.
 *
 * To activate, run via Anonymous Apex:
 *   String cron = '0 0 18 * * ?'; // 18:00 UTC = 02:00 HKT next day
 *   System.schedule('DE IP-2 Asset Sync Daily', cron, new AssetSyncSchedulable());
 */
global class AssetSyncSchedulable implements Schedulable {
    global void execute(SchedulableContext sc) {
        OdooIntegrationSettings__c s = OdooIntegrationSettings__c.getOrgDefaults();
        if (s.IP2_Enabled__c != true) return;
        Integer batchSize = s.IP2_Sync_Batch_Size__c != null
                            ? Integer.valueOf(s.IP2_Sync_Batch_Size__c) : 1;
        Database.executeBatch(new AssetSyncBatch(), batchSize);
    }
}