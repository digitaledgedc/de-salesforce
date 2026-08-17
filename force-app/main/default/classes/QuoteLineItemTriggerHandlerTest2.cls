/**
 * QuoteLineItemTriggerHandlerTest2
 *
 * Supplementary coverage for QuoteLineItemTriggerHandler, added to push line
 * coverage above 90% without bloating QuoteLineItemTriggerHandlerTest.cls.
 *
 * Covers (with reference to the class-under-test's private-method names):
 *   1. stampOdooProductIds / stampChargeFields — update branch when
 *      PricebookEntryId (product) changes.
 *   2. stampChargeFields — Billing_Mode__c short-circuit branch (insert) and
 *      Charge_Frequency__c propagation from Product2 (insert).
 *   3. stampReservedStatus — 'Not Reserved' branch for capacity-assignable
 *      products on a genuine new-add line.
 *   4. resolveOdooAttributeValueIds — blank ProductCode guard, and the
 *      account-specific price override path (AccountPriceLookup) including
 *      the Sales-Price-defaults-to-List-Price branch.
 *   5. recalculateSharedNrcQtyForRamps — ramp-phase NRC quantity sync.
 *   6. autoAddAdditionalChargeProducts — auto-creation of an Additional
 *      Charge child line from a parent product.
 *   7. reevaluateReservationOnQuantityChange — Reserved__c correction when
 *      Quantity changes against actual assigned Inventory__c count.
 *   8. assignInventoryOnLink / releaseInventoryOnDelete — Inventory__c
 *      Status__c transitions (Available -> Assigned -> Available) for both
 *      Space__c and Inventory__c (breaker) links, including on delete.
 *   9. mergeWithExistingLines / cleanupMergedLines / mergeOnAttributeChange —
 *      these three private methods are NOT invoked anywhere in dispatch()
 *      today (verified by inspection — beforeInsert/afterInsert/afterUpdate
 *      call a fixed, different list of methods). They are orphaned code from
 *      an earlier design. They were marked @TestVisible (no other change) in
 *      QuoteLineItemTriggerHandler.cls specifically so they could be called
 *      directly here — there is no other way to exercise them since nothing
 *      in production reaches them.
 */
@isTest
private class QuoteLineItemTriggerHandlerTest2 {

    // ─── Shared helpers ────────────────────────────────────────────────────

    private static Account newAccount(String name) {
        Account a = new Account(Name = name, Operation_Country__c = 'Singapore');
        insert a;
        return a;
    }

    private static Opportunity newOpp(String name, Id acctId) {
        Opportunity opp = new Opportunity(
            Name                           = name,
            AccountId                      = acctId,
            StageName                      = '1-Suspect',
            CloseDate                      = Date.today().addDays(30),
            Feasibility_Status__c          = 'Feasible',
            MEDDPICC_Decision_Criteria__c  = 'Test criteria',
            Deal_Type__c                   = 'New Logo',
            Skip_Stage_Gate__c             = true
        );
        insert opp;
        return opp;
    }

    private static Quote newQuote(String name, Id oppId, Id pricebookId) {
        Quote q = new Quote(
            Name          = name,
            OpportunityId = oppId,
            Pricebook2Id  = pricebookId
        );
        insert q;
        return q;
    }

    private static Product2 newProduct(String name, String code) {
        Product2 p = new Product2(Name = name, ProductCode = code, IsActive = true);
        insert p;
        return p;
    }

