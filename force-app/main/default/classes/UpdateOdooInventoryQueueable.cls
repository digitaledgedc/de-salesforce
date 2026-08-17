/**
 * UpdateOdooInventoryQueueable
 * IP-3 (SF→Odoo): Pushes field updates to existing Inventory records in Odoo.
 * Enqueued from InventoryTriggerHandler.handleAfterUpdate when tracked fields change
 * and Odoo_Space_ID__c is populated.
 *
 * Odoo endpoint: POST /api/v1/create_inventory  (event_type: "update")
 *
 * Tracked fields: Name, Status__c, Space_Type__c, Site_Id__c, Data_Hall__c,
 *                 Hall__c, CabE_Count__c, Breaker_Panel__c, Notes__c
 *
 * GOVERNOR LIMIT: Max 100 callouts per async transaction. Each Inventory record
 * consumes one callout. Batches larger than 100 self-chain: records beyond the
 * first 100 are deferred to a follow-up UpdateOdooInventoryQueueable job, so a
 * large bulk update eventually syncs all of them instead of throwing an
 * unhandled CalloutException past the 100th record.
 */
public without sharing class UpdateOdooInventoryQueueable implements Queueable, Database.AllowsCallouts {

    @TestVisible private static final Integer MAX_CALLOUTS = 100;

    private List<Id> inventoryIds;

    public UpdateOdooInventoryQueueable(List<Id> inventoryIds) {
        this.inventoryIds = inventoryIds;
    }

    private static final Map<String, String> STATUS_TO_STAGE = new Map<String, String>{
        'Available'         => 'available',
        'Reserved'          => 'reserved',
        'Assigned'          => 'assigned',
        'Sold'              => 'sold',
        'Installed'         => 'installed',
        'Pending Available' => 'pending_available',
        'Stranded'          => 'stranded',
        'Decommissioned'    => 'decommissioned',
        'Quoted'            => 'quoted'
    };

    private static final Map<String, String> SPACE_TYPE_TO_ODOO = new Map<String, String>{
        'Cabinet'       => 'cabinet',
        'Cage'          => 'cage',
        'Data Hall'     => 'hall',
        'Hall'          => 'hall',
        'Power Circuit' => 'power_circuit'
    };

    public void execute(QueueableContext ctx) {
        OdooIntegrationSettings__c settings = OdooIntegrationSettings__c.getOrgDefaults();

        List<Inventory__c> records = [
            SELECT Id, Name, RecordType.DeveloperName,
                   Odoo_Space_ID__c, Odoo_Inventory_Id__c,
                   Status__c, Space_Type__c, Capacity_Type__c,
                   Unit_Reference__c, Hall__c, Breaker_Panel__c,
                   Total_Capacity_kVA__c, Total_IT_Power_kVA__c,
                   CabE_Count__c, Total_Area_sqm__c,
                   Power_kVA__c, Power_Circuit_kVA__c, Total_kW__c,
                   Notes__c,
                   Site_Id__r.Odoo_Site_ID__c, Site_Id__r.Site_Code__c,
                   Data_Hall__r.Name,Site_Id__r.Odoo_Company_ID__c ,
                   Account__r.Odoo_Partner_ID__c
            FROM Inventory__c
            WHERE Id IN :inventoryIds
              AND (Odoo_Space_ID__c != null OR Odoo_Inventory_Id__c != null)
        ];

        List<DE_Integration_Error__c> errorsToInsert = new List<DE_Integration_Error__c>();
        List<Inventory__c> toUpdate = new List<Inventory__c>();
        List<Id> deferredIds = new List<Id>();
        Integer calloutCount = 0;

        for (Inventory__c inv : records) {
            Boolean invIsSpace = inv.RecordType.DeveloperName == 'Inventory_Space';
            String odooRefId = invIsSpace ? inv.Odoo_Space_ID__c : inv.Odoo_Inventory_Id__c;
            if (String.isBlank(odooRefId)) continue;

            if (calloutCount >= MAX_CALLOUTS) {
                deferredIds.add(inv.Id);
                continue;
            }

            String payload = buildPayload(inv, settings);
            if (payload == null) continue;
            System.debug('IP-3 UPDATE ▶ ' + inv.Name + ' (Odoo ID: ' + odooRefId + '): ' + payload);

            OdooCalloutService.Response resp =
                OdooCalloutService.post('/api/v1/create_inventory', payload);
            calloutCount++;

            if (resp.isSuccess) {
                toUpdate.add(new Inventory__c(
                    Id                   = inv.Id,
                    Last_Synced__c       = Datetime.now(),
                    Odoo_Sync_Payload__c = payload,
                    Odoo_Sync_Error__c   = null));
                System.debug('IP-3 UPDATE ▶ SUCCESS — ' + inv.Name);
            } else {
                toUpdate.add(new Inventory__c(
                    Id                   = inv.Id,
                    Odoo_Sync_Payload__c = payload,
                    Odoo_Sync_Error__c   = resp.errorBody));
                errorsToInsert.add(new DE_Integration_Error__c(
                    Record_Id__c     = String.valueOf(inv.Id),
                    IP_Reference__c  = 'IP-3',
                    Error_Message__c = 'Failed to update ' + inv.Name + ' in Odoo: ' + resp.errorBody,
                    Status__c        = 'Open',
                    Request_Payload__c = payload));
                System.debug('IP-3 UPDATE ▶ FAILED — ' + inv.Name + ': ' + resp.errorBody);
            }
        }

        if (!toUpdate.isEmpty()) update toUpdate;
        if (!errorsToInsert.isEmpty()) insert errorsToInsert;

        if (!deferredIds.isEmpty() && !Test.isRunningTest()) {
            System.enqueueJob(new UpdateOdooInventoryQueueable(deferredIds));
        }
    }

    private String buildPayload(Inventory__c inv, OdooIntegrationSettings__c settings) {
        Boolean isSpace = inv.RecordType.DeveloperName == 'Inventory_Space';
        String invType = isSpace ? 'space' : 'breaker';

        JSONGenerator gen = JSON.createGenerator(false);
        gen.writeStartObject();
        gen.writeFieldName('params');
        gen.writeStartObject();
		String odooId = isSpace ? inv.Odoo_Space_ID__c : inv.Odoo_Inventory_Id__c;
		if (String.isBlank(odooId)) return null;
        gen.writeNumberField('inventory_id', Integer.valueOf(odooId));
        gen.writeStringField('username', settings.Username__c != null ? settings.Username__c : '');
        gen.writeStringField('password', settings.Password__c != null ? settings.Password__c : '');
        gen.writeStringField('inventory_type', invType);
        gen.writeStringField('event_type', 'update');

        gen.writeFieldName('data');
        gen.writeStartObject();


        //gen.writeStringField('model_type', isSpace ? 'ns.ns_space' : 'ns.ns_breaker');

        gen.writeStringField('ns_name', inv.Name);

        if (inv.Status__c != null) {
            String stage = STATUS_TO_STAGE.get(inv.Status__c);
            if (stage != null) gen.writeStringField('ns_stage', stage);
        }
		if(inv.Site_Id__r.Odoo_Company_ID__c != null) gen.writeNumberField('company_id', inv.Site_Id__r.Odoo_Company_ID__c );


        gen.writeEndObject(); // data
        gen.writeEndObject(); // params
        gen.writeEndObject(); // root

        return gen.getAsString();
    }
}