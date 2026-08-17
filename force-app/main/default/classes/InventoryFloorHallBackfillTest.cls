@IsTest
private class InventoryFloorHallBackfillTest {

    private static Id spaceRtId() {
        return Schema.SObjectType.Inventory__c
            .getRecordTypeInfosByDeveloperName().get('Inventory_Space').getRecordTypeId();
    }

    /**
     * Builds a site with four floors and their data halls, exercising every
     * floor/hall matching strategy in InventoryFloorHallBackfill:
     *  - Floor A ('JKT1-3'): exact floor-key match, single data hall (size==1 branch).
     *  - Floor B ('JKT1-06'): zero-padded floor match; one hall matched by exact
     *    lastSeg string match, another by numeric fallback ('02' vs lastSeg '2').
     *  - Floor C ('JKT1-8'): unpadded floor match (name uses '08'); hall matched
     *    via the non-numeric containsIgnoreCase fallback.
     *  - Floor E ('JKT1-9'): floor matches but has zero data halls.
     * Plus three inventory records that should remain unmatched:
     *  - wrong site-code prefix
     *  - too few name segments after the site code
     *  - a floor suffix that does not exist under the site at all
     */
    @IsTest
    static void testExecute_AllMatchingStrategiesAndUnmatchedCases() {
        Site__c site = new Site__c(Name = 'JKT1', Site_Code__c = 'JKT1', Country__c = 'ID');
        insert site;

        Floor__c floorA = new Floor__c(Name = 'JKT1-3', Site__c = site.Id);
        Floor__c floorB = new Floor__c(Name = 'JKT1-06', Site__c = site.Id);
        Floor__c floorC = new Floor__c(Name = 'JKT1-8', Site__c = site.Id);
        Floor__c floorE = new Floor__c(Name = 'JKT1-9', Site__c = site.Id);
        insert new List<Floor__c>{ floorA, floorB, floorC, floorE };

        DataHall__c hallA1 = new DataHall__c(Name = 'JKT1-3-1', Floor__c = floorA.Id, Site__c = site.Id);
        DataHall__c hallB1 = new DataHall__c(Name = 'JKT1-06-1', Floor__c = floorB.Id, Site__c = site.Id);
        DataHall__c hallB2 = new DataHall__c(Name = 'JKT1-06-2', Floor__c = floorB.Id, Site__c = site.Id);
        DataHall__c hallCMdf = new DataHall__c(Name = 'JKT1-8-MDF-A', Floor__c = floorC.Id, Site__c = site.Id);
        DataHall__c hallCOther = new DataHall__c(Name = 'JKT1-8-OTHER-B', Floor__c = floorC.Id, Site__c = site.Id);
        insert new List<DataHall__c>{ hallA1, hallB1, hallB2, hallCMdf, hallCOther };
        // Floor E intentionally has no data halls.

        Id spaceRt = spaceRtId();
        Inventory__c invSingleHall     = new Inventory__c(Name = 'JKT1-3-1-S-001', RecordTypeId = spaceRt, Site_Id__c = site.Id, Status__c = 'Available');
        Inventory__c invLeadingUnderscore = new Inventory__c(Name = '_JKT1-3-1-S-002', RecordTypeId = spaceRt, Site_Id__c = site.Id, Status__c = 'Available');
        Inventory__c invZeroPadExact    = new Inventory__c(Name = 'JKT1-6-2-S-001', RecordTypeId = spaceRt, Site_Id__c = site.Id, Status__c = 'Available');
        Inventory__c invZeroPadNumeric  = new Inventory__c(Name = 'JKT1-6-02-S-001', RecordTypeId = spaceRt, Site_Id__c = site.Id, Status__c = 'Available');
        Inventory__c invUnpaddedFuzzy   = new Inventory__c(Name = 'JKT1-08-MDF-S-001', RecordTypeId = spaceRt, Site_Id__c = site.Id, Status__c = 'Available');
        Inventory__c invFloorNoHalls    = new Inventory__c(Name = 'JKT1-9-1-S-001', RecordTypeId = spaceRt, Site_Id__c = site.Id, Status__c = 'Available');
        Inventory__c invWrongSite       = new Inventory__c(Name = 'WRONG-3-1-S-001', RecordTypeId = spaceRt, Site_Id__c = site.Id, Status__c = 'Available');
        Inventory__c invTooFewSegments  = new Inventory__c(Name = 'JKT1-3', RecordTypeId = spaceRt, Site_Id__c = site.Id, Status__c = 'Available');
        Inventory__c invFloorNotFound   = new Inventory__c(Name = 'JKT1-99-1-S-001', RecordTypeId = spaceRt, Site_Id__c = site.Id, Status__c = 'Available');

        List<Inventory__c> allInv = new List<Inventory__c>{
            invSingleHall, invLeadingUnderscore, invZeroPadExact, invZeroPadNumeric,
            invUnpaddedFuzzy, invFloorNoHalls, invWrongSite, invTooFewSegments, invFloorNotFound
        };
        insert allInv;

        InventoryFloorHallBackfill batchInstance = new InventoryFloorHallBackfill();

        Test.startTest();
        Database.executeBatch(batchInstance, 200);
        Test.stopTest();

        Map<Id, Inventory__c> updated = new Map<Id, Inventory__c>(
            [SELECT Id, Floor__c, Data_Hall__c FROM Inventory__c WHERE Id IN :allInv]
        );

        Assert.areEqual(floorA.Id, updated.get(invSingleHall.Id).Floor__c, 'Exact floor match with a single hall');
        Assert.areEqual(hallA1.Id, updated.get(invSingleHall.Id).Data_Hall__c, 'Single hall under the floor should be used');

        Assert.areEqual(floorA.Id, updated.get(invLeadingUnderscore.Id).Floor__c, 'Leading underscore should be stripped before matching');
        Assert.areEqual(hallA1.Id, updated.get(invLeadingUnderscore.Id).Data_Hall__c, 'Underscore-stripped name should still resolve the hall');

        Assert.areEqual(floorB.Id, updated.get(invZeroPadExact.Id).Floor__c, 'Zero-padded floor key should match an unpadded floor suffix');
        Assert.areEqual(hallB2.Id, updated.get(invZeroPadExact.Id).Data_Hall__c, 'Hall should match by exact last-segment string comparison');

        Assert.areEqual(floorB.Id, updated.get(invZeroPadNumeric.Id).Floor__c, 'Zero-padded floor key should match again for the numeric hall case');
        Assert.areEqual(hallB2.Id, updated.get(invZeroPadNumeric.Id).Data_Hall__c, 'Hall should match numerically when the hall suffix is zero-padded');

        Assert.areEqual(floorC.Id, updated.get(invUnpaddedFuzzy.Id).Floor__c, 'Unpadded floor key should match a padded floor suffix in the name');
        Assert.areEqual(hallCMdf.Id, updated.get(invUnpaddedFuzzy.Id).Data_Hall__c, 'Non-numeric hall suffix should match via containsIgnoreCase fallback');

        Assert.areEqual(floorE.Id, updated.get(invFloorNoHalls.Id).Floor__c, 'Floor with no data halls should still be matched');
        Assert.isNull(updated.get(invFloorNoHalls.Id).Data_Hall__c, 'No data hall should be assigned when the floor has none');

        Assert.isNull(updated.get(invWrongSite.Id).Floor__c, 'Name not prefixed with the site code should be unmatched');
        Assert.isNull(updated.get(invTooFewSegments.Id).Floor__c, 'Name with too few segments after the site code should be unmatched');
        Assert.isNull(updated.get(invFloorNotFound.Id).Floor__c, 'Floor suffix that does not exist should be unmatched');
    }

