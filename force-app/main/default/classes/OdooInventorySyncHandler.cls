/**
 * OdooInventorySyncHandler
 * IP-3 (Odoo→SF): Inbound REST endpoint for inventory/space synchronization.
 *
 * Endpoint: POST /services/apexrest/de/inventory
 *
 * Odoo posts one inventory record per request when a physical space (ns.ns_space)
 * or breaker (ns.ns_breaker) is created, updated, or decommissioned.
 *
 * model_type mapping:
 *   ns.ns_space   → RecordType Inventory_Space (cabinets, cages, data halls)
 *   ns.ns_breaker → RecordType Inventory_Breaker (power circuits)
 *
 * Odoo ns_stage values map to SF Status__c picklist:
 *   available → Available, reserved → Reserved, assigned → Assigned,
 *   sold → Sold, installed → Installed, pending_available → Pending Available,
 *   stranded → Stranded, decommissioned → Decommissioned
 *
 * Lookup uses Odoo_Inventory_Id__c. Legacy records may store prefixed IDs
 * (SPC-32196, BRK-3659); the handler matches both bare integers and
 * prefixed values in a single query.
 *
 * Validation rule awareness:
 *   VR_INV_09: Unit_Reference__c is immutable after creation — only set on create.
 *   VR_INV_02: Reserved status requires Order__c — skipped with warning if no Order.
 *   Status_Decommission_Manual_Only: Available → Decommissioned blocked — set Stranded first.
 *
 * Auth: OAuth2 bearer token (Connected App), same as IP-2.
 */
