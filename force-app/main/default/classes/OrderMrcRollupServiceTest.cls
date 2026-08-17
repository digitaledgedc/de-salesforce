/**
 * OrderMrcRollupServiceTest
 *
 * Coverage for FB-798 (Ramp MRC and TCV Calculation Spec) — Order_MRC__c /
 * Total_Order_MRC__c, the incremental MRC each ramp order adds.
 *
 *   1. Client's worked example (Product 1 price change, Product 2 new at
 *      Ramp 2, Product 3 unchanged) — asserts the exact per-order deltas
 *      from the spec's "Ramp order totals" table.
 *   2. Aggregate product (Product2.Merge_IB_Task__c = true): delta is the
 *      consecutive-phase difference even with no Ramp_Linked_Phase__c set.
 *
 * Tests call OrderMrcRollupService.calculateForRampChain() directly with
 * hand-built Orders/OrderItems, rather than through the full
 * RampOrderService.splitRampOrder path — isolates the calculation from
 * NRC pairing / Odoo routing / order creation mechanics, none of which this
 * service touches.
 */
@isTest
private class OrderMrcRollupServiceTest {

    @TestSetup
    static void setupTestData() {
        Account acc = new Account(Name = 'FB-798 Order MRC Test Account');
        insert acc;

        Product2 product1  = new Product2(Name = 'Test Product1',  IsActive = true);
        Product2 product2  = new Product2(Name = 'Test Product2',  IsActive = true);
        Product2 product3  = new Product2(Name = 'Test Product3',  IsActive = true);
        Product2 aggregate = new Product2(Name = 'Test Aggregate', IsActive = true, Merge_IB_Task__c = true);
        insert new List<Product2>{ product1, product2, product3, aggregate };

        Id standardPbId = Test.getStandardPricebookId();
        List<PricebookEntry> pbes = new List<PricebookEntry>();
        for (Product2 p : new List<Product2>{ product1, product2, product3, aggregate }) {
            pbes.add(new PricebookEntry(Pricebook2Id = standardPbId, Product2Id = p.Id, UnitPrice = 0, IsActive = true));
        }
        insert pbes;
    }

    private static Order makeOrder(Id accountId, String name, Integer phase, Id parentOrderId) {
        Order o = new Order(
            Name = name, AccountId = accountId, EffectiveDate = Date.today(), Status = 'Draft',
            Pricebook2Id = Test.getStandardPricebookId(),
            Ramp_Phase__c = phase, Original_Order__c = parentOrderId
        );
        insert o;
        return o;
    }

    /**
     * Client's worked example: A=100, B=150, C=200, D=300.
     *   Product 1 (qty 5): Ramp1 Add @A, Ramp3 Price_Change (linked Ramp1) @B
     *   Product 2 (qty 3): Ramp2 Add @C only
     *   Product 3 (qty 1): Ramp1 Add @D, unchanged (Change-linked to Ramp1) through Ramp2/3
     *
     * Expected (spec section 6, "Ramp order totals"):
     *   Ramp 1 Order: 5A + 1D = 800
     *   Ramp 2 Order: 3C = 600
     *   Ramp 3 Order: 5(B-A) = 250
     */
    @isTest
    static void testClientWorkedExample() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Map<String, PricebookEntry> pbeByProduct = new Map<String, PricebookEntry>();
        for (PricebookEntry pbe : [SELECT Id, Product2Id, Product2.Name FROM PricebookEntry WHERE Product2.Name LIKE 'Test Product%']) {
            pbeByProduct.put(pbe.Product2.Name, pbe);
        }
        PricebookEntry pbe1 = pbeByProduct.get('Test Product1');
        PricebookEntry pbe2 = pbeByProduct.get('Test Product2');
        PricebookEntry pbe3 = pbeByProduct.get('Test Product3');

        Order ramp1 = makeOrder(acc.Id, 'Ramp 1 Order', 1, null);
        Order ramp2 = makeOrder(acc.Id, 'Ramp 2 Order', 2, ramp1.Id);
        Order ramp3 = makeOrder(acc.Id, 'Ramp 3 Order', 3, ramp2.Id);

