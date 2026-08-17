@IsTest
private class InventoryControllerTest {

    @TestSetup
    static void setup() {
        // ── Site ──────────────────────────────────────────────────────────
        Site__c site = new Site__c(
            Name            = 'KR-INVTEST-01',
            Country__c      = 'KR',
            Site_Code__c    = 'KR-INVTEST-01',
            Pricebook2__c   = Test.getStandardPricebookId()
        );
        insert site;

        // ── Account + Opportunity ─────────────────────────────────────────
        Account acc = new Account(Name = 'Test Account', Operation_Country__c = 'Korea');
        insert acc;
        Opportunity opp = new Opportunity(
            Name           = 'Test Opp',
            AccountId      = acc.Id,
            StageName      = '1-Suspect',
            CloseDate      = Date.today().addDays(30),
            CurrencyIsoCode = 'KRW',
            Operation_Country__c = 'Korea',
            Target_Site__c = site.Id,
            Pricebook2Id   = Test.getStandardPricebookId()
        );
        insert opp;

        // ── Quotes ────────────────────────────────────────────────────────
        Quote q = new Quote(
            Name          = 'Test Quote',
            OpportunityId = opp.Id,
            CurrencyIsoCode = 'KRW',
            Pricebook2Id  = Test.getStandardPricebookId()
        );
        Quote q2 = new Quote(
            Name          = 'Other Quote',
            OpportunityId = opp.Id,
            CurrencyIsoCode = 'KRW',
            Pricebook2Id  = Test.getStandardPricebookId()
        );
        insert new List<Quote>{ q, q2 };

        // ── Product + PricebookEntry + QuoteLineItem ──────────────────────
        // Site.Pricebook2__c points to the standard pricebook.
        // Quote_BeforeSave_AutoSetup flow copies it to Quote.Pricebook2Id.
        Product2 prod = new Product2(Name = 'CAB001.RC', IsActive = true);
        insert prod;
        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(),
            Product2Id   = prod.Id,
            UnitPrice    = 100,
            CurrencyIsoCode = 'KRW',
            IsActive     = true
        );
        insert pbe;
        QuoteLineItem qli = new QuoteLineItem(
            QuoteId          = q.Id,
            PricebookEntryId = pbe.Id,
            Quantity         = 3,
            UnitPrice        = 100
        );
        insert qli;

        // ── Inventory ─────────────────────────────────────────────────────
        // NOTE (de-partial schema check): Space_Type__c is a RESTRICTED
        // picklist with values Cabinet/Cage/Hall/Flex Office. 'Data Hall'
        // is NOT a valid value and throws INVALID_OR_NULL_FOR_RESTRICTED_
        // PICKLIST on insert, which failed this @TestSetup and caused every
        // test method in this class to error before running (0% coverage).
        // Fixed to 'Hall'.
        Id spaceRtId = Schema.SObjectType.Inventory__c
            .getRecordTypeInfosByDeveloperName().get('Inventory_Space').getRecordTypeId();
        Id breakerRtId = Schema.SObjectType.Inventory__c
            .getRecordTypeInfosByDeveloperName().get('Inventory_Breaker').getRecordTypeId();

