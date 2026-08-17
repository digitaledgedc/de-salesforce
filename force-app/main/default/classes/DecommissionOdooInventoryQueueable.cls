/**
 * DecommissionOdooInventoryQueueable
 * IP-3 (SF→Odoo): Sends event_type "decommission" to archive Inventory record(s) in Odoo.
 * Enqueued from InventoryTriggerHandler.handleAfterUpdate whenever Status__c transitions
 * to 'Decommissioned', regardless of the code path that made the change (LWC, Data Loader,
 * API, other Apex).
 *
 * Odoo endpoint: POST /api/v1/create_inventory  (event_type: "decommission")
 *
 * GOVERNOR LIMIT: Max 100 callouts per async transaction. Each Inventory record
 * consumes one callout. Batches larger than 100 self-chain: records beyond the
 * first 100 are deferred to a follow-up DecommissionOdooInventoryQueueable job.
 */
public without sharing class DecommissionOdooInventoryQueueable implements Queueable, Database.AllowsCallouts {

    @TestVisible private static final Integer MAX_CALLOUTS = 100;

    private List<Id> inventoryIds;

    public DecommissionOdooInventoryQueueable(List<Id> inventoryIds) {
        this.inventoryIds = inventoryIds;
    }

    public void execute(QueueableContext ctx) {
        OdooIntegrationSettings__c settings = OdooIntegrationSettings__c.getOrgDefaults();

        List<Inventory__c> records = [
            SELECT Id, Name, RecordType.DeveloperName, Odoo_Space_ID__c, Odoo_Inventory_Id__c,
                   Status__c, Site_Id__r.Odoo_Site_ID__c, Site_Id__r.Site_Code__c, Site_Id__r.Odoo_Company_ID__c
            FROM Inventory__c
            WHERE Id IN :inventoryIds
        ];

        List<DE_Integration_Error__c> errorsToInsert = new List<DE_Integration_Error__c>();
        List<Inventory__c> toUpdate = new List<Inventory__c>();
        List<Id> deferredIds = new List<Id>();
        Integer calloutCount = 0;

        for (Inventory__c inv : records) {
            Boolean isSpace = inv.RecordType.DeveloperName == 'Inventory_Space';
            String odooId   = isSpace ? inv.Odoo_Space_ID__c : inv.Odoo_Inventory_Id__c;

            if (String.isBlank(odooId)) {
                System.debug('IP-3 DECOMMISSION ▶ Skipped ' + inv.Name + ' — no Odoo ID set');
                continue;
            }

            if (calloutCount >= MAX_CALLOUTS) {
                deferredIds.add(inv.Id);
                continue;
            }

            String invType = isSpace ? 'space' : 'breaker';

            JSONGenerator gen = JSON.createGenerator(false);
            gen.writeStartObject();
            gen.writeFieldName('params');
            gen.writeStartObject();
            gen.writeStringField('username', settings.Username__c != null ? settings.Username__c : '');
            gen.writeStringField('password', settings.Password__c != null ? settings.Password__c : '');
            gen.writeStringField('inventory_type', invType);
            gen.writeStringField('event_type', 'decommission');
            gen.writeNumberField('inventory_id', Integer.valueOf(odooId));
            gen.writeFieldName('data');
            gen.writeStartObject();
            gen.writeStringField('ns_name', inv.Name);
            gen.writeBooleanField('active', false);
            if (inv.Site_Id__r.Odoo_Company_ID__c != null) gen.writeNumberField('company_id', inv.Site_Id__r.Odoo_Company_ID__c);
            gen.writeEndObject(); // data
            gen.writeEndObject(); // params
            gen.writeEndObject(); // root

            String payload = gen.getAsString();
            System.debug('IP-3 DECOMMISSION ▶ ' + inv.Name + ' (Odoo ID: ' + odooId + '): ' + payload);

            OdooCalloutService.Response resp =
                OdooCalloutService.post('/api/v1/create_inventory', payload);
            calloutCount++;

            if (resp.isSuccess) {
                toUpdate.add(new Inventory__c(
                    Id                   = inv.Id,
                    Last_Synced__c       = Datetime.now(),
                    Odoo_Sync_Payload__c = payload,
                    Odoo_Sync_Error__c   = null));
                System.debug('IP-3 DECOMMISSION ▶ SUCCESS — ' + inv.Name);
            } else {
                toUpdate.add(new Inventory__c(
                    Id                   = inv.Id,
                    Odoo_Sync_Payload__c = payload,
                    Odoo_Sync_Error__c   = resp.errorBody));
                errorsToInsert.add(new DE_Integration_Error__c(
                    Record_Id__c       = String.valueOf(inv.Id),
                    IP_Reference__c    = 'IP-3',
                    Error_Message__c   = 'Failed to decommission ' + inv.Name + ' in Odoo: ' + resp.errorBody,
                    Status__c          = 'Open',
                    Request_Payload__c = payload));
                System.debug('IP-3 DECOMMISSION ▶ FAILED — ' + inv.Name + ': ' + resp.errorBody);
            }
        }

        if (!toUpdate.isEmpty()) update toUpdate;
        if (!errorsToInsert.isEmpty()) insert errorsToInsert;

        if (!deferredIds.isEmpty() && !Test.isRunningTest()) {
            System.enqueueJob(new DecommissionOdooInventoryQueueable(deferredIds));
        }
    }
}