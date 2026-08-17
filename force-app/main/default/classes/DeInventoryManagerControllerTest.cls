@IsTest
private class DeInventoryManagerControllerTest {

    // ═══════════════════════════════════════════════════════════════════
    // Shared setup — small, deterministic fixture reused by the original
    // read-path tests. New tests that need a different data shape build
    // their own isolated Site/Floor/Hall via the helpers below instead of
    // mutating this shared fixture, so nothing here needs to change.
    // ═══════════════════════════════════════════════════════════════════

    @TestSetup
    static void setup() {
        // ── Site ──────────────────────────────────────────────────────────
        Site__c site = new Site__c(Site_Code__c = 'TEST-SG01', Country__c = 'SG',
            Pricebook2__c = Test.getStandardPricebookId());
        insert site;

        // ── Floor ─────────────────────────────────────────────────────────
        Floor__c floor = new Floor__c(
            Name     = 'TEST-SG01-01',
            Site__c  = site.Id,
            Sequence__c = 1
        );
        insert floor;

        // ── Data Hall ─────────────────────────────────────────────────────
        DataHall__c hall = new DataHall__c(
            Name               = 'TEST-SG01-01-01',
            Floor__c           = floor.Id,
            Site__c            = site.Id,
            Sequence__c        = 1,
            Room_Description__c = 'Test Data Hall'
        );
        insert hall;

        // ── Record Type IDs ───────────────────────────────────────────────
        Id spaceRtId = Schema.SObjectType.Inventory__c
            .getRecordTypeInfosByDeveloperName().get('Inventory_Space').getRecordTypeId();
        Id breakerRtId = Schema.SObjectType.Inventory__c
            .getRecordTypeInfosByDeveloperName().get('Inventory_Breaker').getRecordTypeId();

        // ── Inventory records ─────────────────────────────────────────────
        List<Inventory__c> records = new List<Inventory__c>{
            // Space — Available
            new Inventory__c(
                RecordTypeId        = spaceRtId,
                Site_Id__c          = site.Id,
                Floor__c            = floor.Id,
                Data_Hall__c        = hall.Id,
                Status__c           = 'Available',
                Space_Type__c       = 'Cabinet',
                Total_Capacity_kVA__c = 10,
                Power_kVA__c        = 5,
                Unit_Reference__c   = 'SG01-DH01-A001'
            ),
            // Space — Quoted (needs Assigned_To_Quote__c for VR, but VR checks QuoteLine — skip for now)
            new Inventory__c(
                RecordTypeId        = spaceRtId,
                Site_Id__c          = site.Id,
                Floor__c            = floor.Id,
                Data_Hall__c        = hall.Id,
                Status__c           = 'Available',
                Space_Type__c       = 'Cage',
                Total_Capacity_kVA__c = 50,
                Power_kVA__c        = 25,
                Unit_Reference__c   = 'SG01-DH01-A002'
            ),
            // Breaker — Available
            new Inventory__c(
                RecordTypeId      = breakerRtId,
                Site_Id__c        = site.Id,
                Floor__c          = floor.Id,
                Data_Hall__c      = hall.Id,
                Status__c         = 'Available',
                Capacity_Type__c  = 'Power Circuit',
                Total_kW__c       = 20,
                Breaker_Panel__c  = 'BP-01',
                Unit_Reference__c = 'SG01-DH01-P001'
            )
        };
        insert records;
    }

    // ═══════════════════════════════════════════════════════════════════
    // Local, self-contained helpers (no shared utility class — private
    // to this test class only, per the parallel-authoring rule).
    // ═══════════════════════════════════════════════════════════════════

    private static Id spaceRt() {
        return Schema.SObjectType.Inventory__c
            .getRecordTypeInfosByDeveloperName().get('Inventory_Space').getRecordTypeId();
    }

    private static Id breakerRt() {
        return Schema.SObjectType.Inventory__c
            .getRecordTypeInfosByDeveloperName().get('Inventory_Breaker').getRecordTypeId();
    }

    private static Site__c mkSite(String code, String country) {
        Site__c s = new Site__c(Site_Code__c = code, Country__c = country,
            Pricebook2__c = Test.getStandardPricebookId());
        insert s;
        return s;
    }

    private static Floor__c mkFloor(Id siteId, String name) {
        Floor__c f = new Floor__c(Name = name, Site__c = siteId);
        insert f;
        return f;
    }

    private static DataHall__c mkHall(Id floorId, String name, String hallNumber) {
        Id siteId = [SELECT Site__c FROM Floor__c WHERE Id = :floorId LIMIT 1].Site__c;
        DataHall__c h = new DataHall__c(Name = name, Floor__c = floorId, Site__c = siteId, Hall_Number__c = hallNumber);
        insert h;
        return h;
    }

    private static Quote mkQuote() {
        Account acc = new Account(Name = 'QA-Acc');
        insert acc;
        Id stdPbId = Test.getStandardPricebookId();
        Opportunity opp = new Opportunity(
            Name = 'QA-Opp', AccountId = acc.Id,
            StageName = '1-Suspect', CloseDate = Date.today().addDays(15),
            CurrencyIsoCode = 'USD',
            Pricebook2Id = stdPbId
        );
        insert opp;
        Quote q = new Quote(Name = 'QA-Quote', OpportunityId = opp.Id, Status = 'Draft',
            CurrencyIsoCode = 'USD', Pricebook2Id = stdPbId);
        insert q;
        return q;
    }

    // Builds a fully-linked QuoteLineItem (Account/Opportunity/Quote/Product2/
    // PricebookEntry/QLI) so getAssignmentDemand()/updateCrossId() have a real
    // record to query/update. Deliberately does NOT touch QuoteLineItem.Space_ID__c
    // or Breaker_ID__c — see final report re: schema-drift risk on those fields.
    private static QuoteLineItem mkQuoteLineItem(Id targetSiteId) {
        return mkQuoteLineItem(targetSiteId, null);
    }

    // Same builder, but puts the parent Quote on a chosen Status. Needed since
    // DIG-863: getAssignmentDemand() filters status in SOQL, so a test that cares
    // which stage a row is on has to say so. Null leaves mkQuote()'s 'Draft'.
    //
    // The status move happens AFTER the line item is inserted: a validation rule
    // blocks QLI DML once the quote leaves Draft ("Line items can only be edited
    // in Draft"). 'Accepted' additionally needs Finance_Approval_Status__c set,
    // or a second rule blocks the transition.
    private static QuoteLineItem mkQuoteLineItem(Id targetSiteId, String quoteStatus) {
        Quote q = mkQuote();
        Id stdPbId = Test.getStandardPricebookId();
        q.Target_Site__c = targetSiteId;
        q.Pricebook2Id = stdPbId;
        update q;
        q = [SELECT Id, CurrencyIsoCode, Pricebook2Id FROM Quote WHERE Id = :q.Id];

        Product2 prod = new Product2(Name = 'QA-Prod', IsActive = true);
        insert prod;
        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = q.Pricebook2Id, Product2Id = prod.Id, UnitPrice = 100,
            CurrencyIsoCode = q.CurrencyIsoCode, IsActive = true
        );
        insert pbe;

