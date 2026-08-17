// isParallel=false: this test's setup activates Orders whose cascade updates
// shared parent rows (Account/BAN/Site), which collides with other tests under
// RunLocalTests parallel execution → UNABLE_TO_LOCK_ROW. It passes in isolation;
// opting out of the parallel batch makes it deterministic.
@IsTest(isParallel=false)
private class RampOrderServiceTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = 'Ramp Test Account', Operation_Country__c = 'Singapore');
        insert acc;

        // BAN required before an Order can be Activated (VR: "A BAN must be assigned
        // before this Order can be activated.") — RampOrderService activates each
        // child Order at the end of splitRampOrder, so the parent Order (and its
        // clones) must carry a valid BillingAccount__c.
        BillingAccount__c ban = new BillingAccount__c(
            Account__c              = acc.Id,
            Invoice_Frequency__c    = 'Monthly',
            Odoo_Partner_ID__c      = '55501',
            Odoo_BAN_ID__c          = 55501,
            Odoo_Invoice_Freq_ID__c = 1
        );
        insert ban;

        // Order - After Save - Won Auto-Close flow moves the Opportunity to Closed
        // Won when a child Order is activated (which splitRampOrder does for every
        // ramp phase). VR_OPP_21_Site_Required_At_Quote requires Target_Site__c
        // from Stage 3-Quote onwards, so it must already be set before that happens.
        Site__c site = new Site__c(
            Name         = 'RAMPTEST',
            Site_Code__c = 'RAMPTEST',
            Country__c   = 'SG'
        );
        insert site;

        Opportunity opp = new Opportunity(
            Name      = 'Ramp Test Opp',
            AccountId = acc.Id,
            StageName = '1-Suspect',
            CloseDate = Date.today().addDays(30),
            Pricebook2Id = Test.getStandardPricebookId(),
            Operation_Country__c = 'Singapore',
            Target_Site__c = site.Id
        );
        insert opp;

        Product2 mrcProd = new Product2(
            Name = 'RAMP-MRC.RC', ProductCode = 'RAMP-MRC.RC', IsActive = true,
            Charge_Type__c = 'MRC'
        );
        Product2 nrcProd = new Product2(
            Name = 'RAMP-MRC.NR', ProductCode = 'RAMP-MRC.NR', IsActive = true,
            Charge_Type__c = 'NRC'
        );
        insert new List<Product2>{ mrcProd, nrcProd };

        PricebookEntry mrcPbe = new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(),
            Product2Id   = mrcProd.Id,
            UnitPrice    = 100,
            IsActive     = true
        );
        PricebookEntry nrcPbe = new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(),
            Product2Id   = nrcProd.Id,
            UnitPrice    = 500,
            IsActive     = true
        );
        insert new List<PricebookEntry>{ mrcPbe, nrcPbe };

        // Ramp deal Order — Phase 1 + Phase 2 + Phase 3
        Order parentOrder = new Order(
            AccountId      = acc.Id,
            OpportunityId  = opp.Id,
            BillingAccount__c = ban.Id,
            EffectiveDate  = Date.today(),
            Status         = 'Draft',
            Pricebook2Id   = Test.getStandardPricebookId(),
            Is_Ramp_Deal__c = true,
            Ramp_Phases__c  = 3,
            Order_Number__c = 'RAMP-TEST-001-OR-1',
            // Header RDD deliberately differs from every phase start date so the
            // per-phase RDD assertions cannot pass by coincidence.
            RDD__c          = Date.today().addDays(5)
        );
        insert parentOrder;

        List<OrderItem> items = new List<OrderItem>();
        // Phase 1 MRC
        items.add(new OrderItem(
            OrderId          = parentOrder.Id,
            Product2Id       = mrcProd.Id,
            PricebookEntryId = mrcPbe.Id,
            Quantity         = 10,
            UnitPrice        = 100,
            Ramp_Phase__c    = 1,
            Ramp_Start_Date__c = Date.today(),
            Charge_Type__c   = 'MRC',
            Is_Active__c     = true
        ));
        // Phase 1 NRC
        items.add(new OrderItem(
            OrderId          = parentOrder.Id,
            Product2Id       = nrcProd.Id,
            PricebookEntryId = nrcPbe.Id,
            Quantity         = 10,
            UnitPrice        = 500,
            Ramp_Phase__c    = 1,
            Ramp_Start_Date__c = Date.today(),
            Charge_Type__c   = 'NRC',
            Is_Auto_NRC__c   = true,
            Is_Active__c     = true
        ));
        // Phase 2 MRC
        items.add(new OrderItem(
            OrderId          = parentOrder.Id,
            Product2Id       = mrcProd.Id,
            PricebookEntryId = mrcPbe.Id,
            Quantity         = 20,
            UnitPrice        = 100,
            Ramp_Phase__c    = 2,
            Ramp_Start_Date__c = Date.today().addMonths(1),
            Charge_Type__c   = 'MRC',
            Is_Active__c     = true
        ));
        // Phase 2 NRC
        items.add(new OrderItem(
            OrderId          = parentOrder.Id,
            Product2Id       = nrcProd.Id,
            PricebookEntryId = nrcPbe.Id,
            Quantity         = 20,
            UnitPrice        = 500,
            Ramp_Phase__c    = 2,
            Ramp_Start_Date__c = Date.today().addMonths(1),
            Charge_Type__c   = 'NRC',
            Is_Auto_NRC__c   = true,
            Is_Active__c     = true
        ));
        // Phase 3 MRC
        items.add(new OrderItem(
            OrderId          = parentOrder.Id,
            Product2Id       = mrcProd.Id,
            PricebookEntryId = mrcPbe.Id,
            Quantity         = 30,
            UnitPrice        = 100,
            Ramp_Phase__c    = 3,
            Ramp_Start_Date__c = Date.today().addMonths(2),
            Charge_Type__c   = 'MRC',
            Is_Active__c     = true
        ));
        insert items;
    }

    @IsTest
    static void splitRampOrder_createsChildOrders() {
        Order parentOrder = [SELECT Id, Order_Number__c FROM Order LIMIT 1];

        Test.startTest();
        RampOrderService.Request req = new RampOrderService.Request();
        req.orderId = parentOrder.Id;
        RampOrderService.splitRampOrder(new List<RampOrderService.Request>{ req });
        Test.stopTest();

        // Parent + 2 child Orders (Phase 2 + Phase 3)
        List<Order> allOrders = [SELECT Id, Parent_Order__c, Order_Number__c, Is_Ramp_Deal__c FROM Order ORDER BY Order_Number__c];
        System.assertEquals(3, allOrders.size(), 'Should have 3 Orders (parent + 2 phases)');

        // Parent retains Phase 1 items only
        List<OrderItem> parentItems = [SELECT Id, Ramp_Phase__c FROM OrderItem WHERE OrderId = :parentOrder.Id];
        System.assertEquals(2, parentItems.size(), 'Parent should have 2 items (Phase 1 MRC + NRC)');
        for (OrderItem oi : parentItems) {
            System.assertEquals(1, Integer.valueOf(oi.Ramp_Phase__c), 'All parent items should be Phase 1');
        }

        // Child Orders
        List<Order> childOrders = [SELECT Id, Parent_Order__c, Order_Number__c FROM Order WHERE Parent_Order__c = :parentOrder.Id ORDER BY Order_Number__c];
        System.assertEquals(2, childOrders.size(), 'Should have 2 child Orders');
        // RampOrderService names child Orders "<original>-RO<phase>" (not "-P<phase>").
        System.assert(childOrders[0].Order_Number__c.endsWith('-RO2'), 'First child should be Phase 2');
        System.assert(childOrders[1].Order_Number__c.endsWith('-RO3'), 'Second child should be Phase 3');

        // Phase 2 child has 2 items (MRC + NRC)
        List<OrderItem> p2Items = [SELECT Id, Ramp_Phase__c, Quantity FROM OrderItem WHERE OrderId = :childOrders[0].Id];
        System.assertEquals(2, p2Items.size(), 'Phase 2 child should have 2 items');

        // Phase 3 child has 1 item (MRC only)
        List<OrderItem> p3Items = [SELECT Id, Ramp_Phase__c, Quantity FROM OrderItem WHERE OrderId = :childOrders[1].Id];
        System.assertEquals(1, p3Items.size(), 'Phase 3 child should have 1 item');
        System.assertEquals(30, p3Items[0].Quantity, 'Phase 3 Qty should be 30');
    }

    @IsTest
    static void splitRampOrder_nonRampDealSkipped() {
        Order parentOrder = [SELECT Id FROM Order LIMIT 1];

        // Remove phase 2+ items so the service detects no ramp phases
        delete [SELECT Id FROM OrderItem WHERE OrderId = :parentOrder.Id AND Ramp_Phase__c > 1];

        Test.startTest();
        RampOrderService.Request req = new RampOrderService.Request();
        req.orderId = parentOrder.Id;
        RampOrderService.splitRampOrder(new List<RampOrderService.Request>{ req });
        Test.stopTest();

        List<Order> allOrders = [SELECT Id FROM Order];
        System.assertEquals(1, allOrders.size(), 'Order with no ramp phases should not create child Orders');
    }

    @IsTest
    static void splitRampOrder_nullInput() {
        Test.startTest();
        RampOrderService.splitRampOrder(null);
        RampOrderService.splitRampOrder(new List<RampOrderService.Request>());
        Test.stopTest();
        // No exception = pass
    }

    @IsTest
    static void splitRampOrder_nrcPairingOnChildOrders() {
        Order parentOrder = [SELECT Id FROM Order LIMIT 1];

        Test.startTest();
        RampOrderService.Request req = new RampOrderService.Request();
        req.orderId = parentOrder.Id;
        RampOrderService.splitRampOrder(new List<RampOrderService.Request>{ req });
        Test.stopTest();

        // Phase 2 child should have NRC item paired to its MRC item
        Order p2Child = [SELECT Id FROM Order WHERE Parent_Order__c = :parentOrder.Id AND Order_Number__c LIKE '%-RO2' LIMIT 1];
        List<OrderItem> p2Nrc = [SELECT Id, Paired_MRC_OrderItem__c FROM OrderItem WHERE OrderId = :p2Child.Id AND Is_Auto_NRC__c = true];
        if (!p2Nrc.isEmpty()) {
            System.assertNotEquals(null, p2Nrc[0].Paired_MRC_OrderItem__c, 'NRC item on Phase 2 child should be paired to its MRC item');
        }
    }

    @IsTest
    static void splitRampOrder_phaseRddFromPhaseStart() {
        Order parentOrder = [SELECT Id FROM Order LIMIT 1];

        Test.startTest();
        RampOrderService.Request req = new RampOrderService.Request();
        req.orderId = parentOrder.Id;
        RampOrderService.splitRampOrder(new List<RampOrderService.Request>{ req });
        Test.stopTest();

        // Each phase order's RDD must equal that phase's Ramp_Start_Date__c,
        // not the header RDD stamped from the quote.
        Order p1 = [SELECT RDD__c FROM Order WHERE Id = :parentOrder.Id];
        System.assertEquals(Date.today(), p1.RDD__c, 'Phase 1 RDD should be the phase 1 start date');

        List<Order> childOrders = [SELECT Order_Number__c, RDD__c FROM Order WHERE Parent_Order__c = :parentOrder.Id ORDER BY Order_Number__c];
        System.assertEquals(2, childOrders.size(), 'Should have 2 child Orders');
        System.assertEquals(Date.today().addMonths(1), childOrders[0].RDD__c, 'Phase 2 RDD should be the phase 2 start date');
        System.assertEquals(Date.today().addMonths(2), childOrders[1].RDD__c, 'Phase 3 RDD should be the phase 3 start date');
    }
}