/**
 * CreateOdooInventoryQueueable
 * IP-3 (SF→Odoo): Pushes newly created Inventory records to Odoo.
 * Called after inventory creation in DeInventoryManagerController (both create and import).
 *
 * Odoo endpoint: POST /api/v1/create_inventory
 *
 * Payload structure:
 *   { "params": { "username", "password", "inventory_type": "space"|"breaker",
 *     "event_type": "create", "data": { ...fields... } } }
 *
 * On success: writes back Odoo ID to both Odoo_Space_ID__c (primary integration key,
 * VR_INV_08 immutable) and Odoo_Inventory_Id__c (used by IP-3 inbound handler for matching).
 * On failure: creates DE_Integration_Error__c per failed record.
 *
 * GOVERNOR LIMIT: Max 100 callouts per async transaction. Each Inventory record
 * consumes one callout. Batches larger than 100 self-chain: records beyond the
 * first 100 are deferred to a follow-up CreateOdooInventoryQueueable job, so a
 * single large import (e.g. 2000 records) eventually syncs all of them instead
 * of silently giving up after the first 100.
 */
public without sharing class CreateOdooInventoryQueueable implements Queueable, Database.AllowsCallouts {

    @TestVisible private static final Integer MAX_CALLOUTS = 100;

    private List<Id> inventoryIds;

    public CreateOdooInventoryQueueable(List<Id> inventoryIds) {
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
        'Cabinet'       => 'Cabinet',
        'Cage'          => 'Cage',
        'Data Hall'     => 'Hall',
        'Hall'          => 'Hall',
        'Power Circuit' => 'power_circuit'
    };

    public void execute(QueueableContext ctx) {
        OdooIntegrationSettings__c settings = OdooIntegrationSettings__c.getOrgDefaults();

        List<Inventory__c> records = [
            SELECT Id, Name, RecordType.DeveloperName,
                   Status__c, Space_Type__c, Capacity_Type__c,
                   Unit_Reference__c, Hall__c, Breaker_Panel__c,
                   Total_Capacity_kVA__c, Total_IT_Power_kVA__c,
                   CabE_Count__c, Total_Area_sqm__c,
                   Power_kVA__c, Power_Circuit_kVA__c, Total_kW__c,
                   Odoo_Inventory_Id__c, Odoo_Space_ID__c,
                   Notes__c,
                   Site_Id__r.Odoo_Site_ID__c, Site_Id__r.Site_Code__c,
                   Data_Hall__r.Name,Site_Id__r.odoo_company_Id__c,
                   Account__r.Odoo_Partner_ID__c
            FROM Inventory__c
            WHERE Id IN :inventoryIds
        ];

        List<Inventory__c> toUpdate = new List<Inventory__c>();
        List<DE_Integration_Error__c> errorsToInsert = new List<DE_Integration_Error__c>();
        List<Id> deferredIds = new List<Id>();
        Integer calloutCount = 0;

        for (Inventory__c inv : records) {
            if (String.isNotBlank(inv.Odoo_Space_ID__c)) {
                continue;
            }

            if (calloutCount >= MAX_CALLOUTS) {
                deferredIds.add(inv.Id);
                continue;
            }

            String payload = buildPayload(inv, settings);
            System.debug('IP-3 ▶ Creating ' + inv.Name + ' in Odoo: ' + payload);

            OdooCalloutService.Response resp =
                OdooCalloutService.post('/api/v1/create_inventory', payload);
            calloutCount++;

            if (resp.isSuccess) {
                Integer odooId = parseIntFromResult(resp.rawBody, 'inventory_id');
                if (odooId == null) odooId = parseIntFromResult(resp.rawBody, 'space_id');
                if (odooId == null) odooId = parseIntFromResult(resp.rawBody, 'breaker_id');
                if (odooId == null) odooId = resp.odooId;

                if (odooId != null && odooId > 0) {
                    Inventory__c upd = new Inventory__c(Id = inv.Id);
                    upd.Odoo_Space_ID__c      = String.valueOf(odooId);
                    upd.Odoo_Inventory_Id__c  = String.valueOf(odooId);
                    upd.Last_Synced__c        = Datetime.now();
                    upd.Odoo_Sync_Payload__c  = payload;
                    upd.Odoo_Sync_Error__c    = null;
                    toUpdate.add(upd);
                    System.debug('IP-3 ▶ SUCCESS — ' + inv.Name + ' → Odoo ID: ' + odooId);
                } else {
                    String errMsg = 'Odoo returned success but no valid inventory ID. Raw response: '
                        + truncate(resp.rawBody, 500);
                    toUpdate.add(new Inventory__c(
                        Id = inv.Id,
                        Odoo_Sync_Payload__c = payload,
                        Odoo_Sync_Error__c   = errMsg));
                    errorsToInsert.add(new DE_Integration_Error__c(
                        Record_Id__c = String.valueOf(inv.Id), IP_Reference__c = 'IP-3',
                        Error_Message__c = errMsg,
                        Status__c = 'Open', Request_Payload__c = payload));
                }
            } else {
                String errMsg = 'Failed to create ' + inv.Name + ' in Odoo: ' + resp.errorBody;
                toUpdate.add(new Inventory__c(
                    Id = inv.Id,
                    Odoo_Sync_Payload__c = payload,
                    Odoo_Sync_Error__c   = truncate(resp.errorBody, 32000)));
                errorsToInsert.add(new DE_Integration_Error__c(
                    Record_Id__c = String.valueOf(inv.Id), IP_Reference__c = 'IP-3',
                    Error_Message__c = errMsg,
                    Status__c = 'Open', Request_Payload__c = payload));
                System.debug('IP-3 ▶ FAILED — ' + inv.Name + ': ' + resp.errorBody);
            }
        }

        if (!toUpdate.isEmpty()) update toUpdate;
        if (!errorsToInsert.isEmpty()) insert errorsToInsert;

        if (!deferredIds.isEmpty() && !Test.isRunningTest()) {
            System.enqueueJob(new CreateOdooInventoryQueueable(deferredIds));
        }
    }

    @TestVisible
    private String buildPayload(Inventory__c inv, OdooIntegrationSettings__c settings) {
        Boolean isSpace = inv.RecordType.DeveloperName == 'Inventory_Space';
        String invType = isSpace ? 'space' : 'breaker';

        JSONGenerator gen = JSON.createGenerator(false);
        gen.writeStartObject();
        gen.writeFieldName('params');
        gen.writeStartObject();

        gen.writeStringField('username', settings.Username__c != null ? settings.Username__c : '');
        gen.writeStringField('password', settings.Password__c != null ? settings.Password__c : '');
        gen.writeStringField('inventory_type', invType);
        gen.writeStringField('event_type', 'create');

        gen.writeFieldName('data');
        gen.writeStartObject();

        //gen.writeStringField('model_type', isSpace ? 'ns.ns_space' : 'ns.ns_breaker');
        gen.writeStringField('ns_name', inv.Name);

        if (inv.Unit_Reference__c != null) gen.writeStringField('display_name', inv.Unit_Reference__c);

        if (inv.Status__c != null) {
            String stage = STATUS_TO_STAGE.get(inv.Status__c);
            if (stage != null) gen.writeStringField('ns_stage', stage);
        }

        if (inv.Site_Id__r != null && inv.Site_Id__r.Odoo_Site_ID__c != null
                && inv.Site_Id__r.Odoo_Site_ID__c != 0) {
            gen.writeNumberField('ns_operation_site', Integer.valueOf(inv.Site_Id__r.Odoo_Site_ID__c));
        }

        

        if (inv.Account__r != null && inv.Account__r.Odoo_Partner_ID__c != null
                && inv.Account__r.Odoo_Partner_ID__c != 0) {
            gen.writeNumberField('ns_customer', Integer.valueOf(inv.Account__r.Odoo_Partner_ID__c));
        }

        if (isSpace) {
            if (inv.Space_Type__c != null) {
                String odooType = SPACE_TYPE_TO_ODOO.get(inv.Space_Type__c);
                if (odooType != null) gen.writeStringField('space_type', odooType);
            }
            if (inv.Data_Hall__r != null && inv.Data_Hall__r.Name != null) {
                gen.writeStringField('ns_room_name', inv.Data_Hall__r.Name);
            }
            if (inv.CabE_Count__c != null) gen.writeNumberField('rack_units', Integer.valueOf(inv.CabE_Count__c));
            //if (inv.Total_IT_Power_kVA__c != null && inv.Total_IT_Power_kVA__c != 0.00 ) gen.writeNumberField('it_power_kva', inv.Total_IT_Power_kVA__c);
        } else {
            //if (inv.Breaker_Panel__c != null) gen.writeStringField('parent_equipment', inv.Breaker_Panel__c);
            if (String.isNotBlank(inv.Odoo_Inventory_Id__c)) gen.writeStringField('external_id', inv.Odoo_Inventory_Id__c);
        }
		if(inv.Site_Id__r.Odoo_Company_ID__c != null) gen.writeNumberField('company_id', inv.Site_Id__r.Odoo_Company_ID__c );
        if (inv.Unit_Reference__c != null) gen.writeStringField('other_name', inv.Unit_Reference__c);
        //system.assert(false,(inv.Total_Capacity_kVA__c != null && inv.Total_Capacity_kVA__c != 0.00 )+ 'ds');
        if (inv.Total_Capacity_kVA__c != null && inv.Total_Capacity_kVA__c != 0.00) gen.writeNumberField('it_power_kva', inv.Total_Capacity_kVA__c);
        if (inv.Total_Area_sqm__c != null) gen.writeNumberField('total_area', inv.Total_Area_sqm__c);

        gen.writeEndObject(); // data
        gen.writeEndObject(); // params
        gen.writeEndObject(); // root

        return gen.getAsString();
    }

    private static Integer parseIntFromResult(String rawBody, String fieldName) {
        try {
            Map<String,Object> parsed = (Map<String,Object>) JSON.deserializeUntyped(rawBody);
            Map<String,Object> result = (Map<String,Object>) parsed.get('result');
            if (result != null && result.get(fieldName) != null) {
                return Integer.valueOf(result.get(fieldName));
            }
        } catch (Exception e) {
            // fall through
        }
        return null;
    }

    private static String truncate(String s, Integer maxLen) {
        if (s == null) return '';
        return s.length() > maxLen ? s.substring(0, maxLen) + '...[truncated]' : s;
    }
}