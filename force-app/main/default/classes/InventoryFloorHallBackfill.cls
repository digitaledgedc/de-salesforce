/**
 * One-time batch to backfill Floor__c and Data_Hall__c lookups on Inventory__c.
 * The imported Odoo data has floor/hall encoded in the Name (e.g. JKT1-3-1-S-001)
 * but the lookup fields were never populated.
 *
 * Run via: Database.executeBatch(new InventoryFloorHallBackfill(), 200);
 */
public without sharing class InventoryFloorHallBackfill
        implements Database.Batchable<SObject>, Database.Stateful {

    // SiteCode-FloorSuffix → Floor Id   e.g. 'JKT1-3' → a0I...
    private Map<String, Id> floorMap;

    // FloorId → list of DataHall records under that floor
    private Map<Id, List<DataHall__c>> hallsByFloor;

    public Integer matched   = 0;
    public Integer unmatched = 0;

    public InventoryFloorHallBackfill() {
        floorMap = new Map<String, Id>();
        for (Floor__c f : [SELECT Id, Name FROM Floor__c]) {
            floorMap.put(f.Name, f.Id);
        }

        hallsByFloor = new Map<Id, List<DataHall__c>>();
        for (DataHall__c dh : [SELECT Id, Name, Floor__c FROM DataHall__c]) {
            List<DataHall__c> lst = hallsByFloor.get(dh.Floor__c);
            if (lst == null) {
                lst = new List<DataHall__c>();
                hallsByFloor.put(dh.Floor__c, lst);
            }
            lst.add(dh);
        }
    }

    /* ─── Start ────────────────────────────────────────────────── */

    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([
            SELECT Id, Name, Site_Id__r.Site_Code__c
            FROM Inventory__c
            WHERE Floor__c = null
              AND RecordType.DeveloperName = 'Inventory_Space'
              AND Site_Id__c != null
        ]);
    }

    /* ─── Execute ──────────────────────────────────────────────── */

    public void execute(Database.BatchableContext bc, List<Inventory__c> scope) {
        List<Inventory__c> toUpdate = new List<Inventory__c>();

        for (Inventory__c inv : scope) {
            String siteCode = inv.Site_Id__r.Site_Code__c;
            if (String.isBlank(siteCode)) {
                unmatched++;
                continue;
            }

            // Strip leading underscore (some TYO records have _TYO1-...)
            String cleanName = inv.Name;
            if (cleanName.startsWith('_')) {
                cleanName = cleanName.substring(1);
            }

            // Must start with SITE-
            if (!cleanName.startsWith(siteCode + '-')) {
                unmatched++;
                continue;
            }

            // After site code: FLOOR-HALL-USAGE-...
            String afterSite = cleanName.removeStart(siteCode + '-');
            List<String> parts = afterSite.split('-');
            if (parts.size() < 2) {
                unmatched++;
                continue;
            }

            String floorPart = parts[0];  // e.g. '3', 'GF', '06'
            String hallPart  = parts[1];  // e.g. '1', 'MDF'

            // ── Match Floor ──
            // Try exact: 'JKT1-3'
            String floorKey = siteCode + '-' + floorPart;
            Id floorId = floorMap.get(floorKey);

            // Try zero-padded: 'JKT2-06' when floorPart is '6'
            if (floorId == null && floorPart.isNumeric()) {
                floorId = floorMap.get(siteCode + '-' + floorPart.leftPad(2, '0'));
            }
            // Try unpadded: 'JKT2-8' when floorPart is '08'
            if (floorId == null && floorPart.isNumeric()) {
                floorId = floorMap.get(siteCode + '-' + String.valueOf(Integer.valueOf(floorPart)));
            }

            if (floorId == null) {
                unmatched++;
                continue;
            }

            // ── Match DataHall ──
            Id hallId = null;
            List<DataHall__c> halls = hallsByFloor.get(floorId);

            if (halls != null && !halls.isEmpty()) {
                if (halls.size() == 1) {
                    // Only one hall — use it
                    hallId = halls[0].Id;
                } else {
                    // Multiple halls — match by hall number
                    Integer hallNum = null;
                    if (hallPart.isNumeric()) {
                        hallNum = Integer.valueOf(hallPart);
                    }

                    for (DataHall__c dh : halls) {
                        // Compare last segment of DataHall name numerically
                        String lastSeg = dh.Name.substringAfterLast('-');
                        if (hallPart == lastSeg) {
                            hallId = dh.Id;
                            break;
                        }
                        if (hallNum != null && lastSeg.isNumeric()
                                && Integer.valueOf(lastSeg) == hallNum) {
                            hallId = dh.Id;
                            break;
                        }
                    }

                    // Fallback: if hallPart is non-numeric (e.g. 'MDF'), check
                    // if any hall name contains it
                    if (hallId == null && !hallPart.isNumeric()) {
                        for (DataHall__c dh : halls) {
                            if (dh.Name.containsIgnoreCase(hallPart)) {
                                hallId = dh.Id;
                                break;
                            }
                        }
                    }
                }
            }

            Inventory__c upd = new Inventory__c(Id = inv.Id, Floor__c = floorId);
            if (hallId != null) {
                upd.Data_Hall__c = hallId;
            }
            toUpdate.add(upd);
            matched++;
        }

        if (!toUpdate.isEmpty()) {
            Database.SaveResult[] results = Database.update(toUpdate, false);
            for (Database.SaveResult sr : results) {
                if (!sr.isSuccess()) {
                    for (Database.Error err : sr.getErrors()) {
                        System.debug(LoggingLevel.WARN,
                            'Backfill failed for ' + sr.getId() + ': ' + err.getMessage());
                    }
                }
            }
        }
    }

    /* ─── Finish ───────────────────────────────────────────────── */

    public void finish(Database.BatchableContext bc) {
        System.debug(LoggingLevel.INFO,
            'InventoryFloorHallBackfill complete — matched: ' + matched
            + ', unmatched: ' + unmatched);
    }
}