@RestResource(urlMapping='/de/inventory')
global with sharing class OdooInventorySyncHandler {

    // ─── DTO ──────────────────────────────────────────────────────────────────

    @TestVisible
    class InventoryPayload {
        public String  event_type;   // create | update | decommission
        public String  model_type;   // ns.ns_space | ns.ns_breaker
        public Long    id;           // Odoo ns.ns_space or ns.ns_breaker integer ID
        public String  ns_name;      // Human-readable space label
        public String  ns_stage;     // Odoo lifecycle stage → SF Status__c
        public Decimal capacity_kva; // Power capacity (kVA)
        public Integer rack_units;   // Number of CabE → CabE_Count__c
        public Long    ns_operation_site; // Odoo m2o → Site_Id__c (via Odoo_Site_ID__c)
        public Long    ns_room;          // Odoo m2o for room (reserved for future Odoo ID on DataHall)
        public String  ns_room_name;     // Room name → Data_Hall__c (lookup by Name)
        public Decimal it_power_kva;     // IT Power (kVA) → Total_IT_Power_kVA__c
        public String  space_type;       // cabinet | cage | hall → Space_Type__c
        public String  display_name;     // Display Name → Unit_Reference__c (CREATE ONLY)
        public String  other_name;       // Other Space/Breaker Name → Hall__c
        public String  parent_equipment; // Parent Power Equipment → Breaker_Panel__c
        public Long    ns_customer;      // Odoo partner ID → Account__c (via Odoo_Partner_ID__c)
        public String  external_id;      // Odoo external_id → Odoo_Inventory_Id__c
        public Decimal total_area;       // Area (sqm) → Total_Area_sqm__c
    }

    // ─── Constants ────────────────────────────────────────────────────────────

    private static final Map<String, String> MODEL_TO_RT = new Map<String, String>{
        'ns.ns_space'   => 'Inventory_Space',
        'ns.ns_breaker' => 'Inventory_Breaker'
    };

    private static final Map<String, String> STAGE_TO_STATUS = new Map<String, String>{
        'available'         => 'Available',
        'reserved'          => 'Reserved',
        'assigned'          => 'Assigned',
        'sold'              => 'Sold',
        'installed'         => 'Installed',
        'pending_available' => 'Pending Available',
        'stranded'          => 'Stranded',
        'decommissioned'    => 'Decommissioned',
        'quoted'            => 'Quoted'
    };

    private static final Map<String, String> SPACE_TYPE_MAP = new Map<String, String>{
        'cabinet'       => 'Cabinet',
        'cage'          => 'Cage',
        'hall'          => 'Data Hall',
        'data hall'     => 'Data Hall',
        'data_hall'     => 'Data Hall',
        'power_circuit' => 'Power Circuit',
        'power circuit' => 'Power Circuit'
    };

    // Collects non-fatal issues during processing
    private static List<String> warnings = new List<String>();

    // ─── Entry point ──────────────────────────────────────────────────────────

    @HttpPost
    global static void handlePost() {
        RestRequest  req = RestContext.request;
        RestResponse res = RestContext.response;
        warnings.clear();

        try {
            InventoryPayload p = (InventoryPayload) JSON.deserialize(
                req.requestBody.toString(), InventoryPayload.class);

            if (p.event_type == null) {
                sendError(res, 400, 'event_type is required');
                return;
            }
            if (p.model_type == null || !MODEL_TO_RT.containsKey(p.model_type)) {
                sendError(res, 400, 'model_type must be ns.ns_space or ns.ns_breaker');
                return;
            }
            if (p.id == null) {
                sendError(res, 400, 'id is required');
                return;
            }

            Id sfRecordId;
            if      (p.event_type == 'create')       sfRecordId = handleCreate(p);
            else if (p.event_type == 'update')        sfRecordId = handleUpdate(p);
            else if (p.event_type == 'decommission')  sfRecordId = handleDecommission(p);
            else {
                sendError(res, 400, 'unknown event_type: ' + jsonSafe(p.event_type));
                return;
            }

            Map<String, Object> response = new Map<String, Object>{
                'status'          => 'ok',
                'sf_inventory_id' => sfRecordId
            };
            if (!warnings.isEmpty()) {  response.put('warnings', warnings);
            }

            res.statusCode = 200;
            res.responseBody = Blob.valueOf(JSON.serialize(response));

        } catch (InventorySyncException e) {
            sendError(res, 422, e.getMessage()); } catch (Exception e) { sendError(res, 500, e.getMessage());
        }
    }

    // ─── CREATE ───────────────────────────────────────────────────────────────
    // Idempotent: if a record with the same Odoo ID already exists, delegates to update.

    private static Id handleCreate(InventoryPayload p) {
        String odooId = String.valueOf(p.id);

        // Check for existing record (idempotent create)
        List<Inventory__c> existing = findByOdooId(odooId, p.model_type);
        if (!existing.isEmpty()) {
            return handleUpdateRecord(existing[0], p);
        }

        if (!Schema.sObjectType.Inventory__c.isCreateable()) {  throw new InventorySyncException('Insufficient permissions to create Inventory');
        }

        Id rtId = Schema.SObjectType.Inventory__c.getRecordTypeInfosByDeveloperName()
            .get(MODEL_TO_RT.get(p.model_type)).getRecordTypeId();

        Inventory__c inv = new Inventory__c(
            RecordTypeId   = rtId,
            Name           = p.ns_name != null ? p.ns_name : 'INV-' + odooId,
            Status__c      = mapStage(p.ns_stage, 'Available'),
            Last_Synced__c = Datetime.now()
        );
        if (p.model_type == 'ns.ns_space') {
            inv.Odoo_Space_ID__c = odooId;
        } else {
            inv.Odoo_Inventory_Id__c = odooId;
        }

        applyOptionalFields(inv, p, true);
        insert inv;
        return inv.Id;
    }

    // ─── UPDATE ───────────────────────────────────────────────────────────────

    private static Id handleUpdate(InventoryPayload p) {
        String odooId = String.valueOf(p.id);
        List<Inventory__c> records = findByOdooId(odooId, p.model_type);
        if (records.isEmpty()) {
            throw new InventorySyncException(
                'No Inventory record found matching Odoo id ' + odooId + ' (model_type: ' + p.model_type + ')');
        }

        if (!Schema.sObjectType.Inventory__c.isUpdateable()) { throw new InventorySyncException('Insufficient permissions to update Inventory');
        }

        Inventory__c inv = records[0];

        if (p.ns_stage != null) {
            String targetStatus = mapStage(p.ns_stage, inv.Status__c);
            // VR_INV_02: Reserved requires Order__c — skip if no Order linked
            if (targetStatus == 'Reserved' && inv.Order__c == null) {
                warnings.add('Status "Reserved" skipped — VR_INV_02 requires Order linkage. '
                    + 'Current status (' + inv.Status__c + ') retained. '
                    + 'Odoo stage: ' + p.ns_stage);
            } else {
                inv.Status__c = targetStatus;
            }
        }
        // When Odoo confirms inventory is back to available after termination,
        // clear all assignment fields so the inventory is fully reset for future orders.
        if ('available'.equalsIgnoreCase(p.ns_stage)) {
            inv.Account__c = null;inv.Order__c = null;inv.Order_Item__c = null;inv.Assigned_To_Order__c = null;  inv.Account__c  = null;
            inv.Assigned_To_Quote__c = null; inv.Quote_Line__c  = null; inv.Contract_End__c = null; inv.SCD__c = null;
        }
        inv.Last_Synced__c = Datetime.now();
        update inv;
        return inv.Id;
    }

    private static Id handleUpdateRecord(Inventory__c inv, InventoryPayload p) {
        if (!Schema.sObjectType.Inventory__c.isUpdateable()) { throw new InventorySyncException('Insufficient permissions to update Inventory');
        }

        if (p.ns_name != null)  inv.Name = p.ns_name;
        if (p.ns_stage != null) {
            String targetStatus = mapStage(p.ns_stage, inv.Status__c);
            // VR_INV_02: Reserved requires Order__c — skip if no Order linked
            if (targetStatus == 'Reserved' && inv.Order__c == null) {
                warnings.add('Status "Reserved" skipped — VR_INV_02 requires Order linkage. '
                    + 'Current status (' + inv.Status__c + ') retained. '
                    + 'Odoo stage: ' + p.ns_stage);
            } else { inv.Status__c = targetStatus;
            }
        }
        inv.Last_Synced__c = Datetime.now();

        applyOptionalFields(inv, p, false);
        update inv;
        return inv.Id;
    }

    // ─── DECOMMISSION ─────────────────────────────────────────────────────────

    private static Id handleDecommission(InventoryPayload p) {
        String odooId = String.valueOf(p.id);
        List<Inventory__c> records = findByOdooId(odooId, p.model_type);
        if (records.isEmpty()) {
            throw new InventorySyncException(
                'No Inventory record found matching Odoo id ' + odooId + ' (model_type: ' + p.model_type + ')');
        }

        if (!Schema.sObjectType.Inventory__c.isUpdateable()) { throw new InventorySyncException('Insufficient permissions to update Inventory');
        }

        Inventory__c inv = records[0];

        // Status_Decommission_Manual_Only: Available → Decommissioned is blocked.
        // Transition through Stranded first if currently Available.
        if (inv.Status__c == 'Available') {inv.Status__c = 'Stranded';inv.Last_Synced__c = Datetime.now(); update inv;
            warnings.add('Intermediate status set to Stranded (was Available). '
                + 'VR blocks direct Available → Decommissioned.');
            // Re-query to get updated record for second DML
            inv = [SELECT Id, Status__c, Last_Synced__c FROM Inventory__c WHERE Id = :inv.Id];
        }

        inv.Status__c      = 'Decommissioned';
        inv.Last_Synced__c = Datetime.now();
        update inv;
        return inv.Id;
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    /**
     * Finds Inventory__c by Odoo integer ID, using the correct field per model_type:
     *   ns.ns_space   → Odoo_Space_ID__c  (also matches legacy "SPC-{id}" prefix)
     *   ns.ns_breaker → Odoo_Inventory_Id__c (also matches legacy "BRK-{id}" prefix)
     * Includes Order__c for VR_INV_02 check.
     */
    @TestVisible
    private static List<Inventory__c> findByOdooId(String odooId, String modelType) {
        if (modelType == 'ns.ns_space') {
            String spcPrefixed = 'SPC-' + odooId;
            return [
                SELECT Id, Name, Status__c,
                       Total_Capacity_kVA__c, Total_IT_Power_kVA__c,
                       CabE_Count__c, Space_Type__c, Unit_Reference__c,
                       Hall__c, Breaker_Panel__c, Odoo_Inventory_Id__c,
                       Total_Area_sqm__c, Site_Id__c, Data_Hall__c,
                       Floor__c, Account__c, Order__c,
                       Order_Item__c, Assigned_To_Order__c, Quote_Line__c
                FROM Inventory__c
                WHERE Odoo_Space_ID__c IN (:odooId, :spcPrefixed)
                LIMIT 1
            ];
        } else {
            String brkPrefixed = 'BRK-' + odooId;
            return [
                SELECT Id, Name, Status__c,
                       Total_Capacity_kVA__c, Total_IT_Power_kVA__c,
                       CabE_Count__c, Space_Type__c, Unit_Reference__c,
                       Hall__c, Breaker_Panel__c, Odoo_Inventory_Id__c,
                       Total_Area_sqm__c, Site_Id__c, Data_Hall__c,
                       Floor__c, Account__c, Order__c,
                       Order_Item__c, Assigned_To_Order__c, Quote_Line__c
                FROM Inventory__c
                WHERE Odoo_Inventory_Id__c IN (:odooId, :brkPrefixed)
                LIMIT 1
            ];
        }
    }

    /**
     * Applies optional payload fields to the Inventory record.
     * isCreate=true on first insert; false on updates (including idempotent create).
     * VR_INV_09: Unit_Reference__c is immutable after creation — only set when isCreate=true.
     */
    private static void applyOptionalFields(Inventory__c inv, InventoryPayload p, Boolean isCreate) {
        // ── Scalar fields ──
        if (p.capacity_kva != null)     inv.Total_Capacity_kVA__c = p.capacity_kva;
        if (p.it_power_kva != null)     inv.Total_IT_Power_kVA__c = p.it_power_kva;
        if (p.rack_units != null)       inv.CabE_Count__c = p.rack_units;
        if (p.space_type != null)       inv.Space_Type__c = mapSpaceType(p.space_type);
        if (p.other_name != null)       inv.Hall__c = p.other_name;
        if (p.parent_equipment != null) inv.Breaker_Panel__c = p.parent_equipment;
        if (p.external_id != null)      inv.Odoo_Inventory_Id__c = p.external_id;
        if (p.total_area != null)       inv.Total_Area_sqm__c = p.total_area;

        // VR_INV_09: Unit_Reference__c is immutable — only set on initial create
        if (p.display_name != null && isCreate) {
            inv.Unit_Reference__c = p.display_name;
        } else if (p.display_name != null && !isCreate) {warnings.add('display_name ignored on update — Unit_Reference__c is immutable (VR_INV_09).');
        }

        // ── Lookup: Site by Odoo_Site_ID__c ──
        if (p.ns_operation_site != null) {
            Decimal siteOdooId = p.ns_operation_site;
            List<Site__c> sites = [
                SELECT Id FROM Site__c
                WHERE Odoo_Site_ID__c = :siteOdooId
                LIMIT 1
            ];
            if (!sites.isEmpty()) {
                inv.Site_Id__c = sites[0].Id;
            }
        }

        // ── Lookup: DataHall by Name, scoped to Site when known ──
        if (p.ns_room_name != null) {
            String roomName = p.ns_room_name;
            Id siteId = inv.Site_Id__c;
            List<DataHall__c> halls;
            if (siteId != null) {
                halls = [
                    SELECT Id, Floor__c FROM DataHall__c
                    WHERE Name = :roomName AND Site__c = :siteId
                    LIMIT 1
                ];
            } else { halls = [ SELECT Id, Floor__c FROM DataHall__c WHERE Name = :roomName LIMIT 1]; }
            if (!halls.isEmpty()) {
                inv.Data_Hall__c = halls[0].Id;
                if (halls[0].Floor__c != null) {
                    inv.Floor__c = halls[0].Floor__c;
                }
            }
        }

        // ── Lookup: Account by Odoo_Partner_ID__c ──
        if (p.ns_customer != null) {
            Decimal custOdooId = p.ns_customer;
            List<Account> accounts = [
                SELECT Id FROM Account
                WHERE Odoo_Partner_ID__c = :custOdooId
                LIMIT 1
            ];
            if (!accounts.isEmpty()) {
                inv.Account__c = accounts[0].Id;
            }
        }
    }

    private static String mapSpaceType(String odooType) {
        if (odooType == null) return null;
        String mapped = SPACE_TYPE_MAP.get(odooType.toLowerCase());
        return mapped != null ? mapped : odooType;
    }

    private static String mapStage(String odooStage, String defaultValue) {
        if (odooStage == null) return defaultValue;
        String mapped = STAGE_TO_STATUS.get(odooStage.toLowerCase());
        return mapped != null ? mapped : defaultValue;
    }

    private static void sendError(RestResponse res, Integer code, String msg) {
        res.statusCode = code;
        res.responseBody = Blob.valueOf('{"error":"' + jsonSafe(msg) + '"}');
    }

    private static String jsonSafe(String s) {
        return s == null ? '' : s.replace('"', '\\"');
    }

    public class InventorySyncException extends Exception {}
}