        OrderItem p1Ramp1 = new OrderItem(OrderId = ramp1.Id, Product2Id = pbe1.Product2Id, PricebookEntryId = pbe1.Id,
            Quantity = 5, UnitPrice = 100, Ramp_Phase__c = 1, Ramp_Identifier__c = 'Add');
        OrderItem p3Ramp1 = new OrderItem(OrderId = ramp1.Id, Product2Id = pbe3.Product2Id, PricebookEntryId = pbe3.Id,
            Quantity = 1, UnitPrice = 300, Ramp_Phase__c = 1, Ramp_Identifier__c = 'Add');

        OrderItem p2Ramp2 = new OrderItem(OrderId = ramp2.Id, Product2Id = pbe2.Product2Id, PricebookEntryId = pbe2.Id,
            Quantity = 3, UnitPrice = 200, Ramp_Phase__c = 2, Ramp_Identifier__c = 'Add');
        OrderItem p3Ramp2 = new OrderItem(OrderId = ramp2.Id, Product2Id = pbe3.Product2Id, PricebookEntryId = pbe3.Id,
            Quantity = 1, UnitPrice = 300, Ramp_Phase__c = 2, Ramp_Identifier__c = 'Change', Ramp_Linked_Phase__c = 1);

        OrderItem p1Ramp3 = new OrderItem(OrderId = ramp3.Id, Product2Id = pbe1.Product2Id, PricebookEntryId = pbe1.Id,
            Quantity = 5, UnitPrice = 150, Ramp_Phase__c = 3, Ramp_Identifier__c = 'Price_Change', Ramp_Linked_Phase__c = 1);
        OrderItem p3Ramp3 = new OrderItem(OrderId = ramp3.Id, Product2Id = pbe3.Product2Id, PricebookEntryId = pbe3.Id,
            Quantity = 1, UnitPrice = 300, Ramp_Phase__c = 3, Ramp_Identifier__c = 'Change', Ramp_Linked_Phase__c = 1);

        insert new List<OrderItem>{ p1Ramp1, p3Ramp1, p2Ramp2, p3Ramp2, p1Ramp3, p3Ramp3 };

        Map<Id, List<OrderItem>> itemsByOrderId = new Map<Id, List<OrderItem>>{
            ramp1.Id => new List<OrderItem>{ p1Ramp1, p3Ramp1 },
            ramp2.Id => new List<OrderItem>{ p2Ramp2, p3Ramp2 },
            ramp3.Id => new List<OrderItem>{ p1Ramp3, p3Ramp3 }
        };

        Test.startTest();
        OrderMrcRollupService.calculateForRampChain(new List<Order>{ ramp1, ramp2, ramp3 }, itemsByOrderId);
        Test.stopTest();

        Map<Id, Order> orders = new Map<Id, Order>([SELECT Id, Total_Order_MRC__c FROM Order WHERE Id IN :new List<Id>{ ramp1.Id, ramp2.Id, ramp3.Id }]);
        System.assertEquals(800, orders.get(ramp1.Id).Total_Order_MRC__c, 'Ramp 1 Order total should be 5A+1D=800');
        System.assertEquals(600, orders.get(ramp2.Id).Total_Order_MRC__c, 'Ramp 2 Order total should be 3C=600');
        System.assertEquals(250, orders.get(ramp3.Id).Total_Order_MRC__c, 'Ramp 3 Order total should be 5(B-A)=250');