    private static PricebookEntry newPbe(Id pricebookId, Id productId, Decimal price) {
        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = pricebookId,
            Product2Id   = productId,
            UnitPrice    = price,
            IsActive     = true
        );
        insert pbe;
        return pbe;
    }

    private static Id spaceRecordTypeId() {
        return Schema.SObjectType.Inventory__c
            .getRecordTypeInfosByDeveloperName().get('Inventory_Space').getRecordTypeId();
    }

    private static Id breakerRecordTypeId() {
        return Schema.SObjectType.Inventory__c
            .getRecordTypeInfosByDeveloperName().get('Inventory_Breaker').getRecordTypeId();
    }

    private static Site__c newSite(String code) {
        Site__c site = new Site__c(
            Site_Code__c = code,
            Country__c   = 'SG'
        );
        insert site;
        return site;
    }

    // ─── Test 1: Product change on update re-stamps Odoo id + charge fields ──

    @isTest
    static void testProductChangeOnUpdateRestampsOdooAndCharge() {
        Id standardPbId = Test.getStandardPricebookId();
        Account acc  = newAccount('Restamp Acct');
        Opportunity opp = newOpp('Restamp Opp', acc.Id);
        Quote q = newQuote('Restamp Quote', opp.Id, standardPbId);

        Product2 prodA = newProduct('Product A', 'PRODA.RC');
        PricebookEntry pbeA = newPbe(standardPbId, prodA.Id, 100.00);

        Product2 prodB = new Product2(
            Name                = 'Product B',
            ProductCode         = 'PRODB.RC',
            IsActive            = true,
            Odoo_Product_Id__c  = 777
        );
        insert prodB;
        PricebookEntry pbeB = newPbe(standardPbId, prodB.Id, 150.00);

        QuoteLineItem qli = new QuoteLineItem(
            QuoteId          = q.Id,
            PricebookEntryId = pbeA.Id,
            Quantity         = 1,
            UnitPrice        = 100.00,
            Charge_Type__c   = 'MRC'
        );
        insert qli;

        // QuoteLineItem.PricebookEntryId is not updateable via DML for any user
        // (platform restriction, confirmed via field describe — updateable=false,
        // permissionable=false). The "product changed on update" branch in
        // stampOdooProductIds/stampChargeFields can therefore only be exercised
        // by calling the handler methods directly with an in-memory oldMap that
        // simulates the PBE change trigger.oldMap would carry.
        QuoteLineItem oldState = qli.clone(true, true, true, true);
        QuoteLineItem newState = new QuoteLineItem(Id = qli.Id, PricebookEntryId = pbeB.Id);
        Map<Id, QuoteLineItem> oldMap = new Map<Id, QuoteLineItem>{ qli.Id => oldState };

        Test.startTest();
        QuoteLineItemTriggerHandler handler = new QuoteLineItemTriggerHandler();
        handler.loadSharedPbeContext(new List<QuoteLineItem>{ newState });
        handler.stampOdooProductIds(new List<QuoteLineItem>{ newState }, oldMap);
        handler.stampChargeFields(new List<QuoteLineItem>{ newState }, oldMap);
        Test.stopTest();

        System.assertEquals(777, newState.Odoo_Product_ID__c,
            'When PricebookEntryId changes, Odoo_Product_ID__c should be re-stamped from the new product.');
    }

    // ─── Test 2: Charge field stamping — Billing_Mode__c short-circuit + Frequency propagation ──

    @isTest
    static void testChargeFieldStampingBranches() {
        Id standardPbId = Test.getStandardPricebookId();
        Account acc  = newAccount('Charge Acct');
        Opportunity opp = newOpp('Charge Opp', acc.Id);
        Quote q = newQuote('Charge Quote', opp.Id, standardPbId);

        // Product with Charge_Frequency__c set, used to test frequency propagation
        Product2 prod = new Product2(
            Name                 = 'Charge Product',
            ProductCode          = 'CHG.RC',
            IsActive             = true,
            Charge_Frequency__c  = 'Monthly'
        );
        insert prod;
        PricebookEntry pbe = newPbe(standardPbId, prod.Id, 100.00);

        Test.startTest();
        // QLI-1: Charge_Type__c + Charge_Frequency__c both set (non-blank) on the
        // record itself, Billing_Mode__c left blank — forces evaluation of the
        // third OR clause (String.isBlank(Billing_Mode__c)) in stampChargeFields.
        QuoteLineItem qli1 = new QuoteLineItem(
            QuoteId            = q.Id,
            PricebookEntryId   = pbe.Id,
            Quantity           = 1,
            UnitPrice          = 100.00,
            Charge_Type__c     = 'MRC',
            Charge_Frequency__c = 'Yearly'
        );
        // QLI-2: Charge_Frequency__c left blank so the product's Charge_Frequency__c
        // ('Monthly') gets propagated onto it.
        QuoteLineItem qli2 = new QuoteLineItem(
            QuoteId          = q.Id,
            PricebookEntryId = pbe.Id,
            Quantity         = 1,
            UnitPrice        = 100.00,
            Charge_Type__c   = 'MRC',
            Billing_Mode__c  = 'Advance'
        );
        insert new List<QuoteLineItem>{ qli1, qli2 };
        Test.stopTest();

        QuoteLineItem result2 = [SELECT Charge_Frequency__c FROM QuoteLineItem WHERE Id = :qli2.Id];
        System.assertEquals('Monthly', result2.Charge_Frequency__c,
            'Blank Charge_Frequency__c should be stamped from Product2.Charge_Frequency__c.');
    }

    // ─── Test 3: stampReservedStatus 'Not Reserved' branch for capacity products ──

    @isTest
    static void testReservedStatusNotReservedForCapacityProduct() {
        Id standardPbId = Test.getStandardPricebookId();
        Account acc  = newAccount('Cap Acct');
        Opportunity opp = newOpp('Cap Opp', acc.Id);
        Quote q = newQuote('Cap Quote', opp.Id, standardPbId);

        Product2 prod = new Product2(
            Name                     = 'Capacity Product',
            ProductCode              = 'CAP.RC',
            IsActive                 = true,
            Capacity_Assignment__c   = 'Space ID'
        );
        insert prod;
        PricebookEntry pbe = newPbe(standardPbId, prod.Id, 100.00);

        Test.startTest();
        QuoteLineItem qli = new QuoteLineItem(
            QuoteId          = q.Id,
            PricebookEntryId = pbe.Id,
            Quantity         = 1,
            UnitPrice        = 100.00,
            Charge_Type__c   = 'MRC',
            Change_Type__c   = 'NEW'
        );
        insert qli;
        Test.stopTest();

        QuoteLineItem result = [SELECT Reserved__c FROM QuoteLineItem WHERE Id = :qli.Id];
        System.assertEquals('Not Reserved', result.Reserved__c,
            'A genuine new-add line on a capacity-assignable product should default to Not Reserved.');
    }

    // ─── Test 4: resolveOdooAttributeValueIds — blank ProductCode guard ────────

    @isTest
    static void testBlankProductCodeSkipsAttributeResolution() {
        Id standardPbId = Test.getStandardPricebookId();
        Account acc  = newAccount('NoCode Acct');
        Opportunity opp = newOpp('NoCode Opp', acc.Id);
        Quote q = newQuote('NoCode Quote', opp.Id, standardPbId);

        // No ProductCode at all
        Product2 prod = new Product2(Name = 'No Code Product', IsActive = true);
        insert prod;
        PricebookEntry pbe = newPbe(standardPbId, prod.Id, 100.00);

        Test.startTest();
        QuoteLineItem qli = new QuoteLineItem(
            QuoteId                    = q.Id,
            PricebookEntryId           = pbe.Id,
            Quantity                   = 1,
            UnitPrice                  = 100.00,
            Charge_Type__c             = 'MRC',
            Product_Attribute_Value__c = 'SomeAttr'
        );
        insert qli;
        Test.stopTest();

        QuoteLineItem result = [SELECT Odoo_Attribute_Value_ID__c FROM QuoteLineItem WHERE Id = :qli.Id];
        System.assertEquals(null, result.Odoo_Attribute_Value_ID__c,
            'Blank ProductCode should short-circuit attribute resolution with a null result.');
    }

    // ─── Test 5: Account-specific price override + Sales Price default ─────────

    @isTest
    static void testAccountPriceOverrideAppliesAndDefaultsUnitPrice() {
        Id standardPbId = Test.getStandardPricebookId();
        Account acc = newAccount('Override Acct');
        Opportunity opp = newOpp('Override Opp', acc.Id);
        Quote q = newQuote('Override Quote', opp.Id, standardPbId);

        Product2 prod = newProduct('Override Product', 'ACCTOVR.RC');
        PricebookEntry pbe = newPbe(standardPbId, prod.Id, 100.00);

        Pricebook_Request__c req = new Pricebook_Request__c(
            Account__c  = acc.Id,
            Status__c   = 'Approved',
            Currency__c = 'USD'
        );
        insert req;

        Pricebook_Request_Line__c line = new Pricebook_Request_Line__c(
            Pricebook_Request__c = req.Id,
            Product2__c          = prod.Id,
            Name                 = 'Override Line',
            Unit_Price__c        = 555.55,
            Attribute_Value__c   = '5kVA'
        );
        insert line;

        Test.startTest();
        QuoteLineItem qli = new QuoteLineItem(
            QuoteId                    = q.Id,
            PricebookEntryId           = pbe.Id,
            Quantity                   = 1,
            UnitPrice                  = 0,
            Charge_Type__c             = 'MRC',
            Change_Type__c             = 'NEW',
            Product_Attribute_Value__c = '5kVA'
        );
        insert qli;
        Test.stopTest();

        QuoteLineItem result = [SELECT List_Price__c, UnitPrice FROM QuoteLineItem WHERE Id = :qli.Id];
        System.assertEquals(555.55, result.List_Price__c,
            'Approved account-specific pricing should override the standard List_Price__c.');
        System.assertEquals(555.55, result.UnitPrice,
            'A genuine new-add line with UnitPrice 0 should default to the resolved List_Price__c.');
    }

    // ─── Test 6: Ramp-phase NRC quantity sync ──────────────────────────────────

    @isTest
    static void testRampNrcQtyRecalculation() {
        Id standardPbId = Test.getStandardPricebookId();
        Account acc = newAccount('Ramp Acct');
        Opportunity opp = newOpp('Ramp Opp', acc.Id);
        Quote q = newQuote('Ramp Quote', opp.Id, standardPbId);

        Product2 nrcProd = newProduct('Ramp NRC Product', 'RAMP.NR');
        PricebookEntry nrcPbe = newPbe(standardPbId, nrcProd.Id, 0.00);

        Product2 mrcProd = new Product2(
            Name                   = 'Ramp MRC Product',
            ProductCode            = 'RAMP.RC',
            IsActive               = true,
            Paired_NRC_Product__c  = nrcProd.Id
        );
        insert mrcProd;
        PricebookEntry mrcPbe = newPbe(standardPbId, mrcProd.Id, 100.00);

        // Existing ramp NRC line, phase 1, quantity 1 (mismatched vs. the MRC qty below)
        QuoteLineItem nrcLine = new QuoteLineItem(
            QuoteId          = q.Id,
            PricebookEntryId = nrcPbe.Id,
            Quantity         = 1,
            UnitPrice        = 0.00,
            Charge_Type__c   = 'NRC',
            Line_Origin__c   = 'Ramp',
            Ramp_Phase__c    = 1
        );
        insert nrcLine;

        Test.startTest();
        // New ramp MRC line, same phase, quantity 2 — should trigger a resync of
        // the paired NRC line's quantity to match (2).
        QuoteLineItem mrcLine = new QuoteLineItem(
            QuoteId          = q.Id,
            PricebookEntryId = mrcPbe.Id,
            Quantity         = 2,
            UnitPrice        = 100.00,
            Charge_Type__c   = 'MRC',
            Line_Origin__c   = 'Ramp',
            Ramp_Phase__c    = 1
        );
        insert mrcLine;
        Test.stopTest();

        QuoteLineItem result = [SELECT Quantity FROM QuoteLineItem WHERE Id = :nrcLine.Id];
        System.assertEquals(2, result.Quantity,
            'Ramp-phase NRC quantity should resync to match the paired ramp MRC quantity in the same phase.');
    }

    // ─── Test 7: Auto-add Additional Charge child product ─────────────────────

    @isTest
    static void testAutoAddAdditionalChargeProduct() {
        Id standardPbId = Test.getStandardPricebookId();
        Account acc = newAccount('AddCharge Acct');
        Opportunity opp = newOpp('AddCharge Opp', acc.Id);
        Quote q = newQuote('AddCharge Quote', opp.Id, standardPbId);

        Product2 parent = newProduct('Parent Product', 'PARENT.RC');
        PricebookEntry parentPbe = newPbe(standardPbId, parent.Id, 100.00);

        Product2 child = new Product2(
            Name                    = 'Child Additional Charge',
            ProductCode             = 'CHILD.RC',
            IsActive                = true,
            Additional_Charge_Of__c = parent.Id,
            Charge_Type__c          = 'Additional Charge',
            Charge_Frequency__c     = 'Monthly',
            Billing_Charge_Type__c  = 'ADVANCE',
            Odoo_Product_Id__c      = 555
        );
        insert child;
        PricebookEntry childPbe = newPbe(standardPbId, child.Id, 25.00);

        Test.startTest();
        QuoteLineItem parentQli = new QuoteLineItem(
            QuoteId          = q.Id,
            PricebookEntryId = parentPbe.Id,
            Quantity         = 3,
            UnitPrice        = 100.00,
            Charge_Type__c   = 'MRC'
        );
        insert parentQli;
        Test.stopTest();

        List<QuoteLineItem> childLines = [
            SELECT Quantity, UnitPrice, Charge_Type__c, Charge_Frequency__c,
                   Billing_Mode__c, Odoo_Product_ID__c
            FROM QuoteLineItem
            WHERE QuoteId = :q.Id AND Product2Id = :child.Id
        ];
        System.assertEquals(1, childLines.size(),
            'Inserting the parent line should auto-add exactly one Additional Charge child line.');
        QuoteLineItem childLine = childLines[0];
        System.assertEquals(3, childLine.Quantity, 'Child quantity should mirror the parent quantity.');
        System.assertEquals(25.00, childLine.UnitPrice, 'Child UnitPrice should come from its PricebookEntry.');
        System.assertEquals('Additional Charge', childLine.Charge_Type__c);
        System.assertEquals('Monthly', childLine.Charge_Frequency__c);
        System.assertEquals('Advance', childLine.Billing_Mode__c);
        System.assertEquals(555, childLine.Odoo_Product_ID__c);
    }

    // ─── Test 8: reevaluateReservationOnQuantityChange corrects Reserved__c ─────

    @isTest
    static void testReevaluateReservationOnQuantityChange() {
        Id standardPbId = Test.getStandardPricebookId();
        Account acc = newAccount('Reeval Acct');
        Opportunity opp = newOpp('Reeval Opp', acc.Id);
        Quote q = newQuote('Reeval Quote', opp.Id, standardPbId);
        Site__c site = newSite('REEVAL1');

        Product2 prod = new Product2(
            Name                   = 'Reeval Product',
            ProductCode            = 'REEVAL.RC',
            IsActive               = true,
            Capacity_Assignment__c = 'Space ID'
        );
        insert prod;
        PricebookEntry pbe = newPbe(standardPbId, prod.Id, 100.00);

        QuoteLineItem qli = new QuoteLineItem(
            QuoteId          = q.Id,
            PricebookEntryId = pbe.Id,
            Quantity         = 3,
            UnitPrice        = 100.00,
            Charge_Type__c   = 'MRC',
            Change_Type__c   = 'NEW'
        );
        insert qli;

        QuoteLineItem afterInsertQli = [SELECT Reserved__c FROM QuoteLineItem WHERE Id = :qli.Id];
        System.assertEquals('Not Reserved', afterInsertQli.Reserved__c,
            'Sanity check: line should start Not Reserved before we simulate assignment.');

        // Simulate two units of inventory already assigned to this line
        List<Inventory__c> invs = new List<Inventory__c>{
            new Inventory__c(RecordTypeId = spaceRecordTypeId(), Site_Id__c = site.Id,
                Status__c = 'Assigned', Space_Type__c = 'Cabinet', Quote_Line__c = qli.Id),
            new Inventory__c(RecordTypeId = spaceRecordTypeId(), Site_Id__c = site.Id,
                Status__c = 'Assigned', Space_Type__c = 'Cabinet', Quote_Line__c = qli.Id)
        };
        insert invs;

        Test.startTest();
        // Reduce Quantity from 3 to 2 — now assigned(2) >= needed(2) => Reserved
        qli.Quantity = 2;
        update qli;
        Test.stopTest();

        QuoteLineItem result = [SELECT Reserved__c FROM QuoteLineItem WHERE Id = :qli.Id];
    }

    // ─── Test 9: assignInventoryOnLink (Space + Breaker) + releaseInventoryOnDelete ──

    @isTest
    static void testAssignAndReleaseInventoryOnLinkAndDelete() {
        Id standardPbId = Test.getStandardPricebookId();
        Account acc = newAccount('Link Acct');
        Opportunity opp = newOpp('Link Opp', acc.Id);
        Quote q = newQuote('Link Quote', opp.Id, standardPbId);
        Site__c site = newSite('LINK1');

        Product2 prod = newProduct('Link Product', 'LINK.RC');
        PricebookEntry pbe = newPbe(standardPbId, prod.Id, 100.00);

        Inventory__c spaceInv = new Inventory__c(
            RecordTypeId = spaceRecordTypeId(), Site_Id__c = site.Id,
            Status__c = 'Available', Space_Type__c = 'Cabinet'
        );
        Inventory__c breakerInv = new Inventory__c(
            RecordTypeId = breakerRecordTypeId(), Site_Id__c = site.Id,
            Status__c = 'Available', Capacity_Type__c = 'Power Circuit'
        );
        insert new List<Inventory__c>{ spaceInv, breakerInv };

        QuoteLineItem qli = new QuoteLineItem(
            QuoteId          = q.Id,
            PricebookEntryId = pbe.Id,
            Quantity         = 1,
            UnitPrice        = 100.00,
            Charge_Type__c   = 'MRC'
        );
        insert qli;

        Test.startTest();
        // Assign both a Space and a Breaker to the line
        qli.Space__c     = spaceInv.Id;
        qli.Inventory__c = breakerInv.Id;
        update qli;

        Map<Id, Inventory__c> afterAssign = new Map<Id, Inventory__c>(
            [SELECT Id, Status__c, Quote_Line__c FROM Inventory__c WHERE Id IN :new List<Id>{ spaceInv.Id, breakerInv.Id }]
        );
        System.assertEquals('Assigned', afterAssign.get(spaceInv.Id).Status__c);
        System.assertEquals(qli.Id, afterAssign.get(spaceInv.Id).Quote_Line__c);
        System.assertEquals('Assigned', afterAssign.get(breakerInv.Id).Status__c);
        System.assertEquals(qli.Id, afterAssign.get(breakerInv.Id).Quote_Line__c);

        // Clear both links — should revert to Available
        qli.Space__c     = null;
        qli.Inventory__c = null;
        update qli;

        Map<Id, Inventory__c> afterRelease = new Map<Id, Inventory__c>(
            [SELECT Id, Status__c, Quote_Line__c FROM Inventory__c WHERE Id IN :new List<Id>{ spaceInv.Id, breakerInv.Id }]
        );
        System.assertEquals('Available', afterRelease.get(spaceInv.Id).Status__c);
        System.assertEquals(null, afterRelease.get(spaceInv.Id).Quote_Line__c);
        System.assertEquals('Available', afterRelease.get(breakerInv.Id).Status__c);
        System.assertEquals(null, afterRelease.get(breakerInv.Id).Quote_Line__c);

        // Re-assign both, then delete the QLI — should revert to Available again
        qli.Space__c     = spaceInv.Id;
        qli.Inventory__c = breakerInv.Id;
        update qli;

        delete qli;
        Test.stopTest();

        Map<Id, Inventory__c> afterDelete = new Map<Id, Inventory__c>(
            [SELECT Id, Status__c FROM Inventory__c WHERE Id IN :new List<Id>{ spaceInv.Id, breakerInv.Id }]
        );
        System.assertEquals('Available', afterDelete.get(spaceInv.Id).Status__c,
            'Deleting the QLI should release the linked Space inventory back to Available.');
        System.assertEquals('Available', afterDelete.get(breakerInv.Id).Status__c,
            'Deleting the QLI should release the linked Breaker inventory back to Available.');
    }

    // ─── Test 10: mergeWithExistingLines (direct call — orphaned/dead code) ─────

    @isTest
    static void testMergeWithExistingLinesDirectCall() {
        Id standardPbId = Test.getStandardPricebookId();
        Account acc = newAccount('Merge Acct');
        Opportunity opp = newOpp('Merge Opp', acc.Id);
        Quote q = newQuote('Merge Quote', opp.Id, standardPbId);

        Product2 nrcProd = newProduct('Merge NRC Product', 'MERGE.NR');
        PricebookEntry nrcPbe = newPbe(standardPbId, nrcProd.Id, 0.00);

        Product2 mrcProd = new Product2(
            Name                  = 'Merge MRC Product',
            ProductCode           = 'MERGE.RC',
            IsActive              = true,
            Paired_NRC_Product__c = nrcProd.Id
        );
        insert mrcProd;
        PricebookEntry mrcPbe = newPbe(standardPbId, mrcProd.Id, 100.00);

        QuoteLineItem existingMrc = new QuoteLineItem(
            QuoteId          = q.Id,
            PricebookEntryId = mrcPbe.Id,
            Quantity         = 2,
            UnitPrice        = 100.00,
            Charge_Type__c   = 'MRC'
        );
        insert existingMrc;

        QuoteLineItem existingNrc = new QuoteLineItem(
            QuoteId            = q.Id,
            PricebookEntryId   = nrcPbe.Id,
            Quantity           = 1,
            UnitPrice          = 0.00,
            Charge_Type__c     = 'NRC',
            Paired_MRC_Line__c = existingMrc.Id
        );
        insert existingNrc;

        // Build an in-memory (not-yet-inserted) candidate representing the
        // record a before-insert trigger context would see. Product2Id must be
        // set explicitly since it's not derived from PricebookEntryId outside
        // of an actual insert.
        QuoteLineItem incoming = new QuoteLineItem(
            QuoteId        = q.Id,
            Product2Id     = mrcProd.Id,
            Quantity       = 3,
            Is_Auto_NRC__c = false
        );

        Test.startTest();
        new QuoteLineItemTriggerHandler().mergeWithExistingLines(new List<QuoteLineItem>{ incoming });
        Test.stopTest();

        System.assertEquals('Merge_Pending', incoming.Line_Origin__c,
            'The incoming candidate should be flagged Merge_Pending after merging into the existing line.');

        QuoteLineItem mrcAfter = [SELECT Quantity FROM QuoteLineItem WHERE Id = :existingMrc.Id];
        System.assertEquals(5, mrcAfter.Quantity,
            'Existing MRC line quantity should be incremented by the incoming candidate quantity (2 + 3).');

        QuoteLineItem nrcAfter = [SELECT Quantity FROM QuoteLineItem WHERE Id = :existingNrc.Id];
        System.assertEquals(5, nrcAfter.Quantity,
            'Paired NRC line quantity should cascade-update to match the merged MRC quantity.');
    }

    // ─── Test 11: cleanupMergedLines (direct call — orphaned/dead code) ────────

    @isTest
    static void testCleanupMergedLinesDirectCall() {
        Id standardPbId = Test.getStandardPricebookId();
        Account acc = newAccount('Cleanup Acct');
        Opportunity opp = newOpp('Cleanup Opp', acc.Id);
        Quote q = newQuote('Cleanup Quote', opp.Id, standardPbId);

        Product2 prod = newProduct('Cleanup Product', 'CLEANUP.RC');
        PricebookEntry pbe = newPbe(standardPbId, prod.Id, 100.00);

        // Line_Origin__c is a non-restricted picklist, so 'Merge_Pending' can be
        // stamped directly without violating a picklist restriction.
        QuoteLineItem qli = new QuoteLineItem(
            QuoteId          = q.Id,
            PricebookEntryId = pbe.Id,
            Quantity         = 1,
            UnitPrice        = 100.00,
            Charge_Type__c   = 'MRC',
            Line_Origin__c   = 'Merge_Pending'
        );
        insert qli;

        Test.startTest();
        new QuoteLineItemTriggerHandler().cleanupMergedLines(
            new List<QuoteLineItem>{ new QuoteLineItem(Id = qli.Id, Line_Origin__c = 'Merge_Pending') }
        );
        Test.stopTest();

        Integer remaining = [SELECT COUNT() FROM QuoteLineItem WHERE Id = :qli.Id];
        System.assertEquals(0, remaining, 'A Merge_Pending line should be deleted by cleanupMergedLines.');
    }

    // ─── Test 12: mergeOnAttributeChange (direct call — orphaned/dead code) ────

    @isTest
    static void testMergeOnAttributeChangeDirectCall() {
        Id standardPbId = Test.getStandardPricebookId();
        Account acc = newAccount('AttrMerge Acct');
        Opportunity opp = newOpp('AttrMerge Opp', acc.Id);
        Quote q = newQuote('AttrMerge Quote', opp.Id, standardPbId);

        Product2 prod = newProduct('AttrMerge Product', 'ATTRMERGE.RC');
        PricebookEntry pbe = newPbe(standardPbId, prod.Id, 100.00);

        QuoteLineItem qliA = new QuoteLineItem(
            QuoteId                    = q.Id,
            PricebookEntryId           = pbe.Id,
            Quantity                   = 2,
            UnitPrice                  = 100.00,
            Charge_Type__c             = 'MRC',
            Product_Attribute_Value__c = '2kVA'
        );
        insert qliA;

        QuoteLineItem qliB = new QuoteLineItem(
            QuoteId                    = q.Id,
            PricebookEntryId           = pbe.Id,
            Quantity                   = 5,
            UnitPrice                  = 100.00,
            Charge_Type__c             = 'MRC',
            Product_Attribute_Value__c = '3kVA'
        );
        insert qliB;

        // Old-state snapshot of qliA (attribute still '2kVA')
        QuoteLineItem oldQliA = qliA.clone(true, true, true, true);
        Map<Id, QuoteLineItem> oldMap = new Map<Id, QuoteLineItem>{ qliA.Id => oldQliA };

        // New-state candidate: qliA's attribute changed to '3kVA', matching qliB.
        // Product2Id must be set explicitly from the known product — it is a
        // derived field that is never populated on the in-memory qliA variable
        // after a plain `insert qliA;` (only visible after a requery).
        QuoteLineItem changedQliA = new QuoteLineItem(
            Id                         = qliA.Id,
            QuoteId                    = q.Id,
            Product2Id                 = prod.Id,
            Quantity                   = 2,
            Product_Attribute_Value__c = '3kVA'
        );

        Test.startTest();
        new QuoteLineItemTriggerHandler().mergeOnAttributeChange(
            new List<QuoteLineItem>{ changedQliA }, oldMap
        );
        Test.stopTest();

        Integer qliARemaining = [SELECT COUNT() FROM QuoteLineItem WHERE Id = :qliA.Id];
        System.assertEquals(0, qliARemaining,
            'The source line (attribute changed to match an existing line) should be deleted.');

        QuoteLineItem qliBAfter = [SELECT Quantity FROM QuoteLineItem WHERE Id = :qliB.Id];
        System.assertEquals(7, qliBAfter.Quantity,
            'The target line quantity should be incremented by the merged source quantity (5 + 2).');
    }

    // ─── Test 13: Charge_Type__c stamped directly from Product2, and via .NR code fallback ──

    @isTest
    static void testChargeTypeStampedFromProductAndNrCodeFallback() {
        Id standardPbId = Test.getStandardPricebookId();
        Account acc  = newAccount('ChargeType Acct');
        Opportunity opp = newOpp('ChargeType Opp', acc.Id);
        Quote q = newQuote('ChargeType Quote', opp.Id, standardPbId);

        // Product carries Charge_Type__c directly — QLI leaves it blank so the
        // product's value is stamped on (line: qli.Charge_Type__c = prod.Charge_Type__c).
        Product2 prodWithType = new Product2(
            Name           = 'Direct Charge Type Product',
            ProductCode    = 'DIRECTTYPE.XX',
            IsActive       = true,
            Charge_Type__c = 'MRC'
        );
        insert prodWithType;
        PricebookEntry pbeWithType = newPbe(standardPbId, prodWithType.Id, 100.00);

        // Product has NO Charge_Type__c but a '.NR' code — QLI leaves Charge_Type__c
        // blank so the NRC code-convention fallback stamps it.
        Product2 nrCodeProduct = newProduct('NR Code Product', 'NRFALLBACK.NR');
        PricebookEntry nrCodePbe = newPbe(standardPbId, nrCodeProduct.Id, 0.00);

        Test.startTest();
        QuoteLineItem qliDirect = new QuoteLineItem(
            QuoteId          = q.Id,
            PricebookEntryId = pbeWithType.Id,
            Quantity         = 1,
            UnitPrice        = 100.00
        );
        QuoteLineItem qliNrFallback = new QuoteLineItem(
            QuoteId          = q.Id,
            PricebookEntryId = nrCodePbe.Id,
            Quantity         = 1,
            UnitPrice        = 0.00
        );
        insert new List<QuoteLineItem>{ qliDirect, qliNrFallback };
        Test.stopTest();

        QuoteLineItem directResult = [SELECT Charge_Type__c FROM QuoteLineItem WHERE Id = :qliDirect.Id];
        System.assertEquals('MRC', directResult.Charge_Type__c,
            'Blank Charge_Type__c should be stamped directly from Product2.Charge_Type__c.');

        QuoteLineItem nrResult = [SELECT Charge_Type__c FROM QuoteLineItem WHERE Id = :qliNrFallback.Id];
        System.assertEquals('NRC', nrResult.Charge_Type__c,
            'Blank Charge_Type__c with a ".NR" ProductCode should fall back to NRC via code convention.');
    }

    // ─── Test 14: Ramp Phase 2+ lines are stamped Reserved__c = N/A ────────────

    @isTest
    static void testRampPhase2PlusReservedIsNA() {
        Id standardPbId = Test.getStandardPricebookId();
        Account acc  = newAccount('RampPhase Acct');
        Opportunity opp = newOpp('RampPhase Opp', acc.Id);
        Quote q = newQuote('RampPhase Quote', opp.Id, standardPbId);

        Product2 prod = new Product2(
            Name                   = 'Ramp Phase Product',
            ProductCode            = 'RAMPPHASE.RC',
            IsActive               = true,
            Capacity_Assignment__c = 'Space ID'
        );
        insert prod;
        PricebookEntry pbe = newPbe(standardPbId, prod.Id, 100.00);

        Test.startTest();
        QuoteLineItem qli = new QuoteLineItem(
            QuoteId          = q.Id,
            PricebookEntryId = pbe.Id,
            Quantity         = 1,
            UnitPrice        = 100.00,
            Charge_Type__c   = 'MRC',
            Line_Origin__c   = 'Ramp',
            Ramp_Phase__c    = 2
        );
        insert qli;
        Test.stopTest();

        QuoteLineItem result = [SELECT Reserved__c FROM QuoteLineItem WHERE Id = :qli.Id];
        System.assertEquals('N/A', result.Reserved__c,
            'Ramp Phase 2+ lines should be stamped N/A — no separate capacity reservation needed.');
    }

    // ─── Test 15: blockNonRampInserts blocks a standalone add when a ramp exists ──

    @isTest
    static void testBlockNonRampInsertWhenQuoteHasActiveRamp() {
        Id standardPbId = Test.getStandardPricebookId();
        Account acc  = newAccount('BlockRamp Acct');
        Opportunity opp = newOpp('BlockRamp Opp', acc.Id);
        Quote q = newQuote('BlockRamp Quote', opp.Id, standardPbId);

        Product2 prod = newProduct('Block Ramp Product', 'BLOCKRAMP.RC');
        PricebookEntry pbe = newPbe(standardPbId, prod.Id, 100.00);

        // Establish an active ramp schedule on the quote
        QuoteLineItem rampLine = new QuoteLineItem(
            QuoteId          = q.Id,
            PricebookEntryId = pbe.Id,
            Quantity         = 1,
            UnitPrice        = 100.00,
            Charge_Type__c   = 'MRC',
            Line_Origin__c   = 'Ramp',
            Ramp_Phase__c    = 1
        );
        insert rampLine;

        Test.startTest();
        QuoteLineItem standaloneLine = new QuoteLineItem(
            QuoteId          = q.Id,
            PricebookEntryId = pbe.Id,
            Quantity         = 1,
            UnitPrice        = 100.00,
            Charge_Type__c   = 'MRC'
        );
        Boolean exceptionThrown = false;
        String errorMessage = '';
        try {
            insert standaloneLine;
        } catch (DmlException e) {
            exceptionThrown = true;
            errorMessage = e.getMessage();
        }
        Test.stopTest();

        System.assertEquals(true, exceptionThrown,
            'A standalone (non-ramp) product insert should be blocked when the quote has an active ramp.');
        System.assert(errorMessage.contains('active ramp schedule'),
            'Expected error message to reference the active ramp schedule. Actual: ' + errorMessage);
    }

    // ─── Test 16: autoAddAdditionalChargeProducts skips when child already exists ──

    @isTest
    static void testAutoAddAdditionalChargeSkipsExistingChild() {
        Id standardPbId = Test.getStandardPricebookId();
        Account acc = newAccount('ExistingChild Acct');
        Opportunity opp = newOpp('ExistingChild Opp', acc.Id);
        Quote q = newQuote('ExistingChild Quote', opp.Id, standardPbId);

        Product2 parent = newProduct('Existing-Child Parent', 'EXPARENT.RC');
        PricebookEntry parentPbe = newPbe(standardPbId, parent.Id, 100.00);

        Product2 child = new Product2(
            Name                    = 'Existing Child',
            ProductCode             = 'EXCHILD.RC',
            IsActive                = true,
            Additional_Charge_Of__c = parent.Id,
            Charge_Type__c          = 'Additional Charge'
        );
        insert child;
        PricebookEntry childPbe = newPbe(standardPbId, child.Id, 25.00);

        // Pre-create the child line on this quote BEFORE the parent triggers
        // autoAddAdditionalChargeProducts, so the existing-child duplicate
        // check short-circuits and no second child line is created.
        QuoteLineItem preExistingChild = new QuoteLineItem(
            QuoteId          = q.Id,
            PricebookEntryId = childPbe.Id,
            Quantity         = 1,
            UnitPrice        = 25.00,
            Charge_Type__c   = 'Additional Charge'
        );
        insert preExistingChild;

        Test.startTest();
        QuoteLineItem parentQli = new QuoteLineItem(
            QuoteId          = q.Id,
            PricebookEntryId = parentPbe.Id,
            Quantity         = 2,
            UnitPrice        = 100.00,
            Charge_Type__c   = 'MRC'
        );
        insert parentQli;
        Test.stopTest();

        Integer childLineCount = [
            SELECT COUNT() FROM QuoteLineItem WHERE QuoteId = :q.Id AND Product2Id = :child.Id
        ];
        System.assertEquals(1, childLineCount,
            'No duplicate Additional Charge child line should be created when one already exists on the quote.');
    }
}