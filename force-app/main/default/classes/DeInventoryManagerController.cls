/**
 * DeInventoryManagerController
 * Apex controller for the deInventoryManager LWC — Operations workspace
 * for browsing, creating, and managing Inventory__c records across sites.
 *
 * FLS enforced via Security.stripInaccessible on all reads.
 * CRUD checked before all DML.
 */
public with sharing class DeInventoryManagerController {

    /* ─── Read: Sites ──────────────────────────────────────────────────── */

    @AuraEnabled(cacheable=true)
    public static List<Site__c> getSites() {
        List<Site__c> records = [
            SELECT Id, Name, Site_Code__c, Country__c
            FROM Site__c
            WHERE Status__c = 'Operational'
            WITH SECURITY_ENFORCED
            ORDER BY Site_Code__c ASC
        ];
        return stripped(records);
    }

    /* ─── Read: Floors by site ─────────────────────────────────────────── */

    @AuraEnabled
    public static List<Floor__c> getFloorsBySite(Id siteId) {
        List<Floor__c> records = [
            SELECT Id, Name, Sequence__c
            FROM Floor__c
            WHERE Site__c = :siteId
              AND Customer_Floor__c = 'Yes'
            ORDER BY Sequence__c ASC NULLS LAST, Name ASC
        ];
        return stripped(records);
    }

    /* ─── Read: Data Halls by site (all floors) ────────────────────────── */

    @AuraEnabled(cacheable=true)
    public static List<DataHall__c> getHallsBySite(Id siteId) {
        Set<Id> floorIds = new Set<Id>();
        for (Floor__c f : [SELECT Id FROM Floor__c WHERE Site__c = :siteId AND Customer_Floor__c = 'Yes']) {
            floorIds.add(f.Id);
        }
        if (floorIds.isEmpty()) {
            return new List<DataHall__c>();
        }
        List<DataHall__c> records = [
            SELECT Id, Name, Sequence__c, Room_Description__c,
                   Floor__c, Floor__r.Name
            FROM DataHall__c
            WHERE Floor__c IN :floorIds
            ORDER BY Floor__r.Name ASC, Sequence__c ASC NULLS LAST, Name ASC
        ];
        return stripped(records);
    }

    /* ─── Read: Data Halls by floor ────────────────────────────────────── */

    @AuraEnabled(cacheable=true)
    public static List<DataHall__c> getHallsByFloor(Id floorId) {
        List<DataHall__c> records = [
            SELECT Id, Name, Sequence__c, Room_Description__c
            FROM DataHall__c
            WHERE Floor__c = :floorId
            ORDER BY Sequence__c ASC NULLS LAST, Name ASC
        ];
        return stripped(records);
    }

    /* ─── Read: Inventory by site (filtered) ───────────────────────────── */

    @AuraEnabled(cacheable=true)
    public static List<Inventory__c> getInventoryBySite(
            Id siteId, String recordTypeName, String statusFilter) {

        String q = 'SELECT Id, Name, RecordType.Name, RecordType.DeveloperName, '
            + 'Site_Id__c, Site_Id__r.Name, Site_Id__r.Site_Code__c, '
            + 'Space_Type__c, Usage_Type__c, Capacity_Type__c, Status__c, '
            + 'Data_Hall__c, Data_Hall__r.Name, Floor__c, Floor__r.Name, '
            + 'Power_kVA__c, Power_Circuit_kVA__c, Total_kW__c, Total_Capacity_kVA__c, '
            + 'Unit_Reference__c, Breaker_Panel__c, Rack_Position__c, Row__c, Zone__c, '
            + 'CabE_Count__c, '
            + 'Opportunity__c, Opportunity__r.Name, '
            + 'Account__c, Account__r.Name, '
            + 'Assigned_To_Quote__c, '
            + 'Notes__c '
            + 'FROM Inventory__c '
            + 'WHERE Site_Id__c = :siteId';

        if (String.isNotBlank(recordTypeName) && recordTypeName != 'All') {
            q += ' AND RecordType.DeveloperName = :recordTypeName';
        }
        if (String.isNotBlank(statusFilter) && statusFilter != 'All') {
            q += ' AND Status__c = :statusFilter';
        }
        q += ' ORDER BY Floor__r.Name ASC NULLS LAST, '
           + 'Data_Hall__r.Name ASC NULLS LAST, Name ASC '
           + 'LIMIT 500';

        List<Inventory__c> records = Database.query(q);
        return stripped(records);
    }

    /* ─── Read: Inventory summary counts ───────────────────────────────── */

    @AuraEnabled
    public static Map<String, Integer> getInventorySummary(Id siteId) {
        List<AggregateResult> agg = [
            SELECT Status__c s, COUNT(Id) c
            FROM Inventory__c
            WHERE Site_Id__c = :siteId
            GROUP BY Status__c
        ];
        Map<String, Integer> m = new Map<String, Integer>();
        Integer total = 0;
        for (AggregateResult a : agg) {
            String status = (String) a.get('s');
            Integer cnt = (Integer) a.get('c');
            m.put(status, cnt);
            total += cnt;
        }
        m.put('Total', total);

        // Committed = Reserved/Assigned WITH a linked quote (not orphaned)
        Set<String> committedStatuses = new Set<String>{ 'Reserved', 'Assigned' };
        List<AggregateResult> committed = [
            SELECT COUNT(Id) c FROM Inventory__c
            WHERE Site_Id__c = :siteId
              AND Status__c IN :committedStatuses
              AND Assigned_To_Quote__c != null
        ];
        m.put('Committed', committed.isEmpty() ? 0 : (Integer) committed[0].get('c'));

        // Space-only counts
        for (AggregateResult a : [
            SELECT Status__c s, COUNT(Id) c
            FROM Inventory__c
            WHERE Site_Id__c = :siteId AND RecordType.DeveloperName = 'Inventory_Space'
            GROUP BY Status__c
        ]) {
            String status = (String) a.get('s');
            Integer cnt = (Integer) a.get('c');
            m.put('Space_' + status, cnt);
        }
        Integer spaceTotal = 0;
        for (String key : m.keySet()) {
            if (key.startsWith('Space_') && key != 'Space_Total') spaceTotal += m.get(key);
        }
        m.put('Space_Total', spaceTotal);
        return m;
    }

    /**
     * Bulk alternative to getInventorySummary — returns summaries for ALL sites
     * in a single call (2 SOQL) instead of N calls (2N SOQL).
     */
    @AuraEnabled(cacheable=true)
    public static Map<Id, Map<String, Integer>> getAllSiteSummaries() {
        Map<Id, Map<String, Integer>> result = new Map<Id, Map<String, Integer>>();

        for (AggregateResult a : [
            SELECT Site_Id__c siteId, Status__c s, COUNT(Id) c
            FROM Inventory__c
            WHERE Site_Id__c != null
            GROUP BY Site_Id__c, Status__c
        ]) {
            Id siteId = (Id) a.get('siteId');
            String status = (String) a.get('s');
            Integer cnt = (Integer) a.get('c');
            if (!result.containsKey(siteId)) result.put(siteId, new Map<String, Integer>());
            result.get(siteId).put(status, cnt);
        }

        // Compute totals per site
        for (Id siteId : result.keySet()) {
            Integer total = 0;
            for (Integer c : result.get(siteId).values()) total += c;
            result.get(siteId).put('Total', total);
        }

        // Committed counts per site
        for (AggregateResult a : [
            SELECT Site_Id__c siteId, COUNT(Id) c
            FROM Inventory__c
            WHERE Site_Id__c != null
              AND Status__c IN ('Reserved', 'Assigned')
              AND Assigned_To_Quote__c != null
            GROUP BY Site_Id__c
        ]) {
            Id siteId = (Id) a.get('siteId');
            Integer cnt = (Integer) a.get('c');
            if (result.containsKey(siteId)) {
                result.get(siteId).put('Committed', cnt);
            }
        }

        // Space-only counts per site
        for (AggregateResult a : [
            SELECT Site_Id__c siteId, Status__c s, COUNT(Id) c
            FROM Inventory__c
            WHERE Site_Id__c != null AND RecordType.DeveloperName = 'Inventory_Space'
            GROUP BY Site_Id__c, Status__c
        ]) {
            Id siteId = (Id) a.get('siteId');
            String status = (String) a.get('s');
            Integer cnt = (Integer) a.get('c');
            if (!result.containsKey(siteId)) result.put(siteId, new Map<String, Integer>());
            result.get(siteId).put('Space_' + status, cnt);
        }
        // Space totals
        for (Id siteId : result.keySet()) {
            Integer spaceTotal = 0;
            for (String key : result.get(siteId).keySet()) {
                if (key.startsWith('Space_') && key != 'Space_Total') {
                    spaceTotal += result.get(siteId).get(key);
                }
            }
            result.get(siteId).put('Space_Total', spaceTotal);
        }

        return result;
    }

    /* ─── Read: Reservations (held inventory across sites) ─────────────── */

    @AuraEnabled(cacheable=true)
    public static List<Inventory__c> getReservations(Id siteId) {
        Set<String> held = new Set<String>{ 'Reserved', 'Assigned', 'Sold' };

        String q = 'SELECT Id, Name, RecordType.Name, RecordType.DeveloperName, '
            + 'Site_Id__c, Site_Id__r.Name, Site_Id__r.Site_Code__c, '
            + 'Space_Type__c, Usage_Type__c, Capacity_Type__c, Status__c, '
            + 'Data_Hall__c, Data_Hall__r.Name, Floor__c, Floor__r.Name, '
            + 'Power_kVA__c, Power_Circuit_kVA__c, Total_kW__c, Total_Capacity_kVA__c, '
            + 'Unit_Reference__c, Breaker_Panel__c, '
            + 'Opportunity__c, Opportunity__r.Name, '
            + 'Account__c, Account__r.Name, '
            + 'Assigned_To_Quote__c, '
            + 'Order__c '
            + 'FROM Inventory__c '
            + 'WHERE Status__c IN :held'
            + ' AND RecordType.DeveloperName = \'Inventory_Space\'';

        if (siteId != null) {
            q += ' AND Site_Id__c = :siteId';
        }
        q += ' ORDER BY Site_Id__r.Site_Code__c ASC, Status__c ASC, Name ASC'
           + ' LIMIT 500';

        List<Inventory__c> records = Database.query(q);
        return stripped(records);
    }

    /* ─── Write: Create inventory records ──────────────────────────────── */
    /*
     * Auto-names per DE Data Center Naming Convention v3.1:
     *   Section 5 (Flex Office): SITE-FLOOR-ROOMXX-FSXX  (e.g. BOM1-01-COLP05-FS01)
     *   Section 6 (Cabinet/Cage/Hall): SITE-FLOOR-DHAA-USAGEXX-RKYYZZ  (e.g. TYO1-04-DH01-S01-RK0304)
     *   Section 8 (Breaker): SITE-FLOOR-ROOMXX-BRKXX  (e.g. MNL1-01-DH01-BRK01)
     *   USAGE: H = Dedicated Hall, C = Cage, S = Shared (Cabinet)
     */

    @AuraEnabled
    public static List<Map<String, String>> getCageHallOptions(Id floorId) {
        List<Map<String, String>> results = new List<Map<String, String>>();
        if (floorId == null) return results;
        for (Inventory__c inv : [
            SELECT Id, Name, Space_Type__c
            FROM Inventory__c
            WHERE Floor__c = :floorId
              AND RecordType.DeveloperName = 'Inventory_Space'
              AND Space_Type__c IN ('Cage', 'Hall')
            ORDER BY Name ASC
            LIMIT 200
        ]) {
            results.add(new Map<String, String>{
                'id'    => inv.Id,
                'name'  => inv.Name,
                'type'  => inv.Space_Type__c
            });
        }
        return results;
    }

    @AuraEnabled
    public static Id createInventoryRecords(
            String recordTypeName, Id siteId, Id floorId, Id dataHallId,
            String spaceType, String capacityType,
            Decimal powerKva, Decimal totalKw, Decimal totalCapacityKva,
            String unitRefPrefix, String breakerPanel,
            String notes, Integer quantity,
            String newFloorName, String newDataHallName,
            String customName,
            String inventoryRow, String inventoryCol,
            String unitNumber,
            String breakerType, String voltageRating, String currentRating,
            String slaTemperature, String slaTemperatureMax, String slaHumidity, String slaHumidityMax, String slaAvailability,
            String cabeSize,
            String inventoryStatus, Decimal contractedPower,
            String usageType, Id cageReferenceId) {

        if (!Schema.sObjectType.Inventory__c.isCreateable()) {
            throw new AuraHandledException(
                'Insufficient permissions to create Inventory records.');
        }

        // ── Create new Floor if requested ──
        if (String.isNotBlank(newFloorName) && floorId == null) {
            if (!Schema.sObjectType.Floor__c.isCreateable()) {
                throw new AuraHandledException(
                    'Insufficient permissions to create Floor records.');
            }
            Floor__c newFloor = new Floor__c(
                Name    = newFloorName,
                Site__c = siteId
            );
            insert newFloor;
            floorId = newFloor.Id;
        }

        // ── Create new Data Hall if requested ──
        if (String.isNotBlank(newDataHallName) && dataHallId == null && floorId != null) {
            if (!Schema.sObjectType.DataHall__c.isCreateable()) {
                throw new AuraHandledException(
                    'Insufficient permissions to create Data Hall records.');
            }
            DataHall__c newHall = new DataHall__c(
                Name     = newDataHallName,
                Floor__c = floorId
            );
            insert newHall;
            dataHallId = newHall.Id;
        }

        Id rtId = Schema.SObjectType.Inventory__c
            .getRecordTypeInfosByDeveloperName()
            .get(recordTypeName)
            .getRecordTypeId();

        // ── Build auto-name prefix from naming convention ──
        Site__c site = [SELECT Site_Code__c FROM Site__c WHERE Id = :siteId LIMIT 1];
        String siteCode = site.Site_Code__c;

        String floorPart = '00';
        if (floorId != null) {
            Floor__c flr = [SELECT Name FROM Floor__c WHERE Id = :floorId LIMIT 1];
            // Floor name format: SITE-FloorNum (e.g. PEK1-1, SEL1-5, OSA1-UG)
            floorPart = flr.Name.removeStart(siteCode + '-');
            if (floorPart.isNumeric()) {
                floorPart = floorPart.leftPad(2, '0');
            }
        }

        String hallPart = '00';
        String dataHallFullName = '';
        if (dataHallId != null) {
            DataHall__c dh = [SELECT Name, Hall_Number__c FROM DataHall__c WHERE Id = :dataHallId LIMIT 1];
            dataHallFullName = dh.Name;
            // Prefer Hall_Number__c; fall back to parsing the name
            if (String.isNotBlank(dh.Hall_Number__c)) {
                hallPart = dh.Hall_Number__c;
            } else {
                hallPart = dh.Name.substringAfterLast('-');
            }
            if (hallPart.isNumeric()) {
                hallPart = hallPart.leftPad(2, '0');
            }
        }

        // Determine if this is a Flex Office (Section 5 naming)
        Boolean isFlexOffice = (spaceType == 'Flex Office');

        String usageTag;
        if (recordTypeName == 'Inventory_Space') {
            if (spaceType == 'Cage')         usageTag = 'C';
            else if (spaceType == 'Hall')    usageTag = 'H';
            else if (spaceType == 'Cabinet' && usageType == 'Private Cage')  usageTag = 'C';
            else if (spaceType == 'Cabinet' && usageType == 'Private Hall')  usageTag = 'H';
            else                             usageTag = 'S';   // Cabinet Shared (default)
        } else {
            usageTag = 'BRK';
        }

        // Unit number for naming convention: USAGEXX (e.g. S01, C99) or FSXX
        String unitPart = '';
        if (String.isNotBlank(unitNumber)) {
            unitPart = unitNumber.isNumeric()
                ? unitNumber.leftPad(2, '0')
                : unitNumber;
        }

        // Build name prefix based on naming convention section
        String namePrefix;
        if (isFlexOffice) {
            // Section 5: SITE-FLOOR-ROOMXX-FSXX
            // Extract room abbreviation from data hall name:
            // e.g. hall "COLP5" → "COLP05", hall "DH01" → "DH01"
            String roomPart = hallPart; // default: just the digits
            if (String.isNotBlank(dataHallFullName)) {
                // Use the last segment of the hall name (e.g. "MNL1-01-COLP5" → "COLP5")
                String lastSeg = dataHallFullName.contains('-')
                    ? dataHallFullName.substringAfterLast('-')
                    : dataHallFullName;
                // Split into alpha prefix and trailing digits
                Pattern p = Pattern.compile('^([A-Za-z]+)(\\d+)$');
                Matcher m = p.matcher(lastSeg);
                if (m.matches()) {
                    roomPart = m.group(1) + m.group(2).leftPad(2, '0');
                } else {
                    roomPart = lastSeg;
                }
            }
            namePrefix = siteCode + '-' + floorPart + '-' + roomPart + '-FS' + unitPart;
        } else {
            // Section 6: SITE-FLOOR-DHAA-USAGEXX (e.g. TYO1-04-DH01-S01, OSA2-02-DH01-C99)
            namePrefix = siteCode + '-' + floorPart + '-DH' + hallPart + '-' + usageTag + unitPart;
        }

        // Row/Col naming convention: force qty=1 when row/col provided (Section 6 only)
        Boolean hasRowCol = String.isNotBlank(inventoryRow)
                         && String.isNotBlank(inventoryCol);
        if (hasRowCol) {
            quantity = 1;
        }

        // Find next available sequence number (fallback when row/col not provided)
        Integer nextSeq = 1;
        if (!hasRowCol && !isFlexOffice) {
            String likePattern = namePrefix + '%';
            List<Inventory__c> existing = [
                SELECT Name FROM Inventory__c
                WHERE Name LIKE :likePattern
                ORDER BY Name DESC
                LIMIT 1
            ];
            if (!existing.isEmpty()) {
                String lastName = existing[0].Name;
                String afterPrefix = lastName.removeStart(namePrefix);
                String seqStr = afterPrefix.contains('-')
                    ? afterPrefix.substringBefore('-')
                    : afterPrefix;
                if (String.isNotBlank(seqStr) && seqStr.isNumeric()) {
                    nextSeq = Integer.valueOf(seqStr) + 1;
                }
            }
        }

        List<Inventory__c> batch = new List<Inventory__c>();
        Boolean hasCustomName = String.isNotBlank(customName);
        for (Integer i = 0; i < quantity; i++) {
            String seqPad = String.valueOf(nextSeq + i).leftPad(2, '0');

            String recName;
            if (isFlexOffice) {
                // Section 5: name is fully formed in namePrefix (SITE-FLOOR-ROOMXX-FSXX)
                recName = namePrefix;
            } else if (hasRowCol) {
                // Section 6: SITE-FLOOR-DH##-TYPEXX-RKYYZZ
                recName = namePrefix + '-RK' + inventoryRow + inventoryCol;
            } else if (hasCustomName) {
                recName = quantity == 1
                    ? customName
                    : customName + '-' + String.valueOf(i + 1).leftPad(2, '0');
            } else if (String.isNotBlank(unitPart)) {
                // Unit number already embedded in namePrefix — no sequence suffix needed
                recName = quantity == 1
                    ? namePrefix
                    : namePrefix + '-' + String.valueOf(i + 1).leftPad(2, '0');
            } else {
                recName = namePrefix + seqPad;
            }

            Inventory__c inv = new Inventory__c(
                Name         = recName,
                RecordTypeId = rtId,
                Site_Id__c   = siteId,
                Floor__c     = floorId,
                Data_Hall__c = dataHallId,
                Status__c    = String.isNotBlank(inventoryStatus) ? inventoryStatus : 'Available',
                Notes__c     = notes
            );

            if (recordTypeName == 'Inventory_Space') {
                inv.Space_Type__c          = spaceType;
                if (spaceType == 'Cabinet' && String.isNotBlank(usageType)) {
                    inv.Usage_Type__c = usageType;
                }
                if (cageReferenceId != null) {
                    if (usageType == 'Private Hall') {
                        inv.Hall_Reference__c = cageReferenceId;
                    } else {
                        inv.Cage_Reference__c = cageReferenceId;
                    }
                }
                inv.Total_Capacity_kVA__c  = totalCapacityKva;
                inv.Total_IT_Power_kVA__c  = contractedPower;
                inv.Power_kVA__c           = powerKva;
                inv.CabE_Size__c           = cabeSize;
                inv.SLA_Temperature_Min__c = slaTemperature;
                inv.SLA_Temperature_Max__c = slaTemperatureMax;
                inv.SLA_Humidity_Min__c    = slaHumidity;
                inv.SLA_Humidity_Max__c    = slaHumidityMax;
                inv.SLA_Availability__c    = slaAvailability;
            } else {
                inv.Capacity_Type__c     = capacityType;
                inv.Breaker_Type__c      = breakerType;
                inv.Voltage_Rating__c    = voltageRating;
                inv.Current_Rating__c    = currentRating;
                inv.Breaker_Panel__c     = breakerPanel;
            }

            // Store row value when using naming convention
            if (String.isNotBlank(inventoryRow)) {
                inv.Row__c = inventoryRow;
            }

            if (String.isNotBlank(unitRefPrefix)) {
                inv.Unit_Reference__c = quantity == 1
                    ? unitRefPrefix
                    : unitRefPrefix + '-' + String.valueOf(i + 1).leftPad(3, '0');
            }

            batch.add(inv);
        }

        insert batch;

        return batch[0].Id;
    }

    /* ─── Write: Release reservation ───────────────────────────────────── */

    @AuraEnabled
    public static void updateInventoryField(Id recordId, String fieldName, String fieldValue) {
        if (!Schema.sObjectType.Inventory__c.isUpdateable()) {
            throw new AuraHandledException('Insufficient permissions to update Inventory records.');
        }
        Inventory__c inv = new Inventory__c(Id = recordId);
        // Determine field type for proper casting
        Schema.SObjectField field = Inventory__c.sObjectType.getDescribe().fields.getMap().get(fieldName.toLowerCase());
        if (field == null) throw new AuraHandledException('Unknown field: ' + fieldName);
        Schema.DisplayType fType = field.getDescribe().getType();
        if (fType == Schema.DisplayType.DOUBLE || fType == Schema.DisplayType.CURRENCY) {
            inv.put(fieldName, String.isNotBlank(fieldValue) ? Decimal.valueOf(fieldValue) : null);
        } else {
            inv.put(fieldName, fieldValue);
        }
        update inv;
    }

    @AuraEnabled
    public static void updateInventoryFieldBulk(List<Id> recordIds, String fieldName, String fieldValue) {
        if (!Schema.sObjectType.Inventory__c.isUpdateable()) {
            throw new AuraHandledException('Insufficient permissions to update Inventory records.');
        }
        Schema.SObjectField field = Inventory__c.sObjectType.getDescribe().fields.getMap().get(fieldName.toLowerCase());
        if (field == null) throw new AuraHandledException('Unknown field: ' + fieldName);
        Schema.DisplayType fType = field.getDescribe().getType();
        Object typedValue;
        if (fType == Schema.DisplayType.DOUBLE || fType == Schema.DisplayType.CURRENCY) {
            typedValue = String.isNotBlank(fieldValue) ? Decimal.valueOf(fieldValue) : null;
        } else {
            typedValue = fieldValue;
        }
        List<Inventory__c> toUpdate = new List<Inventory__c>();
        for (Id rid : recordIds) {
            Inventory__c inv = new Inventory__c(Id = rid);
            inv.put(fieldName, typedValue);
            toUpdate.add(inv);
        }
        update toUpdate;
    }

    @AuraEnabled
    public static void releaseInventory(Id inventoryId) {
        if (!Schema.sObjectType.Inventory__c.isUpdateable()) {
            throw new AuraHandledException(
                'Insufficient permissions to update Inventory records.');
        }
        update new Inventory__c(
            Id                   = inventoryId,
            Status__c            = 'Available',
            Opportunity__c       = null,
            Assigned_To_Quote__c = null,
            Assigned_To_Order__c = null,
            Order__c             = null,
            Quote_Line__c        = null,
            Order_Item__c        = null,
            Account__c           = null
        );
    }

    /* ─── Write: Decommission inventory ───────────────────────────────── */

    @AuraEnabled
    public static void decommissionInventory(Id inventoryId) {
        if (!Schema.sObjectType.Inventory__c.isUpdateable()) {
            throw new AuraHandledException(
                'Insufficient permissions to update Inventory records.');
        }
        // Odoo decommission event is fired by InventoryTriggerHandler.handleAfterUpdate
        // when Status__c transitions to 'Decommissioned' — single code path for every
        // entry point (this button, Data Loader, API, other Apex).
        update new Inventory__c(Id = inventoryId, Status__c = 'Decommissioned');
    }

    /* ─── Write: Create floor with data halls ─────────────────────────── */

    @AuraEnabled
    public static Id createFloor(Id siteId, String floorName, List<String> hallNames) {
        if (!Schema.sObjectType.Floor__c.isCreateable()) {
            throw new AuraHandledException(
                'Insufficient permissions to create Floor records.');
        }
        Floor__c newFloor = new Floor__c(Name = floorName, Site__c = siteId);
        insert newFloor;
        Id floorId = newFloor.Id;

        if (hallNames != null && !hallNames.isEmpty()) {
            if (!Schema.sObjectType.DataHall__c.isCreateable()) {
                throw new AuraHandledException(
                    'Insufficient permissions to create Data Hall records.');
            }
            List<DataHall__c> newHalls = new List<DataHall__c>();
            for (String hn : hallNames) {
                if (String.isNotBlank(hn)) {
                    newHalls.add(new DataHall__c(Name = hn, Floor__c = floorId, Site__c = siteId));
                }
            }
            if (!newHalls.isEmpty()) {
                insert newHalls;
            }
        }
        return floorId;
    }

    /* ─── Write: Bulk release inventory ────────────────────────────────── */

    @AuraEnabled
    public static void bulkReleaseInventory(List<Id> inventoryIds) {
        if (!Schema.sObjectType.Inventory__c.isUpdateable()) {
            throw new AuraHandledException(
                'Insufficient permissions to update Inventory records.');
        }
        List<Inventory__c> reserved = [
            SELECT Id FROM Inventory__c
            WHERE Id IN :inventoryIds AND Status__c = 'Reserved'
        ];
        if (reserved.isEmpty()) {
            throw new AuraHandledException(
                'Only Reserved inventory can be released.');
        }
        List<Inventory__c> toUpdate = new List<Inventory__c>();
        for (Inventory__c inv : reserved) {
            toUpdate.add(new Inventory__c(
                Id                   = inv.Id,
                Status__c            = 'Available',
                Opportunity__c       = null,
                Assigned_To_Quote__c = null,
                Assigned_To_Order__c = null,
                Order__c             = null,
                Quote_Line__c        = null,
                Order_Item__c        = null,
                Account__c           = null
            ));
        }
        update toUpdate;
    }

    /* ─── Read: Floor/Hall summary cards for dashboard ───────────────── */

    public class FloorHallCard implements Comparable {
        @AuraEnabled public String  floorId;
        @AuraEnabled public String  floorName;
        @AuraEnabled public String  hallId;
        @AuraEnabled public String  hallName;
        @AuraEnabled public String  hallNumber;
        @AuraEnabled public Integer total     = 0;
        @AuraEnabled public Integer available = 0;
        @AuraEnabled public Integer held      = 0;
        @AuraEnabled public Integer active    = 0;
        @AuraEnabled public Integer sold      = 0;
        @AuraEnabled public Integer installed = 0;
        @AuraEnabled public Integer spaceTotal = 0;
        @AuraEnabled public Integer spaceAvail = 0;
        @AuraEnabled public Integer spaceSold      = 0;
        @AuraEnabled public Integer spaceInstalled = 0;
        @AuraEnabled public Integer spaceHeld      = 0;

        public Integer compareTo(Object other) {
            FloorHallCard o = (FloorHallCard) other;
            String a = (floorName != null ? floorName : 'zzz')
                     + (hallName  != null ? hallName  : 'zzz');
            String b = (o.floorName != null ? o.floorName : 'zzz')
                     + (o.hallName  != null ? o.hallName  : 'zzz');
            return a.compareTo(b);
        }
    }

    @AuraEnabled
    public static List<FloorHallCard> getFloorHallSummary(Id siteId) {
        Map<Id, String> floorNames = new Map<Id, String>();
        for (Floor__c f : [SELECT Id, Name FROM Floor__c WHERE Site__c = :siteId AND Customer_Floor__c = 'Yes']) {
            floorNames.put(f.Id, f.Name);
        }
        Map<Id, DataHall__c> hallData = new Map<Id, DataHall__c>();
        for (DataHall__c h : [SELECT Id, Name, Floor__c, Hall_Number__c
                              FROM DataHall__c
                              WHERE Floor__c IN :floorNames.keySet()
                                AND Customer_Data_Hall__c = 'Yes']) {
            hallData.put(h.Id, h);
        }

        Set<String> availSet = new Set<String>{ 'Available', 'Pending Available' };
        Set<String> heldSet  = new Set<String>{ 'Reserved', 'Assigned' };
        Map<String, FloorHallCard> cards = new Map<String, FloorHallCard>();

        for (AggregateResult a : [
            SELECT Data_Hall__c hallId, Status__c status, COUNT(Id) cnt
            FROM Inventory__c
            WHERE Site_Id__c = :siteId AND Data_Hall__c IN :hallData.keySet()
            GROUP BY Data_Hall__c, Status__c
        ]) {
            Id hId     = (Id) a.get('hallId');
            String key = String.valueOf(hId);

            if (!cards.containsKey(key)) {
                DataHall__c dh  = hallData.get(hId);
                FloorHallCard c = new FloorHallCard();
                c.hallId    = key;
                c.hallName   = dh.Name;
                c.hallNumber = dh.Hall_Number__c;
                c.floorId    = String.valueOf(dh.Floor__c);
                c.floorName  = floorNames.get(dh.Floor__c);
                cards.put(key, c);
            }

            FloorHallCard c = cards.get(key);
            String status   = (String) a.get('status');
            Integer cnt     = (Integer) a.get('cnt');
            c.total += cnt;

            if (availSet.contains(status))      c.available  += cnt;
            else if (heldSet.contains(status))  c.held       += cnt;
            else if (status == 'Sold')          { c.sold += cnt; c.active += cnt; }
            else if (status == 'Installed')     { c.installed += cnt; c.active += cnt; }
            else                                c.active     += cnt;
        }

        // Space-only counts per hall
        for (AggregateResult a : [
            SELECT Data_Hall__c hallId, Status__c status, COUNT(Id) cnt
            FROM Inventory__c
            WHERE Site_Id__c = :siteId AND Data_Hall__c IN :hallData.keySet()
              AND RecordType.DeveloperName = 'Inventory_Space'
            GROUP BY Data_Hall__c, Status__c
        ]) {
            String key = String.valueOf((Id) a.get('hallId'));
            if (cards.containsKey(key)) {
                FloorHallCard c = cards.get(key);
                String status = (String) a.get('status');
                Integer cnt = (Integer) a.get('cnt');
                c.spaceTotal += cnt;
                if (availSet.contains(status))      c.spaceAvail     += cnt;
                else if (heldSet.contains(status))  c.spaceHeld      += cnt;
                else if (status == 'Sold')          c.spaceSold      += cnt;
                else if (status == 'Installed')     c.spaceInstalled += cnt;
            }
        }

        // Include empty halls (no inventory yet) so newly created floors appear
        for (Id hId : hallData.keySet()) {
            String key = String.valueOf(hId);
            if (!cards.containsKey(key)) {
                DataHall__c dh  = hallData.get(hId);
                FloorHallCard c = new FloorHallCard();
                c.hallId     = key;
                c.hallName   = dh.Name;
                c.hallNumber = dh.Hall_Number__c;
                c.floorId    = String.valueOf(dh.Floor__c);
                c.floorName  = floorNames.get(dh.Floor__c);
                cards.put(key, c);
            }
        }

        List<FloorHallCard> result = new List<FloorHallCard>(cards.values());
        result.sort();
        return result;
    }

    /* ─── Read: Inventory by data hall (drill-down) ───────────────── */

    @AuraEnabled
    public static List<Inventory__c> getInventoryByHall(Id dataHallId) {
        List<Inventory__c> records = [
            SELECT Id, Name, RecordType.Name, RecordType.DeveloperName,
                Site_Id__c, Site_Id__r.Name, Site_Id__r.Site_Code__c,
                Space_Type__c, Capacity_Type__c, Status__c,
                Data_Hall__c, Data_Hall__r.Name, Floor__c, Floor__r.Name,
                Power_kVA__c, Power_Circuit_kVA__c, Total_kW__c, Total_Capacity_kVA__c, Total_IT_Power_kVA__c,
                Unit_Reference__c, Breaker_Panel__c, Rack_Position__c, Row__c, Zone__c,
                CabE_Count__c, CabE_Size__c,
                Breaker_Type__c, Voltage_Rating__c, Current_Rating__c,
                SLA_Temperature__c, SLA_Humidity__c, SLA_Availability__c,
                Opportunity__c, Opportunity__r.Name,
                Account__c, Account__r.Name,
                Assigned_To_Quote__c,
                Notes__c
            FROM Inventory__c
            WHERE Data_Hall__c = :dataHallId
            ORDER BY Name ASC
        ];
        return stripped(records);
    }

    /* ─── Read: Export inventory for a site (or hall) as structured data ─── */

    @AuraEnabled
    public static List<Inventory__c> getExportData(Id siteId, Id dataHallId,
            String statusFilter, String recordTypeFilter, List<String> countries) {

        String q = 'SELECT Id, Name, RecordType.DeveloperName, '
            + 'Site_Id__c, Site_Id__r.Site_Code__c, Site_Id__r.Country__c, '
            + 'Floor__c, Floor__r.Name, '
            + 'Data_Hall__c, Data_Hall__r.Name, '
            + 'Space_Type__c, Usage_Type__c, Status__c, '
            + 'Unit_Reference__c, Cage_Reference__r.Name, Hall_Reference__r.Name, '
            + 'Breaker_Type__c, Voltage_Rating__c, Current_Rating__c, '
            + 'CabE_Size__c, CabE_Count__c, Total_Capacity_kVA__c, Power_kVA__c, '
            + 'Total_IT_Power_kVA__c, '
            + 'SLA_Availability__c, '
            + 'SLA_Temperature_Min__c, SLA_Temperature_Max__c, '
            + 'SLA_Humidity_Min__c, SLA_Humidity_Max__c, '
            + 'TH_Sensor_ID__c, '
            + 'Notes__c, '
            + 'Account__c, Account__r.Name, '
            + 'Opportunity__c, Opportunity__r.Name, '
            + 'Odoo_Space_ID__c, Odoo_Inventory_Id__c '
            + 'FROM Inventory__c ';

        q += buildExportWhereClause(siteId, dataHallId, statusFilter, recordTypeFilter, countries);
        q += ' ORDER BY Site_Id__r.Site_Code__c ASC, Floor__r.Name ASC NULLS LAST, '
           + 'Data_Hall__r.Name ASC NULLS LAST, Name ASC '
           + 'LIMIT 10000';

        return stripped(Database.query(q));
    }

    /* ─── Read: Live count of records matching the export filters ──────── */
    // Lets the Export modal show "N records match" before the user downloads,
    // instead of finding out the row count only after the file is generated.

    @AuraEnabled
    public static Integer getExportCount(Id siteId, Id dataHallId,
            String statusFilter, String recordTypeFilter, List<String> countries) {
        String q = 'SELECT COUNT() FROM Inventory__c ';
        q += buildExportWhereClause(siteId, dataHallId, statusFilter, recordTypeFilter, countries);
        return Database.countQuery(q);
    }

    private static String buildExportWhereClause(Id siteId, Id dataHallId,
            String statusFilter, String recordTypeFilter, List<String> countries) {
        String w;
        if (siteId != null) {
            w = 'WHERE Site_Id__c = :siteId';
            if (dataHallId != null) {
                w += ' AND Data_Hall__c = :dataHallId';
            }
        } else if (countries != null && !countries.isEmpty()) {
            w = 'WHERE Site_Id__r.Country__c IN :countries';
        } else {
            w = 'WHERE Site_Id__c != null'; // all sites
        }

        if (String.isNotBlank(statusFilter) && statusFilter != 'All') {
            w += ' AND Status__c = :statusFilter';
        }
        if (String.isNotBlank(recordTypeFilter) && recordTypeFilter != 'All') {
            w += ' AND RecordType.DeveloperName = :recordTypeFilter';
        }
        return w;
    }

    /* ─── Write: Bulk import with auto-naming ──────────────────────────── */

    // CSV label → API name mapping
    // NOTE: 'Id' is handled separately (it routes the row to update vs. create) —
    // it is intentionally NOT in this map.
    private static final Map<String, String> IMPORT_FIELD_MAP = new Map<String, String>{
        'Inventory ID'                      => 'Name',   // client's label for the record Name field
        'Inventory Status'                  => 'Status__c',
        'Space Type'                        => 'Space_Type__c',
        'Usage Type'                        => 'Usage_Type__c',
        'CabE Size'                         => 'CabE_Size__c',
        'CabE Count'                        => 'CabE_Count__c',
        'Average Power per Cab (kVA)'       => 'Total_Capacity_kVA__c',
        'Subscribed/Contracted Power (kVA)' => 'Power_kVA__c',
        'Contracted Power (kVA)'            => 'Total_IT_Power_kVA__c',
        'Breaker Type'                      => 'Breaker_Type__c',
        'Voltage Rating (V)'                => 'Voltage_Rating__c',
        'Current Rating (A)'                => 'Current_Rating__c',
        // 'Capacity Type' and 'Breaker Panel Reference' intentionally NOT importable —
        // client flagged both as easy sources of integration errors (free-text/loosely
        // validated fields feeding Odoo matching).
        'Remarks'                           => 'Notes__c',
        'Other Inventory Name'              => 'Unit_Reference__c',
        'SLA Temperature Min'               => 'SLA_Temperature_Min__c',
        'SLA Temperature Max'               => 'SLA_Temperature_Max__c',
        'SLA Humidity Min'                   => 'SLA_Humidity_Min__c',
        'SLA Humidity Max'                   => 'SLA_Humidity_Max__c',
        'SLA Availability'                  => 'SLA_Availability__c',
        'TH Sensor ID'                      => 'TH_Sensor_ID__c',
        'TH Sensor Group ID'                => 'TH_Sensor_Group_ID__c'
    };

    @AuraEnabled
    public static Map<String, Object> importInventoryBulk(
            String recordTypeName, Id siteId, Id floorId, Id dataHallId, String rowsJson) {

        if (!Schema.sObjectType.Inventory__c.isCreateable()) {
            throw new AuraHandledException('Insufficient permissions to create Inventory records.');
        }
        if (!Schema.sObjectType.Inventory__c.isUpdateable()) {
            throw new AuraHandledException('Insufficient permissions to update Inventory records.');
        }

        List<Object> rawRows = (List<Object>) JSON.deserializeUntyped(rowsJson);
        if (rawRows == null || rawRows.isEmpty()) {
            throw new AuraHandledException('No rows to import.');
        }

        // Resolve record type ID
        Id rtId = Schema.SObjectType.Inventory__c.getRecordTypeInfosByDeveloperName()
            .get(recordTypeName)?.getRecordTypeId();
        if (rtId == null) {
            throw new AuraHandledException('Invalid record type: ' + recordTypeName);
        }
        Boolean isSpace = recordTypeName == 'Inventory_Space';

        // Resolve naming context
        Site__c site = [SELECT Site_Code__c FROM Site__c WHERE Id = :siteId LIMIT 1];
        String siteCode = site.Site_Code__c;
        Floor__c floor = [SELECT Name FROM Floor__c WHERE Id = :floorId LIMIT 1];
        DataHall__c hall = [SELECT Name, Hall_Number__c FROM DataHall__c WHERE Id = :dataHallId LIMIT 1];

        String floorPart = '';
        if (floor.Name != null) {
            String num = floor.Name.replaceAll('[^0-9]', '');
            floorPart = String.isNotBlank(num) ? num.leftPad(2, '0') : '01';
        }
        String hallPart = '';
        if (hall.Hall_Number__c != null) {
            String hallNum = String.valueOf(hall.Hall_Number__c).replaceAll('[^0-9]', '');
            hallPart = String.isNotBlank(hallNum) ? hallNum.leftPad(2, '0') : '01';
        } else if (hall.Name != null) {
            String num = hall.Name.replaceAll('[^0-9]', '');
            hallPart = String.isNotBlank(num) ? num.leftPad(2, '0') : '01';
        }

        // Build records with auto-naming
        Map<String, Integer> nextSeqByPrefix = new Map<String, Integer>();
        List<Inventory__c> toInsert = new List<Inventory__c>();
        List<Inventory__c> toUpdate = new List<Inventory__c>();
        List<Integer> insertRowNums = new List<Integer>();
        List<Integer> updateRowNums = new List<Integer>();
        List<String> errors = new List<String>();
        // Per-row outcome, keyed by 1-based CSV row number — lets the client build a
        // downloadable results file (original row + status/message) instead of just
        // a flat error list disconnected from the source data.
        Map<Integer, Map<String, Object>> rowResultsByNum = new Map<Integer, Map<String, Object>>();

        // Cage Reference / Hall Reference are Lookup(Inventory__c) fields whose lookup
        // filter (Space_Type__c = 'Cage'/'Hall') is a UI-only constraint — Apex DML does
        // NOT enforce it. Resolve + validate CSV values (Inventory Names) explicitly,
        // batched here since per-row queries inside the loop below aren't bulk-safe.
        Map<String, Id> cageIdByName = new Map<String, Id>();
        Map<String, Id> hallIdByName = new Map<String, Id>();
        if (isSpace) {
            Set<String> cageNames = new Set<String>();
            Set<String> hallNames = new Set<String>();
            for (Object rawRow : rawRows) {
                Map<String, Object> row = (Map<String, Object>) rawRow;
                Object cageVal = row.get('Cage Reference');
                if (cageVal != null && String.isNotBlank(String.valueOf(cageVal))) {
                    cageNames.add(String.valueOf(cageVal).trim());
                }
                Object hallVal = row.get('Hall Reference');
                if (hallVal != null && String.isNotBlank(String.valueOf(hallVal))) {
                    hallNames.add(String.valueOf(hallVal).trim());
                }
            }
            if (!cageNames.isEmpty()) {
                for (Inventory__c rec : [
                    SELECT Id, Name FROM Inventory__c
                    WHERE Floor__c = :floorId AND RecordType.DeveloperName = 'Inventory_Space'
                      AND Space_Type__c = 'Cage' AND Name IN :cageNames
                ]) {
                    cageIdByName.put(rec.Name, rec.Id);
                }
            }
            if (!hallNames.isEmpty()) {
                for (Inventory__c rec : [
                    SELECT Id, Name FROM Inventory__c
                    WHERE Floor__c = :floorId AND RecordType.DeveloperName = 'Inventory_Space'
                      AND Space_Type__c = 'Hall' AND Name IN :hallNames
                ]) {
                    hallIdByName.put(rec.Name, rec.Id);
                }
            }
        }

        Integer rowNum = 0;
        for (Object rawRow : rawRows) {
            rowNum++;
            Map<String, Object> row = (Map<String, Object>) rawRow;

            // An 'Id' column with a value routes this row to UPDATE an existing record;
            // blank/absent 'Id' means CREATE. This lets an exported CSV be edited and
            // re-imported to update records, alongside plain new-record rows.
            Object idVal = row.get('Id');
            String idStr = idVal != null ? String.valueOf(idVal).trim() : '';
            Boolean isUpdate = String.isNotBlank(idStr);

            Inventory__c inv;
            if (isUpdate) {
                try {
                    inv = new Inventory__c(Id = (Id) idStr);
                } catch (Exception e) {
                    String msg = '"' + idStr + '" is not a valid Salesforce record ID.';
                    errors.add('Row ' + rowNum + ': ' + msg);
                    rowResultsByNum.put(rowNum, new Map<String, Object>{
                        'row' => rowNum, 'status' => 'error', 'message' => msg, 'id' => null
                    });
                    continue;
                }
            } else {
                inv = new Inventory__c(
                    RecordTypeId = rtId,
                    Site_Id__c   = siteId,
                    Floor__c     = floorId,
                    Data_Hall__c = dataHallId
                );
            }

            // Map CSV labels to SObject fields; validate data types + picklist values
            List<String> missing = new List<String>();
            List<String> invalidValues = new List<String>();

            for (String csvLabel : row.keySet()) {
                if (csvLabel == 'Id') continue;

                if (csvLabel == 'Cage Reference' || csvLabel == 'Hall Reference') {
                    Object refVal = row.get(csvLabel);
                    String refName = refVal != null ? String.valueOf(refVal).trim() : '';
                    if (String.isBlank(refName)) continue;
                    Map<String, Id> lookupMap = csvLabel == 'Cage Reference' ? cageIdByName : hallIdByName;
                    if (lookupMap.containsKey(refName)) {
                        if (csvLabel == 'Cage Reference') inv.Cage_Reference__c = lookupMap.get(refName);
                        else inv.Hall_Reference__c = lookupMap.get(refName);
                    } else {
                        invalidValues.add(csvLabel + ' ("' + refName + '" — no '
                            + (csvLabel == 'Cage Reference' ? 'Cage' : 'Hall')
                            + ' inventory with that name found on this floor)');
                    }
                    continue;
                }

                String apiName = IMPORT_FIELD_MAP.get(csvLabel);
                if (apiName == null) continue;
                Object val = row.get(csvLabel);
                if (val == null || String.isBlank(String.valueOf(val))) continue;

                String sVal = String.valueOf(val).trim();
                Schema.SObjectField field = Inventory__c.sObjectType.getDescribe()
                    .fields.getMap().get(apiName.toLowerCase());
                if (field == null) continue;

                Schema.DisplayType fType = field.getDescribe().getType();
                if (fType == Schema.DisplayType.DOUBLE || fType == Schema.DisplayType.CURRENCY) {
                    try { inv.put(apiName, Decimal.valueOf(sVal)); }
                    catch (Exception e) { errors.add('Row ' + rowNum + ': Invalid number in ' + csvLabel); continue; }
                } else if (fType == Schema.DisplayType.PICKLIST) {
                    Set<String> validValues = getPicklistValues(apiName);
                    if (!validValues.isEmpty() && !validValues.contains(sVal)) {
                        invalidValues.add(csvLabel + ' ("' + sVal + '" — expected one of: '
                            + String.join(new List<String>(validValues), ', ') + ')');
                        continue; // don't store the bad value
                    }
                    inv.put(apiName, sVal);
                } else {
                    inv.put(apiName, sVal);
                }
            }

            // Required fields only apply to new records — an update row may legitimately
            // touch just one field on an already-complete record.
            if (!isUpdate) {
                if (isSpace) {
                    if (String.isBlank((String) inv.get('Status__c'))) missing.add('Inventory Status');
                    if (String.isBlank((String) inv.get('Space_Type__c'))) missing.add('Space Type');
                    if (inv.get('Total_Capacity_kVA__c') == null) missing.add('Average Power per Cab (kVA)');
                    if (inv.get('Total_IT_Power_kVA__c') == null) missing.add('Contracted Power (kVA)');
                } else {
                    if (String.isBlank((String) inv.get('Status__c'))) missing.add('Inventory Status');
                    if (String.isBlank((String) inv.get('Breaker_Type__c'))) missing.add('Breaker Type');
                    if (String.isBlank((String) inv.get('Voltage_Rating__c'))) missing.add('Voltage Rating (V)');
                    if (String.isBlank((String) inv.get('Current_Rating__c'))) missing.add('Current Rating (A)');
                }
                if (!missing.isEmpty()) {
                    String msg = 'Missing required field(s): ' + String.join(missing, ', ');
                    errors.add('Row ' + rowNum + ': ' + msg);
                    rowResultsByNum.put(rowNum, new Map<String, Object>{
                        'row' => rowNum, 'status' => 'error', 'message' => msg, 'id' => null
                    });
                    continue;
                }
            }
            if (!invalidValues.isEmpty()) {
                String msg = 'Invalid value for ' + String.join(invalidValues, '; ');
                errors.add('Row ' + rowNum + ': ' + msg);
                rowResultsByNum.put(rowNum, new Map<String, Object>{
                    'row' => rowNum, 'status' => 'error', 'message' => msg, 'id' => null
                });
                continue;
            }

            // Use the CSV-provided name when given; otherwise auto-generate per naming convention.
            // Never auto-renames an existing record on update unless a name was explicitly supplied.
            if (!isUpdate && String.isBlank(inv.Name)) {
                String usageTag;
                if (isSpace) {
                    String st = (String) inv.get('Space_Type__c');
                    String ut = (String) inv.get('Usage_Type__c');
                    if (st == 'Cage') usageTag = 'C';
                    else if (st == 'Data Hall' || st == 'Dedicated Hall') usageTag = 'H';
                    else if (st == 'Cabinet' && ut == 'Private Cage') usageTag = 'C';
                    else if (st == 'Cabinet' && ut == 'Private Hall') usageTag = 'H';
                    else usageTag = 'S'; // Cabinet Shared (default)
                } else {
                    usageTag = 'BRK';
                }
                String namePrefix = siteCode + '-' + floorPart + '-DH' + hallPart + '-' + usageTag;

                if (!nextSeqByPrefix.containsKey(namePrefix)) {
                    // Query for last existing record with this prefix
                    String likePattern = namePrefix + '%';
                    List<Inventory__c> existing = [
                        SELECT Name FROM Inventory__c
                        WHERE Name LIKE :likePattern
                        ORDER BY Name DESC LIMIT 1
                    ];
                    Integer seq = 1;
                    if (!existing.isEmpty()) {
                        String lastName = existing[0].Name;
                        String afterPrefix = lastName.removeStart(namePrefix);
                        String seqStr = afterPrefix.contains('-') ? afterPrefix.substringBefore('-') : afterPrefix;
                        if (String.isNotBlank(seqStr) && seqStr.isNumeric()) {
                            seq = Integer.valueOf(seqStr) + 1;
                        }
                    }
                    nextSeqByPrefix.put(namePrefix, seq);
                }

                Integer seq = nextSeqByPrefix.get(namePrefix);
                String seqPad = isSpace
                    ? String.valueOf(seq).leftPad(2, '0')
                    : String.valueOf(seq).leftPad(3, '0');
                inv.Name = namePrefix + seqPad;
                nextSeqByPrefix.put(namePrefix, seq + 1);
            }

            if (isUpdate) {
                toUpdate.add(inv);
                updateRowNums.add(rowNum);
                rowResultsByNum.put(rowNum, new Map<String, Object>{
                    'row' => rowNum, 'status' => 'pending', 'message' => '', 'id' => (Id) idStr
                });
            } else {
                toInsert.add(inv);
                insertRowNums.add(rowNum);
                rowResultsByNum.put(rowNum, new Map<String, Object>{
                    'row' => rowNum, 'status' => 'pending', 'message' => '', 'id' => null
                });
            }
        }

        // Insert/update with partial success
        Map<String, Object> result = new Map<String, Object>();
        Integer inserted = 0;
        Integer updated = 0;
        List<Id> createdIds = new List<Id>();

        if (!toInsert.isEmpty()) {
            Database.SaveResult[] srs = Database.insert(toInsert, false);
            for (Integer i = 0; i < srs.size(); i++) {
                Integer rn = insertRowNums[i];
                Map<String, Object> entry = rowResultsByNum.get(rn);
                if (srs[i].isSuccess()) {
                    inserted++;
                    createdIds.add(srs[i].getId());
                    entry.put('status', 'created');
                    entry.put('id', srs[i].getId());
                } else {
                    List<String> msgs = new List<String>();
                    for (Database.Error e : srs[i].getErrors()) {
                        String friendly = friendlyDmlError(e, rn);
                        errors.add(friendly);
                        msgs.add(friendly);
                    }
                    entry.put('status', 'error');
                    entry.put('message', String.join(msgs, ' '));
                }
            }
        }

        if (!toUpdate.isEmpty()) {
            Database.SaveResult[] urs = Database.update(toUpdate, false);
            for (Integer i = 0; i < urs.size(); i++) {
                Integer rn = updateRowNums[i];
                Map<String, Object> entry = rowResultsByNum.get(rn);
                if (urs[i].isSuccess()) {
                    updated++;
                    entry.put('status', 'updated');
                } else {
                    List<String> msgs = new List<String>();
                    for (Database.Error e : urs[i].getErrors()) {
                        String friendly = friendlyDmlError(e, rn);
                        errors.add(friendly);
                        msgs.add(friendly);
                    }
                    entry.put('status', 'error');
                    entry.put('message', String.join(msgs, ' '));
                }
            }
        }

        // Ordered row-by-row outcome list, one entry per input row.
        List<Map<String, Object>> rowResults = new List<Map<String, Object>>();
        for (Integer i = 1; i <= rawRows.size(); i++) {
            if (rowResultsByNum.containsKey(i)) {
                rowResults.add(rowResultsByNum.get(i));
            }
        }

        result.put('inserted', inserted);
        result.put('updated', updated);
        result.put('createdIds', createdIds);
        result.put('errors', errors);
        result.put('rowResults', rowResults);
        return result;
    }

    /* ─── Write: Import/upsert inventory from CSV data (legacy) ─────── */

    @AuraEnabled
    public static Map<String, Object> importInventory(
            List<Map<String, String>> rows, Id siteId) {

        if (!Schema.sObjectType.Inventory__c.isCreateable()) {
            throw new AuraHandledException(
                'Insufficient permissions to create Inventory records.');
        }
        if (!Schema.sObjectType.Inventory__c.isUpdateable()) {
            throw new AuraHandledException(
                'Insufficient permissions to update Inventory records.');
        }

        // Record type map
        Map<String, Id> rtMap = new Map<String, Id>();
        for (RecordTypeInfo rti : Schema.SObjectType.Inventory__c
                .getRecordTypeInfosByDeveloperName().values()) {
            if (rti.isActive() && !rti.isMaster()) {
                rtMap.put(rti.getDeveloperName(), rti.getRecordTypeId());
            }
        }

        // Floor + DataHall lookup maps for this site
        Map<String, Id> floorsByName = new Map<String, Id>();
        for (Floor__c f : [
            SELECT Id, Name FROM Floor__c WHERE Site__c = :siteId
        ]) {
            floorsByName.put(f.Name, f.Id);
        }
        Map<String, Id> hallsByName = new Map<String, Id>();
        for (DataHall__c dh : [
            SELECT Id, Name FROM DataHall__c
            WHERE Floor__c IN (SELECT Id FROM Floor__c WHERE Site__c = :siteId)
        ]) {
            hallsByName.put(dh.Name, dh.Id);
        }

        List<Inventory__c> toInsert = new List<Inventory__c>();
        List<Inventory__c> toUpdate = new List<Inventory__c>();
        Integer skipped = 0;

        for (Map<String, String> row : rows) {
            String rowId = row.get('Id');
            Boolean isUpdate = String.isNotBlank(rowId);

            Inventory__c inv = new Inventory__c();
            if (isUpdate) {
                inv.Id = (Id) rowId;
            }

            // Record Type
            String rtDev = row.get('RecordType');
            if (String.isNotBlank(rtDev) && rtMap.containsKey(rtDev)) {
                inv.RecordTypeId = rtMap.get(rtDev);
            } else if (!isUpdate) {
                // Default to Space for new records
                inv.RecordTypeId = rtMap.get('Inventory_Space');
            }

            // Standard fields
            if (row.containsKey('Name'))            inv.Name = row.get('Name');
            if (row.containsKey('Status'))          inv.Status__c = row.get('Status');
            if (row.containsKey('Space_Type'))      inv.Space_Type__c = row.get('Space_Type');
            if (row.containsKey('Usage_Type'))     inv.Usage_Type__c = row.get('Usage_Type');
            if (row.containsKey('Capacity_Type'))   inv.Capacity_Type__c = row.get('Capacity_Type');
            if (row.containsKey('Unit_Reference'))  inv.Unit_Reference__c = row.get('Unit_Reference');
            if (row.containsKey('Breaker_Panel'))   inv.Breaker_Panel__c = row.get('Breaker_Panel');
            if (row.containsKey('Rack_Position'))   inv.Rack_Position__c = row.get('Rack_Position');
            if (row.containsKey('Row'))             inv.Row__c = row.get('Row');
            if (row.containsKey('Zone'))            inv.Zone__c = row.get('Zone');
            if (row.containsKey('Notes'))           inv.Notes__c = row.get('Notes');

            // Numeric fields
            if (row.containsKey('CabE_Count') && String.isNotBlank(row.get('CabE_Count')))
                inv.CabE_Count__c = Decimal.valueOf(row.get('CabE_Count'));
            if (row.containsKey('Total_Capacity_kVA') && String.isNotBlank(row.get('Total_Capacity_kVA')))
                inv.Total_Capacity_kVA__c = Decimal.valueOf(row.get('Total_Capacity_kVA'));
            if (row.containsKey('Power_kVA') && String.isNotBlank(row.get('Power_kVA')))
                inv.Power_kVA__c = Decimal.valueOf(row.get('Power_kVA'));
            if (row.containsKey('Power_Circuit_kVA') && String.isNotBlank(row.get('Power_Circuit_kVA')))
                inv.Power_Circuit_kVA__c = Decimal.valueOf(row.get('Power_Circuit_kVA'));
            if (row.containsKey('Total_kW') && String.isNotBlank(row.get('Total_kW')))
                inv.Total_kW__c = Decimal.valueOf(row.get('Total_kW'));

            // Lookups by name
            if (row.containsKey('Floor') && String.isNotBlank(row.get('Floor'))) {
                Id fId = floorsByName.get(row.get('Floor'));
                if (fId != null) inv.Floor__c = fId;
            }
            if (row.containsKey('Data_Hall') && String.isNotBlank(row.get('Data_Hall'))) {
                Id dhId = hallsByName.get(row.get('Data_Hall'));
                if (dhId != null) inv.Data_Hall__c = dhId;
            }

            // Site is always the current site context
            if (!isUpdate) {
                inv.Site_Id__c = siteId;
            }

            if (isUpdate) {
                toUpdate.add(inv);
            } else {
                toInsert.add(inv);
            }
        }

        Integer inserted = 0;
        Integer updated  = 0;
        List<String> errors = new List<String>();

        List<Id> newOdooIds = new List<Id>();
        if (!toInsert.isEmpty()) {
            Database.SaveResult[] results = Database.insert(toInsert, false);
            for (Integer i = 0; i < results.size(); i++) {
                if (results[i].isSuccess()) {
                    inserted++;
                    newOdooIds.add(results[i].getId());
                } else {
                    for (Database.Error err : results[i].getErrors()) {
                        errors.add('Row ' + (i + 1) + ': ' + err.getMessage());
                    }
                }
            }
        }

        if (!toUpdate.isEmpty()) {
            Database.SaveResult[] results = Database.update(toUpdate, false);
            for (Integer i = 0; i < results.size(); i++) {
                if (results[i].isSuccess()) {
                    updated++;
                } else {
                    for (Database.Error err : results[i].getErrors()) {
                        errors.add('Update row ' + (i + 1) + ': ' + err.getMessage());
                    }
                }
            }
        }



        return new Map<String, Object>{
            'inserted' => inserted,
            'updated'  => updated,
            'errors'   => errors
        };
    }

    /* ─── Read: Check for duplicate inventory name ──────────────────────── */

    @AuraEnabled
    public static Boolean checkDuplicate(String inventoryName) {
        if (String.isBlank(inventoryName)) return false;
        List<Inventory__c> existing = [
            SELECT Id FROM Inventory__c
            WHERE Name = :inventoryName
            LIMIT 1
        ];
        return !existing.isEmpty();
    }

    /* ─── Write: Add a hall to an existing floor ─────────────────────────── */

    @AuraEnabled
    public static Map<String, String> addHallToFloor(Id floorId, Id siteId) {
        if (!Schema.sObjectType.DataHall__c.isCreateable()) {
            throw new AuraHandledException(
                'Insufficient permissions to create Data Hall records.');
        }

        Floor__c floor = [SELECT Id, Name FROM Floor__c WHERE Id = :floorId LIMIT 1];

        // Count existing halls to determine next sequential number
        List<DataHall__c> existingHalls = [
            SELECT Id, Name FROM DataHall__c
            WHERE Floor__c = :floorId
            ORDER BY Name ASC
        ];

        Integer nextNum = existingHalls.size() + 1;
        String hallName = floor.Name + '-' + nextNum;

        DataHall__c newHall = new DataHall__c(
            Name     = hallName,
            Floor__c = floorId,
            Site__c  = siteId
        );
        insert newHall;

        return new Map<String, String>{
            'id'   => newHall.Id,
            'name' => hallName
        };
    }

    /* ─── Read: Assignment demand (QLIs on active quotes for this site) ── */

    // Quotes still awaiting review/assignment action. 'Draft' is excluded — the
    // Assignment UI has never rendered Draft rows (it filters them out client
    // side), so fetching them only burned rows off the LIMIT. 'Accepted' is
    // excluded because closed history dwarfs live demand (partial: 1,917
    // Accepted lines vs 1,105 pending) and it starved every other stage.
    // Accepted stays reachable — the client asks for it explicitly.
    private static final Set<String> PENDING_DEMAND_STATUSES = new Set<String>{
        'In Review', 'Presented', 'Approved'
    };
    // Statuses the client is allowed to request one at a time.
    private static final Set<String> SELECTABLE_DEMAND_STATUSES = new Set<String>{
        'In Review', 'Presented', 'Approved', 'Accepted'
    };
    @TestVisible
    private static final Integer ASSIGNMENT_DEMAND_LIMIT = 2000;

    // CHANGE 2026-08-24 (search): minimum characters before a search reaches the
    // database. Under this length the term is ignored and the plain stage query
    // runs, exactly as it did before this change.
    @TestVisible
    private static final Integer MIN_SEARCH_LENGTH = 3;

    /**
     * @param siteId Site to scope demand to; null = all sites.
     * @param stage  Single quote status to return. Blank / 'All' / unrecognised
     *               falls back to PENDING_DEMAND_STATUSES (or, while searching,
     *               to SELECTABLE_DEMAND_STATUSES — see searchTerm).
     * @param searchTerm Account name / opportunity name / quote number fragment.
     *               Ignored below MIN_SEARCH_LENGTH characters.
     *
     * CHANGE 2026-08-24 (search): search used to run in the browser over
     * whatever rows the LIMIT had already returned, so it could only ever find
     * matches inside the loaded page — an account whose quotes were all
     * Accepted was unfindable under 'All', which never fetched Accepted at all.
     * The term is filtered in SOQL now, so a search reads the whole table.
     *
     * While a term is active and no single stage is picked, the status set
     * widens from PENDING_DEMAND_STATUSES (In Review / Presented / Approved) to
     * SELECTABLE_DEMAND_STATUSES, i.e. those three plus Accepted. That keeps the
     * search set identical to what the stage chips can display: every row a
     * search returns stays reachable by then clicking a chip. Draft, Void and
     * Rejected are deliberately still excluded — no chip renders them.
     *
     * DIG-863: stage is filtered in SOQL, not in the browser. It used to be
     * filtered client side over whatever survived 'LIMIT 500', and because the
     * sort is site code first, that cap cut geographically — in partial the
     * 500 rows stopped inside JKT1, so MNL1, OSA1, PEK1 and every SEL/TYO site
     * returned nothing at all and the stage chips had nothing to filter.
     * Filtering in the query means the cap can never starve a picked stage.
     */
    /* CHANGE 2026-08-24b (quote cap): the row cap used to be spent on LINES, and
     * because the sort is site code first, a term matching more lines than the cap
     * came back as a geographic slice of PARTIAL quotes with nothing saying so.
     * Measured: term "ITOCHU" truly matches 3,275 lines across 641 quotes, but
     * `All` returned 2,000 lines covering 301 quotes and `Accepted` returned a
     * DIFFERENT 2,000 lines covering 279 — which is why the chips could not be
     * reconciled with All. The budget is now spent on WHOLE quotes: quotes are
     * taken in display order until the next one would not fit, so every quote
     * rendered is complete. getAssignmentDemandMeta() reports the true totals so
     * the UI can say how much was left out.
     *
     * The line budget itself is unchanged at ASSIGNMENT_DEMAND_LIMIT, deliberately:
     * a 2,000-row response already measures ~5.2 MB against the 6 MB Apex heap
     * limit, so raising it would trade this bug for a LimitException.
     */

    // Fields the Assignment rows render. Shared by the row query so the phase-1
    // scan and the phase-2 fetch cannot drift apart.
    private static final String DEMAND_SELECT =
          'SELECT Id, QuoteId, Quote.QuoteNumber, Quote.Name, Quote.Status, '
        + 'Quote.RDD__c, '
        + 'Quote.Target_Site__c, Quote.Target_Site__r.Site_Code__c, '
        + 'Quote.Opportunity.Name, '
        + 'Quote.Opportunity.Account.Name, '
        + 'Product2.Name, Product2.ProductCode, '
        + 'Quantity, Reserved__c, '
        + 'Space_ID__c, Space_ID__r.Name, Space_ID__r.Site_Id__c, '
        + 'Breaker_ID__c, Breaker_ID__r.Name, Breaker_ID__r.Site_Id__c, '
        + 'Power_kVA__c, CabE__c, '
        + 'Assigned_Inventory_Location__c '
        + 'FROM QuoteLineItem ';

    private static final String DEMAND_ORDER =
        ' ORDER BY Quote.Target_Site__r.Site_Code__c ASC NULLS LAST, '
        + 'Quote.QuoteNumber ASC, Product2.Name ASC ';

    // Phase 1 selects QuoteId only, so its heap cost is negligible and it can
    // afford to see far more rows than the render budget. Beyond this the totals
    // become a floor rather than a count, which scanCapped reports.
    @TestVisible
    private static final Integer ASSIGNMENT_SCAN_LIMIT = 20000;

    /* Builds the shared WHERE fragment. CALLER CONTRACT: the calling method must
     * hold locals named exactly `demandStatuses`, `siteId` and `search`, because
     * the returned text binds to them. */
    private static String demandWhere(Boolean bySite, Boolean isSearch) {
        // Status gates every row now. It used to sit inside the first OR branch
        // only, so a QLI matched via assigned space/breaker came back at ANY
        // status - Void, Rejected, Draft - and ate the cap.
        String w = 'WHERE Quote.Status IN :demandStatuses';
        if (bySite) {
            // Show QLIs that target this site via quote OR have inventory assigned at this site
            w += ' AND (Quote.Target_Site__c = :siteId '
               + 'OR Space_ID__r.Site_Id__c = :siteId '
               + 'OR Breaker_ID__r.Site_Id__c = :siteId)';
        }
        if (isSearch) {
            // The three fields the Assignment rows display - the account name, the
            // opportunity name it falls back to when the account is blank, and the
            // quote number. Bound, never concatenated.
            w += ' AND (Quote.Opportunity.Account.Name LIKE :search'
               + ' OR Quote.Opportunity.Name LIKE :search'
               + ' OR Quote.QuoteNumber LIKE :search)';
        }
        return w;
    }

    private static Set<String> demandStatusesFor(String stage, Boolean isSearch) {
        Boolean stagePicked =
            String.isNotBlank(stage) && SELECTABLE_DEMAND_STATUSES.contains(stage);
        // A picked chip narrows to that one status, searching or not. 'All' widens
        // to include Accepted only once a term is active.
        return stagePicked
            ? new Set<String>{ stage }
            : (isSearch ? SELECTABLE_DEMAND_STATUSES : PENDING_DEMAND_STATUSES);
    }

    private static Boolean isSearchTerm(String searchTerm) {
        String term = String.isBlank(searchTerm) ? '' : searchTerm.trim();
        return term.length() >= MIN_SEARCH_LENGTH;
    }

    /* Which quotes to render, and what the true totals are. */
    private class DemandScope {
        List<Id> pick = new List<Id>();
        Integer totalQuotes = 0;
        Integer totalLines  = 0;
        Integer shownLines  = 0;
        Boolean scanCapped  = false;
        Boolean truncated() { return totalQuotes > pick.size(); }
    }

    private static DemandScope demandScope(Id siteId, String stage, String searchTerm) {
        Boolean isSearch = isSearchTerm(searchTerm);
        Set<String> demandStatuses = demandStatusesFor(stage, isSearch);
        String search = likeTerm(String.isBlank(searchTerm) ? '' : searchTerm.trim());
        String q = 'SELECT QuoteId FROM QuoteLineItem '
                 + demandWhere(siteId != null, isSearch)
                 + DEMAND_ORDER
                 + ' LIMIT ' + ASSIGNMENT_SCAN_LIMIT;

        DemandScope sc = new DemandScope();
        // Rows arrive in display order, so a quote's lines are contiguous and the
        // first time an id appears is its display position.
        List<Id> ordered = new List<Id>();
        Map<Id, Integer> perQuote = new Map<Id, Integer>();
        for (QuoteLineItem probe : Database.query(q)) {
            if (!perQuote.containsKey(probe.QuoteId)) {
                ordered.add(probe.QuoteId);
                perQuote.put(probe.QuoteId, 0);
            }
            perQuote.put(probe.QuoteId, perQuote.get(probe.QuoteId) + 1);
            sc.totalLines++;
        }
        sc.totalQuotes = ordered.size();
        sc.scanCapped  = (sc.totalLines == ASSIGNMENT_SCAN_LIMIT);

        for (Id qid : ordered) {
            Integer c = perQuote.get(qid);
            // Never return a partial quote. The only exception is a first quote
            // that alone exceeds the budget - taking it beats rendering nothing.
            if (!sc.pick.isEmpty() && sc.shownLines + c > ASSIGNMENT_DEMAND_LIMIT) break;
            sc.pick.add(qid);
            sc.shownLines += c;
        }
        return sc;
    }

    @AuraEnabled
    public static List<QuoteLineItem> getAssignmentDemand(Id siteId, String stage,
                                                          String searchTerm) {
        DemandScope sc = demandScope(siteId, stage, searchTerm);
        if (sc.pick.isEmpty()) return new List<QuoteLineItem>();

        Boolean isSearch = isSearchTerm(searchTerm);
        Set<String> demandStatuses = demandStatusesFor(stage, isSearch);
        String search = likeTerm(String.isBlank(searchTerm) ? '' : searchTerm.trim());
        Set<Id> picked = new Set<Id>(sc.pick);

        // The original predicate is kept verbatim and merely restricted to the
        // chosen quotes. That matters for the site-scoped view, whose filter is
        // partly line-level (assigned space/breaker), so fetching every line of a
        // quote would surface lines the old query correctly excluded.
        String q = DEMAND_SELECT
                 + demandWhere(siteId != null, isSearch)
                 + ' AND QuoteId IN :picked'
                 + DEMAND_ORDER
                 // Backstop only: the budget loop already bounds this. Guards the
                 // pathological single-quote-over-budget case against heap.
                 + ' LIMIT ' + (ASSIGNMENT_DEMAND_LIMIT + 500);
        return stripped(Database.query(q));
    }

    /* True totals for the same filters, so the UI can report what was left out
     * instead of presenting a truncated slice as the whole answer. Counts come
     * from the phase-1 scan, which is not subject to the render budget. */
    @AuraEnabled
    public static Map<String, Object> getAssignmentDemandMeta(Id siteId, String stage,
                                                              String searchTerm) {
        DemandScope sc = demandScope(siteId, stage, searchTerm);
        return new Map<String, Object>{
            'totalQuotes' => sc.totalQuotes,
            'shownQuotes' => sc.pick.size(),
            'totalLines'  => sc.totalLines,
            'shownLines'  => sc.shownLines,
            'truncated'   => sc.truncated(),
            'scanCapped'  => sc.scanCapped
        };
    }

    /* ─── Read: Available inventory by record type ─────────────────────── */

    @AuraEnabled
    public static Map<String, Integer> getAvailableByType(Id siteId) {
        Set<String> availStatuses = new Set<String>{'Available', 'Pending Available'};
        List<AggregateResult> availAgg = [
            SELECT RecordType.DeveloperName rt, COUNT(Id) c
            FROM Inventory__c
            WHERE Site_Id__c = :siteId
              AND Status__c IN :availStatuses
            GROUP BY RecordType.DeveloperName
        ];
        List<AggregateResult> totalAgg = [
            SELECT RecordType.DeveloperName rt, COUNT(Id) c
            FROM Inventory__c
            WHERE Site_Id__c = :siteId
            GROUP BY RecordType.DeveloperName
        ];
        Map<String, Integer> result = new Map<String, Integer>();
        result.put('Space', 0);
        result.put('Breaker', 0);
        result.put('SpaceTotal', 0);
        result.put('BreakerTotal', 0);
        for (AggregateResult a : availAgg) {
            String rt = (String) a.get('rt');
            Integer cnt = (Integer) a.get('c');
            if (rt == 'Inventory_Space') result.put('Space', cnt);
            else if (rt == 'Inventory_Breaker') result.put('Breaker', cnt);
        }
        for (AggregateResult a : totalAgg) {
            String rt = (String) a.get('rt');
            Integer cnt = (Integer) a.get('c');
            if (rt == 'Inventory_Space') result.put('SpaceTotal', cnt);
            else if (rt == 'Inventory_Breaker') result.put('BreakerTotal', cnt);
        }
        return result;
    }

    /* ─── Cross connect asset update ─────────────────────────────────── */

    @AuraEnabled
    public static void updateCrossId(Id lineItemId, Id A_Side_Asset, Id Z_Side_Asset) {
        if (!Schema.sObjectType.QuoteLineItem.isUpdateable()) {
            throw new AuraHandledException('Insufficient permissions to update Quote Line Items.');
        }
        QuoteLineItem qli = new QuoteLineItem(
            Id = lineItemId,
            A_Side_Asset__c = A_Side_Asset,
            Z_Side_Asset__c = Z_Side_Asset
        );
        update qli;
    }

    /* ─── Read: Odoo sync status for recently imported/created records ──── */

    @AuraEnabled
    public static Map<String, Integer> getOdooSyncStatus(List<Id> inventoryIds) {
        Map<String, Integer> result = new Map<String, Integer>{
            'total' => 0, 'synced' => 0, 'failed' => 0, 'pending' => 0
        };
        if (inventoryIds == null || inventoryIds.isEmpty()) return result;

        List<Inventory__c> records = [
            SELECT Id, Odoo_Space_ID__c, Odoo_Sync_Error__c
            FROM Inventory__c
            WHERE Id IN :inventoryIds
            WITH SECURITY_ENFORCED
        ];
        result.put('total', records.size());
        for (Inventory__c r : records) {
            if (String.isNotBlank(r.Odoo_Space_ID__c)) {
                result.put('synced', result.get('synced') + 1);
            } else if (String.isNotBlank(r.Odoo_Sync_Error__c)) {
                result.put('failed', result.get('failed') + 1);
            } else {
                result.put('pending', result.get('pending') + 1);
            }
        }
        return result;
    }

    /* ─── Helper ───────────────────────────────────────────────────────── */

    // Cache of active picklist values per field API name, scoped to this transaction.
    private static Map<String, Set<String>> picklistValueCache = new Map<String, Set<String>>();

    private static Set<String> getPicklistValues(String apiName) {
        String key = apiName.toLowerCase();
        if (picklistValueCache.containsKey(key)) return picklistValueCache.get(key);

        Set<String> values = new Set<String>();
        Schema.SObjectField field = Inventory__c.sObjectType.getDescribe().fields.getMap().get(key);
        if (field != null) {
            for (Schema.PicklistEntry pe : field.getDescribe().getPicklistValues()) {
                if (pe.isActive()) values.add(pe.getValue());
            }
        }
        picklistValueCache.put(key, values);
        return values;
    }

    // Translates a Database.Error into a message a non-admin user can act on.
    // Falls back to the raw platform message for anything not explicitly handled.
    private static String friendlyDmlError(Database.Error err, Integer rowNum) {
        String code = err.getStatusCode() != null ? String.valueOf(err.getStatusCode()) : '';
        String raw = err.getMessage();

        if (code == 'REQUIRED_FIELD_MISSING') {
            String fields = (err.getFields() != null && !err.getFields().isEmpty())
                ? String.join(err.getFields(), ', ') : 'one or more fields';
            return 'Row ' + rowNum + ': Missing required field(s) — ' + fields + '.';
        }
        if (code == 'DUPLICATE_VALUE') {
            return 'Row ' + rowNum + ': A duplicate record already exists.';
        }
        if (code == 'STRING_TOO_LONG') {
            String fields = (err.getFields() != null && !err.getFields().isEmpty())
                ? String.join(err.getFields(), ', ') : '';
            return 'Row ' + rowNum + ': A value is too long for ' + fields + '.';
        }
        if (raw.containsIgnoreCase('bad value for restricted picklist')) {
            return 'Row ' + rowNum + ': One or more values are not valid options for this field.';
        }
        if (code == 'FIELD_CUSTOM_VALIDATION_EXCEPTION') {
            return 'Row ' + rowNum + ': ' + raw;
        }
        return 'Row ' + rowNum + ': ' + raw;
    }

    // CHANGE 2026-08-24 (search): wraps a user's term in LIKE wildcards, escaping
    // the wildcards it may itself contain. Without this, typing '%' matches every
    // row and typing '_' matches any character — the term is always bound, so
    // this is about the search being literal, not about injection.
    @TestVisible
    private static String likeTerm(String raw) {
        String s = (raw == null ? '' : raw.trim())
            .replace('\\', '\\\\')
            .replace('%', '\\%')
            .replace('_', '\\_');
        return '%' + s + '%';
    }

    private static List<SObject> stripped(List<SObject> records) {
        return Security.stripInaccessible(AccessType.READABLE, records)
            .getRecords();
    }
}