        List<Inventory__c> inv = new List<Inventory__c>{
            new Inventory__c(RecordTypeId = spaceRtId, Site_Id__c = site.Id,
                Status__c = 'Available', Space_Type__c = 'Cabinet',
                Total_Capacity_kVA__c = 10, CabE_Count__c = 1,
                Total_IT_Power_kVA__c = 8,
                Unit_Reference__c = 'SG-01-DH01-S-001',
                Account__c = acc.Id),
            new Inventory__c(RecordTypeId = spaceRtId, Site_Id__c = site.Id,
                Status__c = 'Available', Space_Type__c = 'Hall',
                Total_Capacity_kVA__c = 50, CabE_Count__c = 20,
                Total_IT_Power_kVA__c = 40,
                Unit_Reference__c = 'SG-01-DH02-H-001'),
            new Inventory__c(RecordTypeId = breakerRtId, Site_Id__c = site.Id,
                Status__c = 'Available', Capacity_Type__c = 'Power Circuit',
                Total_kW__c = 20)
        };
        insert inv;
    }

    // ═══════════════════════════════════════════════════════════════════
    // Shared private helpers (self-contained to THIS class only)
    // ═══════════════════════════════════════════════════════════════════

    private static Quote firstQuote() {
        return [SELECT Id, OpportunityId FROM Quote ORDER BY CreatedDate ASC LIMIT 1];
    }

    private static Quote secondQuote() {
        List<Quote> qs = [SELECT Id, OpportunityId FROM Quote ORDER BY CreatedDate ASC];
        return qs[1];
    }

    private static Id standardPbeId() {
        return [SELECT Id FROM PricebookEntry LIMIT 1].Id;
    }

    /** Creates and immediately deletes a Quote to obtain a valid-format, non-existent Id. */
    private static Id nonExistentQuoteId() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        Quote temp = new Quote(Name = 'Temp', OpportunityId = opp.Id, Pricebook2Id = Test.getStandardPricebookId());
        insert temp;
        Id fakeId = temp.Id;
        delete temp;
        return fakeId;
    }

    private static Id minimumAccessProfileId() {
        return [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1].Id;
    }

    private static User createRestrictedUser() {
        String suffix = String.valueOf(Datetime.now().getTime());
        User u = new User(
            LastName         = 'InvFlsTest',
            FirstName        = 'Restricted',
            Email            = 'invflstest' + suffix + '@example.com',
            Username         = 'invflstest' + suffix + '@example.com.invtest',
            Alias            = 'ifls' + suffix.right(4),
            TimeZoneSidKey   = 'America/Los_Angeles',
            LocaleSidKey     = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            ProfileId        = minimumAccessProfileId()
        );
        insert u;
        return u;
    }

    // ═══════════════════════════════════════════════════════════════════
    // getQuoteSiteInfo
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void getQuoteSiteInfo_returnsSiteFromQuote() {
        Quote q = firstQuote();

        Test.startTest();
        Map<String, String> info = InventoryController.getQuoteSiteInfo(q.Id);
        Test.stopTest();

        Assert.isNotNull(info, 'Should return site info');
        Assert.isNotNull(info.get('id'), 'Site ID should be present');
        Assert.areEqual('KR-INVTEST-01', info.get('siteCode'), 'Site code should match');
        Assert.areEqual(q.OpportunityId, info.get('oppId'), 'Opportunity ID should match');
    }

    @IsTest
    static void getQuoteSiteInfo_noSiteReturnsNull() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        opp.Target_Site__c = null;
        update opp;

        Quote q = firstQuote();

        Test.startTest();
        Map<String, String> info = InventoryController.getQuoteSiteInfo(q.Id);
        Test.stopTest();

        Assert.isNull(info, 'Should return null when no target site');
    }

    // ═══════════════════════════════════════════════════════════════════
    // getSiteInventoryForQuote
    // ═══════════════════════════════════════════════════════════════════

    // NOTE: These 4 tests originally asserted that InventoryController.getSiteInventoryForQuote
    // threw a QueryException referencing a missing Cage_ID__c field (a known gap being guarded
    // against). Cage_ID__c exists on Inventory__c (see
    // force-app/main/default/objects/Inventory__c/fields/Cage_ID__c.field-meta.xml) and is
    // already selected in the controller's dynamic SOQL, so the query no longer throws — the
    // gap these tests were checking for has since been closed. Updated to assert the correct
    // current (working) behavior instead of a stale expectation of failure.

    @IsTest
    static void getSiteInventoryForQuote_returnsAllAtSite() {
        Quote q = firstQuote();

        Test.startTest();
        List<Inventory__c> results = InventoryController.getSiteInventoryForQuote(q.Id, 'All');
        Test.stopTest();

        Assert.areEqual(3, results.size(),
            'Cage_ID__c is now exposed in the query; All filter should return all 3 Space/Breaker records at site');
    }

    @IsTest
    static void getSiteInventoryForQuote_statusFilterWorks() {
        Quote q = firstQuote();

        List<Inventory__c> cabs = [SELECT Id FROM Inventory__c
            WHERE Space_Type__c = 'Cabinet' AND RecordType.DeveloperName = 'Inventory_Space'];
        InventoryController.bulkAssignToQuote(new List<Id>{ cabs[0].Id }, q.Id);

        Test.startTest();
        List<Inventory__c> results = InventoryController.getSiteInventoryForQuote(q.Id, 'Available');
        Test.stopTest();

        // bulkAssignToQuote sets Assigned_To_Quote__c without touching Status__c, so the
        // assigned cabinet remains 'Available' and should still surface under this filter.
        Assert.areEqual(3, results.size(),
            'Assigning inventory to a quote does not change Status__c, so all 3 records remain Available');
        Boolean foundAssignedCab = false;
        for (Inventory__c inv : results) {
            if (inv.Id == cabs[0].Id) {
                foundAssignedCab = true;
                Assert.areEqual(q.Id, inv.Assigned_To_Quote__c, 'Assigned cabinet should show its quote assignment');
            }
        }
        Assert.isTrue(foundAssignedCab, 'Assigned cabinet should still appear under the Available status filter');
    }

    @IsTest
    static void getSiteInventoryForQuote_blankFilterReturnsAll() {
        Quote q = firstQuote();

        Test.startTest();
        List<Inventory__c> results = InventoryController.getSiteInventoryForQuote(q.Id, '');
        Test.stopTest();

        Assert.areEqual(3, results.size(), 'Blank filter should behave like All and return all records at site');
    }

    @IsTest
    static void getSiteInventoryForQuote_statusFilterNoMatchesReturnsEmpty() {
        Quote q = firstQuote();

        Test.startTest();
        List<Inventory__c> results = InventoryController.getSiteInventoryForQuote(q.Id, 'Sold');
        Test.stopTest();

        Assert.areEqual(0, results.size(), 'No inventory at site has Status Sold, so filter should return empty list');
    }

    @IsTest
    static void getSiteInventoryForQuote_noSiteReturnsEmpty() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        opp.Target_Site__c = null;
        update opp;

        Quote q = firstQuote();

        Test.startTest();
        List<Inventory__c> results = InventoryController.getSiteInventoryForQuote(q.Id, 'All');
        Test.stopTest();

        Assert.areEqual(0, results.size(), 'Should return empty when no site');
    }

    // ═══════════════════════════════════════════════════════════════════
    // getQuoteInventorySummary
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void getQuoteInventorySummary_returnsCounts() {
        Quote q  = firstQuote();
        Quote q2 = secondQuote();

        List<Inventory__c> spaces = [SELECT Id FROM Inventory__c
            WHERE RecordType.DeveloperName = 'Inventory_Space'
            ORDER BY Space_Type__c ASC]; // Cabinet first, then Hall
        InventoryController.bulkAssignToQuote(new List<Id>{ spaces[0].Id }, q.Id);
        InventoryController.bulkAssignToQuote(new List<Id>{ spaces[1].Id }, q2.Id);

        Test.startTest();
        Map<String, Integer> summary = InventoryController.getQuoteInventorySummary(q.Id);
        Test.stopTest();

        Assert.areEqual(3, summary.get('total'), 'Total Space + Breaker records at site');
        Assert.areEqual(1, summary.get('thisQuote'), 'One assigned to this quote');
        Assert.areEqual(1, summary.get('otherHeld'), 'One assigned to other quote');
        Assert.areEqual(3, summary.get('Available'), 'Status breakdown should include Available bucket');
    }

    @IsTest
    static void getQuoteInventorySummary_noSiteReturnsEmptyMap() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        opp.Target_Site__c = null;
        update opp;

        Quote q = firstQuote();

        Test.startTest();
        Map<String, Integer> summary = InventoryController.getQuoteInventorySummary(q.Id);
        Test.stopTest();

        Assert.isTrue(summary.isEmpty(), 'Should return empty map when no site');
    }

    // ═══════════════════════════════════════════════════════════════════
    // bulkAssignToQuote + bulkReleaseFromQuote
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void bulkAssign_linksBothSpacesToQuote() {
        Quote q = firstQuote();
        List<Inventory__c> spaces = [SELECT Id FROM Inventory__c
            WHERE Status__c = 'Available' AND RecordType.DeveloperName = 'Inventory_Space'];
        List<Id> ids = new List<Id>();
        for (Inventory__c s : spaces) ids.add(s.Id);

        Test.startTest();
        Integer count = InventoryController.bulkAssignToQuote(ids, q.Id);
        Test.stopTest();

        Assert.areEqual(2, count, 'Should assign both Space records');
        for (Inventory__c inv : [SELECT Assigned_To_Quote__c, Opportunity__c, Status__c
                FROM Inventory__c WHERE Id IN :ids]) {
            Assert.areEqual(q.Id, inv.Assigned_To_Quote__c, 'Assigned_To_Quote__c should be set');
            Assert.areEqual(q.OpportunityId, inv.Opportunity__c, 'Opportunity__c should be set from quote');
            Assert.areEqual('Available', inv.Status__c, 'Status should remain Available');
        }
    }

    @IsTest
    static void bulkAssignToQuote_invalidQuoteThrows() {
        Id fakeQuoteId = nonExistentQuoteId();
        Inventory__c cab = [SELECT Id FROM Inventory__c
            WHERE Space_Type__c = 'Cabinet' LIMIT 1];

        Test.startTest();
        Boolean threw = false;
        try {
            InventoryController.bulkAssignToQuote(new List<Id>{ cab.Id }, fakeQuoteId);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Should throw AuraHandledException for missing quote');
    }

    @IsTest
    static void bulkAssignToQuote_bulk200Records() {
        Quote q = firstQuote();
        Site__c site = [SELECT Id FROM Site__c LIMIT 1];
        Id spaceRtId = Schema.SObjectType.Inventory__c
            .getRecordTypeInfosByDeveloperName().get('Inventory_Space').getRecordTypeId();

        List<Inventory__c> bulkInv = new List<Inventory__c>();
        for (Integer i = 0; i < 200; i++) {
            bulkInv.add(new Inventory__c(
                RecordTypeId = spaceRtId,
                Site_Id__c   = site.Id,
                Status__c    = 'Available',
                Space_Type__c = 'Cabinet',
                Unit_Reference__c = 'BULK-' + i
            ));
        }
        insert bulkInv;

        List<Id> ids = new List<Id>();
        for (Inventory__c inv : bulkInv) ids.add(inv.Id);

        Test.startTest();
        Integer count = InventoryController.bulkAssignToQuote(ids, q.Id);
        Test.stopTest();

        Assert.areEqual(200, count, 'Should assign all 200 records');
        Integer assignedCount = [SELECT COUNT() FROM Inventory__c
            WHERE Id IN :ids AND Assigned_To_Quote__c = :q.Id];
        Assert.areEqual(200, assignedCount, 'All 200 records should be assigned in the DB');
    }

    @IsTest
    static void bulkAssignToQuote_flsDeniedThrows() {
        User restricted = createRestrictedUser();
        Quote q = firstQuote();
        Inventory__c cab = [SELECT Id FROM Inventory__c
            WHERE Space_Type__c = 'Cabinet' LIMIT 1];

        Boolean threw = false;
        String msg = '';
        Test.startTest();
        System.runAs(restricted) {
            try {
                InventoryController.bulkAssignToQuote(new List<Id>{ cab.Id }, q.Id);
            } catch (AuraHandledException e) {
                threw = true;
                msg = e.getMessage();
            }
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Minimum Access user should be denied edit on Inventory__c');
        Assert.isTrue(String.isNotBlank(msg), 'Exception message should be populated');
    }

    @IsTest
    static void bulkRelease_clearsAssignment() {
        Quote q = firstQuote();
        List<Inventory__c> spaces = [SELECT Id FROM Inventory__c
            WHERE Status__c = 'Available' AND RecordType.DeveloperName = 'Inventory_Space'];
        List<Id> ids = new List<Id>();
        for (Inventory__c s : spaces) ids.add(s.Id);

        InventoryController.bulkAssignToQuote(ids, q.Id);

        Test.startTest();
        Integer count = InventoryController.bulkReleaseFromQuote(ids);
        Test.stopTest();

        Assert.areEqual(2, count, 'Should release both records');
        for (Inventory__c inv : [SELECT Assigned_To_Quote__c, Opportunity__c
                FROM Inventory__c WHERE Id IN :ids]) {
            Assert.isNull(inv.Assigned_To_Quote__c, 'Quote assignment should be cleared');
            Assert.isNull(inv.Opportunity__c, 'Opportunity link should be cleared');
        }
    }

    @IsTest
    static void bulkReleaseFromQuote_bulk200Records() {
        Quote q = firstQuote();
        Site__c site = [SELECT Id FROM Site__c LIMIT 1];
        Id spaceRtId = Schema.SObjectType.Inventory__c
            .getRecordTypeInfosByDeveloperName().get('Inventory_Space').getRecordTypeId();

        List<Inventory__c> bulkInv = new List<Inventory__c>();
        for (Integer i = 0; i < 200; i++) {
            bulkInv.add(new Inventory__c(
                RecordTypeId = spaceRtId,
                Site_Id__c   = site.Id,
                Status__c    = 'Available',
                Space_Type__c = 'Cabinet',
                Unit_Reference__c = 'BULKREL-' + i
            ));
        }
        insert bulkInv;
        List<Id> ids = new List<Id>();
        for (Inventory__c inv : bulkInv) ids.add(inv.Id);
        InventoryController.bulkAssignToQuote(ids, q.Id);

        Test.startTest();
        Integer count = InventoryController.bulkReleaseFromQuote(ids);
        Test.stopTest();

        Assert.areEqual(200, count, 'Should release all 200 records');
        Integer stillAssigned = [SELECT COUNT() FROM Inventory__c
            WHERE Id IN :ids AND Assigned_To_Quote__c != null];
        Assert.areEqual(0, stillAssigned, 'None should remain assigned');
    }

    // ═══════════════════════════════════════════════════════════════════
    // getLineInventory
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void getLineInventory_returnsAssignedAndAvailable() {
        Quote q = firstQuote();
        QuoteLineItem qli = [SELECT Id FROM QuoteLineItem WHERE QuoteId = :q.Id LIMIT 1];

        Inventory__c cab = [SELECT Id FROM Inventory__c
            WHERE Space_Type__c = 'Cabinet' AND RecordType.DeveloperName = 'Inventory_Space' LIMIT 1];
        InventoryController.assignInventoryToLine(new List<Id>{ cab.Id }, qli.Id, q.Id);

        Test.startTest();
        Map<String, Object> result = InventoryController.getLineInventory(qli.Id, q.Id, null);
        Test.stopTest();

        List<Inventory__c> assigned = (List<Inventory__c>) result.get('assigned');
        List<Inventory__c> available = (List<Inventory__c>) result.get('available');

        Assert.areEqual(1, assigned.size(), 'Should have 1 assigned to this QLI');
        Assert.isTrue(available.size() >= 1, 'Should have available inventory at site');
    }

    @IsTest
    static void getLineInventory_spaceTypeFilter() {
        Quote q = firstQuote();
        QuoteLineItem qli = [SELECT Id FROM QuoteLineItem WHERE QuoteId = :q.Id LIMIT 1];

        Test.startTest();
        Map<String, Object> result = InventoryController.getLineInventory(qli.Id, q.Id, 'Space');
        Test.stopTest();

        List<Inventory__c> available = (List<Inventory__c>) result.get('available');
        Assert.areEqual(2, available.size(), 'Should only return Space records');
        for (Inventory__c inv : available) {
            Assert.areEqual('Inventory_Space', inv.RecordType.DeveloperName, 'Only Space records expected');
        }
    }

    @IsTest
    static void getLineInventory_breakerTypeFilter() {
        Quote q = firstQuote();
        QuoteLineItem qli = [SELECT Id FROM QuoteLineItem WHERE QuoteId = :q.Id LIMIT 1];

        Test.startTest();
        Map<String, Object> result = InventoryController.getLineInventory(qli.Id, q.Id, 'Breaker');
        Test.stopTest();

        List<Inventory__c> available = (List<Inventory__c>) result.get('available');
        Assert.areEqual(1, available.size(), 'Should only return Breaker records');
        Assert.areEqual('Inventory_Breaker', available[0].RecordType.DeveloperName, 'Only Breaker record expected');
    }

    @IsTest
    static void getLineInventory_noSiteReturnsEmptyMaps() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        opp.Target_Site__c = null;
        update opp;

        Quote q = firstQuote();
        QuoteLineItem qli = [SELECT Id FROM QuoteLineItem WHERE QuoteId = :q.Id LIMIT 1];

        Test.startTest();
        Map<String, Object> result = InventoryController.getLineInventory(qli.Id, q.Id, null);
        Test.stopTest();

        List<Inventory__c> assigned = (List<Inventory__c>) result.get('assigned');
        List<Inventory__c> available = (List<Inventory__c>) result.get('available');
        Assert.areEqual(0, assigned.size(), 'No site means no assigned records');
        Assert.areEqual(0, available.size(), 'No site means no available records');
    }

    // ═══════════════════════════════════════════════════════════════════
    // assignInventoryToLine
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void assignInventoryToLine_setsAllFields() {
        // Setup's QLI needs Quantity=3; assigning only 1 record here is a
        // PARTIAL assignment, so Reserved__c should stay 'Not Reserved'.
        // (The full-assignment -> Reserved transition is covered separately
        // by assignInventoryToLine_fullyAssignedSetsReserved.)
        Quote q = firstQuote();
        QuoteLineItem qli = [SELECT Id FROM QuoteLineItem WHERE QuoteId = :q.Id LIMIT 1];
        Inventory__c cab = [SELECT Id FROM Inventory__c
            WHERE Space_Type__c = 'Cabinet' AND RecordType.DeveloperName = 'Inventory_Space' LIMIT 1];

        Test.startTest();
        Integer count = InventoryController.assignInventoryToLine(
            new List<Id>{ cab.Id }, qli.Id, q.Id);
        Test.stopTest();

        Assert.areEqual(1, count, 'Should assign 1 record');
        Inventory__c inv = [SELECT Assigned_To_Quote__c, Quote_Line__c,
            Opportunity__c, Account__c, Status__c FROM Inventory__c WHERE Id = :cab.Id];
        Assert.areEqual(q.Id, inv.Assigned_To_Quote__c, 'Quote should be set');
        Assert.areEqual(qli.Id, inv.Quote_Line__c, 'Quote Line should be set');
        Assert.areEqual(q.OpportunityId, inv.Opportunity__c, 'Opportunity should be set');
        Assert.isNotNull(inv.Account__c, 'Account should be set');
        Assert.areEqual('Assigned', inv.Status__c, 'Status should be Assigned');

        QuoteLineItem updatedQli = [SELECT Reserved__c FROM QuoteLineItem WHERE Id = :qli.Id];
        Assert.areEqual('Not Reserved', updatedQli.Reserved__c,
            'QuoteLineItem.Reserved__c should stay Not Reserved when assigned count (1) is below needed qty (3)');
    }

    @IsTest
    static void assignInventoryToLine_fullyAssignedSetsReserved() {
        // Assign ALL 3 site inventory records (Cabinet + Hall + Breaker) to
        // the Quantity=3 QLI so assignedCount >= neededQty and Reserved__c flips.
        Quote q = firstQuote();
        QuoteLineItem qli = [SELECT Id FROM QuoteLineItem WHERE QuoteId = :q.Id LIMIT 1];
        List<Inventory__c> allInv = [SELECT Id FROM Inventory__c];
        List<Id> ids = new List<Id>();
        for (Inventory__c i : allInv) ids.add(i.Id);

        Test.startTest();
        Integer count = InventoryController.assignInventoryToLine(ids, qli.Id, q.Id);
        Test.stopTest();

        Assert.areEqual(3, count, 'Should assign all 3 records');
        QuoteLineItem updatedQli = [SELECT Reserved__c FROM QuoteLineItem WHERE Id = :qli.Id];
        Assert.areEqual('Reserved', updatedQli.Reserved__c,
            'QuoteLineItem.Reserved__c should be Reserved once assigned count meets needed qty');
    }

    @IsTest
    static void assignInventoryToLine_invalidQuoteThrows() {
        QuoteLineItem qli = [SELECT Id FROM QuoteLineItem LIMIT 1];
        Inventory__c cab = [SELECT Id FROM Inventory__c
            WHERE Space_Type__c = 'Cabinet' LIMIT 1];
        Id fakeQuoteId = nonExistentQuoteId();

        Test.startTest();
        Boolean threw = false;
        try {
            InventoryController.assignInventoryToLine(new List<Id>{ cab.Id }, qli.Id, fakeQuoteId);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Should throw AuraHandledException for missing quote');
    }

    @IsTest
    static void assignInventoryToLine_exceedsNeededQtyThrows() {
        Quote q = firstQuote();
        Id pbeId = standardPbeId();
        QuoteLineItem smallQli = new QuoteLineItem(
            QuoteId = q.Id, PricebookEntryId = pbeId, Quantity = 1, UnitPrice = 100);
        insert smallQli;

        List<Inventory__c> spaces = [SELECT Id FROM Inventory__c
            WHERE RecordType.DeveloperName = 'Inventory_Space'];
        List<Id> ids = new List<Id>();
        for (Inventory__c s : spaces) ids.add(s.Id); // 2 records against a needed qty of 1

        Test.startTest();
        Boolean threw = false;
        String message = '';
        try {
            InventoryController.assignInventoryToLine(ids, smallQli.Id, q.Id);
        } catch (AuraHandledException e) {
            threw = true;
            message = e.getMessage();
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Should throw when assignment exceeds needed quantity');
        Assert.isTrue(String.isNotBlank(message), 'Exception message should be populated');
    }

    // ═══════════════════════════════════════════════════════════════════
    // releaseInventoryFromLine
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void releaseInventoryFromLine_clearsAllFields() {
        // Fully assign all 3 site records first (Reserved__c -> 'Reserved'),
        // then release just the cabinet to verify both field-clearing AND
        // the Reserved -> Not Reserved reversion (2 remaining < needed 3).
        Quote q = firstQuote();
        QuoteLineItem qli = [SELECT Id FROM QuoteLineItem WHERE QuoteId = :q.Id LIMIT 1];
        List<Inventory__c> allInv = [SELECT Id, Space_Type__c FROM Inventory__c];
        List<Id> allIds = new List<Id>();
        Id cabId;
        for (Inventory__c i : allInv) {
            allIds.add(i.Id);
            if (i.Space_Type__c == 'Cabinet') cabId = i.Id;
        }
        InventoryController.assignInventoryToLine(allIds, qli.Id, q.Id);

        QuoteLineItem beforeRelease = [SELECT Reserved__c FROM QuoteLineItem WHERE Id = :qli.Id];
        Assert.areEqual('Reserved', beforeRelease.Reserved__c, 'Fully assigned line should start Reserved');

        Test.startTest();
        Integer count = InventoryController.releaseInventoryFromLine(new List<Id>{ cabId });
        Test.stopTest();

        Assert.areEqual(1, count, 'Should release 1 record');
        Inventory__c inv = [SELECT Assigned_To_Quote__c, Quote_Line__c,
            Opportunity__c, Account__c, Status__c FROM Inventory__c WHERE Id = :cabId];
        Assert.isNull(inv.Assigned_To_Quote__c, 'Quote should be cleared');
        Assert.isNull(inv.Quote_Line__c, 'Quote Line should be cleared');
        Assert.isNull(inv.Opportunity__c, 'Opportunity should be cleared');
        Assert.isNull(inv.Account__c, 'Account should be cleared');
        Assert.areEqual('Available', inv.Status__c, 'Status should revert to Available');

        QuoteLineItem updatedQli = [SELECT Reserved__c FROM QuoteLineItem WHERE Id = :qli.Id];
        Assert.areEqual('Not Reserved', updatedQli.Reserved__c,
            'QuoteLineItem.Reserved__c should revert to Not Reserved once remaining count (2) drops below needed qty (3)');
    }

    @IsTest
    static void releaseInventoryFromLine_partialReleaseStaysNotReserved() {
        Quote q = firstQuote();
        Id pbeId = standardPbeId();
        QuoteLineItem twoQli = new QuoteLineItem(
            QuoteId = q.Id, PricebookEntryId = pbeId, Quantity = 2, UnitPrice = 100);
        insert twoQli;

        List<Inventory__c> spaces = [SELECT Id FROM Inventory__c
            WHERE RecordType.DeveloperName = 'Inventory_Space'];
        List<Id> ids = new List<Id>();
        for (Inventory__c s : spaces) ids.add(s.Id);
        InventoryController.assignInventoryToLine(ids, twoQli.Id, q.Id);

        QuoteLineItem afterFullAssign = [SELECT Reserved__c FROM QuoteLineItem WHERE Id = :twoQli.Id];
        Assert.areEqual('Reserved', afterFullAssign.Reserved__c, 'Fully assigned line should be Reserved');

        Test.startTest();
        Integer count = InventoryController.releaseInventoryFromLine(new List<Id>{ ids[0] });
        Test.stopTest();

        Assert.areEqual(1, count, 'Should release exactly 1 record');
        QuoteLineItem afterPartialRelease = [SELECT Reserved__c FROM QuoteLineItem WHERE Id = :twoQli.Id];
        Assert.areEqual('Not Reserved', afterPartialRelease.Reserved__c,
            'Partial release leaves remaining count below needed qty -> Not Reserved');
    }

    // ═══════════════════════════════════════════════════════════════════
    // effectiveNeededQty (TestVisible)
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void effectiveNeededQty_nonExistentLineReturnsNull() {
        Test.startTest();
        Decimal result = InventoryController.effectiveNeededQty(nonExistentQuoteId());
        Test.stopTest();

        Assert.isNull(result, 'Non-existent QuoteLineItem should return null');
    }

    @IsTest
    static void effectiveNeededQty_nonRampLineReturnsOwnQuantity() {
        QuoteLineItem qli = [SELECT Id FROM QuoteLineItem LIMIT 1];

        Test.startTest();
        Decimal result = InventoryController.effectiveNeededQty(qli.Id);
        Test.stopTest();

        Assert.areEqual(3, result, 'Non-ramp line should return its own Quantity');
    }

    @IsTest
    static void effectiveNeededQty_rampAggregateReturnsPeakPhase() {
        Quote q = firstQuote();
        Id pbeId = standardPbeId();

        QuoteLineItem parent = new QuoteLineItem(
            QuoteId = q.Id, PricebookEntryId = pbeId, Quantity = 5, UnitPrice = 100,
            Line_Origin__c = 'Ramp', Ramp_Phase__c = 1, Charge_Type__c = 'MRC',
            Merge_IB_Task__c = true);
        insert parent;

        QuoteLineItem phase2 = new QuoteLineItem(
            QuoteId = q.Id, PricebookEntryId = pbeId, Quantity = 9, UnitPrice = 100,
            Line_Origin__c = 'Ramp', Ramp_Phase__c = 2, Charge_Type__c = 'MRC',
            Merge_IB_Task__c = true, Ramp_Parent_Line__c = parent.Id);
        insert phase2;

        Test.startTest();
        Decimal result = InventoryController.effectiveNeededQty(parent.Id);
        Test.stopTest();

        Assert.areEqual(9, result, 'Aggregate ramp product should return the peak (last phase) quantity');
    }

    @IsTest
    static void effectiveNeededQty_rampSumReturnsNetAdditions() {
        Quote q = firstQuote();
        Id pbeId = standardPbeId();

        QuoteLineItem parent = new QuoteLineItem(
            QuoteId = q.Id, PricebookEntryId = pbeId, Quantity = 5, UnitPrice = 100,
            Line_Origin__c = 'Ramp', Ramp_Phase__c = 1, Charge_Type__c = 'MRC',
            Merge_IB_Task__c = false);
        insert parent;

        QuoteLineItem phase2 = new QuoteLineItem(
            QuoteId = q.Id, PricebookEntryId = pbeId, Quantity = 3, UnitPrice = 100,
            Line_Origin__c = 'Ramp', Ramp_Phase__c = 2, Charge_Type__c = 'MRC',
            Merge_IB_Task__c = false, Ramp_Parent_Line__c = parent.Id);

        QuoteLineItem linkedPhase3 = new QuoteLineItem(
            QuoteId = q.Id, PricebookEntryId = pbeId, Quantity = 100, UnitPrice = 100,
            Line_Origin__c = 'Ramp', Ramp_Phase__c = 3, Charge_Type__c = 'MRC',
            Merge_IB_Task__c = false, Ramp_Parent_Line__c = parent.Id, Ramp_Linked_Phase__c = 2);
        // Bulk-inserted together (rather than as 2 separate single-row inserts) so this
        // test's arrange phase stays at 2 QuoteLineItem DML statements total, matching
        // effectiveNeededQty_rampAggregateReturnsPeakPhase. Each single-row QLI insert
        // cascades through several other before/after-save flows (Account Legal Entity
        // Default, Opportunity DefaultSplits, Quote SOFHandler, QuoteLineItem Reserved
        // Default, Termination Qty, etc.); Flow's automatic bulkification only collapses
        // those flows' queries across records inserted in the SAME DML call. With 3
        // separate single-row inserts the cumulative SOQL count crossed the 100-query
        // synchronous governor limit on the 3rd insert (observed via debug log:
        // "System.LimitException: Too many SOQL queries: 101"), which Salesforce then
        // surfaced as an unhandled-fault CANNOT_EXECUTE_FLOW_TRIGGER against whichever
        // flow was mid-query at that moment (Termination Qty) — a red herring, not an
        // actual business-rule rejection from that flow.
        insert new List<QuoteLineItem>{ phase2, linkedPhase3 };

        Test.startTest();
        Decimal result = InventoryController.effectiveNeededQty(parent.Id);
        Test.stopTest();

        Assert.areEqual(8, result,
            'Non-aggregate ramp product should sum net additions only (linked phase excluded)');
    }

    // ═══════════════════════════════════════════════════════════════════
    // markInventorySoldForOrder (InvocableMethod)
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void markInventorySoldForOrder_happyPathStampsOrderAndSpace() {
        Quote q = firstQuote();
        Account acc = [SELECT Id FROM Account LIMIT 1];
        QuoteLineItem qli = [SELECT Id FROM QuoteLineItem WHERE QuoteId = :q.Id LIMIT 1];
        Id pbeId = standardPbeId();

        Inventory__c cab = [SELECT Id FROM Inventory__c
            WHERE Space_Type__c = 'Cabinet' AND RecordType.DeveloperName = 'Inventory_Space' LIMIT 1];
        Inventory__c breaker = [SELECT Id FROM Inventory__c
            WHERE RecordType.DeveloperName = 'Inventory_Breaker' LIMIT 1];
        InventoryController.assignInventoryToLine(new List<Id>{ cab.Id, breaker.Id }, qli.Id, q.Id);

        Order ord = new Order(
            AccountId    = acc.Id,
            EffectiveDate = Date.today(),
            Status       = 'Draft',
            QuoteId      = q.Id,
            Pricebook2Id = Test.getStandardPricebookId(),
            CurrencyIsoCode = 'KRW'
        );
        insert ord;
        OrderItem oi = new OrderItem(
            OrderId          = ord.Id,
            PricebookEntryId = pbeId,
            Quantity         = 1,
            UnitPrice        = 100,
            QuoteLineItemId  = qli.Id
        );
        insert oi;

        Test.startTest();
        InventoryController.markInventorySoldForOrder(new List<Id>{ ord.Id });
        Test.stopTest();

        Inventory__c updatedCab = [SELECT Status__c, Order__c, Order_Item__c FROM Inventory__c WHERE Id = :cab.Id];
        Inventory__c updatedBreaker = [SELECT Status__c, Order__c, Order_Item__c FROM Inventory__c WHERE Id = :breaker.Id];
        Assert.areEqual('Sold', updatedCab.Status__c, 'Space should be marked Sold');
        Assert.areEqual(ord.Id, updatedCab.Order__c, 'Space should be stamped with the Order');
        Assert.areEqual(oi.Id, updatedCab.Order_Item__c, 'Space should be stamped with the OrderItem');
        Assert.areEqual('Sold', updatedBreaker.Status__c, 'Breaker should be marked Sold');

        OrderItem updatedOi = [SELECT Space__c, Inventory__c FROM OrderItem WHERE Id = :oi.Id];
        Assert.areEqual(cab.Id, updatedOi.Space__c, 'OrderItem.Space__c should point to the first Space');
        Assert.areEqual(breaker.Id, updatedOi.Inventory__c, 'OrderItem.Inventory__c should point to the first Breaker');
    }

    @IsTest
    static void markInventorySoldForOrder_nullOrEmptyListIsNoOp() {
        Test.startTest();
        InventoryController.markInventorySoldForOrder(null);
        InventoryController.markInventorySoldForOrder(new List<Id>());
        Test.stopTest();
        // No exception thrown is the pass condition for these guard clauses.
        Assert.isTrue(true, 'Null/empty orderIds should be a safe no-op');
    }

    @IsTest
    static void markInventorySoldForOrder_noMatchingOrderItemsIsNoOp() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Order ord = new Order(
            AccountId     = acc.Id,
            EffectiveDate = Date.today(),
            Status        = 'Draft',
            Pricebook2Id  = Test.getStandardPricebookId()
        );
        insert ord;

        Test.startTest();
        InventoryController.markInventorySoldForOrder(new List<Id>{ ord.Id });
        Test.stopTest();

        Integer soldCount = [SELECT COUNT() FROM Inventory__c WHERE Status__c = 'Sold'];
        Assert.areEqual(0, soldCount, 'No OrderItems on the order means no Inventory should change');
    }
}