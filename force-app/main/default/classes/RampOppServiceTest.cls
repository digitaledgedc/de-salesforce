@IsTest
private class RampOppServiceTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = 'Ramp Opp Test Account', Operation_Country__c = 'Singapore');
        insert acc;

        Site__c site = new Site__c(
            Name         = 'RAMPOPPTEST',
            Site_Code__c = 'RAMPOPPTEST',
            Country__c   = 'SG'
        );
        insert site;

        Opportunity opp = new Opportunity(
            Name      = 'Ramp Opp Test Opp',
            AccountId = acc.Id,
            StageName = '1-Suspect',
            CloseDate = Date.today().addDays(30),
            Operation_Country__c = 'Singapore',
            Target_Site__c = site.Id,
            // Non-zero placeholders (as Update_Opportunity_PrimaryQuote would
            // have set from the Quote) so the zeroing assertions below prove
            // createRampChildren actually reset them, not that they started blank.
            MRC__c = 6000, NRC__c = 500, Total_Deal_MRC__c = 99999,
            // Non-blank placeholder so the copy-forward assertions below prove
            // createRampChildren actually copied it, not that it started blank.
            Account_Type__c = 'Platform'
        );
        insert opp;

        // Stand-ins for the Orders RampOrderService.splitRampOrder would have
        // already created/MRC-rolled-up by the time RampOppService runs —
        // phase 1 (the renamed original Order) included.
        // Fixed (not Date.today()-relative) dates, landing on the LAST day of
        // March, so every phase's day-summed remaining term (2026-09-03
        // model) comes out to a clean whole number: Jan1->Mar31 = 3,
        // Feb1->Mar31 = 2, Mar1->Mar31 = 1.
        Date contractEnd = Date.newInstance(2027, 3, 31);

        Order parentOrder = new Order(
            AccountId      = acc.Id,
            OpportunityId  = opp.Id,
            EffectiveDate  = Date.today(),
            Status         = 'Draft',
            Pricebook2Id   = Test.getStandardPricebookId(),
            Order_Number__c = 'RAMP-OPP-TEST-OR-1-RO1',
            Ramp_Phase__c  = 1,
            RDD__c         = Date.newInstance(2027, 1, 1),
            Total_Order_MRC__c = 1000,
            Contract_End_Date__c = contractEnd
        );
        insert parentOrder;

        List<Order> childOrders = new List<Order>{
            new Order(
                AccountId = acc.Id, OpportunityId = opp.Id, EffectiveDate = Date.today(),
                Status = 'Draft', Pricebook2Id = Test.getStandardPricebookId(), Order_Number__c = 'RAMP-OPP-TEST-OR-1-RO2',
                Ramp_Phase__c = 2, RDD__c = Date.newInstance(2027, 2, 1), Total_Order_MRC__c = 2000,
                Contract_End_Date__c = contractEnd
            ),
            new Order(
                AccountId = acc.Id, OpportunityId = opp.Id, EffectiveDate = Date.today(),
                Status = 'Draft', Pricebook2Id = Test.getStandardPricebookId(), Order_Number__c = 'RAMP-OPP-TEST-OR-1-RO3',
                Ramp_Phase__c = 3, RDD__c = Date.newInstance(2027, 3, 1), Total_Order_MRC__c = 3000,
                Contract_End_Date__c = contractEnd
            )
        };
        insert childOrders;

        // Total_NRC__c is a roll-up summary (sum of OrderItem.MRC_Amount__c
        // where Charge_Type__c = 'NRC') — not directly settable, so give each
        // phase Order a real NRC line instead: 100 / 200 / 300.
        Product2 nrcProduct = new Product2(Name = 'Ramp Opp Test NRC', IsActive = true, Charge_Type__c = 'NRC');
        insert nrcProduct;
        PricebookEntry nrcPbe = new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(), Product2Id = nrcProduct.Id, UnitPrice = 0, IsActive = true
        );
        insert nrcPbe;
        insert new List<OrderItem>{
            new OrderItem(OrderId = parentOrder.Id, Product2Id = nrcProduct.Id, PricebookEntryId = nrcPbe.Id,
                Quantity = 1, UnitPrice = 100, Charge_Type__c = 'NRC'),
            new OrderItem(OrderId = childOrders[0].Id, Product2Id = nrcProduct.Id, PricebookEntryId = nrcPbe.Id,
                Quantity = 1, UnitPrice = 200, Charge_Type__c = 'NRC'),
            new OrderItem(OrderId = childOrders[1].Id, Product2Id = nrcProduct.Id, PricebookEntryId = nrcPbe.Id,
                Quantity = 1, UnitPrice = 300, Charge_Type__c = 'NRC')
        };
    }

    private static Order getPhase1Order() {
        return [SELECT Id, OpportunityId FROM Order WHERE Order_Number__c = 'RAMP-OPP-TEST-OR-1-RO1' LIMIT 1];
    }

    private static List<Order> getPhase2PlusOrders() {
        return [SELECT Id, OpportunityId, Ramp_Phase__c FROM Order WHERE Order_Number__c != 'RAMP-OPP-TEST-OR-1-RO1' ORDER BY Ramp_Phase__c];
    }

    @IsTest
    static void createRampChildren_createsOneClosedWonChildPerPhaseIncludingPhase1() {
        Opportunity opp = [SELECT Id, Opportunity_Number__c FROM Opportunity LIMIT 1];
        Order parentOrder = getPhase1Order();
        List<Order> childOrders = getPhase2PlusOrders();

        Test.startTest();
        RampOppService.createRampChildren(parentOrder, childOrders);
        Test.stopTest();

        List<Opportunity> children = [
            SELECT Id, Name, StageName, Parent_Opportunity__c, Amount, Opportunity_Number__c, MRC__c, NRC__c, Total_Deal_MRC__c,
                   Remaining_Month__c, Contract_End_Date__c, Is_Ramp_Deal__c,
                   Forecast_Status__c, CloseDate, GoLive_Target_Date__c, Account_Type__c
            FROM Opportunity WHERE Parent_Opportunity__c = :opp.Id ORDER BY Opportunity_Number__c
        ];
        System.assertEquals(3, children.size(), 'Should create one child Opportunity per phase, phase 1 included');
        for (Opportunity child : children) {
            System.assertEquals('5-Won', child.StageName, 'Ramp child Opportunities must be created Closed Won');
        }
        System.assertEquals(opp.Opportunity_Number__c + '-RO1', children[0].Opportunity_Number__c, 'Phase 1 child number should mirror the Order_Number__c "-RO1" convention');
        System.assertEquals(opp.Opportunity_Number__c + '-RO2', children[1].Opportunity_Number__c, 'Phase 2 child number should mirror the Order_Number__c "-RO2" convention');
        System.assertEquals(opp.Opportunity_Number__c + '-RO3', children[2].Opportunity_Number__c, 'Phase 3 child number should mirror the Order_Number__c "-RO3" convention');
        System.assertEquals(1000, children[0].Amount, 'Phase 1 child Amount should come from that phase\'s Total_Order_MRC__c');
        System.assertEquals(2000, children[1].Amount, 'Phase 2 child Amount should come from that phase\'s Total_Order_MRC__c');
        System.assertEquals(3000, children[2].Amount, 'Phase 3 child Amount should come from that phase\'s Total_Order_MRC__c');

        // MRC__c mirrors Amount — that phase's incremental MRC.
        System.assertEquals(1000, children[0].MRC__c, 'Phase 1 child MRC__c should be that phase\'s incremental MRC');
        System.assertEquals(2000, children[1].MRC__c, 'Phase 2 child MRC__c should be that phase\'s incremental MRC');
        System.assertEquals(3000, children[2].MRC__c, 'Phase 3 child MRC__c should be that phase\'s incremental MRC');

        // TCV (stored in Total_Deal_MRC__c) = delta * months REMAINING from
        // that phase's RDD__c through Contract_End_Date__c (today + 3
        // months) — not the window to the next phase (2026-08-26 fix).
        System.assertEquals(3000, children[0].Total_Deal_MRC__c, 'Phase 1 TCV = 1000 delta * 3 remaining months to Contract_End_Date__c');
        System.assertEquals(4000, children[1].Total_Deal_MRC__c, 'Phase 2 TCV = 2000 delta * 2 remaining months to Contract_End_Date__c');
        System.assertEquals(3000, children[2].Total_Deal_MRC__c, 'Phase 3 TCV = 3000 delta * 1 remaining month to Contract_End_Date__c');

        // Remaining_Month__c stores that same day-aware remaining-term figure
        // directly, and Contract_End_Date__c is copied straight from the phase's Order.
        System.assertEquals(3, children[0].Remaining_Month__c, 'Phase 1 Remaining_Month__c should be 3 (today -> today+3mo)');
        System.assertEquals(2, children[1].Remaining_Month__c, 'Phase 2 Remaining_Month__c should be 2 (today+1mo -> today+3mo)');
        System.assertEquals(1, children[2].Remaining_Month__c, 'Phase 3 Remaining_Month__c should be 1 (today+2mo -> today+3mo)');
        for (Opportunity child : children) {
            System.assertEquals(contractEnd(), child.Contract_End_Date__c, 'Child Opportunity Contract_End_Date__c should be copied from its phase Order');
            System.assertEquals(true, child.Is_Ramp_Deal__c, 'Child ramp Opportunities should be flagged Is_Ramp_Deal__c');
            // 2026-09-22 fix: Forecast_Status__c defaults to 'Pipeline' (its
            // required-field default) when left unset — every ramp child is
            // already-won revenue, so this must explicitly read 'Won'.
            System.assertEquals('Won', child.Forecast_Status__c, 'Ramp child Forecast_Status__c should be Won, not the Pipeline default');
            // 2026-09-22 fix: every phase shares the deal's own CloseDate —
            // it must NOT be the phase's own RDD (that belongs on GoLive_Target_Date__c below).
            System.assertEquals(Date.today().addDays(30), child.CloseDate, 'Ramp child CloseDate should mirror the deal Opportunity\'s own CloseDate');
            // 2026-09-22 fix: Account_Type__c wasn't selected by getForRampClone, so it cloned blank.
            System.assertEquals('Platform', child.Account_Type__c, 'Ramp child Account_Type__c should be copied from the deal Opportunity');
        }
        // 2026-09-22 fix: GoLive_Target_Date__c (Requested Delivery Date) must
        // carry each phase's OWN RDD__c — previously never set here, so every
        // phase just inherited the deal-level clone value instead.
        System.assertEquals(Date.newInstance(2027, 1, 1), children[0].GoLive_Target_Date__c, 'Phase 1 GoLive_Target_Date__c should be that phase\'s own RDD__c');
        System.assertEquals(Date.newInstance(2027, 2, 1), children[1].GoLive_Target_Date__c, 'Phase 2 GoLive_Target_Date__c should be that phase\'s own RDD__c');
        System.assertEquals(Date.newInstance(2027, 3, 1), children[2].GoLive_Target_Date__c, 'Phase 3 GoLive_Target_Date__c should be that phase\'s own RDD__c');

        // NRC__c mirrors that phase's own Order.Total_NRC__c.
        System.assertEquals(100, children[0].NRC__c, 'Phase 1 child NRC__c should be that phase\'s Order Total_NRC__c');
        System.assertEquals(200, children[1].NRC__c, 'Phase 2 child NRC__c should be that phase\'s Order Total_NRC__c');
        System.assertEquals(300, children[2].NRC__c, 'Phase 3 child NRC__c should be that phase\'s Order Total_NRC__c');

        // Every phase's Order — phase 1 included — must be re-pointed off
        // the deal Opportunity onto its own new phase Opportunity.
        List<Order> refreshedOrders = [SELECT Id, OpportunityId FROM Order];
        for (Order o : refreshedOrders) {
            System.assertNotEquals(opp.Id, o.OpportunityId, 'Every phase Order, including phase 1, should be re-pointed off the deal Opportunity');
        }

        // With no Order left pointing at it, Order_AfterSave_WonAutoClose can
        // no longer close the deal Opportunity — this method does it instead.
        // Its own MRC/NRC/TCV are also forced to 0 — the children carry that
        // value now, so the deal Opportunity can't double-count alongside them.
        Opportunity refreshedDeal = [SELECT StageName, MRC__c, NRC__c, Total_Deal_MRC__c, Is_Ramp_Deal__c, Contract_End_Date__c FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals('5-Won', refreshedDeal.StageName, 'Deal Opportunity should be closed Won once every phase has its own child');
        System.assertEquals(0, refreshedDeal.MRC__c, 'Deal Opportunity MRC__c should be zeroed once its children carry the real value');
        System.assertEquals(0, refreshedDeal.NRC__c, 'Deal Opportunity NRC__c should be zeroed once its children carry the real value');
        System.assertEquals(0, refreshedDeal.Total_Deal_MRC__c, 'Deal Opportunity TCV should be zeroed once its children carry the real value');
        System.assertEquals(true, refreshedDeal.Is_Ramp_Deal__c, 'Deal Opportunity should be flagged Is_Ramp_Deal__c');
        System.assertEquals(contractEnd(), refreshedDeal.Contract_End_Date__c, 'Deal Opportunity Contract_End_Date__c should be populated from the phases');
    }

    /** Matches the @TestSetup Contract_End_Date__c (fixed 2027-03-31) without re-deriving it per assertion. */
    private static Date contractEnd() {
        return Date.newInstance(2027, 3, 31);
    }

    @IsTest
    static void createRampChildren_duplicateGuardSkipsAlreadyLinkedOrders() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        Order parentOrder = getPhase1Order();

        Test.startTest();
        List<Order> firstPass = getPhase2PlusOrders();
        RampOppService.createRampChildren(parentOrder, firstPass);

        // Re-query — mirrors a retry of the calling flow with fresh data,
        // where every phase's Order now points at its own phase Opportunity.
        Order parentOrderRefreshed = [SELECT Id, OpportunityId FROM Order WHERE Id = :parentOrder.Id];
        List<Order> secondPass = getPhase2PlusOrders();
        RampOppService.createRampChildren(parentOrderRefreshed, secondPass);
        Test.stopTest();

        List<Opportunity> children = [SELECT Id FROM Opportunity WHERE Parent_Opportunity__c = :opp.Id];
        System.assertEquals(3, children.size(), 'Re-running with already-linked Orders must not create duplicate child Opportunities');
    }

    @IsTest
    static void createRampChildren_nullOrEmptyInputNoOp() {
        Test.startTest();
        RampOppService.createRampChildren(null, new List<Order>());
        RampOppService.createRampChildren(new Order(), null);
        RampOppService.createRampChildren(new Order(), new List<Order>());
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Opportunity WHERE Parent_Opportunity__c != null], 'No child Opportunities should be created from null/empty input');
    }

    // OpportunitySelector.getForRampClone's null/empty guard isn't exercised by the real
    // createRampChildren flow above (it's always called with real Ids there) — covered directly
    // here instead of via a separate OpportunitySelectorTest, since getByIds/getChildrenByParentIds
    // are already unit-tested in OpportunityTriggerHandlerTest.
    @IsTest
    static void getForRampClone_nullOrEmptySet_returnsEmptyList() {
        System.assertEquals(0, OpportunitySelector.getForRampClone(null).size(),
            'Null Id set should short-circuit to an empty list');
        System.assertEquals(0, OpportunitySelector.getForRampClone(new Set<Id>()).size(),
            'Empty Id set should short-circuit to an empty list');
    }
}