        Map<Id, OrderItem> items = new Map<Id, OrderItem>([SELECT Id, Order_MRC__c FROM OrderItem WHERE Id IN
            :new List<Id>{ p1Ramp1.Id, p3Ramp1.Id, p2Ramp2.Id, p3Ramp2.Id, p1Ramp3.Id, p3Ramp3.Id }]);
        System.assertEquals(500, items.get(p1Ramp1.Id).Order_MRC__c, 'Product 1 Ramp 1: 5*100=500, no prior phase');
        System.assertEquals(300, items.get(p3Ramp1.Id).Order_MRC__c, 'Product 3 Ramp 1: 1*300=300, no prior phase');
        System.assertEquals(600, items.get(p2Ramp2.Id).Order_MRC__c, 'Product 2 Ramp 2: 3*200=600, no prior phase');
        System.assertEquals(0, items.get(p3Ramp2.Id).Order_MRC__c, 'Product 3 Ramp 2: unchanged from Ramp 1, delta=0');
        System.assertEquals(250, items.get(p1Ramp3.Id).Order_MRC__c, 'Product 1 Ramp 3: 5*150-5*100=250, price change delta');
        System.assertEquals(0, items.get(p3Ramp3.Id).Order_MRC__c, 'Product 3 Ramp 3: still unchanged from Ramp 1, delta=0');
    }

    /**
     * Aggregate product (Merge_IB_Task__c = true): delta is always the
     * consecutive-phase difference, even with no Ramp_Linked_Phase__c set —
     * per spec section 8, asset linking is ignored for aggregate products.
     */
    @isTest
    static void testAggregateProductUsesConsecutivePhaseDelta() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        PricebookEntry pbe = [SELECT Id, Product2Id FROM PricebookEntry WHERE Product2.Name = 'Test Aggregate' LIMIT 1];

        Order ramp1 = makeOrder(acc.Id, 'Agg Ramp 1', 1, null);
        Order ramp2 = makeOrder(acc.Id, 'Agg Ramp 2', 2, ramp1.Id);

        // No Ramp_Linked_Phase__c on either line — aggregate rule should still
        // net Ramp 2 against Ramp 1's amount.
        OrderItem aggRamp1 = new OrderItem(OrderId = ramp1.Id, Product2Id = pbe.Product2Id, PricebookEntryId = pbe.Id,
            Quantity = 1, UnitPrice = 100, Ramp_Phase__c = 1, Ramp_Identifier__c = 'Add');
        OrderItem aggRamp2 = new OrderItem(OrderId = ramp2.Id, Product2Id = pbe.Product2Id, PricebookEntryId = pbe.Id,
            Quantity = 1, UnitPrice = 150, Ramp_Phase__c = 2, Ramp_Identifier__c = 'Add');
        insert new List<OrderItem>{ aggRamp1, aggRamp2 };

        Map<Id, List<OrderItem>> itemsByOrderId = new Map<Id, List<OrderItem>>{
            ramp1.Id => new List<OrderItem>{ aggRamp1 },
            ramp2.Id => new List<OrderItem>{ aggRamp2 }
        };

        Test.startTest();
        OrderMrcRollupService.calculateForRampChain(new List<Order>{ ramp1, ramp2 }, itemsByOrderId);
        Test.stopTest();

        OrderItem result = [SELECT Order_MRC__c FROM OrderItem WHERE Id = :aggRamp2.Id];
        System.assertEquals(50, result.Order_MRC__c, 'Aggregate product delta should be 150-100=50, consecutive phase diff');
    }

    /**
     * End-to-end coverage for the RampOrderService.splitRampOrder integration
     * (calculateForRampChain is called directly in the tests above, isolated
     * from order-splitting mechanics — this proves the wiring itself works,
     * and provides real Apex coverage on RampOrderService for this deploy,
     * independent of RampOrderServiceTest's own, unrelated data-setup gaps).
     *
     * Product 1 (qty 5): Phase 1 Add @ 100, Phase 2 Price_Change (linked
     * Phase 1) @ 150 — expect Phase 2's child Order to end up with
     * Order_MRC__c = 5*150 - 5*100 = 250.
     */
    @isTest
    static void testSplitRampOrderPopulatesOrderMrcEndToEnd() {
        Account acc = new Account(Name = 'FB-798 E2E Test Account');
        insert acc;

        BillingAccount__c ban = new BillingAccount__c(
            Account__c              = acc.Id,
            Invoice_Frequency__c    = 'Monthly',
            Odoo_Partner_ID__c      = '99999',
            Odoo_BAN_ID__c          = 11111,
            Odoo_Invoice_Freq_ID__c = 1
        );
        insert ban;

        // Country_Name__c is a formula off Country__c ("SG" -> "Singapore"),
        // which the Target_Site__c lookup filter matches against
        // Opportunity.Operation_Country__c below.
        Site__c site = new Site__c(
            Name = 'FB-798 E2E Test Site', Site_Code__c = 'FB798', Country__c = 'SG',
            Pricebook2__c = Test.getStandardPricebookId()
        );
        insert site;

        Opportunity opp = new Opportunity(
            Name = 'FB-798 E2E Test Opp', AccountId = acc.Id, StageName = '1-Suspect',
            CloseDate = Date.today().addDays(30), Target_Site__c = site.Id,
            Operation_Country__c = 'Singapore', Booking_Bucket__c = 'Bookings'
        );
        insert opp;

        PricebookEntry pbe1 = [SELECT Id, Product2Id FROM PricebookEntry WHERE Product2.Name = 'Test Product1' LIMIT 1];

        Order parentOrder = new Order(
            AccountId = acc.Id, OpportunityId = opp.Id, EffectiveDate = Date.today(), Status = 'Draft',
            Pricebook2Id = Test.getStandardPricebookId(), BillingAccount__c = ban.Id,
            Order_Number__c = 'FB798-E2E-001'
        );
        insert parentOrder;

        insert new List<OrderItem>{
            new OrderItem(OrderId = parentOrder.Id, Product2Id = pbe1.Product2Id, PricebookEntryId = pbe1.Id,
                Quantity = 5, UnitPrice = 100, Ramp_Phase__c = 1, Ramp_Identifier__c = 'Add'),
            new OrderItem(OrderId = parentOrder.Id, Product2Id = pbe1.Product2Id, PricebookEntryId = pbe1.Id,
                Quantity = 5, UnitPrice = 150, Ramp_Phase__c = 2, Ramp_Identifier__c = 'Price_Change', Ramp_Linked_Phase__c = 1)
        };

        Test.startTest();
        RampOrderService.Request req = new RampOrderService.Request();
        req.orderId = parentOrder.Id;
        RampOrderService.splitRampOrder(new List<RampOrderService.Request>{ req });
        Test.stopTest();

        Order phase2Order = [SELECT Id, Total_Order_MRC__c FROM Order WHERE Parent_Order__c = :parentOrder.Id LIMIT 1];
        System.assertEquals(250, phase2Order.Total_Order_MRC__c, 'Phase 2 child order should show the 250 price-change delta, not the full 750');

        OrderItem phase2Item = [SELECT Order_MRC__c FROM OrderItem WHERE OrderId = :phase2Order.Id LIMIT 1];
        System.assertEquals(250, phase2Item.Order_MRC__c, 'Phase 2 line delta should be 5*150-5*100=250');
    }
    /**
     * "Link all phases" fan-out, the client's 6-cab example:
     *   Phase 1/2/3: Add 2 cabs @ $100 each  (6 cabs @ $100 installed)
     *   Phase 4:     reprice ALL six to $120 via three lines, one linked to
     *                each of phases 1, 2 and 3.
     *
     * Phase 4's incremental MRC is the uplift on the whole installed base:
     * 6 * ($120 - $100) = $120 — reached as three $40 line deltas, NOT the
     * $240 a single line linked to phase 1 alone would report.
     */
    @isTest
    static void testLinkAllPhasesFanOutNetsEveryLinkedPhase() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        PricebookEntry pbe = [SELECT Id, Product2Id FROM PricebookEntry WHERE Product2.Name = 'Test Product1' LIMIT 1];

        Order ramp1 = makeOrder(acc.Id, 'Cab Ramp 1', 1, null);
        Order ramp2 = makeOrder(acc.Id, 'Cab Ramp 2', 2, ramp1.Id);
        Order ramp3 = makeOrder(acc.Id, 'Cab Ramp 3', 3, ramp2.Id);
        Order ramp4 = makeOrder(acc.Id, 'Cab Ramp 4', 4, ramp3.Id);

        OrderItem add1 = new OrderItem(OrderId = ramp1.Id, Product2Id = pbe.Product2Id, PricebookEntryId = pbe.Id,
            Quantity = 2, UnitPrice = 100, Ramp_Phase__c = 1, Ramp_Identifier__c = 'Add');
        OrderItem add2 = new OrderItem(OrderId = ramp2.Id, Product2Id = pbe.Product2Id, PricebookEntryId = pbe.Id,
            Quantity = 2, UnitPrice = 100, Ramp_Phase__c = 2, Ramp_Identifier__c = 'Add');
        OrderItem add3 = new OrderItem(OrderId = ramp3.Id, Product2Id = pbe.Product2Id, PricebookEntryId = pbe.Id,
            Quantity = 2, UnitPrice = 100, Ramp_Phase__c = 3, Ramp_Identifier__c = 'Add');

        // The fan-out: three lines in ONE phase, same product, same attribute.
        OrderItem rp4a = new OrderItem(OrderId = ramp4.Id, Product2Id = pbe.Product2Id, PricebookEntryId = pbe.Id,
            Quantity = 2, UnitPrice = 120, Ramp_Phase__c = 4, Ramp_Identifier__c = 'Price_Change', Ramp_Linked_Phase__c = 1);
        OrderItem rp4b = new OrderItem(OrderId = ramp4.Id, Product2Id = pbe.Product2Id, PricebookEntryId = pbe.Id,
            Quantity = 2, UnitPrice = 120, Ramp_Phase__c = 4, Ramp_Identifier__c = 'Price_Change', Ramp_Linked_Phase__c = 2);
        OrderItem rp4c = new OrderItem(OrderId = ramp4.Id, Product2Id = pbe.Product2Id, PricebookEntryId = pbe.Id,
            Quantity = 2, UnitPrice = 120, Ramp_Phase__c = 4, Ramp_Identifier__c = 'Price_Change', Ramp_Linked_Phase__c = 3);

        insert new List<OrderItem>{ add1, add2, add3, rp4a, rp4b, rp4c };

        Map<Id, List<OrderItem>> itemsByOrderId = new Map<Id, List<OrderItem>>{
            ramp1.Id => new List<OrderItem>{ add1 },
            ramp2.Id => new List<OrderItem>{ add2 },
            ramp3.Id => new List<OrderItem>{ add3 },
            ramp4.Id => new List<OrderItem>{ rp4a, rp4b, rp4c }
        };

        Test.startTest();
        OrderMrcRollupService.calculateForRampChain(new List<Order>{ ramp1, ramp2, ramp3, ramp4 }, itemsByOrderId);
        Test.stopTest();

        Map<Id, Order> orders = new Map<Id, Order>([SELECT Id, Total_Order_MRC__c FROM Order
            WHERE Id IN :new List<Id>{ ramp1.Id, ramp2.Id, ramp3.Id, ramp4.Id }]);
        System.assertEquals(200, orders.get(ramp1.Id).Total_Order_MRC__c, 'Phase 1 adds 2 cabs @ 100');
        System.assertEquals(200, orders.get(ramp2.Id).Total_Order_MRC__c, 'Phase 2 adds 2 cabs @ 100');
        System.assertEquals(200, orders.get(ramp3.Id).Total_Order_MRC__c, 'Phase 3 adds 2 cabs @ 100');
        System.assertEquals(120, orders.get(ramp4.Id).Total_Order_MRC__c,
            'Phase 4 reprices all 6 cabs: 6*(120-100)=120, not 40 (one line) and not 720 (full amount)');

        Map<Id, OrderItem> items = new Map<Id, OrderItem>([SELECT Id, Order_MRC__c FROM OrderItem
            WHERE Id IN :new List<Id>{ rp4a.Id, rp4b.Id, rp4c.Id }]);
        System.assertEquals(40, items.get(rp4a.Id).Order_MRC__c, 'Fan-out line -> phase 1: 2*120-2*100=40');
        System.assertEquals(40, items.get(rp4b.Id).Order_MRC__c, 'Fan-out line -> phase 2: 2*120-2*100=40');
        System.assertEquals(40, items.get(rp4c.Id).Order_MRC__c, 'Fan-out line -> phase 3: 2*120-2*100=40');
    }

    /**
     * A SECOND repricing phase must net against what the first reprice left
     * standing, not against the original 'Add'.
     *
     *   Phases 1-3: Add 2 cabs @ $100     Phase 4: all six -> $120
     *   Phase 5:    all six -> $140
     *
     * Phase 5's increment is 6 * ($140 - $120) = $120. Netting each phase-5
     * line back to phase 1/2/3's original $100 instead would report $240 and
     * double-count phase 4's uplift.
     */
    @isTest
    static void testSecondRepriceNetsAgainstFirstReprice() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        PricebookEntry pbe = [SELECT Id, Product2Id FROM PricebookEntry WHERE Product2.Name = 'Test Product1' LIMIT 1];

        Order ramp1 = makeOrder(acc.Id, 'Reprice Ramp 1', 1, null);
        Order ramp2 = makeOrder(acc.Id, 'Reprice Ramp 2', 2, ramp1.Id);
        Order ramp3 = makeOrder(acc.Id, 'Reprice Ramp 3', 3, ramp2.Id);
        Order ramp4 = makeOrder(acc.Id, 'Reprice Ramp 4', 4, ramp3.Id);
        Order ramp5 = makeOrder(acc.Id, 'Reprice Ramp 5', 5, ramp4.Id);

        List<OrderItem> adds = new List<OrderItem>();
        for (Integer ph = 1; ph <= 3; ph++) {
            Id oid = (ph == 1 ? ramp1.Id : (ph == 2 ? ramp2.Id : ramp3.Id));
            adds.add(new OrderItem(OrderId = oid, Product2Id = pbe.Product2Id, PricebookEntryId = pbe.Id,
                Quantity = 2, UnitPrice = 100, Ramp_Phase__c = ph, Ramp_Identifier__c = 'Add'));
        }
        List<OrderItem> reprice4 = new List<OrderItem>();
        List<OrderItem> reprice5 = new List<OrderItem>();
        for (Integer target = 1; target <= 3; target++) {
            reprice4.add(new OrderItem(OrderId = ramp4.Id, Product2Id = pbe.Product2Id, PricebookEntryId = pbe.Id,
                Quantity = 2, UnitPrice = 120, Ramp_Phase__c = 4, Ramp_Identifier__c = 'Price_Change', Ramp_Linked_Phase__c = target));
            reprice5.add(new OrderItem(OrderId = ramp5.Id, Product2Id = pbe.Product2Id, PricebookEntryId = pbe.Id,
                Quantity = 2, UnitPrice = 140, Ramp_Phase__c = 5, Ramp_Identifier__c = 'Price_Change', Ramp_Linked_Phase__c = target));
        }
        List<OrderItem> all = new List<OrderItem>();
        all.addAll(adds); all.addAll(reprice4); all.addAll(reprice5);
        insert all;

        Map<Id, List<OrderItem>> itemsByOrderId = new Map<Id, List<OrderItem>>{
            ramp1.Id => new List<OrderItem>{ adds[0] },
            ramp2.Id => new List<OrderItem>{ adds[1] },
            ramp3.Id => new List<OrderItem>{ adds[2] },
            ramp4.Id => reprice4,
            ramp5.Id => reprice5
        };

        Test.startTest();
        OrderMrcRollupService.calculateForRampChain(
            new List<Order>{ ramp1, ramp2, ramp3, ramp4, ramp5 }, itemsByOrderId);
        Test.stopTest();

        Map<Id, Order> orders = new Map<Id, Order>([SELECT Id, Total_Order_MRC__c FROM Order
            WHERE Id IN :new List<Id>{ ramp4.Id, ramp5.Id }]);
        System.assertEquals(120, orders.get(ramp4.Id).Total_Order_MRC__c, 'Phase 4: 6*(120-100)=120');
        System.assertEquals(120, orders.get(ramp5.Id).Total_Order_MRC__c,
            'Phase 5 must net against 120, not the original 100: 6*(140-120)=120, not 240');
    }

    /**
     * Regression for the index collapse: a phase that reads back into a
     * fanned-out phase must see that phase's FULL family amount (all three
     * lines), not whichever single line came last in the caller's list.
     *
     * Phase 5 links to phase 4 as one 6-cab line @ $140. Phase 4 stands at
     * 3 * 2 * $120 = $720, so the delta is $840 - $720 = $120. Indexing one
     * OrderItem per (phase, family) saw $240 and reported $600.
     *
     * (The UI's "all phases" option targets the qty-holding Add phases rather
     * than a reprice phase, so this shape is defensive — but nothing in the
     * data model forbids it.)
     */
    @isTest
    static void testLaterPhaseSeesFullFannedOutPhaseAmount() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        PricebookEntry pbe = [SELECT Id, Product2Id FROM PricebookEntry WHERE Product2.Name = 'Test Product1' LIMIT 1];

        Order ramp1 = makeOrder(acc.Id, 'Collapse Ramp 1', 1, null);
        Order ramp2 = makeOrder(acc.Id, 'Collapse Ramp 2', 2, ramp1.Id);
        Order ramp3 = makeOrder(acc.Id, 'Collapse Ramp 3', 3, ramp2.Id);
        Order ramp4 = makeOrder(acc.Id, 'Collapse Ramp 4', 4, ramp3.Id);
        Order ramp5 = makeOrder(acc.Id, 'Collapse Ramp 5', 5, ramp4.Id);

        OrderItem add1 = new OrderItem(OrderId = ramp1.Id, Product2Id = pbe.Product2Id, PricebookEntryId = pbe.Id,
            Quantity = 2, UnitPrice = 100, Ramp_Phase__c = 1, Ramp_Identifier__c = 'Add');
        OrderItem add2 = new OrderItem(OrderId = ramp2.Id, Product2Id = pbe.Product2Id, PricebookEntryId = pbe.Id,
            Quantity = 2, UnitPrice = 100, Ramp_Phase__c = 2, Ramp_Identifier__c = 'Add');
        OrderItem add3 = new OrderItem(OrderId = ramp3.Id, Product2Id = pbe.Product2Id, PricebookEntryId = pbe.Id,
            Quantity = 2, UnitPrice = 100, Ramp_Phase__c = 3, Ramp_Identifier__c = 'Add');

        List<OrderItem> reprice4 = new List<OrderItem>();
        for (Integer target = 1; target <= 3; target++) {
            reprice4.add(new OrderItem(OrderId = ramp4.Id, Product2Id = pbe.Product2Id, PricebookEntryId = pbe.Id,
                Quantity = 2, UnitPrice = 120, Ramp_Phase__c = 4, Ramp_Identifier__c = 'Price_Change', Ramp_Linked_Phase__c = target));
        }
        OrderItem reprice5 = new OrderItem(OrderId = ramp5.Id, Product2Id = pbe.Product2Id, PricebookEntryId = pbe.Id,
            Quantity = 6, UnitPrice = 140, Ramp_Phase__c = 5, Ramp_Identifier__c = 'Price_Change', Ramp_Linked_Phase__c = 4);

        List<OrderItem> all = new List<OrderItem>{ add1, add2, add3 };
        all.addAll(reprice4);
        all.add(reprice5);
        insert all;

        Map<Id, List<OrderItem>> itemsByOrderId = new Map<Id, List<OrderItem>>{
            ramp1.Id => new List<OrderItem>{ add1 },
            ramp2.Id => new List<OrderItem>{ add2 },
            ramp3.Id => new List<OrderItem>{ add3 },
            ramp4.Id => reprice4,
            ramp5.Id => new List<OrderItem>{ reprice5 }
        };

        Test.startTest();
        OrderMrcRollupService.calculateForRampChain(
            new List<Order>{ ramp1, ramp2, ramp3, ramp4, ramp5 }, itemsByOrderId);
        Test.stopTest();

        OrderItem result = [SELECT Order_MRC__c FROM OrderItem WHERE Id = :reprice5.Id];
        System.assertEquals(120, result.Order_MRC__c,
            'Phase 5 nets against phase 4 in full (3 lines = 720): 6*140-720=120, not 600');
    }
}