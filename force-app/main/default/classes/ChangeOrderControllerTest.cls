@IsTest
private class ChangeOrderControllerTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = 'CO Test Customer', Operation_Country__c = 'Singapore');
        insert acc;

        // DE_Entity account + BAN — the Quote.BillingAccount__c lookup filter requires the
        // BAN to match the quote's Account + DE_Entity + Currency + Invoice_Frequency.
        Id deEntityRtId = Schema.SObjectType.Account
            .getRecordTypeInfosByDeveloperName().get('DE_Entity').getRecordTypeId();
        Account deEntity = new Account(Name = 'CO DE SG Pte Ltd', RecordTypeId = deEntityRtId);
        insert deEntity;

        BillingAccount__c origBan = new BillingAccount__c(
            Account__c           = acc.Id,
            DE_Entity__c         = deEntity.Id,
            Invoice_Frequency__c = 'Monthly'
        );
        insert origBan;

        Opportunity opp = new Opportunity(
            Name = 'CO Test Opp', AccountId = acc.Id,
            StageName = '3-Qualified', CloseDate = Date.today().addMonths(3)
        );
        insert opp;

        Id pbId = Test.getStandardPricebookId();

        Product2 prod = new Product2(
            Name = 'Full Cab', IsActive = true, ProductCode = 'CAB.SH.RC',
            QuantityUnitOfMeasure = 'Cab'
        );
        insert prod;

        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = pbId, Product2Id = prod.Id,
            UnitPrice = 5000, IsActive = true
        );
        insert pbe;

        Order ord = new Order(
            AccountId         = acc.Id,
            OpportunityId     = opp.Id,
            Pricebook2Id      = pbId,
            EffectiveDate     = Date.today(),
            Status            = 'Draft',
            BillingAccount__c = origBan.Id
        );
        insert ord;

        OrderItem oi = new OrderItem(
            OrderId          = ord.Id,
            PricebookEntryId = pbe.Id,
            Product2Id       = prod.Id,
            Quantity         = 2,
            UnitPrice        = 5000,
            Charge_Type__c   = 'MRC',
            Is_Active__c     = true
        );
        insert oi;

        Asset asset = new Asset(
            Name               = 'Full Cab Asset',
            AccountId          = acc.Id,
            Product2Id         = prod.Id,
            Quantity           = 2,
            Status             = 'Installed',
            Source_OrderItem__c = oi.Id
        );
        insert asset;
    }

    @IsTest
    static void testGetActiveOrderItems() {
        Order ord = [SELECT Id FROM Order LIMIT 1];

        Test.startTest();
        List<ChangeOrderController.OrderLineRow> rows =
            ChangeOrderController.getActiveOrderItems(ord.Id);
        Test.stopTest();

        System.assertEquals(1, rows.size(), 'Should find 1 active MRC line');
        System.assertEquals('Full Cab', rows[0].productName);
        System.assertEquals('Space', rows[0].category);
    }

    @IsTest
    static void testCreateChangeOrder_amendment() {
        Order ord = [SELECT Id FROM Order LIMIT 1];
        OrderItem oi = [SELECT Id, Product2Id, PricebookEntryId FROM OrderItem LIMIT 1];
        Asset asset = [SELECT Id FROM Asset WHERE Source_OrderItem__c = :oi.Id LIMIT 1];

        String linesJson = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{
                'itemId'           => oi.Id,
                'assetId'          => asset.Id,
                'productId'        => oi.Product2Id,
                'pricebookEntryId' => oi.PricebookEntryId,
                'changeType'       => 'CHANGE',
                'newQuantity'      => 4,
                'newUnitPrice'     => null,
                'quantity'         => 2,
                'unitPrice'        => 5000,
                'billingMode'      => null,
                'odooProductId'    => null,
                'description'      => 'Scaling up cabinets'
            }
        });

        Test.startTest();
        Id quoteId = ChangeOrderController.createChangeOrder(
            ord.Id, 'Change/Upsell', 'Quantity_Change',
            String.valueOf(Date.today().addDays(14)), 'PO-123', linesJson, null
        );
        Test.stopTest();

        System.assertNotEquals(null, quoteId, 'Should return a Quote Id');
        Quote q = [SELECT Quote_Type__c, Amendment_Reason__c, Customer_PO_Reference__c FROM Quote WHERE Id = :quoteId];
        System.assertEquals('Amendment', q.Quote_Type__c);
        System.assertEquals('Quantity Change', q.Amendment_Reason__c);
        System.assertEquals('PO-123', q.Customer_PO_Reference__c);

        List<QuoteLineItem> qlis = [SELECT Quantity, Change_Type__c, Asset__c FROM QuoteLineItem WHERE QuoteId = :quoteId];
        System.assertEquals(1, qlis.size(), 'Should have 1 QLI');
        System.assertEquals(4, qlis[0].Quantity, 'QLI should have new quantity');
        System.assertEquals(asset.Id, qlis[0].Asset__c, 'QLI should carry the source Asset from the CO grid row');
    }

    @IsTest
    static void testCreateChangeOrder_churn() {
        Order ord = [SELECT Id FROM Order LIMIT 1];
        OrderItem oi = [SELECT Id, Product2Id, PricebookEntryId FROM OrderItem LIMIT 1];
        Asset asset = [SELECT Id FROM Asset WHERE Source_OrderItem__c = :oi.Id LIMIT 1];

        String linesJson = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{
                'itemId'           => oi.Id,
                'assetId'          => asset.Id,
                'productId'        => oi.Product2Id,
                'pricebookEntryId' => oi.PricebookEntryId,
                'changeType'       => 'DELETE',
                'newQuantity'      => null,
                'newUnitPrice'     => null,
                'quantity'         => 2,
                'unitPrice'        => 5000,
                'billingMode'      => null,
                'odooProductId'    => null,
                'description'      => null
            }
        });

        Test.startTest();
        Id quoteId = ChangeOrderController.createChangeOrder(
            ord.Id, 'Churn', 'End_of_Term', null, null, linesJson, null
        );
        Test.stopTest();

        Quote q = [SELECT Quote_Type__c, Amendment_Reason__c FROM Quote WHERE Id = :quoteId];
        System.assertEquals('Termination', q.Quote_Type__c);
        System.assertEquals('Termination', q.Amendment_Reason__c);
    }

    @IsTest
    static void testCreateChangeOrder_noChangedLines() {
        Order ord = [SELECT Id FROM Order LIMIT 1];
        OrderItem oi = [SELECT Id, Product2Id, PricebookEntryId FROM OrderItem LIMIT 1];

        // NO_CHANGE lines should be skipped unless BAN Change
        String linesJson = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{
                'itemId'           => oi.Id,
                'productId'        => oi.Product2Id,
                'pricebookEntryId' => oi.PricebookEntryId,
                'changeType'       => 'NO_CHANGE',
                'quantity'         => 2,
                'unitPrice'        => 5000,
                'billingMode'      => null,
                'odooProductId'    => null,
                'description'      => null
            }
        });

        Test.startTest();
        Id quoteId = ChangeOrderController.createChangeOrder(
            ord.Id, 'Change/Upsell', 'Price_Change', null, null, linesJson, null
        );
        Test.stopTest();

        List<QuoteLineItem> qlis = [SELECT Id FROM QuoteLineItem WHERE QuoteId = :quoteId];
        System.assertEquals(0, qlis.size(), 'NO_CHANGE lines should be skipped for non-BAN CO');
    }

    @IsTest
    static void testCreateChangeOrder_banChange() {
        Order ord = [SELECT Id, AccountId FROM Order LIMIT 1];
        OrderItem oi = [SELECT Id, Product2Id, PricebookEntryId FROM OrderItem LIMIT 1];
        Asset asset = [SELECT Id FROM Asset WHERE Source_OrderItem__c = :oi.Id LIMIT 1];

        // New BAN must satisfy the Quote.BillingAccount__c lookup filter:
        // same Account + DE_Entity + Currency + Invoice_Frequency as the quote.
        BillingAccount__c origBan = [SELECT DE_Entity__c, Invoice_Frequency__c FROM BillingAccount__c LIMIT 1];
        BillingAccount__c newBan = new BillingAccount__c(
            Account__c           = ord.AccountId,
            DE_Entity__c         = origBan.DE_Entity__c,
            Invoice_Frequency__c = origBan.Invoice_Frequency__c
        );
        insert newBan;

        // BAN Change includes NO_CHANGE lines
        String linesJson = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{
                'itemId'           => oi.Id,
                'assetId'          => asset.Id,
                'productId'        => oi.Product2Id,
                'pricebookEntryId' => oi.PricebookEntryId,
                'changeType'       => 'NO_CHANGE',
                'quantity'         => 2,
                'unitPrice'        => 5000,
                'billingMode'      => null,
                'odooProductId'    => null,
                'description'      => null
            }
        });

        Test.startTest();
        Id quoteId = ChangeOrderController.createChangeOrder(
            ord.Id, 'BAN Change', 'BAN_Transfer', null, null, linesJson, newBan.Id
        );
        Test.stopTest();

        Quote q = [SELECT Quote_Type__c, Amendment_Reason__c, BillingAccount__c
                   FROM Quote WHERE Id = :quoteId];
        System.assertEquals('Amendment', q.Quote_Type__c);
        System.assertEquals('BAN Change', q.Amendment_Reason__c);
        System.assertEquals(newBan.Id, q.BillingAccount__c,
            'BAN Change quote should use the new BAN, not the original');

        List<QuoteLineItem> qlis = [SELECT Id FROM QuoteLineItem WHERE QuoteId = :quoteId];
        System.assertEquals(1, qlis.size(), 'BAN Change should include NO_CHANGE lines');
    }

    // ── Read/helper methods ──────────────────────────────────────────────────────
    @IsTest
    static void testSearchAvailableProducts() {
        Order ord = [SELECT Id FROM Order LIMIT 1];
        Test.startTest();
        List<Map<String, Object>> matches = ChangeOrderController.searchAvailableProducts(ord.Id, 'Full');
        Test.stopTest();
        System.assert(!matches.isEmpty(), 'Should find the Full Cab product by name');
        System.assertEquals('Full Cab', matches[0].get('productName'), 'Matched product name should be returned');
    }

    @IsTest
    static void testGetPendingActions_andUnlinkedAssets() {
        Order ord = [SELECT Id, AccountId FROM Order LIMIT 1];
        // An imported asset with no Source_OrderItem__c → hasUnlinkedAssets = true
        insert new Asset(
            Name = 'Unlinked Imported Asset', AccountId = ord.AccountId,
            Status = 'Installed', Quantity = 1, Source_Order__c = ord.Id
        );

        Test.startTest();
        List<Map<String, String>> pending = ChangeOrderController.getPendingActions(ord.Id);
        Boolean hasUnlinked = ChangeOrderController.hasUnlinkedAssets(ord.Id);
        Test.stopTest();

        System.assertNotEquals(null, pending, 'Pending actions should return a (possibly empty) list');
        System.assertEquals(true, hasUnlinked, 'Order with a Source_OrderItem-less asset should report unlinked assets');
    }

    // ── Additional order types (Renewal / Partial Churn / BAN mismatch / invalid types) ──

    @IsTest
    static void testCreateChangeOrder_renewal() {
        Order ord = [SELECT Id FROM Order LIMIT 1];
        OrderItem oi = [SELECT Id, Product2Id, PricebookEntryId FROM OrderItem LIMIT 1];
        Asset asset = [SELECT Id FROM Asset WHERE Source_OrderItem__c = :oi.Id LIMIT 1];

        // Renewal includes NO_CHANGE lines so the renewed service carries over.
        String linesJson = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{
                'itemId'           => oi.Id,
                'assetId'          => asset.Id,
                'productId'        => oi.Product2Id,
                'pricebookEntryId' => oi.PricebookEntryId,
                'changeType'       => 'NO_CHANGE',
                'newQuantity'      => null,
                'newUnitPrice'     => null,
                'quantity'         => 2,
                'unitPrice'        => 5000,
                'billingMode'      => null,
                'odooProductId'    => null,
                'description'      => null
            }
        });

        Test.startTest();
        Id quoteId = ChangeOrderController.createChangeOrder(
            ord.Id, 'Renewal', 'Customer_Request', null, null, linesJson, null
        );
        Test.stopTest();

        // Note: Quote.Name assertion intentionally omitted — the deployed
        // "Quote Name Auto" flow rewrites Name post-insert, independent of
        // the RN-/XCO-/CO- prefix ChangeOrderController assigns.
        Quote q = [SELECT Quote_Type__c, Amendment_Reason__c, OpportunityId FROM Quote WHERE Id = :quoteId];
        System.assertEquals('Renewal', q.Quote_Type__c);
        System.assertEquals('Downgrade', q.Amendment_Reason__c, 'Customer_Request on a non-Churn CO maps to Downgrade');

        List<QuoteLineItem> qlis = [SELECT Id FROM QuoteLineItem WHERE QuoteId = :quoteId];
        System.assertEquals(1, qlis.size(), 'Renewal should include NO_CHANGE lines');

        Opportunity opp = [SELECT Deal_Type__c, Order_Type__c FROM Opportunity WHERE Id = :q.OpportunityId];
        System.assertEquals(null, opp.Deal_Type__c, 'Renewal has no auto Deal_Type__c');
        System.assertEquals('Renewal', opp.Order_Type__c);
    }

    @IsTest
    static void testCreateChangeOrder_partialChurn() {
        Order ord = [SELECT Id FROM Order LIMIT 1];
        OrderItem oi = [SELECT Id, Product2Id, PricebookEntryId FROM OrderItem LIMIT 1];
        Asset asset = [SELECT Id FROM Asset WHERE Source_OrderItem__c = :oi.Id LIMIT 1];

        String linesJson = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{
                'itemId'           => oi.Id,
                'assetId'          => asset.Id,
                'productId'        => oi.Product2Id,
                'pricebookEntryId' => oi.PricebookEntryId,
                'changeType'       => 'DELETE',
                'newQuantity'      => 1,
                'newUnitPrice'     => null,
                'quantity'         => 2,
                'unitPrice'        => 5000,
                'billingMode'      => null,
                'odooProductId'    => null,
                'description'      => 'Partial reduction'
            }
        });

        Test.startTest();
        Id quoteId = ChangeOrderController.createChangeOrder(
            ord.Id, 'Partial Churn', 'Capacity_Reduction', null, null, linesJson, null
        );
        Test.stopTest();

        Quote q = [SELECT Quote_Type__c, Amendment_Reason__c, OpportunityId FROM Quote WHERE Id = :quoteId];
        System.assertEquals('Amendment', q.Quote_Type__c);
        System.assertEquals('Downgrade', q.Amendment_Reason__c, 'Capacity_Reduction maps to Downgrade');

        Opportunity opp = [SELECT Deal_Type__c, Booking_Bucket__c, Order_Type__c FROM Opportunity WHERE Id = :q.OpportunityId];
        System.assertEquals('Change Order', opp.Deal_Type__c);
        System.assertEquals('Bookings', opp.Booking_Bucket__c);
        System.assertEquals('Partial Churn', opp.Order_Type__c);
    }

    @IsTest
    static void testCreateChangeOrder_banChange_mismatchedBan_throws() {
        Order ord = [SELECT Id, AccountId FROM Order LIMIT 1];
        OrderItem oi = [SELECT Id, Product2Id, PricebookEntryId FROM OrderItem LIMIT 1];
        Asset asset = [SELECT Id FROM Asset WHERE Source_OrderItem__c = :oi.Id LIMIT 1];

        // A BAN tied to a different Account fails the Quote.BillingAccount__c lookup
        // filter (Account + DE_Entity + Currency + Invoice_Frequency must all match).
        // This org enforces the mismatch via a friendlier validation message rather
        // than the raw FIELD_FILTER_VALIDATION token, so it exercises the catch
        // block's generic (else) branch.
        Account otherAcc = new Account(Name = 'CO Other Customer', Operation_Country__c = 'Singapore');
        insert otherAcc;
        BillingAccount__c origBan = [SELECT DE_Entity__c, Invoice_Frequency__c FROM BillingAccount__c LIMIT 1];
        BillingAccount__c mismatchedBan = new BillingAccount__c(
            Account__c           = otherAcc.Id,
            DE_Entity__c         = origBan.DE_Entity__c,
            Invoice_Frequency__c = origBan.Invoice_Frequency__c
        );
        insert mismatchedBan;

        String linesJson = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{
                'itemId'           => oi.Id,
                'assetId'          => asset.Id,
                'productId'        => oi.Product2Id,
                'pricebookEntryId' => oi.PricebookEntryId,
                'changeType'       => 'NO_CHANGE',
                'quantity'         => 2,
                'unitPrice'        => 5000,
                'billingMode'      => null,
                'odooProductId'    => null,
                'description'      => null
            }
        });

        Test.startTest();
        Boolean threw = false;
        try {
            ChangeOrderController.createChangeOrder(
                ord.Id, 'BAN Change', 'Merger_Acquisition', null, null, linesJson, mismatchedBan.Id
            );
        } catch (AuraHandledException e) {
            threw = true;
            System.assert(
                e.getMessage().contains('Cannot create the change order'),
                'Should surface a change-order failure message: ' + e.getMessage()
            );
        }
        Test.stopTest();

        System.assert(threw, 'Mismatched BAN should fail the Quote lookup filter and be caught as a DmlException');
    }

    @IsTest
    static void testCreateChangeOrder_suspension_invalidPicklist_throws() {
        Order ord = [SELECT Id FROM Order LIMIT 1];
        OrderItem oi = [SELECT Id, Product2Id, PricebookEntryId FROM OrderItem LIMIT 1];
        Asset asset = [SELECT Id FROM Asset WHERE Source_OrderItem__c = :oi.Id LIMIT 1];

        // 'Suspension' is not a value on Opportunity.Order_Type__c (restricted picklist),
        // so Opportunity insert fails and is caught by the generic (non-BAN) DmlException branch.
        String linesJson = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{
                'itemId'           => oi.Id,
                'assetId'          => asset.Id,
                'productId'        => oi.Product2Id,
                'pricebookEntryId' => oi.PricebookEntryId,
                'changeType'       => 'CHANGE',
                'newQuantity'      => 3,
                'newUnitPrice'     => null,
                'quantity'         => 2,
                'unitPrice'        => 5000,
                'billingMode'      => null,
                'odooProductId'    => null,
                'description'      => null
            }
        });

        Test.startTest();
        Boolean threw = false;
        try {
            ChangeOrderController.createChangeOrder(
                ord.Id, 'Suspension', 'Product_Change', null, null, linesJson, null
            );
        } catch (AuraHandledException e) {
            threw = true;
            System.assert(
                e.getMessage().contains('Cannot create the change order'),
                'Should surface the generic DML failure message: ' + e.getMessage()
            );
        }
        Test.stopTest();

        System.assert(threw, 'Suspension should fail Opportunity.Order_Type__c validation');
    }

    @IsTest
    static void testCreateChangeOrder_resumption_invalidPicklist_throws() {
        Order ord = [SELECT Id FROM Order LIMIT 1];
        OrderItem oi = [SELECT Id, Product2Id, PricebookEntryId FROM OrderItem LIMIT 1];
        Asset asset = [SELECT Id FROM Asset WHERE Source_OrderItem__c = :oi.Id LIMIT 1];

        // 'Resumption' is likewise not a value on Opportunity.Order_Type__c.
        String linesJson = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{
                'itemId'           => oi.Id,
                'assetId'          => asset.Id,
                'productId'        => oi.Product2Id,
                'pricebookEntryId' => oi.PricebookEntryId,
                'changeType'       => 'CHANGE',
                'newQuantity'      => 1,
                'newUnitPrice'     => null,
                'quantity'         => 2,
                'unitPrice'        => 5000,
                'billingMode'      => null,
                'odooProductId'    => null,
                'description'      => null
            }
        });

        Test.startTest();
        Boolean threw = false;
        try {
            ChangeOrderController.createChangeOrder(
                ord.Id, 'Resumption', 'Upsell_New_Add', null, null, linesJson, null
            );
        } catch (AuraHandledException e) {
            threw = true;
            System.assert(
                e.getMessage().contains('Cannot create the change order'),
                'Should surface the generic DML failure message: ' + e.getMessage()
            );
        }
        Test.stopTest();

        System.assert(threw, 'Resumption should fail Opportunity.Order_Type__c validation');
    }

    // Split into three standalone tests (each gets fresh @TestSetup data) rather
    // than three sequential createChangeOrder calls in one test — chaining multiple
    // CO creations against the same Original_Order__c in a single transaction
    // triggers an unrelated fault in the org's Opportunity "Assign SE" flow.
    @IsTest
    static void testMapAmendmentReason_nullReason() {
        Order ord = [SELECT Id FROM Order LIMIT 1];
        OrderItem oi = [SELECT Id, Product2Id, PricebookEntryId FROM OrderItem LIMIT 1];
        Asset asset = [SELECT Id FROM Asset WHERE Source_OrderItem__c = :oi.Id LIMIT 1];
        String linesJson = amendmentReasonLinesJson(oi, asset);

        Test.startTest();
        // Null reason → Amendment_Reason__c left blank
        Id quoteId = ChangeOrderController.createChangeOrder(
            ord.Id, 'Change/Upsell', null, null, null, linesJson, null
        );
        Test.stopTest();

        Quote q = [SELECT Amendment_Reason__c FROM Quote WHERE Id = :quoteId];
        System.assertEquals(null, q.Amendment_Reason__c, 'Null reason should leave Amendment_Reason__c blank');
    }

    @IsTest
    static void testMapAmendmentReason_unmappedReason() {
        Order ord = [SELECT Id FROM Order LIMIT 1];
        OrderItem oi = [SELECT Id, Product2Id, PricebookEntryId FROM OrderItem LIMIT 1];
        Asset asset = [SELECT Id FROM Asset WHERE Source_OrderItem__c = :oi.Id LIMIT 1];
        String linesJson = amendmentReasonLinesJson(oi, asset);

        Test.startTest();
        // Unrecognized reason → falls through to 'Other'
        Id quoteId = ChangeOrderController.createChangeOrder(
            ord.Id, 'Change/Upsell', 'Some_Unmapped_Reason', null, null, linesJson, null
        );
        Test.stopTest();

        Quote q = [SELECT Amendment_Reason__c FROM Quote WHERE Id = :quoteId];
        System.assertEquals('Other', q.Amendment_Reason__c, 'Unmapped reason should fall through to Other');
    }

    @IsTest
    static void testMapAmendmentReason_siteTransfer() {
        Order ord = [SELECT Id FROM Order LIMIT 1];
        OrderItem oi = [SELECT Id, Product2Id, PricebookEntryId FROM OrderItem LIMIT 1];
        Asset asset = [SELECT Id FROM Asset WHERE Source_OrderItem__c = :oi.Id LIMIT 1];
        String linesJson = amendmentReasonLinesJson(oi, asset);

        Test.startTest();
        // Site_Transfer → 'Transfer'
        Id quoteId = ChangeOrderController.createChangeOrder(
            ord.Id, 'Change/Upsell', 'Site_Transfer', null, null, linesJson, null
        );
        Test.stopTest();

        Quote q = [SELECT Amendment_Reason__c FROM Quote WHERE Id = :quoteId];
        System.assertEquals('Transfer', q.Amendment_Reason__c, 'Site_Transfer should map to Transfer');
    }

    private static String amendmentReasonLinesJson(OrderItem oi, Asset asset) {
        return JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{
                'itemId'           => oi.Id,
                'assetId'          => asset.Id,
                'productId'        => oi.Product2Id,
                'pricebookEntryId' => oi.PricebookEntryId,
                'changeType'       => 'CHANGE',
                'newQuantity'      => 3,
                'newUnitPrice'     => null,
                'quantity'         => 2,
                'unitPrice'        => 5000,
                'billingMode'      => null,
                'odooProductId'    => null,
                'description'      => null
            }
        });
    }

    // ── getActiveOrderItems: A/Z-side asset resolution ────────────────────────────

    @IsTest
    static void testGetActiveOrderItems_withSideAssets() {
        Order ord = [SELECT Id, AccountId, Pricebook2Id FROM Order LIMIT 1];
        Product2 prod = [SELECT Id FROM Product2 WHERE ProductCode = 'CAB.SH.RC' LIMIT 1];
        PricebookEntry pbe = [SELECT Id FROM PricebookEntry WHERE Product2Id = :prod.Id AND Pricebook2Id = :ord.Pricebook2Id LIMIT 1];

        Asset aSide = new Asset(
            Name = 'A-Side Cross Connect', AccountId = ord.AccountId,
            Product2Id = prod.Id, Quantity = 1, Status = 'Installed'
        );
        insert aSide;
        Asset zSide = new Asset(
            Name = 'Z-Side Cross Connect', AccountId = ord.AccountId,
            Product2Id = prod.Id, Quantity = 1, Status = 'Installed'
        );
        insert zSide;

        OrderItem oi2 = new OrderItem(
            OrderId          = ord.Id,
            PricebookEntryId = pbe.Id,
            Product2Id       = prod.Id,
            Quantity         = 1,
            UnitPrice        = 5000,
            Charge_Type__c   = 'MRC',
            Is_Active__c     = true
        );
        insert oi2;

        Asset mainAsset = new Asset(
            Name                = 'Cross Connect Main',
            AccountId           = ord.AccountId,
            Product2Id          = prod.Id,
            Quantity            = 1,
            Status              = 'Installed',
            Source_OrderItem__c = oi2.Id,
            A_Side_Asset__c     = aSide.Id,
            Z_Side_Asset__c     = zSide.Id
        );
        insert mainAsset;

        Test.startTest();
        List<ChangeOrderController.OrderLineRow> rows = ChangeOrderController.getActiveOrderItems(ord.Id);
        Test.stopTest();

        ChangeOrderController.OrderLineRow found = null;
        for (ChangeOrderController.OrderLineRow r : rows) {
            if (r.assetId == mainAsset.Id) { found = r; break; }
        }
        System.assertNotEquals(null, found, 'Should find the row for the asset with A/Z side links');
        System.assertEquals('A-Side Cross Connect', found.aSideAsset, 'A-side asset name should be resolved');
        System.assertEquals('Z-Side Cross Connect', found.zSideAsset, 'Z-side asset name should be resolved');
    }

    // ── getPendingActions: a real unprocessed child order ─────────────────────────

    @IsTest
    static void testGetPendingActions_returnsPendingOrder() {
        Order ord = [SELECT Id, AccountId, OpportunityId, Pricebook2Id, BillingAccount__c FROM Order LIMIT 1];
        Order pendingChild = new Order(
            AccountId             = ord.AccountId,
            OpportunityId         = ord.OpportunityId,
            Pricebook2Id          = ord.Pricebook2Id,
            EffectiveDate         = Date.today(),
            Status                = 'Draft',
            BillingAccount__c     = ord.BillingAccount__c,
            Original_Order__c     = ord.Id,
            Order_Type__c         = 'Change/Upsell',
            Integration_Status__c = 'Pending'
        );
        insert pendingChild;

        Test.startTest();
        List<Map<String, String>> pending = ChangeOrderController.getPendingActions(ord.Id);
        Test.stopTest();

        System.assertEquals(1, pending.size(), 'Should surface the unprocessed child order');
        System.assertEquals('Pending', pending[0].get('status'));
    }

    // ── searchAvailableProducts: account-level price overlay ──────────────────────

    @IsTest
    static void testSearchAvailableProducts_accountPriceOverlay() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'CO Test Customer' LIMIT 1];
        Product2 prod = [SELECT Id FROM Product2 WHERE ProductCode = 'CAB.SH.RC' LIMIT 1];

        Pricebook2 customPb = new Pricebook2(Name = 'CO Custom Pricebook', IsActive = true);
        insert customPb;
        PricebookEntry acctPbe = new PricebookEntry(
            Pricebook2Id = customPb.Id, Product2Id = prod.Id,
            UnitPrice = 4200, IsActive = true
        );
        insert acctPbe;

        acc.Customer_Pricebook__c = customPb.Id;
        update acc;

        Order ord = [SELECT Id FROM Order LIMIT 1];

        Test.startTest();
        List<Map<String, Object>> matches = ChangeOrderController.searchAvailableProducts(ord.Id, 'Full');
        Test.stopTest();

        System.assert(!matches.isEmpty(), 'Should still find the product');
        System.assertEquals(4200, (Decimal) matches[0].get('unitPrice'),
            'Account price overlay should override the standard pricebook price');
    }
}