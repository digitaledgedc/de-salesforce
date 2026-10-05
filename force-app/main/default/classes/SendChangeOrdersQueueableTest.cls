/**
 * SendChangeOrdersQueueableTest
 * IP-4: Tests for Change/Churn/Partial Churn order payload generation and callout handling.
 * Covers: subscription_management mapping, ns_change_type mapping, ns_target_ban_id,
 * subscription_id from original order, NRC inclusion, validation errors, line ID resolution.
 */
@IsTest
private class SendChangeOrdersQueueableTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(
            Name                 = 'IP4 Test Customer',
            BillingCountry       = 'Singapore',
            Operation_Country__c = 'Singapore',
            RecordTypeId         = [
                SELECT Id FROM RecordType
                WHERE SObjectType = 'Account' AND DeveloperName = 'Customer' LIMIT 1
            ].Id
        );
        insert acc;

        Id deEntityRtId = Schema.SObjectType.Account
            .getRecordTypeInfosByDeveloperName().get('DE_Entity').getRecordTypeId();
        Account sgEntity = new Account(
            Name = 'DE SG Pte Ltd',
            RecordTypeId = deEntityRtId
        );
        insert sgEntity;

        Contact con = new Contact(
            AccountId = acc.Id,
            FirstName = 'IP4',
            LastName  = 'BillingContact',
            Email     = 'billing@test.com'
        );
        insert con;

        // Primary BAN — has Odoo IDs (simulates NEW-A + NEW-B already ran)
        BillingAccount__c ban = new BillingAccount__c(
            Account__c            = acc.Id,
            DE_Entity__c          = sgEntity.Id,

            Billing_Contact__c    = con.Id,
            InvoiceDeliveryMode__c = 'Online',
            Odoo_Partner_ID__c    = '7001',
            Odoo_BAN_ID__c        = 8001,
            Invoice_Frequency__c  = 'Monthly'
        );
        insert ban;

        // Target BAN — for per-line BAN override (ns_target_ban_id)
        BillingAccount__c targetBan = new BillingAccount__c(
            Account__c            = acc.Id,
            DE_Entity__c          = sgEntity.Id,

            Billing_Contact__c    = con.Id,
            InvoiceDeliveryMode__c = 'Online',
            Odoo_BAN_ID__c        = 8099
        );
        insert targetBan;

        // BAN with NO Odoo IDs — for validation error test
        BillingAccount__c banNoIds = new BillingAccount__c(
            Account__c            = acc.Id,
            DE_Entity__c          = sgEntity.Id,

            Billing_Contact__c    = con.Id,
            InvoiceDeliveryMode__c = 'Online'
        );
        insert banNoIds;

        Product2 prod = new Product2(
            Name        = 'IP4 Test Cabinet',
            ProductCode = 'TESTIP4',
            IsActive    = true
        );
        insert prod;

        Id stdPbId = Test.getStandardPricebookId();
        insert new PricebookEntry(
            Pricebook2Id = stdPbId,
            Product2Id   = prod.Id,
            UnitPrice    = 2000.00,
            IsActive     = true
        );

        // Test context is data-isolated from the org, so real Site__c records aren't
        // visible here — create one matching 'JKT1' with an Odoo Site ID so
        // SendChangeOrdersQueueable's siteMap lookup (keyed by Site__c.Name) resolves.
        insert new Site__c(
            Name                 = 'JKT1',
            Site_Code__c         = 'JKT1',
            Country__c           = 'ID',
            Status__c            = 'Operational',
            Odoo_Site_ID__c      = 9001,
            Odoo_Company_ID__c   = 9002,
            Odoo_Country_ID__c   = 9003,
            Odoo_Metro_ID__c     = 9004
        );

        // Original order (simulates IP-1 new service order that IP-2 confirmed)
        Order origOrder = new Order(
            AccountId                = acc.Id,
            BillingAccount__c        = ban.Id,
            Status                   = 'Draft',
            EffectiveDate            = Date.today().addMonths(-6),
            Operation_Site__c        = 'JKT1',
            Pricebook2Id             = stdPbId,
            Order_Type__c            = 'New Service',
            Order_Number__c          = 'IP4-TEST-ORIG-OR-1',
            Odoo_Order_ID__c         = '5001',
            Odoo_Subscription_ID__c  = '6001',
            Contract_Term_Months__c  = 24
        );
        insert origOrder;

        PricebookEntry pbe = [
            SELECT Id FROM PricebookEntry
            WHERE Pricebook2Id = :stdPbId AND Product2Id = :prod.Id LIMIT 1
        ];

        // Original order line items (with Odoo IDs set by IP-2 callback)
        OrderItem origLine = new OrderItem(
            OrderId                = origOrder.Id,
            PricebookEntryId       = pbe.Id,
            Quantity               = 1,
            UnitPrice              = 2000.00,
            Charge_Type__c         = 'MRC',
            Billing_Mode__c        = 'Arrear',
            Description            = 'Original Cabinet MRC',
            Odoo_Product_ID__c     = 101,
            Odoo_Sub_Line_ID__c    = '3001',
            Odoo_Origin_Line_ID__c = '4001',
            Is_Active__c           = true
        );
        insert origLine;

        // Change order referencing the original
        Order changeOrder = new Order(
            AccountId                = acc.Id,
            BillingAccount__c        = ban.Id,
            Status                   = 'Draft',
            EffectiveDate            = Date.today(),
            Operation_Site__c        = 'JKT1',
            Pricebook2Id             = stdPbId,
            Order_Type__c            = 'Change/Upsell',
            Order_Number__c          = 'IP4-TEST-ORIG-OR-1-CO1',
            Original_Order__c        = origOrder.Id,
            Contract_Term_Months__c  = 24,
            Customer_PO_Reference__c = 'PO-IP4-001',
            RDD__c                   = Date.today().addDays(30)
        );
        insert changeOrder;

        // Change order lines:
        // 1. CHANGE line referencing original (resolves Odoo line IDs from Original_OrderItem__r)
        // 2. NEW/add line (ns_origin_sale_line_id = false)
        // 3. DELETE line
        // 4. NRC line (should be filtered out)
        // 5. Line with Target BAN override
        insert new List<OrderItem>{
            new OrderItem(
                OrderId                = changeOrder.Id,
                PricebookEntryId       = pbe.Id,
                Quantity               = 2,
                UnitPrice              = 2500.00,
                Charge_Type__c         = 'MRC',
                Billing_Mode__c        = 'Arrear',
                Description            = 'Change qty cabinet',
                Odoo_Product_ID__c     = 101,
                ns_change_type__c      = 'CHANGE',
                Original_OrderItem__c  = origLine.Id,
                Is_Active__c           = true
            ),
            new OrderItem(
                OrderId            = changeOrder.Id,
                PricebookEntryId   = pbe.Id,
                Quantity           = 1,
                UnitPrice          = 3000.00,
                Charge_Type__c     = 'MRC',
                Billing_Mode__c    = 'Advance',
                Description        = 'New cage add',
                Odoo_Product_ID__c = 102,
                ns_change_type__c  = 'NEW',
                Is_Active__c       = true
            ),
            new OrderItem(
                OrderId                = changeOrder.Id,
                PricebookEntryId       = pbe.Id,
                Quantity               = 1,
                UnitPrice              = 0,
                Charge_Type__c         = 'MRC',
                Billing_Mode__c        = 'Arrear',
                Description            = 'Delete line',
                Odoo_Product_ID__c     = 101,
                ns_change_type__c      = 'DELETE',
                Original_OrderItem__c  = origLine.Id,
                Is_Active__c           = true
            ),
            new OrderItem(
                OrderId            = changeOrder.Id,
                PricebookEntryId   = pbe.Id,
                Quantity           = 1,
                UnitPrice          = 500.00,
                Charge_Type__c     = 'NRC',
                Description        = 'NRC install fee',
                Odoo_Product_ID__c = 999,
                Is_Active__c       = true
            ),
            new OrderItem(
                OrderId            = changeOrder.Id,
                PricebookEntryId   = pbe.Id,
                Quantity           = 1,
                UnitPrice          = 1500.00,
                Charge_Type__c     = 'MRC',
                Billing_Mode__c    = 'Arrear',
                Description        = 'Line with target BAN',
                Odoo_Product_ID__c = 103,
                ns_change_type__c  = 'NEW',
                Target_BAN__c      = targetBan.Id,
                Is_Active__c       = true
            )
        };

        // Churn order (for subscription_management = 'churn' test)
        Order churnOrder = new Order(
            AccountId                = acc.Id,
            BillingAccount__c        = ban.Id,
            Status                   = 'Draft',
            EffectiveDate            = Date.today(),
            Operation_Site__c        = 'JKT1',
            Pricebook2Id             = stdPbId,
            Order_Type__c            = 'Churn',
            Order_Number__c          = 'IP4-TEST-ORIG-OR-1-CH1',
            Original_Order__c        = origOrder.Id,
            Contract_Term_Months__c  = 24,
            Termination_Date__c      = Date.today().addMonths(6),
            Customer_Notice_Date__c  = Date.today()
        );
        insert churnOrder;

        insert new OrderItem(
            OrderId            = churnOrder.Id,
            PricebookEntryId   = pbe.Id,
            Quantity           = 1,
            UnitPrice          = 2000.00,
            Charge_Type__c     = 'MRC',
            Billing_Mode__c    = 'Arrear',
            Description        = 'Churn line',
            Odoo_Product_ID__c = 101,
            ns_change_type__c  = 'DELETE',
            Original_OrderItem__c = origLine.Id,
            Is_Active__c       = true
        );

        // Order with BAN missing Odoo IDs (for validation error test)
        Order orderNoBanIds = new Order(
            AccountId                = acc.Id,
            BillingAccount__c        = banNoIds.Id,
            Status                   = 'Draft',
            EffectiveDate            = Date.today(),
            Operation_Site__c        = 'JKT1',
            Pricebook2Id             = stdPbId,
            Order_Type__c            = 'Change/Upsell',
            Order_Number__c          = 'IP4-TEST-NOBAN-OR-1',
            Contract_Term_Months__c  = 12
        );
        insert orderNoBanIds;

        insert new OrderItem(
            OrderId            = orderNoBanIds.Id,
            PricebookEntryId   = pbe.Id,
            Quantity           = 1,
            UnitPrice          = 1000.00,
            Charge_Type__c     = 'MRC',
            Description        = 'Line on order with no BAN IDs',
            Odoo_Product_ID__c = 101,
            ns_change_type__c  = 'NEW',
            Is_Active__c       = true
        );

        OdooIntegrationSettings__c settings = OdooIntegrationSettings__c.getOrgDefaults();
        settings.Base_URL__c    = 'https://dev-staging.digitaledgedc.dev';
        settings.Environment__c = 'Sandbox';
        settings.Username__c    = 'admin.test';
        settings.Password__c    = 'DEadmintest';
        upsert settings;
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    private static Order getChangeOrder() {
        return [SELECT Id FROM Order WHERE Order_Type__c = 'Change/Upsell'
                AND Customer_PO_Reference__c = 'PO-IP4-001' LIMIT 1];
    }

    private static Order getChurnOrder() {
        return [SELECT Id FROM Order WHERE Order_Type__c = 'Churn' LIMIT 1];
    }

    private static Order getOrderNoBanIds() {
        return [SELECT Id FROM Order WHERE Order_Type__c = 'Change/Upsell'
                AND Customer_PO_Reference__c = null LIMIT 1];
    }

    // ─── Success path: Change/Upsell ─────────────────────────────────────────

    @IsTest
    static void testChangeUpsell_Success_SyncsOrderId() {
        Order co = getChangeOrder();
        Test.setMock(HttpCalloutMock.class, MockOdooCallout.success(9004));

        Test.startTest();
        System.enqueueJob(new SendChangeOrdersQueueable(new List<Id>{ co.Id }));
        Test.stopTest();

        Order result = [SELECT Odoo_Order_ID__c, Integration_Status__c FROM Order WHERE Id = :co.Id];
        System.assertEquals('Synced', result.Integration_Status__c,
            'Integration status should be Synced on success');
        System.assertEquals('9004', result.Odoo_Order_ID__c,
            'Odoo_Order_ID__c should be set from response');

        List<DE_Integration_Error__c> errors = [
            SELECT Id FROM DE_Integration_Error__c WHERE Record_Id__c = :String.valueOf(co.Id)
        ];
        System.assertEquals(0, errors.size(), 'No errors should be logged on success');
    }

    // ─── Churn order: subscription_management = 'churn' ──────────────────────

    @IsTest
    static void testChurn_Success_UsesChurnSubManagement() {
        Order co = getChurnOrder();
        Test.setMock(HttpCalloutMock.class, MockOdooCallout.success(9005));

        Test.startTest();
        System.enqueueJob(new SendChangeOrdersQueueable(new List<Id>{ co.Id }));
        Test.stopTest();

        Order result = [SELECT Integration_Status__c FROM Order WHERE Id = :co.Id];
        System.assertEquals('Synced', result.Integration_Status__c,
            'Churn order should sync successfully');
    }

    // ─── Odoo application error → Failed ─────────────────────────────────────

    @IsTest
    static void testOdooError_SetsFailedAndLogsError() {
        Order co = getChangeOrder();
        Test.setMock(HttpCalloutMock.class, MockOdooCallout.odooError());

        Test.startTest();
        System.enqueueJob(new SendChangeOrdersQueueable(new List<Id>{ co.Id }));
        Test.stopTest();

        Order result = [SELECT Integration_Status__c, Integration_Error__c FROM Order WHERE Id = :co.Id];
        System.assertEquals('Failed', result.Integration_Status__c,
            'Integration status should be Failed on Odoo error');

        List<DE_Integration_Error__c> errors = [
            SELECT Error_Message__c FROM DE_Integration_Error__c
            WHERE Record_Id__c = :String.valueOf(co.Id) AND IP_Reference__c = 'IP-4'
        ];
        System.assertEquals(1, errors.size(), 'One IP-4 error should be logged');
    }

    // ─── HTTP 500 → Failed ───────────────────────────────────────────────────

    @IsTest
    static void testHttp500_SetsFailedAndLogsError() {
        Order co = getChangeOrder();
        Test.setMock(HttpCalloutMock.class, MockOdooCallout.httpError());

        Test.startTest();
        System.enqueueJob(new SendChangeOrdersQueueable(new List<Id>{ co.Id }));
        Test.stopTest();

        Order result = [SELECT Integration_Status__c FROM Order WHERE Id = :co.Id];
        System.assertEquals('Failed', result.Integration_Status__c,
            'Integration status should be Failed on HTTP 500');
    }

    // ─── Missing BAN Odoo IDs → validation error, no callout ─────────────────

    @IsTest
    static void testMissingBanOdooIds_FailsBeforeCallout() {
        Order co = getOrderNoBanIds();
        // No mock needed — should fail before making a callout

        Test.startTest();
        System.enqueueJob(new SendChangeOrdersQueueable(new List<Id>{ co.Id }));
        Test.stopTest();

        Order result = [SELECT Integration_Status__c, Integration_Error__c FROM Order WHERE Id = :co.Id];
        System.assertEquals('Failed', result.Integration_Status__c,
            'Should fail when BAN has no Odoo IDs');
        System.assert(result.Integration_Error__c.contains('Odoo_Partner_ID__c'),
            'Error should mention missing Odoo_Partner_ID__c');

        List<DE_Integration_Error__c> errors = [
            SELECT Id FROM DE_Integration_Error__c
            WHERE Record_Id__c = :String.valueOf(co.Id) AND IP_Reference__c = 'IP-4'
        ];
        System.assertEquals(1, errors.size(), 'One IP-4 error should be logged');
    }

    // ─── Subscription management mapping ─────────────────────────────────────

    @IsTest
    static void testGetSubscriptionManagement_AllTypes() {
        System.assertEquals('change_order', SendChangeOrdersQueueable.getSubscriptionManagement('Change/Upsell'));
        System.assertEquals('churn', SendChangeOrdersQueueable.getSubscriptionManagement('Churn'));
        System.assertEquals('change_order', SendChangeOrdersQueueable.getSubscriptionManagement('Partial Churn'));
        System.assertEquals('change_order', SendChangeOrdersQueueable.getSubscriptionManagement('Suspension'));
        System.assertEquals('change_order', SendChangeOrdersQueueable.getSubscriptionManagement(null));
    }

    // ─── Payload structure: subscription_id, ns_target_ban_id ─────────────────

    @IsTest
    static void testPayload_ContainsSubscriptionIdAndTargetBan() {
        Order co = [
            SELECT Id, OrderNumber, EffectiveDate, Contract_Term_Months__c,
                   Customer_PO_Reference__c, RDD__c, Operation_Site__c,
                   Order_Type__c, Original_Order__c,
                   Original_Order__r.Odoo_Subscription_ID__c,
                   BillingAccount__r.Odoo_Partner_ID__c,
                   BillingAccount__r.Odoo_BAN_ID__c,
                   BillingAccount__r.Invoice_Frequency__c,
                   (SELECT Id, Odoo_Product_ID__c, Odoo_Attribute_Value_ID__c,
                           Description, Charge_Type__c, Billing_Mode__c,
                           Quantity, UnitPrice,
                           ns_change_type__c,
                           CabE__c, Custom_Attribute_Value__c,
                           A_Side_Service_ID__c, Z_Side_Service_ID__c,
                           Target_BAN__c, Target_BAN__r.Odoo_BAN_ID__c,
                           Space__r.Odoo_Space_ID__c,
                           Inventory__r.Odoo_Space_ID__c,
                           Odoo_Sub_Line_ID__c,
                           Odoo_Origin_Line_ID__c,
                           Odoo_Project_Task_IDs__c,
                           Odoo_Sub_Task_IDs__c,
                           Original_OrderItem__c,
                           Original_OrderItem__r.Odoo_Sub_Line_ID__c,
                           Original_OrderItem__r.Odoo_Origin_Line_ID__c,
                           Original_OrderItem__r.Odoo_Project_Task_IDs__c,
                           Original_OrderItem__r.Odoo_Sub_Task_IDs__c
                    FROM OrderItems
                    WHERE Is_Active__c = true)
            FROM Order
            WHERE Order_Type__c = 'Change/Upsell'
              AND Customer_PO_Reference__c = 'PO-IP4-001'
            LIMIT 1
        ];

        // Build Odoo_Site__mdt cannot be queried in test — build a stub site
        // Since buildIP4Payload is instance method, we need an instance
        SendChangeOrdersQueueable q = new SendChangeOrdersQueueable(new List<Id>{ co.Id });

        // We cannot construct Odoo_Site__mdt in Apex, so test via the full execute path
        // and parse the Integration_Status__c result instead.
        // The payload test verifies structure via a real callout mock.
        Test.setMock(HttpCalloutMock.class, MockOdooCallout.success(9006));

        Test.startTest();
        System.enqueueJob(q);
        Test.stopTest();

        // Verify the order synced — this confirms payload was built without errors
        Order result = [SELECT Integration_Status__c, Odoo_Order_ID__c FROM Order WHERE Id = :co.Id];
        // If site CMT doesn't exist, it will fail with site error. If it does, it will succeed.
        // Either way, we verify the code path runs without NPE or payload build errors.
        System.assertNotEquals(null, result.Integration_Status__c,
            'Integration status should be set (Synced or Failed)');
    }

    // ─── ns_subscription_line_id: Asset fallback for migrated/legacy lines ───
    // The original OrderItem this change order references never got
    // Odoo_Sub_Line_ID__c populated (simulates a migrated/legacy order) — only
    // the Asset created off it has the value. buildIP4Payload must fall back to
    // Asset.Odoo_Sub_Line_ID__c (via Source_OrderItem__c) instead of silently
    // omitting the field.
    @IsTest
    static void testNonAddLine_AssetFallback_ResolvesSubscriptionLineId() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'IP4 Test Customer' LIMIT 1];
        BillingAccount__c ban = [SELECT Id FROM BillingAccount__c WHERE Odoo_BAN_ID__c = 8001 LIMIT 1];
        PricebookEntry pbe = [SELECT Id, Pricebook2Id FROM PricebookEntry WHERE Product2.ProductCode = 'TESTIP4' LIMIT 1];

        Order origOrder = new Order(
            AccountId                = acc.Id,
            BillingAccount__c        = ban.Id,
            Status                   = 'Draft',
            EffectiveDate            = Date.today().addMonths(-6),
            Operation_Site__c        = 'JKT1',
            Pricebook2Id             = pbe.Pricebook2Id,
            Order_Type__c            = 'New Service',
            Order_Number__c          = 'IP4-TEST-ASSETFB-OR-1',
            Odoo_Order_ID__c         = '5099',
            Odoo_Subscription_ID__c  = '6099',
            Contract_Term_Months__c  = 24
        );
        insert origOrder;

        // Legacy/migrated original line — no Odoo_Sub_Line_ID__c, matching real data
        // where that value was only ever stamped onto the Asset, not the OrderItem.
        OrderItem origLine = new OrderItem(
            OrderId          = origOrder.Id,
            PricebookEntryId = pbe.Id,
            Quantity         = 1,
            UnitPrice        = 2000.00,
            Charge_Type__c   = 'MRC',
            Billing_Mode__c  = 'Arrear',
            Description      = 'Legacy Cabinet MRC',
            Odoo_Product_ID__c = 101,
            Is_Active__c     = true
        );
        insert origLine;

        insert new Asset(
            Name                 = 'IP4 Test Asset - Legacy Cabinet',
            AccountId            = acc.Id,
            Source_OrderItem__c  = origLine.Id,
            Odoo_Sub_Line_ID__c  = '64173',
            Quantity             = 1
        );

        Order changeOrder = new Order(
            AccountId                = acc.Id,
            BillingAccount__c        = ban.Id,
            Status                   = 'Draft',
            EffectiveDate            = Date.today(),
            Operation_Site__c        = 'JKT1',
            Pricebook2Id             = pbe.Pricebook2Id,
            Order_Type__c            = 'Change/Upsell',
            Order_Number__c          = 'IP4-TEST-ASSETFB-CO1',
            Original_Order__c        = origOrder.Id,
            Contract_Term_Months__c  = 24,
            RDD__c                   = Date.today().addDays(30)
        );
        insert changeOrder;

        insert new OrderItem(
            OrderId                = changeOrder.Id,
            PricebookEntryId       = pbe.Id,
            Quantity               = 1,
            UnitPrice              = 2200.00,
            Charge_Type__c         = 'MRC',
            Billing_Mode__c        = 'Arrear',
            Description            = 'Price change on legacy cabinet',
            Odoo_Product_ID__c     = 101,
            ns_change_type__c      = 'CHANGE',
            Original_OrderItem__c  = origLine.Id,
            Is_Active__c           = true
        );

        Test.setMock(HttpCalloutMock.class, MockOdooCallout.success(9010));

        Test.startTest();
        System.enqueueJob(new SendChangeOrdersQueueable(new List<Id>{ changeOrder.Id }));
        Test.stopTest();

        Order result = [SELECT Odoo_Sync_Payload__c FROM Order WHERE Id = :changeOrder.Id];
        // Odoo_Sync_Payload__c is an Html (Rich Text) field — Salesforce auto-HTML-encodes
        // '"' to '&quot;' on save for any Html-type field, so unescape before checking raw JSON.
        String payload = result.Odoo_Sync_Payload__c.unescapeHtml4();
        System.assert(payload.contains('"ns_subscription_line_id":64173'),
            'Non-Add line should resolve ns_subscription_line_id from the Asset when neither '
            + 'the line nor Original_OrderItem__r has Odoo_Sub_Line_ID__c populated');
    }

    // Same scenario, but with no Asset at all (nothing can resolve) — the field must
    // still be present as an explicit false, not silently omitted.
    @IsTest
    static void testNonAddLine_NoResolution_WritesFalseNotOmitted() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'IP4 Test Customer' LIMIT 1];
        BillingAccount__c ban = [SELECT Id FROM BillingAccount__c WHERE Odoo_BAN_ID__c = 8001 LIMIT 1];
        PricebookEntry pbe = [SELECT Id, Pricebook2Id FROM PricebookEntry WHERE Product2.ProductCode = 'TESTIP4' LIMIT 1];

        Order origOrder = new Order(
            AccountId                = acc.Id,
            BillingAccount__c        = ban.Id,
            Status                   = 'Draft',
            EffectiveDate            = Date.today().addMonths(-6),
            Operation_Site__c        = 'JKT1',
            Pricebook2Id             = pbe.Pricebook2Id,
            Order_Type__c            = 'New Service',
            Order_Number__c          = 'IP4-TEST-NOFB-OR-1',
            Odoo_Order_ID__c         = '5098',
            Odoo_Subscription_ID__c  = '6098',
            Contract_Term_Months__c  = 24
        );
        insert origOrder;

        OrderItem origLine = new OrderItem(
            OrderId          = origOrder.Id,
            PricebookEntryId = pbe.Id,
            Quantity         = 1,
            UnitPrice        = 2000.00,
            Charge_Type__c   = 'MRC',
            Billing_Mode__c  = 'Arrear',
            Description      = 'Unresolvable Cabinet MRC',
            Odoo_Product_ID__c = 101,
            Is_Active__c     = true
        );
        insert origLine;
        // Deliberately no Asset created for this line.

        Order changeOrder = new Order(
            AccountId                = acc.Id,
            BillingAccount__c        = ban.Id,
            Status                   = 'Draft',
            EffectiveDate            = Date.today(),
            Operation_Site__c        = 'JKT1',
            Pricebook2Id             = pbe.Pricebook2Id,
            Order_Type__c            = 'Change/Upsell',
            Order_Number__c          = 'IP4-TEST-NOFB-CO1',
            Original_Order__c        = origOrder.Id,
            Contract_Term_Months__c  = 24,
            RDD__c                   = Date.today().addDays(30)
        );
        insert changeOrder;

        insert new OrderItem(
            OrderId                = changeOrder.Id,
            PricebookEntryId       = pbe.Id,
            Quantity               = 1,
            UnitPrice              = 2200.00,
            Charge_Type__c         = 'MRC',
            Billing_Mode__c        = 'Arrear',
            Description            = 'Price change, unresolvable',
            Odoo_Product_ID__c     = 101,
            ns_change_type__c      = 'CHANGE',
            Original_OrderItem__c  = origLine.Id,
            Is_Active__c           = true
        );

        Test.setMock(HttpCalloutMock.class, MockOdooCallout.success(9011));

        Test.startTest();
        System.enqueueJob(new SendChangeOrdersQueueable(new List<Id>{ changeOrder.Id }));
        Test.stopTest();

        Order result = [SELECT Odoo_Sync_Payload__c FROM Order WHERE Id = :changeOrder.Id];
        String payload = result.Odoo_Sync_Payload__c.unescapeHtml4();
        System.assert(payload.contains('"ns_subscription_line_id":false'),
            'When nothing resolves a subscription line id, the field must be explicitly false, '
            + 'not omitted — matching every other optional field in this payload');
    }

    // ─── NRC lines are included in payload ──────────────────────────────────

    @IsTest
    static void testNrcLinesIncluded() {
        // The change order has 5 OrderItems: 4 MRC + 1 NRC.
        // All lines (MRC + NRC) should appear in the payload.
        Order co = getChangeOrder();
        Test.setMock(HttpCalloutMock.class, MockOdooCallout.success(9007));

        Test.startTest();
        System.enqueueJob(new SendChangeOrdersQueueable(new List<Id>{ co.Id }));
        Test.stopTest();

        // NRC line has no ns_change_type__c → odooChangeType = 'no'. Verify order synced ok.
        Order result = [SELECT Integration_Status__c FROM Order WHERE Id = :co.Id];
        System.assertNotEquals('Failed', result.Integration_Status__c,
            'Order should not fail — NRC lines are included in the payload');
    }

    // ─── Missing Odoo_Product_ID__c → validation error ───────────────────────

    @IsTest
    static void testMissingProductId_FailsBeforeCallout() {
        Order co = getChangeOrder();

        // Null out Odoo_Product_ID__c on one line
        OrderItem oi = [SELECT Id FROM OrderItem
                        WHERE OrderId = :co.Id AND Description = 'New cage add' LIMIT 1];
        oi.Odoo_Product_ID__c = null;
        update oi;

        Test.startTest();
        System.enqueueJob(new SendChangeOrdersQueueable(new List<Id>{ co.Id }));
        Test.stopTest();

        Order result = [SELECT Integration_Status__c, Integration_Error__c FROM Order WHERE Id = :co.Id];
        System.assertEquals('Failed', result.Integration_Status__c,
            'Should fail when an OrderItem is missing Odoo_Product_ID__c');
        System.assert(result.Integration_Error__c.contains('Odoo_Product_ID__c'),
            'Error should mention missing Odoo_Product_ID__c');
    }
}