        QuoteLineItem qli = new QuoteLineItem(
            QuoteId = q.Id, Product2Id = prod.Id, PricebookEntryId = pbe.Id,
            Quantity = 2, UnitPrice = 100
        );
        insert qli;
        moveQuoteTo(q.Id, quoteStatus);
        return qli;
    }

    // Moves a quote off Draft, satisfying the rules that guard the transition:
    //
    //  - VR_QUOTE_12_Binding_Requires_RDD blocks Draft -> 'In Review' when RDD__c
    //    is blank. Set unconditionally; it is harmless on the other statuses.
    //  - 'Accepted' is rejected while Finance_Approval_Status__c is Pending or
    //    Rejected. 'Not Required' clears that without waking the "Init Finance
    //    Approval" flow, which faults on a synthetic quote.
    //
    // Note VR_QUOTE_12 is ACTIVE in production and INACTIVE in the partial and full
    // sandboxes, so a sandbox-only test run will not catch a missing RDD__c.
    private static void moveQuoteTo(Id quoteId, String quoteStatus) {
        if (String.isBlank(quoteStatus) || quoteStatus == 'Draft') return;
        Quote toMove = new Quote(
            Id = quoteId, Status = quoteStatus, RDD__c = Date.today().addDays(30)
        );
        if (quoteStatus == 'Accepted') {
            toMove.Finance_Approval_Status__c = 'Not Required';
        }
        update toMove;
    }

    // Inventory_Edit_Lock rejects DML on a record whose Status__c is 'Installed'
    // unless the running user holds Inventory_Admin or the status is itself
    // changing. Nothing grants Inventory_Admin in either sandbox or in production,
    // so an Installed fixture cannot be created by a plain insert — it gets
    // inserted at another status and moved here, which makes ISCHANGED(Status__c)
    // true and stands the rule down.
    //
    // Call this AFTER Test.stopTest(). CreateOdooInventoryQueueable, enqueued by
    // InventoryTriggerHandler on insert, writes Odoo_Sync_* back to every record it
    // processed WITHOUT changing Status__c — so if the record is already Installed
    // when that queueable drains, the rule blocks the write-back and the whole test
    // fails from inside the queueable. Draining first keeps the record editable.
    //
    // The Odoo refs are cleared in the same DML so the after-update sync's
    // hasOdooRef gate stays shut; otherwise this would enqueue a second job and
    // breach the one-queueable-per-test limit.
    private static void markInstalled(Inventory__c rec) {
        update new Inventory__c(
            Id = rec.Id, Status__c = 'Installed',
            Odoo_Space_ID__c = null, Odoo_Inventory_Id__c = null
        );
    }

    // A second QLI on its own Quote, reusing the first one's Opportunity, Product
    // and PricebookEntry. A test that needs two stages side by side cannot afford
    // two full mkQuoteLineItem trees — the Quote save flows ("Quote - After Save -
    // Credit Rollup") then blow the 100-SOQL governor limit during setup.
    private static QuoteLineItem mkSiblingQuoteLineItem(QuoteLineItem existing,
                                                        Id targetSiteId,
                                                        String quoteStatus) {
        QuoteLineItem src = [
            SELECT Id, Product2Id, PricebookEntryId,
                   Quote.OpportunityId, Quote.Pricebook2Id, Quote.CurrencyIsoCode
            FROM QuoteLineItem WHERE Id = :existing.Id LIMIT 1
        ];
        Quote q = new Quote(
            Name = 'QA-Quote-Sibling', OpportunityId = src.Quote.OpportunityId,
            Status = 'Draft', CurrencyIsoCode = src.Quote.CurrencyIsoCode,
            Pricebook2Id = src.Quote.Pricebook2Id
        );
        insert q;
        // Target_Site__c set by a follow-up update, not on the insert — same order
        // mkQuoteLineItem() uses. Set at insert time it does not survive.
        update new Quote(Id = q.Id, Target_Site__c = targetSiteId);
        QuoteLineItem qli = new QuoteLineItem(
            QuoteId = q.Id, Product2Id = src.Product2Id,
            PricebookEntryId = src.PricebookEntryId, Quantity = 1, UnitPrice = 100
        );
        insert qli;
        moveQuoteTo(q.Id, quoteStatus);
        return qli;
    }

    // Wraps the 32-parameter createInventoryRecords signature so individual
    // tests only set the fields they care about (named-field style) instead
    // of risking a mis-counted positional call.
    private class CreateParams {
        String recordTypeName = 'Inventory_Space';
        Id siteId;
        Id floorId;
        Id dataHallId;
        String spaceType;
        String capacityType;
        Decimal powerKva;
        Decimal totalKw;
        Decimal totalCapacityKva;
        String unitRefPrefix;
        String breakerPanel;
        String notes;
        Integer quantity = 1;
        String newFloorName;
        String newDataHallName;
        String customName;
        String inventoryRow;
        String inventoryCol;
        String unitNumber;
        String breakerType;
        String voltageRating;
        String currentRating;
        String slaTemperature;
        String slaTemperatureMax;
        String slaHumidity;
        String slaHumidityMax;
        String slaAvailability;
        String cabeSize;
        String inventoryStatus;
        Decimal contractedPower;
        String usageType;
        Id cageReferenceId;
    }

    private static Id callCreate(CreateParams p) {
        return DeInventoryManagerController.createInventoryRecords(
            p.recordTypeName, p.siteId, p.floorId, p.dataHallId,
            p.spaceType, p.capacityType,
            p.powerKva, p.totalKw, p.totalCapacityKva,
            p.unitRefPrefix, p.breakerPanel,
            p.notes, p.quantity,
            p.newFloorName, p.newDataHallName,
            p.customName,
            p.inventoryRow, p.inventoryCol,
            p.unitNumber,
            p.breakerType, p.voltageRating, p.currentRating,
            p.slaTemperature, p.slaTemperatureMax, p.slaHumidity, p.slaHumidityMax, p.slaAvailability,
            p.cabeSize,
            p.inventoryStatus, p.contractedPower,
            p.usageType, p.cageReferenceId
        );
    }

    // ── FLS/CRUD-denied test helpers (mirrors InventoryControllerTest's
    // Minimum-Access-user pattern for exercising the isCreateable()/
    // isUpdateable() throw branches without touching real permission grants) ──

    private static Id minimumAccessProfileId() {
        return [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1].Id;
    }

    private static User createRestrictedUser() {
        String suffix = String.valueOf(Datetime.now().getTime());
        User u = new User(
            LastName          = 'DeInvFlsTest',
            FirstName         = 'Restricted',
            Email             = 'deinvflstest' + suffix + '@example.com',
            Username          = 'deinvflstest' + suffix + '@example.com.deinvtest',
            Alias             = 'dift' + suffix.right(4),
            TimeZoneSidKey    = 'America/Los_Angeles',
            LocaleSidKey      = 'en_US',
            EmailEncodingKey  = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            ProfileId         = minimumAccessProfileId()
        );
        insert u;
        return u;
    }

    // Grants exactly one atomic object-permission set to an otherwise-restricted
    // user, so a test can isolate "has create on X but not Y" combinations
    // (e.g. DE_Regional_Manager_Supplement: Inventory__c create/edit, but no
    // Floor__c/DataHall__c create) instead of blanket admin/no-access.
    //
    // PermissionSetAssignment is a "setup" object — inserting it in the same
    // transaction as prior DML on a non-setup object (Site__c/Floor__c, etc.,
    // already inserted by the calling test) throws MIXED_DML_OPERATION.
    // System.runAs opens a fresh mixed-DML context, which is the standard
    // Salesforce-documented workaround for this exact restriction.
    private static void assignPermissionSet(Id userId, String permSetName) {
        PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = :permSetName LIMIT 1];
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = ps.Id);
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // getSites
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void getSites_returnsSites() {
        Test.startTest();
        List<Site__c> sites = DeInventoryManagerController.getSites();
        Test.stopTest();

        Assert.isTrue(sites.size() >= 1, 'Should return at least 1 site');
        Boolean found = false;
        for (Site__c s : sites) {
            if (s.Site_Code__c == 'TEST-SG01') found = true;
        }
        Assert.isTrue(found, 'Test site should be in results');
    }

    // ═══════════════════════════════════════════════════════════════════
    // getFloorsBySite
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void getFloorsBySite_returnsFloors() {
        Site__c site = [SELECT Id FROM Site__c WHERE Site_Code__c = 'TEST-SG01' LIMIT 1];

        Test.startTest();
        List<Floor__c> floors = DeInventoryManagerController.getFloorsBySite(site.Id);
        Test.stopTest();

        Assert.areEqual(1, floors.size(), 'Should return 1 floor for the test site');
        Assert.areEqual('TEST-SG01-01', floors[0].Name, 'Floor name should match');
    }

    // ═══════════════════════════════════════════════════════════════════
    // getHallsBySite
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void getHallsBySite_returnsHalls() {
        Site__c site = [SELECT Id FROM Site__c WHERE Site_Code__c = 'TEST-SG01' LIMIT 1];

        Test.startTest();
        List<DataHall__c> halls = DeInventoryManagerController.getHallsBySite(site.Id);
        Test.stopTest();

        Assert.areEqual(1, halls.size(), 'Should return 1 data hall');
        Assert.areEqual('TEST-SG01-01-01', halls[0].Name, 'Data hall name should match');
    }

    @IsTest
    static void getHallsBySite_noFloorsReturnsEmpty() {
        Site__c emptySite = mkSite('TEST-EMPTY', 'HK');

        Test.startTest();
        List<DataHall__c> halls = DeInventoryManagerController.getHallsBySite(emptySite.Id);
        Test.stopTest();

        Assert.areEqual(0, halls.size(), 'Site with no floors should return empty list');
    }

    // ═══════════════════════════════════════════════════════════════════
    // getHallsByFloor
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void getHallsByFloor_returnsHalls() {
        Floor__c floor = [SELECT Id FROM Floor__c WHERE Name = 'TEST-SG01-01' LIMIT 1];

        Test.startTest();
        List<DataHall__c> halls = DeInventoryManagerController.getHallsByFloor(floor.Id);
        Test.stopTest();

        Assert.areEqual(1, halls.size(), 'Should return 1 data hall for the floor');
    }

    // ═══════════════════════════════════════════════════════════════════
    // getInventoryBySite
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void getInventoryBySite_returnsAll() {
        Site__c site = [SELECT Id FROM Site__c WHERE Site_Code__c = 'TEST-SG01' LIMIT 1];

        Test.startTest();
        List<Inventory__c> inv = DeInventoryManagerController.getInventoryBySite(
            site.Id, 'All', 'All');
        Test.stopTest();

        Assert.areEqual(3, inv.size(), 'Should return all 3 inventory records');
    }

    @IsTest
    static void getInventoryBySite_filtersByRecordType() {
        Site__c site = [SELECT Id FROM Site__c WHERE Site_Code__c = 'TEST-SG01' LIMIT 1];

        Test.startTest();
        List<Inventory__c> spaceOnly = DeInventoryManagerController.getInventoryBySite(
            site.Id, 'Inventory_Space', 'All');
        Test.stopTest();

        Assert.areEqual(2, spaceOnly.size(), 'Should return 2 Space records');
    }

    @IsTest
    static void getInventoryBySite_filtersByStatus() {
        Site__c site = [SELECT Id FROM Site__c WHERE Site_Code__c = 'TEST-SG01' LIMIT 1];

        Test.startTest();
        List<Inventory__c> available = DeInventoryManagerController.getInventoryBySite(
            site.Id, 'All', 'Available');
        Test.stopTest();

        Assert.areEqual(3, available.size(), 'All test records are Available');
    }

    @IsTest
    static void getInventoryBySite_filtersBoth() {
        Site__c site = [SELECT Id FROM Site__c WHERE Site_Code__c = 'TEST-SG01' LIMIT 1];

        Test.startTest();
        List<Inventory__c> result = DeInventoryManagerController.getInventoryBySite(
            site.Id, 'Inventory_Breaker', 'Available');
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'Should return 1 Breaker Available record');
    }

    @IsTest
    static void getInventoryBySite_bulk200Records() {
        Site__c site = mkSite('BLK-INV', 'SG');
        List<Inventory__c> bulkRecords = new List<Inventory__c>();
        for (Integer i = 0; i < 200; i++) {
            bulkRecords.add(new Inventory__c(
                RecordTypeId = spaceRt(),
                Site_Id__c   = site.Id,
                Status__c    = 'Available',
                Space_Type__c = 'Cabinet',
                Name = 'BULK-' + i
            ));
        }
        insert bulkRecords;

        Test.startTest();
        List<Inventory__c> result = DeInventoryManagerController.getInventoryBySite(
            site.Id, 'All', 'All');
        Test.stopTest();

        Assert.areEqual(200, result.size(), 'Should return all 200 bulk records (under the 500 cap)');
    }

    // ═══════════════════════════════════════════════════════════════════
    // getInventorySummary
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void getInventorySummary_countsByStatus() {
        Site__c site = [SELECT Id FROM Site__c WHERE Site_Code__c = 'TEST-SG01' LIMIT 1];

        Test.startTest();
        Map<String, Integer> summary = DeInventoryManagerController.getInventorySummary(site.Id);
        Test.stopTest();

        Assert.areEqual(3, summary.get('Total'), 'Total should be 3');
        Assert.areEqual(3, summary.get('Available'), 'Available should be 3');
    }

    @IsTest
    static void getInventorySummary_committedAndSpaceCounts() {
        Site__c site = mkSite('SUM-SITE', 'SG');
        QuoteLineItem qli = mkQuoteLineItem(site.Id);

        insert new List<Inventory__c>{
            new Inventory__c(
                RecordTypeId = spaceRt(), Site_Id__c = site.Id,
                Status__c = 'Reserved', Space_Type__c = 'Cabinet',
                Assigned_To_Quote__c = qli.QuoteId,
                Quote_Line__c = qli.Id
            ),
            new Inventory__c(
                RecordTypeId = spaceRt(), Site_Id__c = site.Id,
                Status__c = 'Available', Space_Type__c = 'Cage'
            ),
            new Inventory__c(
                RecordTypeId = breakerRt(), Site_Id__c = site.Id,
                Status__c = 'Available', Capacity_Type__c = 'Power Circuit'
            )
        };

        Test.startTest();
        Map<String, Integer> summary = DeInventoryManagerController.getInventorySummary(site.Id);
        Test.stopTest();

        Assert.areEqual(3, summary.get('Total'), 'Total across all record types');
        Assert.areEqual(1, summary.get('Reserved'), 'One Reserved record overall');
        Assert.areEqual(2, summary.get('Available'), 'Two Available records overall');
        Assert.areEqual(1, summary.get('Committed'), 'Reserved+quoted counts as Committed');
        Assert.areEqual(1, summary.get('Space_Reserved'), 'Space-only Reserved count');
        Assert.areEqual(1, summary.get('Space_Available'), 'Space-only Available count');
        Assert.areEqual(2, summary.get('Space_Total'), 'Space-only total excludes the breaker');
    }

    // ═══════════════════════════════════════════════════════════════════
    // getAllSiteSummaries
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void getAllSiteSummaries_multiSite() {
        Site__c siteA = mkSite('ALLSUM-A', 'SG');
        Site__c siteB = mkSite('ALLSUM-B', 'HK');
        QuoteLineItem qli = mkQuoteLineItem(siteA.Id);

        insert new List<Inventory__c>{
            new Inventory__c(
                RecordTypeId = spaceRt(), Site_Id__c = siteA.Id,
                Status__c = 'Reserved', Space_Type__c = 'Cabinet',
                Assigned_To_Quote__c = qli.QuoteId,
                Quote_Line__c = qli.Id
            ),
            new Inventory__c(
                RecordTypeId = breakerRt(), Site_Id__c = siteA.Id,
                Status__c = 'Available', Capacity_Type__c = 'Power Circuit'
            ),
            new Inventory__c(
                RecordTypeId = spaceRt(), Site_Id__c = siteB.Id,
                Status__c = 'Available', Space_Type__c = 'Cage'
            )
        };

        Test.startTest();
        Map<Id, Map<String, Integer>> all = DeInventoryManagerController.getAllSiteSummaries();
        Test.stopTest();

        Map<String, Integer> aMap = all.get(siteA.Id);
        Map<String, Integer> bMap = all.get(siteB.Id);
        Assert.isNotNull(aMap, 'Site A should have a summary entry');
        Assert.isNotNull(bMap, 'Site B should have a summary entry');
        Assert.areEqual(2, aMap.get('Total'), 'Site A total is 2');
        Assert.areEqual(1, aMap.get('Committed'), 'Site A has 1 committed record');
        Assert.areEqual(1, aMap.get('Space_Total'), 'Site A space-only total is 1');
        Assert.areEqual(1, bMap.get('Total'), 'Site B total is 1');
        Assert.areEqual(1, bMap.get('Space_Total'), 'Site B space-only total is 1');
        Assert.isFalse(bMap.containsKey('Committed'), 'Site B has no committed records');
    }

    // ═══════════════════════════════════════════════════════════════════
    // getReservations
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void getReservations_noHeldInventory() {
        Site__c site = [SELECT Id FROM Site__c WHERE Site_Code__c = 'TEST-SG01' LIMIT 1];

        Test.startTest();
        List<Inventory__c> res = DeInventoryManagerController.getReservations(site.Id);
        Test.stopTest();

        Assert.areEqual(0, res.size(), 'No records have held statuses');
    }

    @IsTest
    static void getReservations_nullSiteReturnsAll() {
        Test.startTest();
        List<Inventory__c> res = DeInventoryManagerController.getReservations(null);
        Test.stopTest();

        // All test records are Available, so no held records exist
        Assert.areEqual(0, res.size(), 'No held records across any site');
    }

    @IsTest
    static void getReservations_returnsHeldSpaceRecordsForSite() {
        Site__c site = mkSite('RES-SITE', 'SG');
        QuoteLineItem qli = mkQuoteLineItem(site.Id);
        insert new List<Inventory__c>{
            new Inventory__c(RecordTypeId = spaceRt(), Site_Id__c = site.Id, Status__c = 'Reserved', Space_Type__c = 'Cabinet', Quote_Line__c = qli.Id, Assigned_To_Quote__c = qli.QuoteId),
            new Inventory__c(RecordTypeId = spaceRt(), Site_Id__c = site.Id, Status__c = 'Assigned', Space_Type__c = 'Cabinet'),
            new Inventory__c(RecordTypeId = spaceRt(), Site_Id__c = site.Id, Status__c = 'Assigned', Space_Type__c = 'Cabinet'),
            new Inventory__c(RecordTypeId = spaceRt(), Site_Id__c = site.Id, Status__c = 'Available', Space_Type__c = 'Cabinet'),
            new Inventory__c(RecordTypeId = breakerRt(), Site_Id__c = site.Id, Status__c = 'Available', Capacity_Type__c = 'Power Circuit')
        };

        Test.startTest();
        List<Inventory__c> res = DeInventoryManagerController.getReservations(site.Id);
        Test.stopTest();

        Assert.areEqual(3, res.size(), 'Only held Space records (Reserved/Assigned/Sold) should return; breaker excluded');
    }

    // ═══════════════════════════════════════════════════════════════════
    // getCageHallOptions
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void getCageHallOptions_nullFloorReturnsEmpty() {
        Test.startTest();
        List<Map<String, String>> options = DeInventoryManagerController.getCageHallOptions(null);
        Test.stopTest();

        Assert.areEqual(0, options.size(), 'Null floor should return empty list');
    }

    @IsTest
    static void getCageHallOptions_returnsOnlyCageAndHall() {
        Site__c site = mkSite('CHO-SITE', 'SG');
        Floor__c floor = mkFloor(site.Id, 'CHO-SITE-01');

        insert new List<Inventory__c>{
            new Inventory__c(RecordTypeId = spaceRt(), Site_Id__c = site.Id, Floor__c = floor.Id, Status__c = 'Available', Space_Type__c = 'Cage', Name = 'CHO-CAGE'),
            new Inventory__c(RecordTypeId = spaceRt(), Site_Id__c = site.Id, Floor__c = floor.Id, Status__c = 'Available', Space_Type__c = 'Hall', Name = 'CHO-HALL'),
            new Inventory__c(RecordTypeId = spaceRt(), Site_Id__c = site.Id, Floor__c = floor.Id, Status__c = 'Available', Space_Type__c = 'Cabinet', Name = 'CHO-CAB'),
            new Inventory__c(RecordTypeId = breakerRt(), Site_Id__c = site.Id, Floor__c = floor.Id, Status__c = 'Available', Capacity_Type__c = 'Power Circuit', Name = 'CHO-BRK')
        };

        Test.startTest();
        List<Map<String, String>> options = DeInventoryManagerController.getCageHallOptions(floor.Id);
        Test.stopTest();

        Assert.areEqual(2, options.size(), 'Only Cage and Hall space types should be returned');
        Set<String> names = new Set<String>();
        for (Map<String, String> m : options) {
            names.add(m.get('name'));
            Assert.isNotNull(m.get('id'), 'Each option should carry an id');
            Assert.isNotNull(m.get('type'), 'Each option should carry a type');
        }
        Assert.isTrue(names.contains('CHO-CAGE'), 'Cage record should be included');
        Assert.isTrue(names.contains('CHO-HALL'), 'Hall record should be included');
    }

    // ═══════════════════════════════════════════════════════════════════
    // createInventoryRecords
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void createInventoryRecords_spaceType() {
        Site__c site = [SELECT Id FROM Site__c WHERE Site_Code__c = 'TEST-SG01' LIMIT 1];
        Floor__c floor = [SELECT Id FROM Floor__c WHERE Name = 'TEST-SG01-01' LIMIT 1];
        DataHall__c hall = [SELECT Id FROM DataHall__c WHERE Name = 'TEST-SG01-01-01' LIMIT 1];

        CreateParams p = new CreateParams();
        p.siteId = site.Id; p.floorId = floor.Id; p.dataHallId = hall.Id;
        p.spaceType = 'Cabinet';
        p.powerKva = 5.0; p.totalCapacityKva = 10.0;
        p.unitRefPrefix = 'NEW-CAB';
        p.notes = 'Test notes';
        p.quantity = 3;

        Test.startTest();
        Id firstId = callCreate(p);
        Test.stopTest();

        Assert.isNotNull(firstId, 'Should return the Id of the first created record');
        List<Inventory__c> newRecords = [
            SELECT Name, Unit_Reference__c, Status__c, Space_Type__c
            FROM Inventory__c
            WHERE Unit_Reference__c LIKE 'NEW-CAB%'
            ORDER BY Name
        ];
        Assert.areEqual(3, newRecords.size(), '3 new inventory records should exist');
        Assert.areEqual('TEST-SG01-01-DH01-S01', newRecords[0].Name,
            'Name should follow SITE-FLOOR-DHAA-USAGEXX convention');
        Assert.areEqual('TEST-SG01-01-DH01-S03', newRecords[2].Name,
            'Third record should be sequence 03');
        Assert.areEqual('NEW-CAB-001', newRecords[0].Unit_Reference__c,
            'First record should have -001 suffix');
        Assert.areEqual('Available', newRecords[0].Status__c,
            'New records should default to Available');
        Assert.areEqual('Cabinet', newRecords[0].Space_Type__c,
            'Space type should be set');
    }

    @IsTest
    static void createInventoryRecords_breakerType() {
        Site__c site = [SELECT Id FROM Site__c WHERE Site_Code__c = 'TEST-SG01' LIMIT 1];
        Floor__c floor = [SELECT Id FROM Floor__c WHERE Name = 'TEST-SG01-01' LIMIT 1];
        DataHall__c hall = [SELECT Id FROM DataHall__c WHERE Name = 'TEST-SG01-01-01' LIMIT 1];

        CreateParams p = new CreateParams();
        p.recordTypeName = 'Inventory_Breaker';
        p.siteId = site.Id; p.floorId = floor.Id; p.dataHallId = hall.Id;
        p.capacityType = 'Power Circuit';
        p.totalKw = 15.0;
        p.unitRefPrefix = 'NEW-PWR';
        p.breakerPanel = 'BP-02';
        p.quantity = 1;

        Test.startTest();
        Id createdId = callCreate(p);
        Test.stopTest();

        Assert.isNotNull(createdId, 'Should return the created record Id');
        Inventory__c rec = [
            SELECT Name, Unit_Reference__c, Capacity_Type__c, Breaker_Panel__c, Total_kW__c
            FROM Inventory__c
            WHERE Unit_Reference__c = 'NEW-PWR'
        ];
        Assert.areEqual('TEST-SG01-01-DH01-BRK01', rec.Name,
            'Breaker name should follow SITE-FLOOR-DHAA-BRKXX convention');
        Assert.areEqual('NEW-PWR', rec.Unit_Reference__c,
            'Single record should not have suffix');
        Assert.areEqual('Power Circuit', rec.Capacity_Type__c,
            'Capacity type should be set');
        Assert.areEqual('BP-02', rec.Breaker_Panel__c,
            'Breaker panel should be set');
    }

    @IsTest
    static void createInventoryRecords_newFloorAndHall() {
        Site__c site = [SELECT Id FROM Site__c WHERE Site_Code__c = 'TEST-SG01' LIMIT 1];

        CreateParams p = new CreateParams();
        p.siteId = site.Id;
        p.spaceType = 'Cage';
        p.totalCapacityKva = 20.0;
        p.quantity = 1;
        p.newFloorName = 'TEST-SG01-05';
        p.newDataHallName = 'TEST-SG01-05-01';

        Boolean threw = false;
        Test.startTest();
        try {
            callCreate(p);
        } catch (DmlException e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('Site__c'),
                'Current production code creates DataHall__c without required Site__c: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Current deployed new-hall path should expose the required Site__c production bug');
    }

    @IsTest
    static void createInventoryRecords_flexOffice() {
        Site__c site = mkSite('FLX1', 'SG');
        Floor__c floor = mkFloor(site.Id, 'FLX1-01');
        DataHall__c hall = mkHall(floor.Id, 'FLX1-01-COLP5', null);

        CreateParams p = new CreateParams();
        p.siteId = site.Id; p.floorId = floor.Id; p.dataHallId = hall.Id;
        p.spaceType = 'Flex Office';
        p.unitNumber = '1';
        p.quantity = 1;

        Test.startTest();
        Id createdId = callCreate(p);
        Test.stopTest();

        Inventory__c rec = [SELECT Name FROM Inventory__c WHERE Id = :createdId];
        Assert.areEqual('FLX1-01-COLP05-FS01', rec.Name,
            'Flex Office naming should follow SITE-FLOOR-ROOMXX-FSXX (Section 5)');
    }

    @IsTest
    static void createInventoryRecords_rowColForcesSingleRecord() {
        Site__c site = mkSite('RKX1', 'SG');
        Floor__c floor = mkFloor(site.Id, 'RKX1-02');
        DataHall__c hall = mkHall(floor.Id, 'RKX1-02-H1', '1');

        CreateParams p = new CreateParams();
        p.siteId = site.Id; p.floorId = floor.Id; p.dataHallId = hall.Id;
        p.spaceType = 'Cabinet';
        p.unitNumber = '2';
        p.inventoryRow = '03';
        p.inventoryCol = '05';
        p.quantity = 5; // should be forced down to 1 because row/col are set

        Test.startTest();
        Id createdId = callCreate(p);
        Test.stopTest();

        List<Inventory__c> created = [SELECT Name, Row__c FROM Inventory__c WHERE Site_Id__c = :site.Id];
        Assert.areEqual(1, created.size(), 'Row/Col naming should force quantity to 1');
        Assert.areEqual('RKX1-02-DH01-S02-RK0305', created[0].Name,
            'Row/Col name should follow SITE-FLOOR-DHAA-USAGEXX-RKYYZZ (Section 6)');
        Assert.areEqual('03', created[0].Row__c, 'Row__c should store the row value');
    }

    @IsTest
    static void createInventoryRecords_customNameMulti() {
        Site__c site = mkSite('CNX1', 'SG');
        Floor__c floor = mkFloor(site.Id, 'CNX1-01');
        DataHall__c hall = mkHall(floor.Id, 'CNX1-01-H1', '01');

        CreateParams p = new CreateParams();
        p.siteId = site.Id; p.floorId = floor.Id; p.dataHallId = hall.Id;
        p.spaceType = 'Cabinet';
        p.customName = 'MYNAME';
        p.quantity = 2;

        Test.startTest();
        callCreate(p);
        Test.stopTest();

        List<Inventory__c> created = [SELECT Name FROM Inventory__c WHERE Site_Id__c = :site.Id ORDER BY Name];
        Assert.areEqual(2, created.size(), 'Should create 2 records');
        Assert.areEqual('MYNAME-01', created[0].Name, 'Custom name multi-quantity gets -01 suffix');
        Assert.areEqual('MYNAME-02', created[1].Name, 'Custom name multi-quantity gets -02 suffix');
    }

    @IsTest
    static void createInventoryRecords_unitNumberSuffixMulti() {
        Site__c site = mkSite('UNX1', 'SG');
        Floor__c floor = mkFloor(site.Id, 'UNX1-01');
        DataHall__c hall = mkHall(floor.Id, 'UNX1-01-H1', '01');

        CreateParams p = new CreateParams();
        p.siteId = site.Id; p.floorId = floor.Id; p.dataHallId = hall.Id;
        p.spaceType = 'Cabinet';
        p.unitNumber = '7';
        p.quantity = 3;

        Test.startTest();
        callCreate(p);
        Test.stopTest();

        List<Inventory__c> created = [SELECT Name FROM Inventory__c WHERE Site_Id__c = :site.Id ORDER BY Name];
        Assert.areEqual(3, created.size(), 'Should create 3 records');
        Assert.areEqual('UNX1-01-DH01-S07-01', created[0].Name, 'Unit number prefix, first suffix');
        Assert.areEqual('UNX1-01-DH01-S07-03', created[2].Name, 'Unit number prefix, third suffix');
    }

    @IsTest
    static void createInventoryRecords_cageReference() {
        Site__c site = mkSite('CGX1', 'SG');
        Floor__c floor = mkFloor(site.Id, 'CGX1-01');
        DataHall__c hall = mkHall(floor.Id, 'CGX1-01-H1', '01');

        Inventory__c cageRef = new Inventory__c(
            RecordTypeId = spaceRt(), Site_Id__c = site.Id, Floor__c = floor.Id, Data_Hall__c = hall.Id,
            Status__c = 'Available', Space_Type__c = 'Cage', Name = 'REFCAGE-X',
            Total_Capacity_kVA__c = 1, Power_kVA__c = 1
        );
        insert cageRef;

        CreateParams p = new CreateParams();
        p.siteId = site.Id; p.floorId = floor.Id; p.dataHallId = hall.Id;
        p.spaceType = 'Cabinet';
        p.usageType = 'Private Cage';
        p.cageReferenceId = cageRef.Id;
        p.quantity = 1;

        Test.startTest();
        Id createdId = callCreate(p);
        Test.stopTest();

        Inventory__c rec = [SELECT Name, Usage_Type__c, Cage_Reference__c, Hall_Reference__c FROM Inventory__c WHERE Id = :createdId];
        Assert.areEqual('CGX1-01-DH01-C01', rec.Name, 'Private Cage naming should use the C usage tag');
        Assert.areEqual('Private Cage', rec.Usage_Type__c, 'Usage type should be recorded');
        Assert.areEqual(cageRef.Id, rec.Cage_Reference__c, 'Cage reference should be linked');
        Assert.isNull(rec.Hall_Reference__c, 'Hall reference should stay null for a cage link');
    }

    @IsTest
    static void createInventoryRecords_hallReference() {
        Site__c site = mkSite('HLX1', 'SG');
        Floor__c floor = mkFloor(site.Id, 'HLX1-01');
        DataHall__c hall = mkHall(floor.Id, 'HLX1-01-H1', '01');

        Inventory__c hallRef = new Inventory__c(
            RecordTypeId = spaceRt(), Site_Id__c = site.Id, Floor__c = floor.Id, Data_Hall__c = hall.Id,
            Status__c = 'Available', Space_Type__c = 'Hall', Name = 'REFHALL-X',
            Total_Capacity_kVA__c = 1, Power_kVA__c = 1
        );
        insert hallRef;

        CreateParams p = new CreateParams();
        p.siteId = site.Id; p.floorId = floor.Id; p.dataHallId = hall.Id;
        p.spaceType = 'Cabinet';
        p.usageType = 'Private Hall';
        p.cageReferenceId = hallRef.Id;
        p.quantity = 1;

        Test.startTest();
        Id createdId = callCreate(p);
        Test.stopTest();

        Inventory__c rec = [SELECT Name, Usage_Type__c, Cage_Reference__c, Hall_Reference__c FROM Inventory__c WHERE Id = :createdId];
        Assert.areEqual('HLX1-01-DH01-H01', rec.Name, 'Private Hall naming should use the H usage tag');
        Assert.areEqual('Private Hall', rec.Usage_Type__c, 'Usage type should be recorded');
        Assert.areEqual(hallRef.Id, rec.Hall_Reference__c, 'Hall reference should be linked');
        Assert.isNull(rec.Cage_Reference__c, 'Cage reference should stay null for a hall link');
    }

    @IsTest
    static void createInventoryRecords_statusOverrideAndContractedPower() {
        Site__c site = mkSite('STX1', 'SG');
        Floor__c floor = mkFloor(site.Id, 'STX1-01');
        DataHall__c hall = mkHall(floor.Id, 'STX1-01-H1', '01');

        CreateParams p = new CreateParams();
        p.siteId = site.Id; p.floorId = floor.Id; p.dataHallId = hall.Id;
        p.spaceType = 'Cabinet';
        p.inventoryStatus = 'Pending Available';
        p.contractedPower = 123.45;
        p.quantity = 1;

        Test.startTest();
        Id createdId = callCreate(p);
        Test.stopTest();

        Inventory__c rec = [SELECT Status__c, Total_IT_Power_kVA__c FROM Inventory__c WHERE Id = :createdId];
        Assert.areEqual('Pending Available', rec.Status__c, 'Explicit status should override the Available default');
        Assert.areEqual(123.45, rec.Total_IT_Power_kVA__c, 'Contracted power should map to Total_IT_Power_kVA__c');
    }

    @IsTest
    static void createInventoryRecords_sequenceContinuesAcrossCalls() {
        Site__c site = mkSite('SQX1', 'SG');
        Floor__c floor = mkFloor(site.Id, 'SQX1-01');
        DataHall__c hall = mkHall(floor.Id, 'SQX1-01-H1', '01');

        CreateParams p = new CreateParams();
        p.siteId = site.Id; p.floorId = floor.Id; p.dataHallId = hall.Id;
        p.spaceType = 'Cabinet';
        p.quantity = 2;

        Test.startTest();
        callCreate(p);
        callCreate(p);
        Test.stopTest();

        List<Inventory__c> created = [SELECT Name FROM Inventory__c WHERE Site_Id__c = :site.Id ORDER BY Name];
        Assert.areEqual(4, created.size(), 'Two calls of quantity 2 should produce 4 records');
        Assert.areEqual('SQX1-01-DH01-S01', created[0].Name, 'First call starts sequence at 01');
        Assert.areEqual('SQX1-01-DH01-S04', created[3].Name, 'Second call should continue the sequence at 03/04');
    }

    @IsTest
    static void createInventoryRecords_noFloorNoHallDefaults() {
        Site__c site = mkSite('NFX1', 'SG');

        CreateParams p = new CreateParams();
        p.recordTypeName = 'Inventory_Breaker';
        p.siteId = site.Id;
        p.breakerType = '3 Phase';
        p.voltageRating = '230V';
        p.currentRating = '20A';
        p.breakerPanel = 'BP-99';
        p.quantity = 1;

        Test.startTest();
        Id createdId = callCreate(p);
        Test.stopTest();

        Inventory__c rec = [SELECT Name, Floor__c, Data_Hall__c FROM Inventory__c WHERE Id = :createdId];
        Assert.areEqual('NFX1-00-DH00-BRK01', rec.Name, 'Missing floor/hall should default both parts to 00');
        Assert.isNull(rec.Floor__c, 'No floor should be linked');
        Assert.isNull(rec.Data_Hall__c, 'No data hall should be linked');
    }

    @IsTest
    static void createInventoryRecords_bulkQuantity200() {
        Site__c site = mkSite('BLX1', 'SG');
        Floor__c floor = mkFloor(site.Id, 'BLX1-01');
        DataHall__c hall = mkHall(floor.Id, 'BLX1-01-H1', '01');

        CreateParams p = new CreateParams();
        p.siteId = site.Id; p.floorId = floor.Id; p.dataHallId = hall.Id;
        p.spaceType = 'Cabinet';
        p.quantity = 200;

        Test.startTest();
        callCreate(p);
        Test.stopTest();

        Integer count = [SELECT COUNT() FROM Inventory__c WHERE Site_Id__c = :site.Id];
        Assert.areEqual(200, count, 'Bulk create should insert exactly 200 records');
        Integer sequence200 = [SELECT COUNT() FROM Inventory__c WHERE Site_Id__c = :site.Id AND Name = 'BLX1-01-DH01-S200'];
        Assert.areEqual(1, sequence200, 'Generated records should include sequence 200');
    }

    // ═══════════════════════════════════════════════════════════════════
    // updateInventoryField
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void updateInventoryField_numericFieldSetAndClear() {
        Inventory__c inv = [SELECT Id FROM Inventory__c WHERE Unit_Reference__c = 'SG01-DH01-A001' LIMIT 1];

        Test.startTest();
        DeInventoryManagerController.updateInventoryField(inv.Id, 'Power_kVA__c', '42.5');
        Inventory__c afterSet = [SELECT Power_kVA__c FROM Inventory__c WHERE Id = :inv.Id];
        Assert.areEqual(42.5, afterSet.Power_kVA__c, 'Numeric field should be parsed to Decimal');

        DeInventoryManagerController.updateInventoryField(inv.Id, 'Power_kVA__c', '');
        Test.stopTest();

        Inventory__c afterClear = [SELECT Power_kVA__c FROM Inventory__c WHERE Id = :inv.Id];
        Assert.isNull(afterClear.Power_kVA__c, 'Blank value should clear a numeric field to null');
    }

    @IsTest
    static void updateInventoryField_textField() {
        Inventory__c inv = [SELECT Id FROM Inventory__c WHERE Unit_Reference__c = 'SG01-DH01-A001' LIMIT 1];

        Test.startTest();
        DeInventoryManagerController.updateInventoryField(inv.Id, 'Notes__c', 'Updated via test');
        Test.stopTest();

        Inventory__c updated = [SELECT Notes__c FROM Inventory__c WHERE Id = :inv.Id];
        Assert.areEqual('Updated via test', updated.Notes__c, 'Text field should be set as-is');
    }

    @IsTest
    static void updateInventoryField_unknownFieldThrows() {
        Inventory__c inv = [SELECT Id FROM Inventory__c WHERE Unit_Reference__c = 'SG01-DH01-A001' LIMIT 1];

        Test.startTest();
        try {
            DeInventoryManagerController.updateInventoryField(inv.Id, 'Not_A_Real_Field__c', 'x');
            Assert.fail('Expected AuraHandledException for an unknown field');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'Exception should be thrown for an unknown field');
        }
        Test.stopTest();
    }

    // ═══════════════════════════════════════════════════════════════════
    // updateInventoryFieldBulk
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void updateInventoryFieldBulk_bulk200() {
        Site__c site = mkSite('BFB-SITE', 'SG');
        List<Inventory__c> bulkRecords = new List<Inventory__c>();
        for (Integer i = 0; i < 200; i++) {
            bulkRecords.add(new Inventory__c(
                RecordTypeId = spaceRt(), Site_Id__c = site.Id,
                Status__c = 'Available', Space_Type__c = 'Cabinet', Name = 'BFB-' + i
            ));
        }
        insert bulkRecords;
        List<Id> ids = new List<Id>();
        for (Inventory__c r : bulkRecords) ids.add(r.Id);

        Test.startTest();
        DeInventoryManagerController.updateInventoryFieldBulk(ids, 'Notes__c', 'Bulk updated');
        Test.stopTest();

        Integer updatedCount = 0;
        for (Inventory__c inv : [SELECT Notes__c FROM Inventory__c WHERE Site_Id__c = :site.Id]) {
            if (inv.Notes__c == 'Bulk updated') {
                updatedCount++;
            }
        }
        Assert.areEqual(200, updatedCount, 'All 200 records should be updated in bulk');
    }

    @IsTest
    static void updateInventoryFieldBulk_numericField() {
        List<Inventory__c> invs = [SELECT Id FROM Inventory__c WHERE Unit_Reference__c IN ('SG01-DH01-A001', 'SG01-DH01-A002')];
        List<Id> ids = new List<Id>();
        for (Inventory__c i : invs) ids.add(i.Id);

        Test.startTest();
        DeInventoryManagerController.updateInventoryFieldBulk(ids, 'Total_Capacity_kVA__c', '99.9');
        Test.stopTest();

        List<Inventory__c> updated = [SELECT Total_Capacity_kVA__c FROM Inventory__c WHERE Id IN :ids];
        for (Inventory__c u : updated) {
            Assert.areEqual(99.9, u.Total_Capacity_kVA__c, 'Numeric field should be parsed for every record');
        }
    }

    @IsTest
    static void updateInventoryFieldBulk_unknownFieldThrows() {
        Inventory__c inv = [SELECT Id FROM Inventory__c WHERE Unit_Reference__c = 'SG01-DH01-A001' LIMIT 1];

        Test.startTest();
        try {
            DeInventoryManagerController.updateInventoryFieldBulk(
                new List<Id>{ inv.Id }, 'Not_A_Real_Field__c', 'x');
            Assert.fail('Expected AuraHandledException for an unknown field');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'Exception should be thrown for an unknown field');
        }
        Test.stopTest();
    }

    // ═══════════════════════════════════════════════════════════════════
    // releaseInventory / decommissionInventory
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void releaseInventory_resetsFields() {
        Inventory__c inv = [
            SELECT Id FROM Inventory__c
            WHERE Unit_Reference__c = 'SG01-DH01-A001' LIMIT 1
        ];

        Test.startTest();
        DeInventoryManagerController.releaseInventory(inv.Id);
        Test.stopTest();

        Inventory__c updated = [
            SELECT Status__c, Opportunity__c, Assigned_To_Quote__c, Account__c
            FROM Inventory__c
            WHERE Id = :inv.Id
        ];
        Assert.areEqual('Available', updated.Status__c,
            'Status should be reset to Available');
        Assert.isNull(updated.Opportunity__c,
            'Opportunity should be cleared');
        Assert.isNull(updated.Assigned_To_Quote__c,
            'Quote assignment should be cleared');
        Assert.isNull(updated.Account__c,
            'Account should be cleared');
    }

    @IsTest
    static void decommissionInventory_setsStatus() {
        Inventory__c inv = [SELECT Id FROM Inventory__c WHERE Unit_Reference__c = 'SG01-DH01-A001' LIMIT 1];

        Test.startTest();
        DeInventoryManagerController.decommissionInventory(inv.Id);
        Test.stopTest();

        Inventory__c updated = [SELECT Status__c FROM Inventory__c WHERE Id = :inv.Id];
        Assert.areEqual('Decommissioned', updated.Status__c, 'Status should be set to Decommissioned');
    }

    // ═══════════════════════════════════════════════════════════════════
    // createFloor
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void createFloor_createsFloorAndHalls() {
        Site__c site = [SELECT Id FROM Site__c WHERE Site_Code__c = 'TEST-SG01' LIMIT 1];

        Test.startTest();
        Id floorId = DeInventoryManagerController.createFloor(
            site.Id, 'TEST-SG01-09',
            new List<String>{ 'TEST-SG01-09-1', 'TEST-SG01-09-2' }
        );
        Test.stopTest();

        Assert.isNotNull(floorId, 'Should return new floor Id');
        Floor__c floor = [SELECT Name, Site__c FROM Floor__c WHERE Id = :floorId];
        Assert.areEqual('TEST-SG01-09', floor.Name, 'Floor name should match');
        Assert.areEqual(site.Id, floor.Site__c, 'Floor should reference the site');

        List<DataHall__c> halls = [
            SELECT Name FROM DataHall__c
            WHERE Floor__c = :floorId ORDER BY Name
        ];
        Assert.areEqual(2, halls.size(), 'Should create 2 data halls');
        Assert.areEqual('TEST-SG01-09-1', halls[0].Name, 'First hall name should match');
        Assert.areEqual('TEST-SG01-09-2', halls[1].Name, 'Second hall name should match');
    }

    @IsTest
    static void createFloor_noHalls() {
        Site__c site = [SELECT Id FROM Site__c WHERE Site_Code__c = 'TEST-SG01' LIMIT 1];

        Test.startTest();
        Id floorId = DeInventoryManagerController.createFloor(
            site.Id, 'TEST-SG01-10', null
        );
        Test.stopTest();

        Assert.isNotNull(floorId, 'Should return new floor Id');
        List<DataHall__c> halls = [SELECT Id FROM DataHall__c WHERE Floor__c = :floorId];
        Assert.areEqual(0, halls.size(), 'No halls should be created');
    }

    // ═══════════════════════════════════════════════════════════════════
    // bulkReleaseInventory
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void bulkReleaseInventory_releasesMultiple() {
        List<Inventory__c> invList = [
            SELECT Id, Site_Id__c FROM Inventory__c
            WHERE Unit_Reference__c IN ('SG01-DH01-A001', 'SG01-DH01-A002')
        ];
        List<Id> ids = new List<Id>();
        for (Inventory__c inv : invList) { ids.add(inv.Id); }

        // Set them to Reserved first so the negative-filter query matches
        Id siteId = invList[0].Site_Id__c;
        QuoteLineItem qli = mkQuoteLineItem(siteId);
        for (Inventory__c inv : invList) {
            inv.Status__c = 'Reserved';
            inv.Quote_Line__c = qli.Id;
            inv.Assigned_To_Quote__c = qli.QuoteId;
        }
        update invList;

        Test.startTest();
        DeInventoryManagerController.bulkReleaseInventory(ids);
        Test.stopTest();

        List<Inventory__c> updated = [
            SELECT Status__c, Account__c FROM Inventory__c
            WHERE Id IN :ids
        ];
        for (Inventory__c u : updated) {
            Assert.areEqual('Available', u.Status__c,
                'Status should be reset to Available');
            Assert.isNull(u.Account__c,
                'Account should be cleared');
        }
    }

    @IsTest
    static void bulkReleaseInventory_noReservedThrows() {
        List<Inventory__c> invList = [
            SELECT Id FROM Inventory__c
            WHERE Unit_Reference__c = 'SG01-DH01-A001'
        ];
        List<Id> ids = new List<Id>();
        for (Inventory__c inv : invList) { ids.add(inv.Id); }
        // Records are still 'Available' from setup — none are Reserved.

        Test.startTest();
        try {
            DeInventoryManagerController.bulkReleaseInventory(ids);
            Assert.fail('Expected AuraHandledException when no records are Reserved');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'Exception should be thrown');
        }
        Test.stopTest();
    }

    @IsTest
    static void bulkReleaseInventory_bulk200() {
        Site__c site = mkSite('BRI-SITE', 'SG');
        QuoteLineItem qli = mkQuoteLineItem(site.Id);
        List<Inventory__c> bulkRecords = new List<Inventory__c>();
        for (Integer i = 0; i < 200; i++) {
            bulkRecords.add(new Inventory__c(
                RecordTypeId = spaceRt(), Site_Id__c = site.Id,
                Status__c = 'Reserved', Space_Type__c = 'Cabinet', Name = 'BRI-' + i,
                Quote_Line__c = qli.Id, Assigned_To_Quote__c = qli.QuoteId
            ));
        }
        insert bulkRecords;
        List<Id> ids = new List<Id>();
        for (Inventory__c r : bulkRecords) ids.add(r.Id);

        Test.startTest();
        DeInventoryManagerController.bulkReleaseInventory(ids);
        Test.stopTest();

        Integer availableCount = [SELECT COUNT() FROM Inventory__c WHERE Site_Id__c = :site.Id AND Status__c = 'Available'];
        Assert.areEqual(200, availableCount, 'All 200 reserved records should be released');
    }

    // ═══════════════════════════════════════════════════════════════════
    // getFloorHallSummary
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void getFloorHallSummary_returnsCards() {
        Site__c site = [SELECT Id FROM Site__c WHERE Site_Code__c = 'TEST-SG01' LIMIT 1];

        Test.startTest();
        List<DeInventoryManagerController.FloorHallCard> cards =
            DeInventoryManagerController.getFloorHallSummary(site.Id);
        Test.stopTest();

        Assert.areEqual(1, cards.size(), 'Should return 1 card (one hall)');
        DeInventoryManagerController.FloorHallCard c = cards[0];
        Assert.areEqual(3, c.total, 'Total should be 3');
        Assert.areEqual(3, c.available, 'All 3 should be available');
        Assert.areEqual(0, c.held, 'None should be held');
        Assert.areEqual(0, c.active, 'None should be active');
        Assert.areEqual('TEST-SG01-01', c.floorName, 'Floor name should match');
        Assert.areEqual('TEST-SG01-01-01', c.hallName, 'Hall name should match');
    }

    @IsTest
    static void getFloorHallSummary_variedStatusesAndEmptyHall() {
        Site__c site = mkSite('FHS-SITE', 'SG');
        Floor__c floor = mkFloor(site.Id, 'FHS-SITE-01');
        DataHall__c hallA = mkHall(floor.Id, 'FHS-SITE-01-A', '01');
        DataHall__c hallB = mkHall(floor.Id, 'FHS-SITE-01-B', '02'); // stays empty
        QuoteLineItem qli = mkQuoteLineItem(site.Id);

        List<Inventory__c> inv = new List<Inventory__c>{
            new Inventory__c(RecordTypeId = spaceRt(), Site_Id__c = site.Id, Floor__c = floor.Id, Data_Hall__c = hallA.Id, Status__c = 'Available', Space_Type__c = 'Cabinet'),
            new Inventory__c(RecordTypeId = spaceRt(), Site_Id__c = site.Id, Floor__c = floor.Id, Data_Hall__c = hallA.Id, Status__c = 'Reserved', Space_Type__c = 'Cabinet', Quote_Line__c = qli.Id, Assigned_To_Quote__c = qli.QuoteId),
            new Inventory__c(RecordTypeId = spaceRt(), Site_Id__c = site.Id, Floor__c = floor.Id, Data_Hall__c = hallA.Id, Status__c = 'Assigned', Space_Type__c = 'Cabinet'),
            new Inventory__c(RecordTypeId = spaceRt(), Site_Id__c = site.Id, Floor__c = floor.Id, Data_Hall__c = hallA.Id, Status__c = 'Available', Space_Type__c = 'Cabinet'),
            new Inventory__c(RecordTypeId = spaceRt(), Site_Id__c = site.Id, Floor__c = floor.Id, Data_Hall__c = hallA.Id, Status__c = 'Stranded', Space_Type__c = 'Cabinet'),
            new Inventory__c(RecordTypeId = breakerRt(), Site_Id__c = site.Id, Floor__c = floor.Id, Data_Hall__c = hallA.Id, Status__c = 'Available', Capacity_Type__c = 'Power Circuit')
        };
        insert inv;

        // stopTest() first, with nothing Installed yet, so the Odoo create-sync
        // queueable drains cleanly. Only then flip inv[3] to Installed and read the
        // summary. See markInstalled for why the order matters.
        Test.startTest();
        Test.stopTest();
        markInstalled(inv[3]);

        List<DeInventoryManagerController.FloorHallCard> cards =
            DeInventoryManagerController.getFloorHallSummary(site.Id);

        Assert.areEqual(2, cards.size(), 'Should include the empty hall as its own card');

        DeInventoryManagerController.FloorHallCard cardA;
        DeInventoryManagerController.FloorHallCard cardB;
        for (DeInventoryManagerController.FloorHallCard c : cards) {
            if (c.hallId == hallA.Id) cardA = c;
            if (c.hallId == hallB.Id) cardB = c;
        }
        Assert.isNotNull(cardA, 'Hall A card should be present');
        Assert.isNotNull(cardB, 'Hall B (empty) card should be present');

        Assert.areEqual(6, cardA.total, 'Hall A total across all record types');
        Assert.areEqual(2, cardA.available, 'One available Space plus one available Breaker');
        Assert.areEqual(2, cardA.held, 'Reserved and Assigned both count as held');
        Assert.areEqual(0, cardA.sold, 'No Sold record is inserted because Sold requires an Order Item link');
        Assert.areEqual(1, cardA.installed, 'One Installed record');
        Assert.areEqual(2, cardA.active, 'Installed and Stranded count as active; Available is reported separately');
        Assert.areEqual(5, cardA.spaceTotal, 'Space-only total excludes the breaker');
        Assert.areEqual(0, cardA.spaceSold, 'Space-only sold count');
        Assert.areEqual(1, cardA.spaceInstalled, 'Space-only installed count');
        Assert.areEqual(2, cardA.spaceHeld, 'Space-only held count includes Reserved and Assigned');

        Assert.areEqual(0, cardB.total, 'Empty hall should default to zero counts');
    }

    // ═══════════════════════════════════════════════════════════════════
    // getInventoryByHall
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void getInventoryByHall_returnsRecords() {
        DataHall__c hall = [SELECT Id FROM DataHall__c
                           WHERE Name = 'TEST-SG01-01-01' LIMIT 1];

        Test.startTest();
        List<Inventory__c> inv =
            DeInventoryManagerController.getInventoryByHall(hall.Id);
        Test.stopTest();

        Assert.areEqual(3, inv.size(), 'Should return all 3 records in the hall');
    }

    // ═══════════════════════════════════════════════════════════════════
    // getExportData / getExportCount
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void getExportData_bySiteAndHall() {
        Site__c site = [SELECT Id FROM Site__c WHERE Site_Code__c = 'TEST-SG01' LIMIT 1];
        DataHall__c hall = [SELECT Id FROM DataHall__c WHERE Name = 'TEST-SG01-01-01' LIMIT 1];

        Test.startTest();
        List<Inventory__c> result = DeInventoryManagerController.getExportData(
            site.Id, hall.Id, 'All', 'All', null);
        Test.stopTest();

        Assert.areEqual(3, result.size(), 'Should return all 3 records for the site+hall filter');
    }

    @IsTest
    static void getExportData_filtersByStatusAndRecordType() {
        Site__c site = [SELECT Id FROM Site__c WHERE Site_Code__c = 'TEST-SG01' LIMIT 1];

        Test.startTest();
        List<Inventory__c> spaceOnly = DeInventoryManagerController.getExportData(
            site.Id, null, 'All', 'Inventory_Space', null);
        Test.stopTest();

        Assert.areEqual(2, spaceOnly.size(), 'Record-type filter should limit to Space records');
    }

    @IsTest
    static void getExportData_byCountriesWithNullSite() {
        Site__c site = mkSite('EXP-HK', 'HK');
        insert new List<Inventory__c>{
            new Inventory__c(RecordTypeId = spaceRt(), Site_Id__c = site.Id, Status__c = 'Available', Space_Type__c = 'Cabinet'),
            new Inventory__c(RecordTypeId = spaceRt(), Site_Id__c = site.Id, Status__c = 'Available', Space_Type__c = 'Cage')
        };

        Test.startTest();
        List<Inventory__c> result = DeInventoryManagerController.getExportData(
            null, null, 'All', 'All', new List<String>{ 'HK' });
        Test.stopTest();

        Assert.areEqual(2, result.size(), 'Country filter should scope to HK-only records');
    }

    @IsTest
    static void getExportData_allSitesWhenNoFilterGiven() {
        Test.startTest();
        List<Inventory__c> result = DeInventoryManagerController.getExportData(
            null, null, 'All', 'All', null);
        Test.stopTest();

        Assert.areEqual(3, result.size(), 'No site/country filter should return all 3 setup records');
    }

    @IsTest
    static void getExportCount_matchesExportDataSize() {
        Site__c site = [SELECT Id FROM Site__c WHERE Site_Code__c = 'TEST-SG01' LIMIT 1];

        Test.startTest();
        Integer count = DeInventoryManagerController.getExportCount(site.Id, null, 'Available', 'All', null);
        List<Inventory__c> data = DeInventoryManagerController.getExportData(site.Id, null, 'Available', 'All', null);
        Test.stopTest();

        Assert.areEqual(data.size(), count, 'Count and data-size should agree for identical filters');
        Assert.areEqual(3, count, 'All 3 setup records are Available');
    }

    // ═══════════════════════════════════════════════════════════════════
    // importInventoryBulk
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void importInventoryBulk_createsSpaceRecords() {
        Site__c site = mkSite('IMPX', 'SG');
        Floor__c floor = mkFloor(site.Id, 'IMPX-02');
        DataHall__c hall = mkHall(floor.Id, 'IMPX-02-H1', '01');

        List<Map<String, Object>> rows = new List<Map<String, Object>>{
            new Map<String, Object>{
                'Inventory Status' => 'Available', 'Space Type' => 'Cabinet',
                'Average Power per Cab (kVA)' => '10', 'Contracted Power (kVA)' => '8',
                'Remarks' => 'row1'
            },
            new Map<String, Object>{
                'Inventory Status' => 'Available', 'Space Type' => 'Cage',
                'Average Power per Cab (kVA)' => '20', 'Contracted Power (kVA)' => '15'
            }
        };

        Test.startTest();
        Map<String, Object> result = DeInventoryManagerController.importInventoryBulk(
            'Inventory_Space', site.Id, floor.Id, hall.Id, JSON.serialize(rows));
        Test.stopTest();

        Assert.areEqual(2, (Integer) result.get('inserted'), 'Both rows should insert successfully');
        Assert.areEqual(0, (Integer) result.get('updated'), 'No update rows in this batch');
        List<String> errors = (List<String>) result.get('errors');
        Assert.areEqual(0, errors.size(), 'No errors expected for valid rows');

        List<Inventory__c> created = [SELECT Name, Notes__c FROM Inventory__c WHERE Site_Id__c = :site.Id ORDER BY Name];
        Assert.areEqual(2, created.size(), 'Two records should exist in the DB');
        Assert.areEqual('IMPX-02-DH01-C01', created[0].Name, 'Cage row uses the C usage tag');
        Assert.areEqual('IMPX-02-DH01-S01', created[1].Name, 'Cabinet row uses the S usage tag');
    }

    @IsTest
    static void importInventoryBulk_createsBreakerRecords() {
        Site__c site = mkSite('IMPB', 'SG');
        Floor__c floor = mkFloor(site.Id, 'IMPB-01');
        DataHall__c hall = mkHall(floor.Id, 'IMPB-01-H1', '02');

        List<Map<String, Object>> rows = new List<Map<String, Object>>{
            new Map<String, Object>{
                'Inventory Status' => 'Available', 'Breaker Type' => '3 Phase',
                'Voltage Rating (V)' => '230V', 'Current Rating (A)' => '20A'
            }
        };

        Test.startTest();
        Map<String, Object> result = DeInventoryManagerController.importInventoryBulk(
            'Inventory_Breaker', site.Id, floor.Id, hall.Id, JSON.serialize(rows));
        Test.stopTest();

        Assert.areEqual(1, (Integer) result.get('inserted'), 'Breaker row should insert');
        Inventory__c created = [SELECT Name, Breaker_Type__c FROM Inventory__c WHERE Site_Id__c = :site.Id LIMIT 1];
        Assert.areEqual('IMPB-01-DH02-BRK001', created.Name, 'Breaker rows use 3-digit sequence padding');
        Assert.areEqual('3 Phase', created.Breaker_Type__c, 'Picklist field should be stored');
    }

    @IsTest
    static void importInventoryBulk_updatesExistingRecord() {
        Site__c site = mkSite('IMPU', 'SG');
        Inventory__c existing = new Inventory__c(
            RecordTypeId = spaceRt(), Site_Id__c = site.Id, Status__c = 'Available',
            Space_Type__c = 'Cabinet', Name = 'IMPU-EXISTING'
        );
        insert existing;
        Floor__c floor = mkFloor(site.Id, 'IMPU-01');
        DataHall__c hall = mkHall(floor.Id, 'IMPU-01-H1', '01');

        List<Map<String, Object>> rows = new List<Map<String, Object>>{
            new Map<String, Object>{ 'Id' => existing.Id, 'Inventory Status' => 'Pending Available', 'Remarks' => 'updated via import' }
        };

        Test.startTest();
        Map<String, Object> result = DeInventoryManagerController.importInventoryBulk(
            'Inventory_Space', site.Id, floor.Id, hall.Id, JSON.serialize(rows));
        Test.stopTest();

        Assert.areEqual(1, (Integer) result.get('updated'), 'One row should update');
        Inventory__c updated = [SELECT Status__c, Notes__c FROM Inventory__c WHERE Id = :existing.Id];
        Assert.areEqual('Pending Available', updated.Status__c, 'Status should be updated');
        Assert.areEqual('updated via import', updated.Notes__c, 'Notes should be updated');
    }

    @IsTest
    static void importInventoryBulk_missingRequiredFieldPartialSuccess() {
        Site__c site = mkSite('IMPM', 'SG');
        Floor__c floor = mkFloor(site.Id, 'IMPM-01');
        DataHall__c hall = mkHall(floor.Id, 'IMPM-01-H1', '01');

        List<Map<String, Object>> rows = new List<Map<String, Object>>{
            new Map<String, Object>{
                'Inventory Status' => 'Available', 'Space Type' => 'Cabinet',
                'Average Power per Cab (kVA)' => '10', 'Contracted Power (kVA)' => '8'
            },
            new Map<String, Object>{
                'Inventory Status' => 'Available'
                // missing Space Type / power fields
            }
        };

        Test.startTest();
        Map<String, Object> result = DeInventoryManagerController.importInventoryBulk(
            'Inventory_Space', site.Id, floor.Id, hall.Id, JSON.serialize(rows));
        Test.stopTest();

        Assert.areEqual(1, (Integer) result.get('inserted'), 'Only the valid row should insert');
        List<String> errors = (List<String>) result.get('errors');
        Assert.isTrue(errors.size() >= 1, 'Missing-field row should produce at least one error');
        List<Map<String, Object>> rowResults = (List<Map<String, Object>>) result.get('rowResults');
        Assert.areEqual('error', (String) rowResults[1].get('status'), 'Second row should be flagged as error');
    }

    @IsTest
    static void importInventoryBulk_invalidPicklistValueRejected() {
        Site__c site = mkSite('IMPP', 'SG');
        Floor__c floor = mkFloor(site.Id, 'IMPP-01');
        DataHall__c hall = mkHall(floor.Id, 'IMPP-01-H1', '01');

        List<Map<String, Object>> rows = new List<Map<String, Object>>{
            new Map<String, Object>{
                'Inventory Status' => 'Available', 'Breaker Type' => 'Not A Real Value',
                'Voltage Rating (V)' => '230V', 'Current Rating (A)' => '20A'
            }
        };

        Test.startTest();
        Map<String, Object> result = DeInventoryManagerController.importInventoryBulk(
            'Inventory_Breaker', site.Id, floor.Id, hall.Id, JSON.serialize(rows));
        Test.stopTest();

        Assert.areEqual(0, (Integer) result.get('inserted'), 'Row with invalid picklist value should not insert');
        List<String> errors = (List<String>) result.get('errors');
        Assert.isTrue(errors.size() >= 1, 'Invalid picklist value should produce an error');
    }

    @IsTest
    static void importInventoryBulk_invalidIdFormatCaught() {
        Site__c site = mkSite('IMPI', 'SG');
        Floor__c floor = mkFloor(site.Id, 'IMPI-01');
        DataHall__c hall = mkHall(floor.Id, 'IMPI-01-H1', '01');

        List<Map<String, Object>> rows = new List<Map<String, Object>>{
            new Map<String, Object>{ 'Id' => 'not-a-real-id', 'Inventory Status' => 'Pending Available' }
        };

        Test.startTest();
        Map<String, Object> result = DeInventoryManagerController.importInventoryBulk(
            'Inventory_Space', site.Id, floor.Id, hall.Id, JSON.serialize(rows));
        Test.stopTest();

        Assert.areEqual(0, (Integer) result.get('updated'), 'Invalid Id row should not be processed as an update');
        List<String> errors = (List<String>) result.get('errors');
        Assert.isTrue(errors.size() >= 1, 'Invalid Id format should produce an error');
        Assert.isTrue(errors[0].contains('not a valid Salesforce record ID'), 'Error message should explain the Id problem');
    }

    @IsTest
    static void importInventoryBulk_cageReferenceResolution() {
        Site__c site = mkSite('IMPC', 'SG');
        Floor__c floor = mkFloor(site.Id, 'IMPC-01');
        DataHall__c hall = mkHall(floor.Id, 'IMPC-01-H1', '01');

        Inventory__c cageRef = new Inventory__c(
            RecordTypeId = spaceRt(), Site_Id__c = site.Id, Floor__c = floor.Id, Data_Hall__c = hall.Id,
            Status__c = 'Available', Space_Type__c = 'Cage', Name = 'IMPC-REFCAGE'
        );
        insert cageRef;

        List<Map<String, Object>> rows = new List<Map<String, Object>>{
            new Map<String, Object>{
                'Inventory Status' => 'Available', 'Space Type' => 'Cabinet',
                'Average Power per Cab (kVA)' => '10', 'Contracted Power (kVA)' => '8',
                'Cage Reference' => 'IMPC-REFCAGE'
            },
            new Map<String, Object>{
                'Inventory Status' => 'Available', 'Space Type' => 'Cabinet',
                'Average Power per Cab (kVA)' => '10', 'Contracted Power (kVA)' => '8',
                'Cage Reference' => 'DOES-NOT-EXIST'
            }
        };

        Test.startTest();
        Map<String, Object> result = DeInventoryManagerController.importInventoryBulk(
            'Inventory_Space', site.Id, floor.Id, hall.Id, JSON.serialize(rows));
        Test.stopTest();

        Assert.areEqual(1, (Integer) result.get('inserted'), 'Only the row with a valid Cage Reference should insert');
        List<String> errors = (List<String>) result.get('errors');
        Assert.isTrue(errors.size() >= 1, 'Unresolvable Cage Reference should produce an error');

        Inventory__c created = [SELECT Cage_Reference__c FROM Inventory__c WHERE Space_Type__c = 'Cabinet' AND Site_Id__c = :site.Id LIMIT 1];
        Assert.areEqual(cageRef.Id, created.Cage_Reference__c, 'Cage Reference should resolve to the matching Inventory record');
    }

    @IsTest
    static void importInventoryBulk_noRowsThrows() {
        Site__c site = mkSite('IMPZ', 'SG');

        Test.startTest();
        try {
            DeInventoryManagerController.importInventoryBulk('Inventory_Space', site.Id, null, null, '[]');
            Assert.fail('Expected AuraHandledException for an empty row list');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'Exception should be thrown for no rows');
        }
        Test.stopTest();
    }

    @IsTest
    static void importInventoryBulk_invalidRecordTypeThrows() {
        Site__c site = mkSite('IMPR', 'SG');
        List<Map<String, Object>> rows = new List<Map<String, Object>>{
            new Map<String, Object>{ 'Inventory Status' => 'Available' }
        };

        Test.startTest();
        try {
            DeInventoryManagerController.importInventoryBulk('Bogus_RT', site.Id, null, null, JSON.serialize(rows));
            Assert.fail('Expected AuraHandledException for an invalid record type');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'Exception should be thrown for an invalid record type');
        }
        Test.stopTest();
    }

    @IsTest
    static void importInventoryBulk_invalidNumericValueCaught() {
        Site__c site = mkSite('IMPN', 'SG');
        Floor__c floor = mkFloor(site.Id, 'IMPN-01');
        DataHall__c hall = mkHall(floor.Id, 'IMPN-01-H1', '01');

        List<Map<String, Object>> rows = new List<Map<String, Object>>{
            new Map<String, Object>{
                'Inventory Status' => 'Available', 'Space Type' => 'Cabinet',
                'Average Power per Cab (kVA)' => 'not-a-number', 'Contracted Power (kVA)' => '8'
            }
        };

        Test.startTest();
        Map<String, Object> result = DeInventoryManagerController.importInventoryBulk(
            'Inventory_Space', site.Id, floor.Id, hall.Id, JSON.serialize(rows));
        Test.stopTest();

        Assert.areEqual(0, (Integer) result.get('inserted'), 'Row with a non-numeric value should not insert');
        List<String> errors = (List<String>) result.get('errors');
        Assert.isTrue(errors.size() >= 1, 'Invalid numeric value should produce at least one error');
    }

    @IsTest
    static void importInventoryBulk_bulk200Rows() {
        Site__c site = mkSite('IMPBLK', 'SG');
        Floor__c floor = mkFloor(site.Id, 'IMPBLK-01');
        DataHall__c hall = mkHall(floor.Id, 'IMPBLK-01-H1', '01');

        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        for (Integer i = 0; i < 200; i++) {
            rows.add(new Map<String, Object>{
                'Inventory Status' => 'Available', 'Space Type' => 'Cabinet',
                'Average Power per Cab (kVA)' => '10', 'Contracted Power (kVA)' => '8'
            });
        }

        Test.startTest();
        Map<String, Object> result = DeInventoryManagerController.importInventoryBulk(
            'Inventory_Space', site.Id, floor.Id, hall.Id, JSON.serialize(rows));
        Test.stopTest();

        Assert.areEqual(200, (Integer) result.get('inserted'), 'All 200 rows should insert');
        Integer dbCount = [SELECT COUNT() FROM Inventory__c WHERE Site_Id__c = :site.Id];
        Assert.areEqual(200, dbCount, 'DB should reflect 200 new records');
    }

    // ═══════════════════════════════════════════════════════════════════
    // importInventory (legacy)
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void importInventory_insertsAndUpdates() {
        Site__c site = [SELECT Id FROM Site__c WHERE Site_Code__c = 'TEST-SG01' LIMIT 1];
        Inventory__c existing = [SELECT Id FROM Inventory__c WHERE Unit_Reference__c = 'SG01-DH01-A001' LIMIT 1];

        List<Map<String, String>> rows = new List<Map<String, String>>{
            new Map<String, String>{
                'RecordType' => 'Inventory_Space', 'Name' => 'LEGACY-01', 'Status' => 'Available',
                'Space_Type' => 'Cabinet', 'Total_Capacity_kVA' => '10', 'Power_kVA' => '5',
                'Floor' => 'TEST-SG01-01', 'Data_Hall' => 'TEST-SG01-01-01'
            },
            new Map<String, String>{
                'Id' => existing.Id, 'Status' => 'Pending Available'
            }
        };

        Test.startTest();
        Map<String, Object> result = DeInventoryManagerController.importInventory(rows, site.Id);
        Test.stopTest();

        Assert.areEqual(1, (Integer) result.get('inserted'), 'One new row should insert');
        Assert.areEqual(1, (Integer) result.get('updated'), 'One row should update');
        List<String> errors = (List<String>) result.get('errors');
        Assert.areEqual(0, errors.size(), 'No errors expected');

        Inventory__c created = [SELECT Name, Floor__c, Data_Hall__c, Site_Id__c FROM Inventory__c WHERE Name = 'LEGACY-01'];
        Assert.areEqual(site.Id, created.Site_Id__c, 'New record should be linked to the current site');
        Assert.isNotNull(created.Floor__c, 'Floor should resolve by name');
        Assert.isNotNull(created.Data_Hall__c, 'Data hall should resolve by name');

        Inventory__c updated = [SELECT Status__c FROM Inventory__c WHERE Id = :existing.Id];
        Assert.areEqual('Pending Available', updated.Status__c, 'Existing record should be updated');
    }

    @IsTest
    static void importInventory_defaultsRecordTypeWhenMissing() {
        Site__c site = [SELECT Id FROM Site__c WHERE Site_Code__c = 'TEST-SG01' LIMIT 1];

        List<Map<String, String>> rows = new List<Map<String, String>>{
            new Map<String, String>{ 'Name' => 'LEGACY-NORT', 'Status' => 'Available' }
        };

        Test.startTest();
        Map<String, Object> result = DeInventoryManagerController.importInventory(rows, site.Id);
        Test.stopTest();

        Assert.areEqual(1, (Integer) result.get('inserted'), 'Row without RecordType should still insert');
        Inventory__c created = [SELECT RecordTypeId FROM Inventory__c WHERE Name = 'LEGACY-NORT'];
        Assert.areEqual(spaceRt(), created.RecordTypeId, 'Should default to the Space record type');
    }

    @IsTest
    static void importInventory_capturesDmlErrors() {
        Site__c site = [SELECT Id FROM Site__c WHERE Site_Code__c = 'TEST-SG01' LIMIT 1];

        List<Map<String, String>> rows = new List<Map<String, String>>{
            new Map<String, String>{ 'Name' => 'LEGACY-BAD', 'Status' => 'NotARealStatusValue' }
        };

        Test.startTest();
        Map<String, Object> result = DeInventoryManagerController.importInventory(rows, site.Id);
        Test.stopTest();

        Assert.areEqual(0, (Integer) result.get('inserted'), 'Invalid picklist value should prevent insert');
        List<String> errors = (List<String>) result.get('errors');
        Assert.isTrue(errors.size() >= 1, 'DML failure should surface as an error message');
    }

    // ═══════════════════════════════════════════════════════════════════
    // checkDuplicate
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void checkDuplicate_trueForExistingName() {
        Inventory__c existing = [SELECT Name FROM Inventory__c WHERE Unit_Reference__c = 'SG01-DH01-A001' LIMIT 1];

        Test.startTest();
        Boolean result = DeInventoryManagerController.checkDuplicate(existing.Name);
        Test.stopTest();

        Assert.isTrue(result, 'Existing name should be reported as a duplicate');
    }

    @IsTest
    static void checkDuplicate_falseForNonExistingName() {
        Test.startTest();
        Boolean result = DeInventoryManagerController.checkDuplicate('DEFINITELY-NOT-A-REAL-NAME-XYZ');
        Test.stopTest();

        Assert.isFalse(result, 'Non-existing name should not be a duplicate');
    }

    @IsTest
    static void checkDuplicate_blankReturnsFalse() {
        Test.startTest();
        Boolean result = DeInventoryManagerController.checkDuplicate('');
        Test.stopTest();

        Assert.isFalse(result, 'Blank name should short-circuit to false');
    }

    // ═══════════════════════════════════════════════════════════════════
    // addHallToFloor
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void addHallToFloor_sequentialNumbering() {
        Site__c site = mkSite('AHF-SITE', 'SG');
        Id floorId = DeInventoryManagerController.createFloor(site.Id, 'AH-FLOOR', null);

        Test.startTest();
        Map<String, String> first = DeInventoryManagerController.addHallToFloor(floorId, site.Id);
        Map<String, String> second = DeInventoryManagerController.addHallToFloor(floorId, site.Id);
        Test.stopTest();

        Assert.areEqual('AH-FLOOR-1', first.get('name'), 'First hall should be numbered 1');
        Assert.areEqual('AH-FLOOR-2', second.get('name'), 'Second hall should be numbered 2');
        Assert.isNotNull(first.get('id'), 'First hall id should be returned');
        Assert.isNotNull(second.get('id'), 'Second hall id should be returned');
    }

    // ═══════════════════════════════════════════════════════════════════
    // getAssignmentDemand
    // ═══════════════════════════════════════════════════════════════════

    private static Boolean containsQli(List<QuoteLineItem> demand, Id qliId) {
        for (QuoteLineItem d : demand) {
            if (d.Id == qliId) return true;
        }
        return false;
    }

    @IsTest
    static void getAssignmentDemand_bySiteViaQuoteTargetSite() {
        Site__c site = mkSite('DEM-SITE', 'SG');
        QuoteLineItem qli = mkQuoteLineItem(site.Id, 'Presented');

        Test.startTest();
        List<QuoteLineItem> demand = DeInventoryManagerController.getAssignmentDemand(site.Id, null);
        Test.stopTest();

        Assert.isTrue(containsQli(demand, qli.Id),
            'QLI on a Presented quote targeting this site should appear in demand');
    }

    @IsTest
    static void getAssignmentDemand_nullSiteReturnsAllDemand() {
        Site__c site = mkSite('DEM-SITE2', 'SG');
        QuoteLineItem qli = mkQuoteLineItem(site.Id, 'In Review');

        Test.startTest();
        List<QuoteLineItem> demand = DeInventoryManagerController.getAssignmentDemand(null, 'All');
        Test.stopTest();

        Assert.isTrue(containsQli(demand, qli.Id),
            'Null site should surface pending demand across all sites');
    }

    // DIG-863: the default (blank/'All'/unrecognised stage) result set is the
    // pending-review set only — Draft and Accepted must not be in it.
    @IsTest
    static void getAssignmentDemand_defaultExcludesDraft() {
        Site__c site = mkSite('DEM-DRAFT', 'SG');
        QuoteLineItem draftQli = mkQuoteLineItem(site.Id, 'Draft');

        Test.startTest();
        List<QuoteLineItem> demand = DeInventoryManagerController.getAssignmentDemand(site.Id, 'All');
        Test.stopTest();

        Assert.isFalse(containsQli(demand, draftQli.Id),
            'Draft is never rendered by the Assignment UI, so it must not be fetched');
    }

    @IsTest
    static void getAssignmentDemand_defaultExcludesAccepted() {
        Site__c site = mkSite('DEM-ACC', 'SG');
        QuoteLineItem acceptedQli = mkQuoteLineItem(site.Id, 'Accepted');
        QuoteLineItem pendingQli  = mkSiblingQuoteLineItem(acceptedQli, site.Id, 'Approved');

        Test.startTest();
        List<QuoteLineItem> demand = DeInventoryManagerController.getAssignmentDemand(site.Id, '');
        Test.stopTest();

        Assert.isFalse(containsQli(demand, acceptedQli.Id),
            'Accepted is closed history — opt-in only, not part of the default set');
        Assert.isTrue(containsQli(demand, pendingQli.Id),
            'Approved is pending review and belongs in the default set');
    }

    @IsTest
    static void getAssignmentDemand_acceptedIsOptIn() {
        Site__c site = mkSite('DEM-ACC2', 'SG');
        QuoteLineItem acceptedQli = mkQuoteLineItem(site.Id, 'Accepted');

        Test.startTest();
        List<QuoteLineItem> demand =
            DeInventoryManagerController.getAssignmentDemand(site.Id, 'Accepted');
        Test.stopTest();

        Assert.isTrue(containsQli(demand, acceptedQli.Id),
            'Asking for Accepted explicitly must return Accepted rows');
    }

    // The bug the ticket reported: picking a stage returned nothing. Stage now
    // narrows in SOQL, so a single-stage request returns that stage and only it.
    @IsTest
    static void getAssignmentDemand_singleStageReturnsOnlyThatStage() {
        Site__c site = mkSite('DEM-STAGE', 'SG');
        QuoteLineItem presented = mkQuoteLineItem(site.Id, 'Presented');
        QuoteLineItem approved  = mkSiblingQuoteLineItem(presented, site.Id, 'Approved');

        Test.startTest();
        List<QuoteLineItem> demand =
            DeInventoryManagerController.getAssignmentDemand(site.Id, 'Presented');
        Test.stopTest();

        Assert.isTrue(containsQli(demand, presented.Id), 'Presented row must be returned');
        Assert.isFalse(containsQli(demand, approved.Id),
            'Approved must not leak into a Presented-only request');
        for (QuoteLineItem d : demand) {
            Assert.areEqual('Presented', d.Quote.Status,
                'Every returned row must be on the requested stage');
        }
    }

    // An unrecognised stage string must not be pushed into the SOQL bind — it
    // falls back to the pending set rather than returning an empty list.
    @IsTest
    static void getAssignmentDemand_unknownStageFallsBackToPending() {
        Site__c site = mkSite('DEM-BAD', 'SG');
        QuoteLineItem pendingQli = mkQuoteLineItem(site.Id, 'In Review');

        Test.startTest();
        List<QuoteLineItem> demand =
            DeInventoryManagerController.getAssignmentDemand(site.Id, 'Banana');
        Test.stopTest();

        Assert.isTrue(containsQli(demand, pendingQli.Id),
            'Unrecognised stage should fall back to the pending set, not return nothing');
    }

    @IsTest
    static void getAssignmentDemand_capIsAboveOldFiveHundred() {
        Assert.isTrue(DeInventoryManagerController.ASSIGNMENT_DEMAND_LIMIT >= 2000,
            'Row cap must clear the pending backlog; 500 truncated it geographically');
    }

    // ═══════════════════════════════════════════════════════════════════
    // getAvailableByType
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void getAvailableByType_countsSpaceAndBreaker() {
        Site__c site = mkSite('AVB-SITE', 'SG');
        QuoteLineItem qli = mkQuoteLineItem(site.Id);
        List<Inventory__c> inv = new List<Inventory__c>{
            new Inventory__c(RecordTypeId = spaceRt(), Site_Id__c = site.Id, Status__c = 'Available', Space_Type__c = 'Cabinet'),
            new Inventory__c(RecordTypeId = spaceRt(), Site_Id__c = site.Id, Status__c = 'Pending Available', Space_Type__c = 'Cage'),
            new Inventory__c(RecordTypeId = spaceRt(), Site_Id__c = site.Id, Status__c = 'Reserved', Space_Type__c = 'Cabinet', Quote_Line__c = qli.Id, Assigned_To_Quote__c = qli.QuoteId),
            new Inventory__c(RecordTypeId = breakerRt(), Site_Id__c = site.Id, Status__c = 'Available', Capacity_Type__c = 'Power Circuit'),
            // Was 'Installed'. This test only needs a second Breaker that is NOT
            // available — it asserts no Installed count — so 'Stranded' serves the
            // same purpose without tripping Inventory_Edit_Lock.
            new Inventory__c(RecordTypeId = breakerRt(), Site_Id__c = site.Id, Status__c = 'Stranded', Capacity_Type__c = 'Power Circuit')
        };
        insert inv;

        Test.startTest();
        Map<String, Integer> result = DeInventoryManagerController.getAvailableByType(site.Id);
        Test.stopTest();

        Assert.areEqual(2, result.get('Space'), 'Two Space records are Available/Pending Available');
        Assert.areEqual(3, result.get('SpaceTotal'), 'Three Space records total');
        Assert.areEqual(1, result.get('Breaker'), 'One Breaker record is Available');
        Assert.areEqual(2, result.get('BreakerTotal'), 'Two Breaker records total');
    }

    // ═══════════════════════════════════════════════════════════════════
    // updateCrossId
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void updateCrossId_updatesAssets() {
        Site__c site = mkSite('UCX-SITE', 'SG');
        QuoteLineItem qli = mkQuoteLineItem(site.Id);

        Asset aSide = new Asset(Name = 'A-Side-Asset');
        Asset zSide = new Asset(Name = 'Z-Side-Asset');
        insert new List<Asset>{ aSide, zSide };

        Test.startTest();
        DeInventoryManagerController.updateCrossId(qli.Id, aSide.Id, zSide.Id);
        Test.stopTest();

        QuoteLineItem updated = [SELECT A_Side_Asset__c, Z_Side_Asset__c FROM QuoteLineItem WHERE Id = :qli.Id];
        Assert.areEqual(aSide.Id, updated.A_Side_Asset__c, 'A-side asset should be linked');
        Assert.areEqual(zSide.Id, updated.Z_Side_Asset__c, 'Z-side asset should be linked');
    }

    // ═══════════════════════════════════════════════════════════════════
    // getOdooSyncStatus
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void getOdooSyncStatus_emptyListReturnsZeros() {
        Test.startTest();
        Map<String, Integer> result = DeInventoryManagerController.getOdooSyncStatus(new List<Id>());
        Test.stopTest();

        Assert.areEqual(0, result.get('total'), 'Empty input should return zero total');
        Assert.areEqual(0, result.get('synced'), 'Empty input should return zero synced');
    }

    @IsTest
    static void getOdooSyncStatus_countsSyncedFailedPending() {
        Site__c site = mkSite('ODOO-SITE', 'SG');
        Inventory__c synced = new Inventory__c(
            RecordTypeId = spaceRt(), Site_Id__c = site.Id, Status__c = 'Available',
            Space_Type__c = 'Cabinet', Odoo_Space_ID__c = 'ODOO-123'
        );
        Inventory__c failed = new Inventory__c(
            RecordTypeId = spaceRt(), Site_Id__c = site.Id, Status__c = 'Available',
            Space_Type__c = 'Cabinet', Odoo_Sync_Error__c = 'Sync failed: timeout'
        );
        Inventory__c pending = new Inventory__c(
            RecordTypeId = spaceRt(), Site_Id__c = site.Id, Status__c = 'Available',
            Space_Type__c = 'Cabinet'
        );
        insert new List<Inventory__c>{ synced, failed, pending };

        Test.startTest();
        Map<String, Integer> result = DeInventoryManagerController.getOdooSyncStatus(
            new List<Id>{ synced.Id, failed.Id, pending.Id });
        Test.stopTest();

        Assert.areEqual(3, result.get('total'), 'Total should reflect all 3 records');
        Assert.areEqual(1, result.get('synced'), 'One record has Odoo_Space_ID__c set');
        Assert.areEqual(1, result.get('failed'), 'One record has Odoo_Sync_Error__c set');
        Assert.areEqual(1, result.get('pending'), 'One record has neither set');
    }

    // ═══════════════════════════════════════════════════════════════════
    // Coverage top-up: FLS/CRUD-denied branches (all follow the same
    // "restricted Minimum-Access user, no grants" shape used across the DE
    // controllers' test suites). Each of these throw-checks runs BEFORE any
    // SOQL/DML in the method under test, so record-level sharing for the
    // restricted user never comes into play — only the object-level
    // isCreateable()/isUpdateable() describe result matters here.
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void createInventoryRecords_flsInventoryCreateDenied() {
        Site__c site = mkSite('FLSIV', 'SG');
        User restricted = createRestrictedUser();

        CreateParams p = new CreateParams();
        p.siteId = site.Id;
        p.spaceType = 'Cabinet';
        p.totalCapacityKva = 5;
        p.quantity = 1;

        Boolean threw = false;
        Test.startTest();
        System.runAs(restricted) {
            try {
                callCreate(p);
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Restricted user without Inventory create should be denied');
    }

    @IsTest
    static void createInventoryRecords_flsFloorCreateDenied() {
        Site__c site = mkSite('FLSFL', 'SG');
        User restricted = createRestrictedUser();
        assignPermissionSet(restricted.Id, 'DE_Regional_Manager_Supplement');

        CreateParams p = new CreateParams();
        p.siteId = site.Id;
        p.spaceType = 'Cage';
        p.totalCapacityKva = 5;
        p.quantity = 1;
        p.newFloorName = 'FLSFL-01'; // floorId left null so the new-Floor branch runs

        Boolean threw = false;
        String msg = '';
        Test.startTest();
        System.runAs(restricted) {
            try {
                callCreate(p);
            } catch (AuraHandledException e) {
                threw = true;
                msg = e.getMessage();
            }
        }
        Test.stopTest();

        Assert.isTrue(threw,
            'User with Inventory create but no Floor create should be denied when a new floor is requested');
        // Note: AuraHandledException.getMessage() returns the generic "Script-thrown
        // exception" outside of an actual Aura/LWC invocation (a documented Salesforce
        // platform quirk, not specific to this class) — so only content-free assertions
        // on the message are reliable here, matching InventoryControllerTest's convention.
        Assert.isTrue(String.isNotBlank(msg), 'Exception message should be populated: ' + msg);
    }

    @IsTest
    static void createInventoryRecords_flsDataHallCreateDenied() {
        Site__c site = mkSite('FLSDH', 'SG');
        Floor__c floor = mkFloor(site.Id, 'FLSDH-01');
        User restricted = createRestrictedUser();
        assignPermissionSet(restricted.Id, 'DE_Regional_Manager_Supplement');

        CreateParams p = new CreateParams();
        p.siteId = site.Id;
        p.floorId = floor.Id; // existing floor supplied, so only the DataHall check is reached
        p.spaceType = 'Cage';
        p.totalCapacityKva = 5;
        p.quantity = 1;
        p.newDataHallName = 'FLSDH-01-01';

        Boolean threw = false;
        String msg = '';
        Test.startTest();
        System.runAs(restricted) {
            try {
                callCreate(p);
            } catch (AuraHandledException e) {
                threw = true;
                msg = e.getMessage();
            }
        }
        Test.stopTest();

        Assert.isTrue(threw,
            'User with Inventory create but no Data Hall create should be denied when a new hall is requested');
        // See note in createInventoryRecords_flsFloorCreateDenied re: getMessage()
        // returning the generic "Script-thrown exception" outside Aura/LWC context.
        Assert.isTrue(String.isNotBlank(msg), 'Exception message should be populated: ' + msg);
    }

    @IsTest
    static void updateInventoryField_flsDeniedThrows() {
        Inventory__c inv = [SELECT Id FROM Inventory__c WHERE Unit_Reference__c = 'SG01-DH01-A001' LIMIT 1];
        User restricted = createRestrictedUser();

        Boolean threw = false;
        Test.startTest();
        System.runAs(restricted) {
            try {
                DeInventoryManagerController.updateInventoryField(inv.Id, 'Notes__c', 'x');
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Restricted user without Inventory edit should be denied');
    }

    @IsTest
    static void updateInventoryFieldBulk_flsDeniedThrows() {
        Inventory__c inv = [SELECT Id FROM Inventory__c WHERE Unit_Reference__c = 'SG01-DH01-A001' LIMIT 1];
        User restricted = createRestrictedUser();

        Boolean threw = false;
        Test.startTest();
        System.runAs(restricted) {
            try {
                DeInventoryManagerController.updateInventoryFieldBulk(new List<Id>{ inv.Id }, 'Notes__c', 'x');
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Restricted user without Inventory edit should be denied for bulk update');
    }

    @IsTest
    static void releaseInventory_flsDeniedThrows() {
        Inventory__c inv = [SELECT Id FROM Inventory__c WHERE Unit_Reference__c = 'SG01-DH01-A001' LIMIT 1];
        User restricted = createRestrictedUser();

        Boolean threw = false;
        Test.startTest();
        System.runAs(restricted) {
            try {
                DeInventoryManagerController.releaseInventory(inv.Id);
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Restricted user without Inventory edit should be denied on release');
    }

    @IsTest
    static void decommissionInventory_flsDeniedThrows() {
        Inventory__c inv = [SELECT Id FROM Inventory__c WHERE Unit_Reference__c = 'SG01-DH01-A001' LIMIT 1];
        User restricted = createRestrictedUser();

        Boolean threw = false;
        Test.startTest();
        System.runAs(restricted) {
            try {
                DeInventoryManagerController.decommissionInventory(inv.Id);
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Restricted user without Inventory edit should be denied on decommission');
    }

    @IsTest
    static void createFloor_flsDeniedThrows() {
        Site__c site = mkSite('FLSCF', 'SG');
        User restricted = createRestrictedUser();

        Boolean threw = false;
        Test.startTest();
        System.runAs(restricted) {
            try {
                DeInventoryManagerController.createFloor(site.Id, 'FLSCF-01', null);
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Restricted user without Floor create should be denied');
    }

    @IsTest
    static void bulkReleaseInventory_flsDeniedThrows() {
        Inventory__c inv = [SELECT Id FROM Inventory__c WHERE Unit_Reference__c = 'SG01-DH01-A001' LIMIT 1];
        User restricted = createRestrictedUser();

        Boolean threw = false;
        Test.startTest();
        System.runAs(restricted) {
            try {
                DeInventoryManagerController.bulkReleaseInventory(new List<Id>{ inv.Id });
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Restricted user without Inventory edit should be denied on bulk release');
    }

    @IsTest
    static void importInventoryBulk_flsCreateDeniedThrows() {
        Site__c site = mkSite('FLSIB', 'SG');
        User restricted = createRestrictedUser();

        Boolean threw = false;
        Test.startTest();
        System.runAs(restricted) {
            try {
                DeInventoryManagerController.importInventoryBulk('Inventory_Space', site.Id, null, null, '[]');
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Restricted user without Inventory create should be denied for bulk import');
    }

    @IsTest
    static void importInventory_flsCreateDeniedThrows() {
        Site__c site = mkSite('FLSLI', 'SG');
        User restricted = createRestrictedUser();

        Boolean threw = false;
        Test.startTest();
        System.runAs(restricted) {
            try {
                DeInventoryManagerController.importInventory(new List<Map<String, String>>(), site.Id);
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Restricted user without Inventory create should be denied for legacy import');
    }

    @IsTest
    static void addHallToFloor_flsDeniedThrows() {
        Site__c site = mkSite('FLSAH', 'SG');
        Id floorId = DeInventoryManagerController.createFloor(site.Id, 'FLSAH-01', null);
        User restricted = createRestrictedUser();

        Boolean threw = false;
        Test.startTest();
        System.runAs(restricted) {
            try {
                DeInventoryManagerController.addHallToFloor(floorId, site.Id);
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Restricted user without Data Hall create should be denied');
    }

    @IsTest
    static void updateCrossId_flsDeniedThrows() {
        Site__c site = mkSite('FLSCX', 'SG');
        QuoteLineItem qli = mkQuoteLineItem(site.Id);
        User restricted = createRestrictedUser();

        Boolean threw = false;
        Test.startTest();
        System.runAs(restricted) {
            try {
                DeInventoryManagerController.updateCrossId(qli.Id, null, null);
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Restricted user without Quote Line Item edit should be denied');
    }

    // ═══════════════════════════════════════════════════════════════════
    // Coverage top-up: createInventoryRecords naming-convention edge branches
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void createInventoryRecords_unitNumberNonNumeric() {
        Site__c site = mkSite('UNA1', 'SG');
        Floor__c floor = mkFloor(site.Id, 'UNA1-01');
        DataHall__c hall = mkHall(floor.Id, 'UNA1-01-H1', '01');

        CreateParams p = new CreateParams();
        p.siteId = site.Id; p.floorId = floor.Id; p.dataHallId = hall.Id;
        p.spaceType = 'Cabinet';
        p.unitNumber = 'A'; // non-numeric — should be used verbatim, no zero-padding
        p.quantity = 1;

        Test.startTest();
        Id createdId = callCreate(p);
        Test.stopTest();

        Inventory__c rec = [SELECT Name FROM Inventory__c WHERE Id = :createdId];
        Assert.areEqual('UNA1-01-DH01-SA', rec.Name,
            'Non-numeric unit number should be appended as-is without leftPad');
    }

    @IsTest
    static void createInventoryRecords_flexOfficeNoHyphenHallName() {
        Site__c site = mkSite('FLX2', 'SG');
        Floor__c floor = mkFloor(site.Id, 'FLX2-01');
        DataHall__c hall = mkHall(floor.Id, 'COLP7', null); // hall Name has no hyphen

        CreateParams p = new CreateParams();
        p.siteId = site.Id; p.floorId = floor.Id; p.dataHallId = hall.Id;
        p.spaceType = 'Flex Office';
        p.unitNumber = '3';
        p.quantity = 1;

        Test.startTest();
        Id createdId = callCreate(p);
        Test.stopTest();

        Inventory__c rec = [SELECT Name FROM Inventory__c WHERE Id = :createdId];
        Assert.areEqual('FLX2-01-COLP07-FS03', rec.Name,
            'A hall Name with no hyphen should be used whole as the last segment');
    }

    @IsTest
    static void createInventoryRecords_flexOfficeRoomPartRegexNoMatch() {
        Site__c site = mkSite('FLX3', 'SG');
        Floor__c floor = mkFloor(site.Id, 'FLX3-01');
        DataHall__c hall = mkHall(floor.Id, 'FLX3-01-05', null); // last segment "05" has no alpha prefix

        CreateParams p = new CreateParams();
        p.siteId = site.Id; p.floorId = floor.Id; p.dataHallId = hall.Id;
        p.spaceType = 'Flex Office';
        p.unitNumber = '9';
        p.quantity = 1;

        Test.startTest();
        Id createdId = callCreate(p);
        Test.stopTest();

        Inventory__c rec = [SELECT Name FROM Inventory__c WHERE Id = :createdId];
        Assert.areEqual('FLX3-01-05-FS09', rec.Name,
            'A last segment that does not match the alpha+digits pattern should be used verbatim');
    }

    @IsTest
    static void createInventoryRecords_sequenceSkipsHyphenatedExisting() {
        Site__c site = mkSite('SQH1', 'SG');
        Floor__c floor = mkFloor(site.Id, 'SQH1-01');
        DataHall__c hall = mkHall(floor.Id, 'SQH1-01-H1', '01');

        // First: a Row/Col-named record sharing the same prefix (no unit number)
        CreateParams rc = new CreateParams();
        rc.siteId = site.Id; rc.floorId = floor.Id; rc.dataHallId = hall.Id;
        rc.spaceType = 'Cabinet';
        rc.inventoryRow = '01';
        rc.inventoryCol = '02';
        rc.quantity = 5; // forced down to 1 by row/col
        callCreate(rc);

        // Second: a plain sequential create with the SAME prefix (no row/col)
        CreateParams p = new CreateParams();
        p.siteId = site.Id; p.floorId = floor.Id; p.dataHallId = hall.Id;
        p.spaceType = 'Cabinet';
        p.quantity = 1;

        Test.startTest();
        Id createdId = callCreate(p);
        Test.stopTest();

        Inventory__c rec = [SELECT Name FROM Inventory__c WHERE Id = :createdId];
        Assert.areEqual('SQH1-01-DH01-S01', rec.Name,
            'A hyphenated existing name sharing the prefix should not corrupt sequence parsing; falls back to seq 1');
    }

    @IsTest
    static void createInventoryRecords_customNameSingleQuantity() {
        Site__c site = mkSite('CNS1', 'SG');
        Floor__c floor = mkFloor(site.Id, 'CNS1-01');
        DataHall__c hall = mkHall(floor.Id, 'CNS1-01-H1', '01');

        CreateParams p = new CreateParams();
        p.siteId = site.Id; p.floorId = floor.Id; p.dataHallId = hall.Id;
        p.spaceType = 'Cabinet';
        p.customName = 'SOLONAME';
        p.quantity = 1;

        Test.startTest();
        Id createdId = callCreate(p);
        Test.stopTest();

        Inventory__c rec = [SELECT Name FROM Inventory__c WHERE Id = :createdId];
        Assert.areEqual('SOLONAME', rec.Name,
            'Single-quantity custom name should be used exactly, with no -NN suffix');
    }

    @IsTest
    static void createInventoryRecords_unitNumberSingleQuantity() {
        Site__c site = mkSite('UNQ1', 'SG');
        Floor__c floor = mkFloor(site.Id, 'UNQ1-01');
        DataHall__c hall = mkHall(floor.Id, 'UNQ1-01-H1', '01');

        CreateParams p = new CreateParams();
        p.siteId = site.Id; p.floorId = floor.Id; p.dataHallId = hall.Id;
        p.spaceType = 'Cabinet';
        p.unitNumber = '9';
        p.quantity = 1;

        Test.startTest();
        Id createdId = callCreate(p);
        Test.stopTest();

        Inventory__c rec = [SELECT Name FROM Inventory__c WHERE Id = :createdId];
        Assert.areEqual('UNQ1-01-DH01-S09', rec.Name,
            'Single-quantity unit-number record should use the prefix verbatim with no -NN suffix');
    }

    // ═══════════════════════════════════════════════════════════════════
    // Coverage top-up: importInventoryBulk edge branches
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void importInventoryBulk_hallNumberFallsBackToHallName() {
        Site__c site = mkSite('IMPHN', 'SG');
        Floor__c floor = mkFloor(site.Id, 'IMPHN-01');
        DataHall__c hall = mkHall(floor.Id, 'H5', null); // no Hall_Number__c set

        List<Map<String, Object>> rows = new List<Map<String, Object>>{
            new Map<String, Object>{
                'Inventory Status' => 'Available', 'Space Type' => 'Cabinet',
                'Average Power per Cab (kVA)' => '10', 'Contracted Power (kVA)' => '8'
            }
        };

        Test.startTest();
        Map<String, Object> result = DeInventoryManagerController.importInventoryBulk(
            'Inventory_Space', site.Id, floor.Id, hall.Id, JSON.serialize(rows));
        Test.stopTest();

        Assert.areEqual(1, (Integer) result.get('inserted'), 'Row should insert successfully');
        Inventory__c created = [SELECT Name FROM Inventory__c WHERE Site_Id__c = :site.Id LIMIT 1];
        Assert.areEqual('IMPHN-01-DH05-S01', created.Name,
            'Hall part should fall back to digits parsed from the hall Name when Hall_Number__c is blank');
    }

    @IsTest
    static void importInventoryBulk_hallReferenceResolution() {
        Site__c site = mkSite('IMPHR', 'SG');
        Floor__c floor = mkFloor(site.Id, 'IMPHR-01');
        DataHall__c hall = mkHall(floor.Id, 'IMPHR-01-H1', '01');

        Inventory__c hallRef = new Inventory__c(
            RecordTypeId = spaceRt(), Site_Id__c = site.Id, Floor__c = floor.Id, Data_Hall__c = hall.Id,
            Status__c = 'Available', Space_Type__c = 'Hall', Name = 'IMPHR-REFHALL'
        );
        insert hallRef;

        List<Map<String, Object>> rows = new List<Map<String, Object>>{
            new Map<String, Object>{
                'Inventory Status' => 'Available', 'Space Type' => 'Cabinet',
                'Average Power per Cab (kVA)' => '10', 'Contracted Power (kVA)' => '8',
                'Hall Reference' => 'IMPHR-REFHALL'
            },
            new Map<String, Object>{
                'Inventory Status' => 'Available', 'Space Type' => 'Cabinet',
                'Average Power per Cab (kVA)' => '10', 'Contracted Power (kVA)' => '8',
                'Hall Reference' => 'DOES-NOT-EXIST-HALL'
            }
        };

        Test.startTest();
        Map<String, Object> result = DeInventoryManagerController.importInventoryBulk(
            'Inventory_Space', site.Id, floor.Id, hall.Id, JSON.serialize(rows));
        Test.stopTest();

        Assert.areEqual(1, (Integer) result.get('inserted'), 'Only the row with a valid Hall Reference should insert');
        List<String> errors = (List<String>) result.get('errors');
        Assert.isTrue(errors.size() >= 1, 'Unresolvable Hall Reference should produce an error');

        Inventory__c created = [SELECT Hall_Reference__c FROM Inventory__c
            WHERE Space_Type__c = 'Cabinet' AND Site_Id__c = :site.Id LIMIT 1];
        Assert.areEqual(hallRef.Id, created.Hall_Reference__c,
            'Hall Reference should resolve to the matching Inventory record');
    }

    @IsTest
    static void importInventoryBulk_sequenceContinuesAcrossCalls() {
        Site__c site = mkSite('IMPSEQ', 'SG');
        Floor__c floor = mkFloor(site.Id, 'IMPSEQ-01');
        DataHall__c hall = mkHall(floor.Id, 'IMPSEQ-01-H1', '01');

        List<Map<String, Object>> rows1 = new List<Map<String, Object>>{
            new Map<String, Object>{
                'Inventory Status' => 'Available', 'Space Type' => 'Cabinet',
                'Average Power per Cab (kVA)' => '10', 'Contracted Power (kVA)' => '8'
            }
        };
        List<Map<String, Object>> rows2 = new List<Map<String, Object>>{
            new Map<String, Object>{
                'Inventory Status' => 'Available', 'Space Type' => 'Cabinet',
                'Average Power per Cab (kVA)' => '10', 'Contracted Power (kVA)' => '8'
            }
        };

        Test.startTest();
        DeInventoryManagerController.importInventoryBulk(
            'Inventory_Space', site.Id, floor.Id, hall.Id, JSON.serialize(rows1));
        DeInventoryManagerController.importInventoryBulk(
            'Inventory_Space', site.Id, floor.Id, hall.Id, JSON.serialize(rows2));
        Test.stopTest();

        List<Inventory__c> created = [SELECT Name FROM Inventory__c WHERE Site_Id__c = :site.Id ORDER BY Name];
        Assert.areEqual(2, created.size(), 'Two import calls should produce 2 records');
        Assert.areEqual('IMPSEQ-01-DH01-S01', created[0].Name, 'First call starts the sequence at 01');
        Assert.areEqual('IMPSEQ-01-DH01-S02', created[1].Name, 'Second call should continue the sequence at 02');
    }

    @IsTest
    static void importInventoryBulk_insertDmlErrorCaught() {
        Site__c site = mkSite('IMPDE', 'SG');
        Floor__c floor = mkFloor(site.Id, 'IMPDE-01');
        DataHall__c hall = mkHall(floor.Id, 'IMPDE-01-H1', '01');

        // Status = Sold with no linked Order Item trips VR_INV_03_SoldNeedsOrderItem
        // at DML time — a valid, active picklist value our own manual checks don't
        // (and shouldn't) reject, and this rule has no $Permission bypass (unlike
        // VR_INV_02), so it fails regardless of which user runs the test.
        List<Map<String, Object>> rows = new List<Map<String, Object>>{
            new Map<String, Object>{
                'Inventory Status' => 'Sold', 'Space Type' => 'Cabinet',
                'Average Power per Cab (kVA)' => '10', 'Contracted Power (kVA)' => '8'
            }
        };

        Test.startTest();
        Map<String, Object> result = DeInventoryManagerController.importInventoryBulk(
            'Inventory_Space', site.Id, floor.Id, hall.Id, JSON.serialize(rows));
        Test.stopTest();

        Assert.areEqual(0, (Integer) result.get('inserted'),
            'Sold without a linked Order Item should fail VR-INV-03 at insert');
        List<String> errors = (List<String>) result.get('errors');
        Assert.isTrue(errors.size() >= 1, 'DML validation failure should surface as a friendly error message');
        List<Map<String, Object>> rowResults = (List<Map<String, Object>>) result.get('rowResults');
        Assert.areEqual('error', (String) rowResults[0].get('status'),
            'Row should be flagged as error after the failed insert');
    }

    @IsTest
    static void importInventoryBulk_updateDmlErrorCaught() {
        Site__c site = mkSite('IMPDU', 'SG');
        Floor__c floor = mkFloor(site.Id, 'IMPDU-01');
        DataHall__c hall = mkHall(floor.Id, 'IMPDU-01-H1', '01');
        Inventory__c existing = new Inventory__c(
            RecordTypeId = spaceRt(), Site_Id__c = site.Id, Floor__c = floor.Id, Data_Hall__c = hall.Id,
            Status__c = 'Available', Space_Type__c = 'Cabinet', Name = 'IMPDU-EXISTING',
            Total_Capacity_kVA__c = 10, Total_IT_Power_kVA__c = 8
        );
        insert existing;

        List<Map<String, Object>> rows = new List<Map<String, Object>>{
            new Map<String, Object>{ 'Id' => existing.Id, 'Inventory Status' => 'Sold' }
        };

        Test.startTest();
        Map<String, Object> result = DeInventoryManagerController.importInventoryBulk(
            'Inventory_Space', site.Id, floor.Id, hall.Id, JSON.serialize(rows));
        Test.stopTest();

        Assert.areEqual(0, (Integer) result.get('updated'),
            'Sold without a linked Order Item should fail VR-INV-03 at update');
        List<String> errors = (List<String>) result.get('errors');
        Assert.isTrue(errors.size() >= 1, 'DML validation failure should surface as a friendly error message on update');
    }

    // ═══════════════════════════════════════════════════════════════════
    // Coverage top-up: legacy importInventory edge branches
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void importInventory_numericFieldsCabeCountPowerCircuitTotalKw() {
        Site__c site = [SELECT Id FROM Site__c WHERE Site_Code__c = 'TEST-SG01' LIMIT 1];

        List<Map<String, String>> rows = new List<Map<String, String>>{
            new Map<String, String>{
                'RecordType' => 'Inventory_Breaker', 'Name' => 'LEGACY-NUM',
                'Status' => 'Available', 'Capacity_Type' => 'Power Circuit',
                'CabE_Count' => '4', 'Power_Circuit_kVA' => '30', 'Total_kW' => '25'
            }
        };

        Test.startTest();
        Map<String, Object> result = DeInventoryManagerController.importInventory(rows, site.Id);
        Test.stopTest();

        Assert.areEqual(1, (Integer) result.get('inserted'), 'Row should insert successfully');
        Inventory__c created = [
            SELECT CabE_Count__c, Power_Circuit_kVA__c, Total_kW__c
            FROM Inventory__c WHERE Name = 'LEGACY-NUM'
        ];
        Assert.areEqual(4, created.CabE_Count__c, 'CabE_Count should be parsed to Decimal');
        Assert.areEqual(30, created.Power_Circuit_kVA__c, 'Power_Circuit_kVA should be parsed to Decimal');
        Assert.areEqual(25, created.Total_kW__c, 'Total_kW should be parsed to Decimal');
    }

    @IsTest
    static void importInventory_capturesUpdateDmlErrors() {
        Site__c site = [SELECT Id FROM Site__c WHERE Site_Code__c = 'TEST-SG01' LIMIT 1];
        Inventory__c existing = [SELECT Id FROM Inventory__c WHERE Unit_Reference__c = 'SG01-DH01-A001' LIMIT 1];

        List<Map<String, String>> rows = new List<Map<String, String>>{
            new Map<String, String>{ 'Id' => existing.Id, 'Status' => 'NotARealStatusValue' }
        };

        Test.startTest();
        Map<String, Object> result = DeInventoryManagerController.importInventory(rows, site.Id);
        Test.stopTest();

        Assert.areEqual(0, (Integer) result.get('updated'),
            'Invalid picklist value should prevent the update from succeeding');
        List<String> errors = (List<String>) result.get('errors');
        Assert.isTrue(errors.size() >= 1, 'Update DML failure should surface as an error message');
        Assert.isTrue(errors[0].startsWith('Update row'), 'Error message should be prefixed for the update path');
    }
}