    @IsTest
    static void testExecute_Bulk200Records() {
        Site__c site = new Site__c(Name = 'JKTB', Site_Code__c = 'JKTB', Country__c = 'ID');
        insert site;

        Floor__c floor = new Floor__c(Name = 'JKTB-1', Site__c = site.Id);
        insert floor;

        DataHall__c hall = new DataHall__c(Name = 'JKTB-1-1', Floor__c = floor.Id, Site__c = site.Id);
        insert hall;

        Id spaceRt = spaceRtId();
        List<Inventory__c> invs = new List<Inventory__c>();
        for (Integer i = 0; i < 200; i++) {
            invs.add(new Inventory__c(
                Name = 'JKTB-1-1-S-' + String.valueOf(i).leftPad(4, '0'),
                RecordTypeId = spaceRt,
                Site_Id__c = site.Id,
                Status__c = 'Available'
            ));
        }
        insert invs;

        InventoryFloorHallBackfill batchInstance = new InventoryFloorHallBackfill();

        Test.startTest();
        Database.executeBatch(batchInstance, 200);
        Test.stopTest();

        Integer floorSetCount = [SELECT COUNT() FROM Inventory__c WHERE Id IN :invs AND Floor__c = :floor.Id];
        Integer hallSetCount = [SELECT COUNT() FROM Inventory__c WHERE Id IN :invs AND Data_Hall__c = :hall.Id];
        Assert.areEqual(200, floorSetCount, 'All 200 records should have Floor__c populated');
        Assert.areEqual(200, hallSetCount, 'All 200 records should have Data_Hall__c populated');
    }

    @IsTest
    static void testStartAndFinish_NoEligibleRecords() {
        // No Inventory__c records exist yet, so start()'s QueryLocator returns
        // an empty scope and finish() should still complete cleanly.
        InventoryFloorHallBackfill batchInstance = new InventoryFloorHallBackfill();

        Test.startTest();
        Database.executeBatch(batchInstance, 200);
        Test.stopTest();

        Assert.areEqual(0, batchInstance.matched, 'No records should be matched when there is no eligible scope');
        Assert.areEqual(0, batchInstance.unmatched, 'No records should be unmatched when there is no eligible scope');
    }
}