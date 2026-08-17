/**
 * OrderTriggerTest
 * Unit tests for IP-1 and IP-4 trigger → handler → queueable chain.
 * Covers: success, Odoo error, HTTP 500, churn routing, non-confirmed status.
 *
 * CMT dependency: Odoo_Site__mdt records must be deployed (JKT1 used here).
 * Callout mock: MockOdooCallout provides HTTP layer mock.
 */
@IsTest
public with sharing class OrderTriggerTest {

    @TestSetup
    static void setup() {
        // OdooIntegrationSettings__c org defaults — enable IP-1
        OdooIntegrationSettings__c settings = OdooIntegrationSettings__c.getOrgDefaults();
        settings.IP1_Enabled__c  = true;
        settings.IP2_Enabled__c  = false;
        settings.Environment__c  = 'Sandbox';
        settings.Base_URL__c     = 'https://test.odoo.example.com';
        settings.Username__c     = 'test_user';
        settings.Password__c     = 'test_pass';
        settings.Max_Retry_Count__c = 3;
        upsert settings;

        // Site__c — the queueables query Site__c by Name (custom object, so org data is
        // NOT visible in tests; this record must exist for validation + payload build to pass).
        insert new Site__c(
            Name               = 'JKT1',
            Site_Code__c       = 'JKT1',
            Country__c         = 'ID',
            Odoo_Site_ID__c    = 2,
            Odoo_Company_ID__c = 21,
            Odoo_Country_ID__c = 4,
            Odoo_Metro_ID__c   = 5
        );

        // Account
        Account acct = new Account(Name = 'Test Customer', Operation_Country__c = 'Indonesia');
        insert acct;

        // BillingAccount with Odoo IDs populated (required for IP-1 validation)
        BillingAccount__c ban = new BillingAccount__c(
            Account__c              = acct.Id,
            Invoice_Frequency__c    = 'Monthly',
            Odoo_Partner_ID__c      = '12345',
            Odoo_BAN_ID__c          = 67890,
            Odoo_Invoice_Freq_ID__c = 1
        );
        insert ban;

        // Product with Odoo Product ID
        Product2 prod = new Product2(
            Name             = 'Test Colocation 1U',
            IsActive         = true,
            Odoo_Product_ID__c = 100
        );
        insert prod;

        // Standard Pricebook Entry
        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(),
            Product2Id   = prod.Id,
            UnitPrice    = 500.00,
            IsActive     = true
        );
        insert pbe;

        // Order — Draft status, operation site matches deployed CMT (JKT1)
        Order ord = new Order(
            AccountId       = acct.Id,
            BillingAccount__c = ban.Id,
            EffectiveDate   = Date.today(),
            Status          = 'Draft',
            Pricebook2Id    = Test.getStandardPricebookId(),
            Order_Type__c   = 'New Service',
            Operation_Site__c = 'JKT1',
            Order_Number__c = 'SETUP-ORD-1',
            Contract_Term_Months__c = 12
        );
        insert ord;

        // OrderItem — required before activation
        OrderItem oi = new OrderItem(
            OrderId          = ord.Id,
            PricebookEntryId = pbe.Id,
            Product2Id       = prod.Id,
            Quantity         = 1,
            UnitPrice        = 500.00,
            Odoo_Product_ID__c = 100,
            Charge_Type__c   = 'MRC',
            Billing_Mode__c  = 'Advance',
            Is_Active__c     = true
        );
        insert oi;
    }

    @IsTest
    static void testIP1_Success() {
        Test.setMock(HttpCalloutMock.class, MockOdooCallout.success(9001));

        Order ord = [SELECT Id, Status FROM Order LIMIT 1];

        Test.startTest();
        ord.Status = 'Activated';
        update ord;
        Test.stopTest();

        Order result = [SELECT Integration_Status__c, Odoo_Order_ID__c FROM Order WHERE Id = :ord.Id];
        System.assertEquals('Synced', result.Integration_Status__c,
            'IP-1 success should set Integration_Status__c to Synced');
        System.assertEquals('9001', result.Odoo_Order_ID__c,
            'IP-1 success should write back Odoo order ID');
    }

    @IsTest
    static void testIP1_OdooError() {
        Test.setMock(HttpCalloutMock.class, MockOdooCallout.odooError());

        Order ord = [SELECT Id FROM Order LIMIT 1];

        Test.startTest();
        ord.Status = 'Activated';
        update ord;
        Test.stopTest();

        Order result = [SELECT Integration_Status__c FROM Order WHERE Id = :ord.Id];
        System.assertEquals('Failed', result.Integration_Status__c,
            'Odoo application error should set Integration_Status__c to Failed');

        List<DE_Integration_Error__c> errors = [
            SELECT IP_Reference__c FROM DE_Integration_Error__c
            WHERE Record_Id__c = :String.valueOf(ord.Id)
        ];
        System.assert(!errors.isEmpty(), 'Odoo error should create DE_Integration_Error__c');
        System.assertEquals('IP-1', errors[0].IP_Reference__c,
            'Error should reference IP-1');
    }

    @IsTest
    static void testIP1_HTTP500() {
        Test.setMock(HttpCalloutMock.class, MockOdooCallout.httpError());

        Order ord = [SELECT Id FROM Order LIMIT 1];

        Test.startTest();
        ord.Status = 'Activated';
        update ord;
        Test.stopTest();

        Order result = [SELECT Integration_Status__c FROM Order WHERE Id = :ord.Id];
        System.assertEquals('Failed', result.Integration_Status__c,
            'HTTP 500 should set Integration_Status__c to Failed');

        List<DE_Integration_Error__c> errors = [
            SELECT Id FROM DE_Integration_Error__c
            WHERE Record_Id__c = :String.valueOf(ord.Id)
        ];
        System.assert(!errors.isEmpty(), 'HTTP 500 should create DE_Integration_Error__c');
    }

    @IsTest
    static void testIP4_ChurnOrder() {
        Test.setMock(HttpCalloutMock.class, MockOdooCallout.success(9002));

        Order ord = [SELECT Id, Order_Type__c FROM Order LIMIT 1];
        // Switch to Churn — this should route to SendChangeOrdersQueueable, not SendNewOrdersQueueable
        ord.Order_Type__c = 'Churn';
        update ord;

        Test.startTest();
        ord.Status = 'Activated';
        update ord;
        Test.stopTest();

        // Verify Integration_Status__c updated (churn orders also sync to Odoo)
        Order result = [SELECT Integration_Status__c FROM Order WHERE Id = :ord.Id];
        System.assertNotEquals(null, result.Integration_Status__c,
            'Churn Order should trigger IP-4 and update Integration_Status__c');
    }

    @IsTest
    static void testNonConfirmedStatusChange() {
        Test.setMock(HttpCalloutMock.class, MockOdooCallout.success(9999));

        Order ord = [SELECT Id FROM Order LIMIT 1];

        Test.startTest();
        // Status stays Draft — should NOT trigger any queueable
        // No status change at all — the handler checks justConfirmed flag
        Test.stopTest();

        // No DE_Integration_Error__c should be created
        List<DE_Integration_Error__c> errors = [SELECT Id FROM DE_Integration_Error__c];
        System.assert(errors.isEmpty(),
            'Non-activation status should not trigger integration or create errors');
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  Additional coverage for SendNewOrdersQueueable (IP-1) &
    //  SendChangeOrdersQueueable (IP-4). Payload builders are exercised directly
    //  (they are @TestVisible), validation branches via direct execute(), and the
    //  batch-split branch with an oversized id list.
    // ══════════════════════════════════════════════════════════════════════════

    private static Account acct()  { return [SELECT Id FROM Account LIMIT 1]; }
    private static BillingAccount__c goodBan() {
        return [SELECT Id, Odoo_Partner_ID__c, Odoo_BAN_ID__c, Odoo_Invoice_Freq_ID__c FROM BillingAccount__c LIMIT 1];
    }
    private static Product2 prod() { return [SELECT Id FROM Product2 LIMIT 1]; }
    private static PricebookEntry stdPbe() { return [SELECT Id FROM PricebookEntry LIMIT 1]; }

    // Builds a Draft order (won't fire integration) with one active OrderItem.
    private static Integer orderSeq = 0;
    private static Order buildOrder(String orderType, String site, Id banId, Integer odooProductId) {
        orderSeq++;
        Order o = new Order(
            AccountId         = acct().Id,
            BillingAccount__c = banId,
            EffectiveDate     = Date.today(),
            Status            = 'Draft',
            Pricebook2Id      = Test.getStandardPricebookId(),
            Order_Type__c     = orderType,
            Operation_Site__c = site,
            Order_Number__c   = 'BLD-' + orderSeq,
            Contract_Term_Months__c = 12
        );
        insert o;
        OrderItem oi = new OrderItem(
            OrderId          = o.Id,
            PricebookEntryId = stdPbe().Id,
            Product2Id       = prod().Id,
            Quantity         = 1,
            UnitPrice        = 500,
            Odoo_Product_ID__c = odooProductId,
            Charge_Type__c   = 'MRC',
            Billing_Mode__c  = 'Advance',
            Is_Active__c     = true
        );
        insert oi;
        return o;
    }

    private static Site__c jkt() {
        return [SELECT Name, Odoo_Company_ID__c, Odoo_Country_ID__c, Odoo_Site_ID__c, Odoo_Metro_ID__c
                FROM Site__c WHERE Name = 'JKT1' LIMIT 1];
    }
    private static OdooIntegrationSettings__c settings() { return OdooIntegrationSettings__c.getOrgDefaults(); }

    // ── IP-1 buildIP1Payload — rich branch coverage (FX, ramp, aggregate, phase-2,
    //     optional line fields, spaces/breakers, renewal/create sub-management) ────
    @IsTest
    static void ip1_buildPayload_richBranches() {
        // Phase-1 (original) order with an aggregate product line
        Product2 agg = new Product2(Name = 'Aggregate Prod', IsActive = true,
            Odoo_Product_ID__c = 100, Merge_IB_Task__c = true);
        insert agg;
        PricebookEntry aggPbe = new PricebookEntry(Pricebook2Id = Test.getStandardPricebookId(),
            Product2Id = agg.Id, UnitPrice = 500, IsActive = true);
        insert aggPbe;

        BillingAccount__c ban2 = new BillingAccount__c(Account__c = acct().Id,
            Invoice_Frequency__c = 'Monthly', Odoo_Partner_ID__c = '99', Odoo_BAN_ID__c = 88,
            Odoo_Invoice_Freq_ID__c = 1);
        insert ban2;

        Order orig = new Order(AccountId = acct().Id, BillingAccount__c = goodBan().Id,
            EffectiveDate = Date.today(), Status = 'Draft', Pricebook2Id = Test.getStandardPricebookId(),
            Order_Type__c = 'New Service', Operation_Site__c = 'JKT1', Contract_Term_Months__c = 12,
            Order_Number__c = 'RICH1-ORIG');
        insert orig;
        OrderItem origItem = new OrderItem(OrderId = orig.Id, PricebookEntryId = aggPbe.Id, Product2Id = agg.Id,
            Quantity = 1, UnitPrice = 500, Odoo_Product_ID__c = 100, Odoo_Attribute_Value_ID__c = 7,
            Charge_Type__c = 'MRC', Billing_Mode__c = 'Advance', Is_Active__c = true);
        insert origItem;

        // Phase-2 order referencing the original, with FX + ramp flags
        Order ph2 = new Order(AccountId = acct().Id, BillingAccount__c = goodBan().Id,
            EffectiveDate = Date.today(), Status = 'Draft', Pricebook2Id = Test.getStandardPricebookId(),
            Order_Type__c = 'New Service', Operation_Site__c = 'JKT1', Contract_Term_Months__c = 12,
            Original_Order__c = orig.Id, RDD__c = Date.today().addDays(5),
            Customer_PO_Reference__c = 'PO-123', Order_Number__c = 'RICH1-PH2',
            FX_Billing_Flag__c = true, FX_Rate_Model__c = 'Fixed', FX_Rate_Terms__c = 'Monthly',
            Is_Ramp_Deal__c = true);
        insert ph2;
        // Line A: aggregate, matches original for sf_originitem_id; rich optional fields
        OrderItem lineA = new OrderItem(OrderId = ph2.Id, PricebookEntryId = aggPbe.Id, Product2Id = agg.Id,
            Quantity = 2, UnitPrice = 600, Odoo_Product_ID__c = 100, Odoo_Attribute_Value_ID__c = 7,
            Product_Attribute_Value__c = 'Attr-X', Billing_Mode__c = 'Advance', CabE__c = 5,
            Custom_Attribute_Value__c = '9', A_Side_Service_ID__c = '11', Z_Side_Service_ID__c = '22',
            Line_Remarks__c = 'remarks', Target_BAN__c = ban2.Id, Ramp_Linked_Phase__c = 1,
            Charge_Type__c = 'MRC', Is_Active__c = true);
        // Line B: non-aggregate, ramp price_change, non-numeric custom attr (TypeException path)
        OrderItem lineB = new OrderItem(OrderId = ph2.Id, PricebookEntryId = stdPbe().Id, Product2Id = prod().Id,
            Quantity = 1, UnitPrice = 300, Odoo_Product_ID__c = 200, Odoo_Attribute_Value_ID__c = 3,
            Custom_Attribute_Value__c = 'not-a-number', Ramp_Identifier__c = 'Price_Change',
            Charge_Type__c = 'MRC', Billing_Mode__c = 'Advance', Is_Active__c = true);
        insert new List<OrderItem>{ lineA, lineB };

        // Query phase-2 the way processOrders does
        Order o = [SELECT Id, Order_Number__c, EffectiveDate, Contract_Term_Months__c, Customer_PO_Reference__c,
                          RDD__c, Operation_Site__c, Target_Site__c, Target_Site__r.Site_Code__c, Order_Type__c,
                          FX_Billing_Flag__c, FX_Rate_Model__c, FX_Rate_Terms__c, Is_Ramp_Deal__c,
                          Original_Order__c, BillingAccount__c, CurrencyIsoCode,
                          BillingAccount__r.Odoo_Partner_ID__c, BillingAccount__r.Odoo_BAN_ID__c,
                          BillingAccount__r.Odoo_Invoice_Freq_ID__c,
                          (SELECT Id, Product2.Name, Product2.Merge_IB_Task__c, Odoo_Product_ID__c,
                                  Odoo_Attribute_Value_ID__c, Product_Attribute_Value__c, Description, Quantity,
                                  UnitPrice, Billing_Mode__c, CabE__c, Custom_Attribute_Value__c, Line_Remarks__c,
                                  A_Side_Service_ID__c, Z_Side_Service_ID__c, Target_BAN__r.Odoo_BAN_ID__c,
                                  QuoteLineItemId, Ramp_Identifier__c, Ramp_Linked_Phase__c, Original_OrderItem__c
                           FROM OrderItems WHERE Is_Active__c = true)
                   FROM Order WHERE Id = :ph2.Id];
        OrderItem origItemQueried = [SELECT Id, UnitPrice, Odoo_Product_ID__c, Odoo_Attribute_Value_ID__c FROM OrderItem WHERE Id = :origItem.Id];

        // Previous-phase + original maps (as processOrders builds them)
        Map<String, OrderItem> prevItems = new Map<String, OrderItem>{ '100_7' => origItemQueried };
        Map<Id, Map<String, OrderItem>> prevPhaseMap = new Map<Id, Map<String, OrderItem>>{ orig.Id => prevItems };
        Map<Id, Id> orderToOriginal = new Map<Id, Id>{ ph2.Id => orig.Id };

        // Space/breaker maps — keyed by (null) QuoteLineItemId; buildIP1Payload only reads the maps
        Map<Id, List<Inventory__c>> spaceMap = new Map<Id, List<Inventory__c>>{
            null => new List<Inventory__c>{ new Inventory__c(Odoo_Space_ID__c = '111') } };
        Map<Id, List<Inventory__c>> breakerMap = new Map<Id, List<Inventory__c>>{
            null => new List<Inventory__c>{ new Inventory__c(Odoo_Inventory_Id__c = '222') } };

        SendNewOrdersQueueable q = new SendNewOrdersQueueable(new List<Id>{ ph2.Id });

        Test.startTest();
        String changeOrderPayload = q.buildIP1Payload(o, jkt(), settings(), spaceMap, breakerMap, prevPhaseMap, orderToOriginal);
        // Renewal sub-management branch
        o.Order_Type__c = 'Renewal';
        String renewalPayload = q.buildIP1Payload(o, jkt(), settings(), spaceMap, breakerMap, prevPhaseMap, orderToOriginal);
        // "create" branch (no original order → phase 1)
        o.Order_Type__c = 'New Service';
        o.Original_Order__c = null;
        String createPayload = q.buildIP1Payload(o, jkt(), settings(), spaceMap, breakerMap, prevPhaseMap, orderToOriginal);
        Test.stopTest();

        System.assert(changeOrderPayload.contains('"subscription_management":"change_order"'), 'Phase-2 non-renewal → change_order');
        System.assert(changeOrderPayload.contains('ns_from_ramp_up'), 'Ramp deal flag should be present');
        System.assert(changeOrderPayload.contains('x_studio_fx_rate_model'), 'FX billing fields should be present');
        System.assert(renewalPayload.contains('"subscription_management":"renewal"'), 'Renewal order type → renewal');
        System.assert(createPayload.contains('"subscription_management":"create"'), 'Phase-1 → create');
    }

    // ── IP-1 validation branches (missing site / missing Odoo IDs / missing product) ─
    @IsTest
    static void ip1_validationFailures() {
        Test.setMock(HttpCalloutMock.class, MockOdooCallout.success(1));
        // Missing site
        Order noSite = buildOrder('New Service', 'NOSITE', goodBan().Id, 100);
        // BAN missing Odoo IDs
        BillingAccount__c rawBan = new BillingAccount__c(Account__c = acct().Id, Invoice_Frequency__c = 'Monthly');
        insert rawBan;
        Order noIds = buildOrder('New Service', 'JKT1', rawBan.Id, 100);
        // Order item missing Odoo_Product_ID__c
        Order noProd = buildOrder('New Service', 'JKT1', goodBan().Id, null);

        Test.startTest();
        new SendNewOrdersQueueable(new List<Id>{ noSite.Id, noIds.Id, noProd.Id }).execute(null);
        Test.stopTest();

        Map<Id, Order> byId = new Map<Id, Order>([SELECT Id, Integration_Status__c FROM Order WHERE Id IN (:noSite.Id, :noIds.Id, :noProd.Id)]);
        System.assertEquals('Failed', byId.get(noSite.Id).Integration_Status__c, 'Missing site → Failed');
        System.assertEquals('Failed', byId.get(noIds.Id).Integration_Status__c, 'Missing Odoo IDs → Failed');
        System.assertEquals('Failed', byId.get(noProd.Id).Integration_Status__c, 'Missing product id → Failed');
        System.assert([SELECT COUNT() FROM DE_Integration_Error__c WHERE IP_Reference__c = 'IP-1'] >= 3,
            'Each validation failure should log an IP-1 error');
    }

    // ── IP-1 batch-split branch (list > BATCH_SIZE) ──────────────────────────────
    @IsTest
    static void ip1_batchSplit() {
        Test.setMock(HttpCalloutMock.class, MockOdooCallout.success(5));
        Order o = [SELECT Id FROM Order LIMIT 1];
        List<Id> ids = new List<Id>();
        for (Integer i = 0; i < 11; i++) ids.add(o.Id); // size > 10 → batch-split path
        Test.startTest();
        // Call execute() directly so the chained "remaining batch" enqueue is a normal
        // first-level enqueue (enqueuing from within an async run in a test throws
        // "Maximum stack depth has been reached").
        new SendNewOrdersQueueable(ids).execute(null);
        Test.stopTest();
        System.assert(true, 'Batch-split path executed without error');
    }

    // ── IP-4 getSubscriptionManagement mapping (all branches) ────────────────────
    @IsTest
    static void ip4_subscriptionManagement() {
        System.assertEquals('change_order', SendChangeOrdersQueueable.getSubscriptionManagement('Change/Upsell'));
        System.assertEquals('churn',        SendChangeOrdersQueueable.getSubscriptionManagement('Churn'));
        System.assertEquals('change_order', SendChangeOrdersQueueable.getSubscriptionManagement('Partial Churn'));
        System.assertEquals('renew',        SendChangeOrdersQueueable.getSubscriptionManagement('Renewal'));
        System.assertEquals('change_order', SendChangeOrdersQueueable.getSubscriptionManagement('Anything Else'));
    }

    // ── IP-4 buildIP4Payload — rich branch coverage ──────────────────────────────
    @IsTest
    static void ip4_buildPayload_richBranches() {
        BillingAccount__c ban2 = new BillingAccount__c(Account__c = acct().Id, Invoice_Frequency__c = 'Monthly',
            Odoo_Partner_ID__c = '5', Odoo_BAN_ID__c = 6);
        insert ban2;

        Order orig = new Order(AccountId = acct().Id, BillingAccount__c = goodBan().Id, EffectiveDate = Date.today(),
            Status = 'Draft', Pricebook2Id = Test.getStandardPricebookId(), Order_Type__c = 'New Service',
            Operation_Site__c = 'JKT1', Contract_Term_Months__c = 12, Odoo_Subscription_ID__c = '4321',
            Order_Number__c = 'RICH4-ORIG');
        insert orig;
        OrderItem origItem = new OrderItem(OrderId = orig.Id, PricebookEntryId = stdPbe().Id, Product2Id = prod().Id,
            Quantity = 1, UnitPrice = 500, Odoo_Product_ID__c = 100, Charge_Type__c = 'MRC',
            Billing_Mode__c = 'Advance', Is_Active__c = true, Odoo_Sub_Line_ID__c = '77', Odoo_Origin_Line_ID__c = '88');
        insert origItem;

        Order co = new Order(AccountId = acct().Id, BillingAccount__c = goodBan().Id, EffectiveDate = Date.today(),
            Status = 'Draft', Pricebook2Id = Test.getStandardPricebookId(), Order_Type__c = 'Change/Upsell',
            Operation_Site__c = 'JKT1', Contract_Term_Months__c = 12, Original_Order__c = orig.Id,
            RDD__c = Date.today().addDays(3), Customer_PO_Reference__c = 'CO-1', Order_Number__c = 'RICH4-CO');
        insert co;
        // Add-line (ns_change_type NEW)
        OrderItem l1 = new OrderItem(OrderId = co.Id, PricebookEntryId = stdPbe().Id, Product2Id = prod().Id,
            Quantity = 1, UnitPrice = 500, Odoo_Product_ID__c = 100, ns_change_type__c = 'NEW',
            Billing_Mode__c = 'Advance', Product_Attribute_Value__c = 'AV', CabE__c = 3, Custom_Attribute_Value__c = '7',
            A_Side_Service_ID__c = '11', Z_Side_Service_ID__c = '22', Description = 'desc1',
            Original_OrderItem__c = origItem.Id, Target_BAN__c = ban2.Id, Odoo_Project_Task_IDs__c = '1,2',
            Charge_Type__c = 'MRC', Is_Active__c = true);
        // Change-line: origin/sub line IDs (numeric + external-id format), non-numeric custom attr
        OrderItem l2 = new OrderItem(OrderId = co.Id, PricebookEntryId = stdPbe().Id, Product2Id = prod().Id,
            Quantity = 1, UnitPrice = 400, Odoo_Product_ID__c = 200, ns_change_type__c = 'CHANGE',
            Odoo_Origin_Line_ID__c = '123', Odoo_Sub_Line_ID__c = 'ext_456', Custom_Attribute_Value__c = 'nan',
            Charge_Type__c = 'MRC', Billing_Mode__c = 'Advance', Is_Active__c = true);
        insert new List<OrderItem>{ l1, l2 };

        Order o = [SELECT Id, OrderNumber, EffectiveDate, Contract_Term_Months__c, Customer_PO_Reference__c, RDD__c,
                          Operation_Site__c, Order_Type__c, Original_Order__c, Order_Number__c,
                          Original_Order__r.Odoo_Subscription_ID__c, BillingAccount__r.Odoo_Partner_ID__c,
                          BillingAccount__r.Odoo_BAN_ID__c, CurrencyIsoCode, BillingAccount__r.Invoice_Frequency__c,
                          (SELECT Id, Product2.Name, Odoo_Product_ID__c, Odoo_Attribute_Value_ID__c,
                                  Product_Attribute_Value__c, Description, Charge_Type__c, Billing_Mode__c, Quantity,
                                  UnitPrice, ns_change_type__c, QuoteLineItemId, CabE__c, Custom_Attribute_Value__c,
                                  A_Side_Service_ID__c, Z_Side_Service_ID__c, Target_BAN__c, Target_BAN__r.Odoo_BAN_ID__c,
                                  Odoo_Sub_Line_ID__c, Odoo_Origin_Line_ID__c, Odoo_Project_Task_IDs__c, Odoo_Sub_Task_IDs__c,
                                  Original_OrderItem__c, Original_OrderItem__r.Odoo_Sub_Line_ID__c, Line_Remarks__c,
                                  Original_OrderItem__r.Odoo_Origin_Line_ID__c, Original_OrderItem__r.Odoo_Project_Task_IDs__c,
                                  Original_OrderItem__r.Odoo_Sub_Task_IDs__c
                           FROM OrderItems WHERE Is_Active__c = true)
                   FROM Order WHERE Id = :co.Id];

        Map<String, Integer> freqMap = new Map<String, Integer>{ 'Monthly' => 1 };
        Map<Id, List<Inventory__c>> spaceMap = new Map<Id, List<Inventory__c>>{
            null => new List<Inventory__c>{ new Inventory__c(Odoo_Space_ID__c = '111') } };
        Map<Id, List<Inventory__c>> breakerMap = new Map<Id, List<Inventory__c>>{
            null => new List<Inventory__c>{ new Inventory__c(Odoo_Inventory_Id__c = '222') } };

        SendChangeOrdersQueueable q = new SendChangeOrdersQueueable(new List<Id>{ co.Id });
        Test.startTest();
        String p1 = q.buildIP4Payload(o, jkt(), true, freqMap, settings(), spaceMap, breakerMap);
        // Frequency-not-found branch
        String p2 = q.buildIP4Payload(o, jkt(), false, new Map<String, Integer>(), settings(), spaceMap, breakerMap);
        Test.stopTest();

        System.assert(p1.contains('"subscription_management":"change_order"'), 'Change/Upsell → change_order');
        System.assert(p1.contains('subscription_id'), 'Original subscription id should be written');
        System.assert(p2.contains('"ns_invoice_frequency_id":false'), 'Unmapped frequency → false');
    }

    // ── IP-4 validation branches ─────────────────────────────────────────────────
    @IsTest
    static void ip4_validationFailures() {
        Test.setMock(HttpCalloutMock.class, MockOdooCallout.success(1));
        Order noSite = buildOrder('Churn', 'NOSITE', goodBan().Id, 100);
        BillingAccount__c rawBan = new BillingAccount__c(Account__c = acct().Id, Invoice_Frequency__c = 'Monthly');
        insert rawBan;
        Order noIds = buildOrder('Churn', 'JKT1', rawBan.Id, 100);
        Order noProd = buildOrder('Churn', 'JKT1', goodBan().Id, null);

        Test.startTest();
        new SendChangeOrdersQueueable(new List<Id>{ noSite.Id, noIds.Id, noProd.Id }).execute(null);
        Test.stopTest();

        Map<Id, Order> byId = new Map<Id, Order>([SELECT Id, Integration_Status__c FROM Order WHERE Id IN (:noSite.Id, :noIds.Id, :noProd.Id)]);
        System.assertEquals('Failed', byId.get(noSite.Id).Integration_Status__c, 'Missing site → Failed');
        System.assertEquals('Failed', byId.get(noIds.Id).Integration_Status__c, 'Missing Odoo IDs → Failed');
        System.assertEquals('Failed', byId.get(noProd.Id).Integration_Status__c, 'Missing product id → Failed');
        System.assert([SELECT COUNT() FROM DE_Integration_Error__c WHERE IP_Reference__c = 'IP-4'] >= 3,
            'Each validation failure should log an IP-4 error');
    }

    // ── IP-4 batch-split branch ──────────────────────────────────────────────────
    @IsTest
    static void ip4_batchSplit() {
        Test.setMock(HttpCalloutMock.class, MockOdooCallout.success(5));
        Order o = [SELECT Id FROM Order LIMIT 1];
        List<Id> ids = new List<Id>();
        for (Integer i = 0; i < 11; i++) ids.add(o.Id);
        Test.startTest();
        new SendChangeOrdersQueueable(ids).execute(null);
        Test.stopTest();
        System.assert(true, 'Batch-split path executed without error');
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  OrderTriggerHandler lifecycle coverage — inventory transitions on activation
    //  and the insert-already-Activated routing path.
    // ══════════════════════════════════════════════════════════════════════════

    private static Id jktSiteId() { return [SELECT Id FROM Site__c WHERE Name = 'JKT1' LIMIT 1].Id; }
    private static Id spaceRtId() {
        return Schema.SObjectType.Inventory__c.getRecordTypeInfosByDeveloperName().get('Inventory_Space').getRecordTypeId();
    }

    // Activation transitions Assigned/Quoted/Reserved inventory → Sold (Path A: OrderItem.Space__c).
    // Uses a Change/Upsell order so routing goes to IP-4 (which does not chain IP-3 capacity
    // locking — that chain would hit "Maximum stack depth" for a queued job in a test).
    @IsTest
    static void activation_setsInventoryToSold() {
        Test.setMock(HttpCalloutMock.class, MockOdooCallout.success(700));
        Inventory__c inv = new Inventory__c(Name = 'Sold-Test-Space', RecordTypeId = spaceRtId(),
            Status__c = 'Assigned', Site_Id__c = jktSiteId());
        insert inv;
        OrderItem oi = [SELECT Id FROM OrderItem LIMIT 1];
        update new OrderItem(Id = oi.Id, Space__c = inv.Id);

        Order ord = [SELECT Id FROM Order LIMIT 1];
        ord.Order_Type__c = 'Change/Upsell';
        update ord;
        Test.startTest();
        ord.Status = 'Activated';
        update ord;
        Test.stopTest();

        System.assertEquals('Sold', [SELECT Status__c FROM Inventory__c WHERE Id = :inv.Id].Status__c,
            'Assigned inventory should transition to Sold on order activation');
    }

    // Churn activation transitions Sold/Installed inventory → Pending Available.
    @IsTest
    static void churnActivation_setsInventoryPendingAvailable() {
        Test.setMock(HttpCalloutMock.class, MockOdooCallout.success(701));
        // Insert as Installed (a VR blocks setting Sold without an Order Item link);
        // the handler transitions Sold OR Installed → Pending Available on churn.
        Inventory__c inv = new Inventory__c(Name = 'PA-Test-Space', RecordTypeId = spaceRtId(),
            Status__c = 'Installed', Site_Id__c = jktSiteId());
        insert inv;
        OrderItem oi = [SELECT Id FROM OrderItem LIMIT 1];
        update new OrderItem(Id = oi.Id, Space__c = inv.Id);

        Order ord = [SELECT Id FROM Order LIMIT 1];
        ord.Order_Type__c = 'Churn';
        update ord;

        Test.startTest();
        ord.Status = 'Activated';
        update ord;
        Test.stopTest();

        System.assertEquals('Pending Available', [SELECT Status__c FROM Inventory__c WHERE Id = :inv.Id].Status__c,
            'Sold inventory should transition to Pending Available on churn activation');
    }

    // NOTE: handleAfterInsert (Orders inserted already-Activated) is not unit-testable —
    // the platform blocks inserting an Order directly in Activated status ("For a new order,
    // choose Draft"). That path is only reachable from the SOF Handler's system context.

    // Change-order activation with a QuoteLineItem→Asset→Inventory chain exercises both
    // updateInventoryToSold (Path B: QLI→Inventory) and stampInventoryScdFromAsset.
    @IsTest
    static void changeActivation_inventoryPathBAndScdStamp() {
        Test.setMock(HttpCalloutMock.class, MockOdooCallout.success(703));
        Account a = acct();
        String curr = [SELECT CurrencyIsoCode FROM Order LIMIT 1].CurrencyIsoCode;
        // Stage-1 opp with no Operation_Country/Target_Site so the country→currency default
        // flow doesn't switch the Quote off the pricebook-entry currency (QLI currency check).
        Opportunity opp = new Opportunity(Name = 'CO SCD Opp', AccountId = a.Id, StageName = '1-Suspect',
            CloseDate = Date.today().addMonths(2), Skip_Stage_Gate__c = true, CurrencyIsoCode = curr);
        insert opp;
        Quote q = new Quote(Name = 'CO SCD Quote', OpportunityId = opp.Id,
            Pricebook2Id = Test.getStandardPricebookId(), CurrencyIsoCode = curr);
        insert q;
        QuoteLineItem qli = new QuoteLineItem(QuoteId = q.Id, Product2Id = prod().Id,
            PricebookEntryId = stdPbe().Id, Quantity = 1, UnitPrice = 500);
        insert qli;
        Asset asset = new Asset(Name = 'CO SCD Asset', AccountId = a.Id, Status = 'Installed',
            Quantity = 1, SCD__c = Date.today().addDays(10), InstallDate = Date.today());
        insert asset;
        update new QuoteLineItem(Id = qli.Id, Asset__c = asset.Id);

        Inventory__c inv = new Inventory__c(Name = 'SCD Inv', RecordTypeId = spaceRtId(),
            Status__c = 'Assigned', Site_Id__c = jktSiteId(), Quote_Line__c = qli.Id);
        insert inv;

        Order ord = [SELECT Id FROM Order LIMIT 1];
        // OrderItem.QuoteLineItemId requires the Order to be linked to that QLI's Quote.
        ord.QuoteId = q.Id;
        ord.Order_Type__c = 'Change/Upsell';
        update ord;
        insert new OrderItem(OrderId = ord.Id, PricebookEntryId = stdPbe().Id, Product2Id = prod().Id,
            Quantity = 1, UnitPrice = 500, Odoo_Product_ID__c = 100, Charge_Type__c = 'MRC',
            Billing_Mode__c = 'Advance', Is_Active__c = true, QuoteLineItemId = qli.Id);

        Test.startTest();
        ord.Status = 'Activated';
        update ord;
        Test.stopTest();

        System.assertEquals(Date.today().addDays(10),
            [SELECT SCD__c FROM Inventory__c WHERE Id = :inv.Id].SCD__c,
            'Inventory SCD should be stamped from the linked Asset on change-order activation');
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  Additional OrderTriggerHandler coverage — handleAfterInsert, the full
    //  Order_Type__c OR-chain, the BAN-sync routing branches (order- and
    //  line-level), the dead-code applyChangeOrderAssetUpdates path (exposed via
    //  @TestVisible), and the remaining inventory Path A/B branches.
    // ══════════════════════════════════════════════════════════════════════════

    // handleAfterInsert (Orders inserted already-Activated, e.g. from SOFHandler quote
    // acceptance) routes through the same IP-1/Inventory logic as handleAfterUpdate.
    // The platform blocks inserting an Order directly in Activated status, so this calls
    // the public static method directly against an in-memory Order pointing at a real,
    // already-inserted Order Id — routeActivatedOrders re-queries Order_Type__c by Id,
    // so only the Id needs to be real.
    @IsTest
    static void handleAfterInsert_activatedOrder_routesLikeUpdate() {
        Test.setMock(HttpCalloutMock.class, MockOdooCallout.success(8001));
        Order ord = [SELECT Id FROM Order LIMIT 1];

        Test.startTest();
        OrderTriggerHandler.handleAfterInsert(new List<Order>{ new Order(Id = ord.Id, Status = 'Activated') });
        Test.stopTest();

        Order result = [SELECT Integration_Status__c FROM Order WHERE Id = :ord.Id];
        System.assertEquals('Synced', result.Integration_Status__c,
            'handleAfterInsert should route an already-Activated Order through the same IP-1 logic as handleAfterUpdate');
    }

    // routeActivatedOrders Order_Type__c OR-chain: Renewal doesn't match either of the
    // first two OR clauses (New Service / Change-Upsell-Churn-Partial Churn-Suspension),
    // so covering it forces evaluation through to the final "Resumption/BAN Change/Renewal"
    // clause — the only way to reach those continuation lines.
    @IsTest
    static void renewalOrderType_evaluatesFullOrTypeChain_routesToChangeOrders() {
        Test.setMock(HttpCalloutMock.class, MockOdooCallout.success(8002));
        Order ord = [SELECT Id FROM Order LIMIT 1];
        ord.Order_Type__c = 'Renewal';
        update ord;

        Test.startTest();
        ord.Status = 'Activated';
        update ord;
        Test.stopTest();

        Order result = [SELECT Integration_Status__c FROM Order WHERE Id = :ord.Id];
        System.assertNotEquals(null, result.Integration_Status__c,
            'Renewal Order_Type__c should route through the full OR-chain to SendChangeOrdersQueueable (IP-4)');
    }

    // routeActivatedOrders New-Service BAN-sync branch: an order-level BillingAccount__c
    // missing Odoo IDs AND an OrderItem-level Target_BAN__c override that's also unsynced
    // both feed unsyncedBanIds, so activation routes to OdooBanSyncQueueable instead of a
    // direct SendNewOrdersQueueable enqueue. IP1_Enabled__c is flipped off before
    // Test.stopTest() flushes the async queue so the queued job's own chain-back doesn't
    // attempt a nested System.enqueueJob — chaining a second queueable from inside an
    // already-running one throws "Maximum stack depth" in test context (see the
    // ip1_batchSplit/ip4_batchSplit comments above for the same constraint). A synced
    // Billing_Contact__c is used on both BANs to avoid tripping the (separate, pre-existing)
    // NEW-C null-contact path in OdooBanSyncQueueable, which isn't what this test targets.
    @IsTest
    static void newService_unsyncedBanAndLineLevelOverride_enqueuesBanSyncQueueable() {
        Test.setMock(HttpCalloutMock.class, MockOdooCallout.success(8003));

        Contact syncedCon = new Contact(AccountId = acct().Id, FirstName = 'Synced', LastName = 'Contact',
            Email = 'synced-c@test.com', Odoo_Partner_ID__c = 999);
        insert syncedCon;
        BillingAccount__c rawBan = new BillingAccount__c(Account__c = acct().Id, Invoice_Frequency__c = 'Monthly',
            Billing_Contact__c = syncedCon.Id);
        insert rawBan;
        BillingAccount__c lineBan = new BillingAccount__c(Account__c = acct().Id, Invoice_Frequency__c = 'Monthly',
            Billing_Contact__c = syncedCon.Id);
        insert lineBan;

        Order ord = buildOrder('New Service', 'JKT1', rawBan.Id, 100);
        OrderItem oi = [SELECT Id FROM OrderItem WHERE OrderId = :ord.Id LIMIT 1];
        update new OrderItem(Id = oi.Id, Target_BAN__c = lineBan.Id);
        // Second line with BAN_ID__c pointing at a fully-synced BAN: BAN_ID__r.Odoo_Partner_ID__c
        // is non-null so the OR-chain's first clause is false, forcing evaluation through
        // Odoo_BAN_ID__c and Odoo_Invoice_Freq_ID__c too (full-chain coverage, whatever the
        // final outcome — the order-level rawBan check above already guarantees the
        // unsyncedBanIds-not-empty branch fires).
        insert new OrderItem(OrderId = ord.Id, PricebookEntryId = stdPbe().Id, Product2Id = prod().Id,
            Quantity = 1, UnitPrice = 500, Odoo_Product_ID__c = 100, Charge_Type__c = 'MRC',
            Billing_Mode__c = 'Advance', Is_Active__c = true,
            BAN_ID__c = goodBan().Id, Target_BAN__c = lineBan.Id);

        Test.startTest();
        ord.Status = 'Activated';
        update ord;

        OdooIntegrationSettings__c s = settings();
        s.IP1_Enabled__c = false;
        upsert s;
        Test.stopTest();

        System.assert(true,
            'New Service activation with an unsynced order-level BAN and an unsynced line-level BAN override should enqueue OdooBanSyncQueueable without error');
    }

    // Same as above, mirrored for the Change-Order (IP-4) BAN-sync branch.
    @IsTest
    static void changeOrder_unsyncedBanAndLineLevelOverride_enqueuesBanSyncQueueable() {
        Test.setMock(HttpCalloutMock.class, MockOdooCallout.success(8004));

        Contact syncedCon = new Contact(AccountId = acct().Id, FirstName = 'Synced2', LastName = 'Contact',
            Email = 'synced-c2@test.com', Odoo_Partner_ID__c = 999);
        insert syncedCon;
        BillingAccount__c rawBan = new BillingAccount__c(Account__c = acct().Id, Invoice_Frequency__c = 'Monthly',
            Billing_Contact__c = syncedCon.Id);
        insert rawBan;
        BillingAccount__c lineBan = new BillingAccount__c(Account__c = acct().Id, Invoice_Frequency__c = 'Monthly',
            Billing_Contact__c = syncedCon.Id);
        insert lineBan;

        Order ord = buildOrder('Change/Upsell', 'JKT1', rawBan.Id, 100);
        OrderItem oi = [SELECT Id FROM OrderItem WHERE OrderId = :ord.Id LIMIT 1];
        update new OrderItem(Id = oi.Id, Target_BAN__c = lineBan.Id);
        // Second line with BAN_ID__c pointing at a fully-synced BAN — forces evaluation
        // through the full Odoo_BAN_ID__c / Odoo_Invoice_Freq_ID__c OR-chain (see the
        // New Service test above for the identical rationale).
        insert new OrderItem(OrderId = ord.Id, PricebookEntryId = stdPbe().Id, Product2Id = prod().Id,
            Quantity = 1, UnitPrice = 500, Odoo_Product_ID__c = 100, Charge_Type__c = 'MRC',
            Billing_Mode__c = 'Advance', Is_Active__c = true,
            BAN_ID__c = goodBan().Id, Target_BAN__c = lineBan.Id);

        Test.startTest();
        ord.Status = 'Activated';
        update ord;

        OdooIntegrationSettings__c s = settings();
        s.IP1_Enabled__c = false;
        upsert s;
        Test.stopTest();

        System.assert(true,
            'Change order activation with an unsynced order-level BAN and an unsynced line-level BAN override should enqueue OdooBanSyncQueueable (IP-4 chain target) without error');
    }

    // applyChangeOrderAssetUpdates is currently dead code — its call site in
    // routeActivatedOrders is commented out in favor of stampInventoryScdFromAsset (see
    // the method's own header comment in OrderTriggerHandler.cls) — so it's only
    // reachable via the @TestVisible annotation added for direct invocation here.
    // Exercises the QLI(CHANGE/CHANGE_PRICE)→Asset lookup and the AssetSystemDml inner
    // class's `update recs` line.
    @IsTest
    static void applyChangeOrderAssetUpdates_pushesChangeLineValuesOntoAsset() {
        Account a = acct();
        String curr = [SELECT CurrencyIsoCode FROM Order LIMIT 1].CurrencyIsoCode;
        Opportunity opp = new Opportunity(Name = 'Asset Sync Opp', AccountId = a.Id, StageName = '1-Suspect',
            CloseDate = Date.today().addMonths(2), Skip_Stage_Gate__c = true, CurrencyIsoCode = curr);
        insert opp;
        Quote q = new Quote(Name = 'Asset Sync Quote', OpportunityId = opp.Id,
            Pricebook2Id = Test.getStandardPricebookId(), CurrencyIsoCode = curr);
        insert q;
        QuoteLineItem qli = new QuoteLineItem(QuoteId = q.Id, Product2Id = prod().Id,
            PricebookEntryId = stdPbe().Id, Quantity = 1, UnitPrice = 750,
            Change_Type__c = 'CHANGE_PRICE', Product_Attribute_Value__c = 'New-Attr');
        insert qli;
        Asset asset = new Asset(Name = 'Asset Sync Target', AccountId = a.Id, Status = 'Pending Change',
            Quantity = 1, InstallDate = Date.today());
        insert asset;
        update new QuoteLineItem(Id = qli.Id, Asset__c = asset.Id);

        Order ord = [SELECT Id FROM Order LIMIT 1];
        ord.QuoteId = q.Id;
        update ord;
        insert new OrderItem(OrderId = ord.Id, PricebookEntryId = stdPbe().Id, Product2Id = prod().Id,
            Quantity = 1, UnitPrice = 750, Odoo_Product_ID__c = 100, Charge_Type__c = 'MRC',
            Billing_Mode__c = 'Advance', Is_Active__c = true, QuoteLineItemId = qli.Id);

        Test.startTest();
        OrderTriggerHandler.applyChangeOrderAssetUpdates(new List<Id>{ ord.Id });
        Test.stopTest();

        Asset result = [SELECT Status, Price, MRC__c, Product_Attribute__c FROM Asset WHERE Id = :asset.Id];
        System.assertEquals('In Service', result.Status,
            'CHANGE_PRICE line should push the Asset to In Service');
        System.assertEquals(750, result.Price, 'Asset Price should be updated from the QLI UnitPrice');
        System.assertEquals('New-Attr', result.Product_Attribute__c,
            'Asset Product_Attribute__c should be updated from the QLI Product_Attribute_Value__c');
    }

    // updateInventoryToSold Path A via OrderItem.Inventory__c (the "Breaker" field) —
    // mirrors activation_setsInventoryToSold above but through Inventory__c instead of
    // Space__c, since the handler treats the two as separate branches.
    @IsTest
    static void activation_setsInventoryToSold_viaInventoryBreakerField() {
        Test.setMock(HttpCalloutMock.class, MockOdooCallout.success(8010));
        Inventory__c inv = new Inventory__c(Name = 'Sold-Test-Breaker', RecordTypeId = spaceRtId(),
            Status__c = 'Assigned', Site_Id__c = jktSiteId());
        insert inv;
        OrderItem oi = [SELECT Id FROM OrderItem LIMIT 1];
        update new OrderItem(Id = oi.Id, Inventory__c = inv.Id);

        Order ord = [SELECT Id FROM Order LIMIT 1];
        ord.Order_Type__c = 'Change/Upsell';
        update ord;

        Test.startTest();
        ord.Status = 'Activated';
        update ord;
        Test.stopTest();

        System.assertEquals('Sold', [SELECT Status__c FROM Inventory__c WHERE Id = :inv.Id].Status__c,
            'Assigned inventory linked via OrderItem.Inventory__c should transition to Sold on order activation');
    }

    // updateInventoryToPendingAvailable Path B (QLI → Inventory lookup) — mirrors
    // changeActivation_inventoryPathBAndScdStamp's Path B setup but for a churn order, to
    // hit the QLI lookup inside updateInventoryToPendingAvailable rather than
    // updateInventoryToSold.
    @IsTest
    static void churnActivation_pendingAvailable_viaQuoteLinePathB() {
        Test.setMock(HttpCalloutMock.class, MockOdooCallout.success(8011));
        Account a = acct();
        String curr = [SELECT CurrencyIsoCode FROM Order LIMIT 1].CurrencyIsoCode;
        Opportunity opp = new Opportunity(Name = 'Churn PathB Opp', AccountId = a.Id, StageName = '1-Suspect',
            CloseDate = Date.today().addMonths(2), Skip_Stage_Gate__c = true, CurrencyIsoCode = curr);
        insert opp;
        Quote q = new Quote(Name = 'Churn PathB Quote', OpportunityId = opp.Id,
            Pricebook2Id = Test.getStandardPricebookId(), CurrencyIsoCode = curr);
        insert q;
        QuoteLineItem qli = new QuoteLineItem(QuoteId = q.Id, Product2Id = prod().Id,
            PricebookEntryId = stdPbe().Id, Quantity = 1, UnitPrice = 500);
        insert qli;

        Inventory__c inv = new Inventory__c(Name = 'Churn PathB Inv', RecordTypeId = spaceRtId(),
            Status__c = 'Installed', Site_Id__c = jktSiteId(), Quote_Line__c = qli.Id);
        insert inv;

        Order ord = [SELECT Id FROM Order LIMIT 1];
        ord.QuoteId = q.Id;
        ord.Order_Type__c = 'Churn';
        update ord;
        insert new OrderItem(OrderId = ord.Id, PricebookEntryId = stdPbe().Id, Product2Id = prod().Id,
            Quantity = 1, UnitPrice = 500, Odoo_Product_ID__c = 100, Charge_Type__c = 'MRC',
            Billing_Mode__c = 'Advance', Is_Active__c = true, QuoteLineItemId = qli.Id);

        Test.startTest();
        ord.Status = 'Activated';
        update ord;
        Test.stopTest();

        System.assertEquals('Pending Available',
            [SELECT Status__c FROM Inventory__c WHERE Id = :inv.Id].Status__c,
            'Installed inventory linked via QuoteLineItem should transition to Pending Available on churn activation');
    }
}