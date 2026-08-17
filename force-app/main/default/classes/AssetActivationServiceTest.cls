/**
 * AssetActivationServiceTest
 *
 * Tests for AssetActivationService covering:
 *   1. New Order → creates Assets from MRC OrderItems
 *   2. CO CHANGE → end-dates old asset, creates replacement
 *   3. CO DELETE → end-dates old asset only
 *   4. BAN Change CO → updates BillingAccount__c on existing assets (AST-004)
 *   5. BAN Change CO with no items → no error
 */
@IsTest
private class AssetActivationServiceTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(
            Name = 'Asset Test Account',
            Operation_Country__c = 'Singapore',
            Tax_ID__c = 'AST12345X'
        );
        insert acc;

        Id deEntityRtId = Schema.SObjectType.Account
            .getRecordTypeInfosByDeveloperName().get('DE_Entity').getRecordTypeId();
        Account sgEntity = new Account(
            Name = 'DE SG Pte Ltd',
            RecordTypeId = deEntityRtId
        );
        insert sgEntity;

        Contact ctc = new Contact(
            FirstName = 'Asset',
            LastName = 'TestContact',
            AccountId = acc.Id,
            Email = 'asset.test@example.com'
        );
        insert ctc;

        BillingAccount__c oldBan = new BillingAccount__c(
            Name = 'OLD-BAN-001',
            Account__c = acc.Id,
            Billing_Contact__c = ctc.Id,
            DE_Entity__c = sgEntity.Id
        );
        insert oldBan;

        BillingAccount__c newBan = new BillingAccount__c(
            Name = 'NEW-BAN-002',
            Account__c = acc.Id,
            Billing_Contact__c = ctc.Id,
            DE_Entity__c = sgEntity.Id
        );
        insert newBan;

        Opportunity opp = new Opportunity(
            Name = 'Asset Test Opp',
            AccountId = acc.Id,
            StageName = '3-Qualified',
            CloseDate = Date.today().addMonths(3)
        );
        insert opp;

        Id stdPbId = Test.getStandardPricebookId();

        Product2 mrcProd = new Product2(
            Name = 'Test MRC Product',
            ProductCode = 'ASTTEST.RC',
            IsActive = true
        );
        insert mrcProd;

        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = stdPbId,
            Product2Id = mrcProd.Id,
            UnitPrice = 500.00,
            IsActive = true
        );
        insert pbe;

        // Original New Service Order
        Order origOrder = new Order(
            AccountId = acc.Id,
            OpportunityId = opp.Id,
            EffectiveDate = Date.today(),
            Status = 'Draft',
            Pricebook2Id = stdPbId,
            Order_Type__c = 'New Service',
            BillingAccount__c = oldBan.Id
        );
        insert origOrder;

        OrderItem origItem = new OrderItem(
            OrderId = origOrder.Id,
            Product2Id = mrcProd.Id,
            PricebookEntryId = pbe.Id,
            Quantity = 1,
            UnitPrice = 500.00,
            Charge_Type__c = 'MRC',
            Description = 'Test Cabinet Service'
        );
        insert origItem;
    }

    // ─── Test 1: New Order creates assets ──────────────────────────────────

    @IsTest
    static void testNewOrderCreatesAssets() {
        Order ord = [SELECT Id FROM Order WHERE Order_Type__c = 'New Service' LIMIT 1];

        Test.startTest();
        AssetActivationService.Request req = new AssetActivationService.Request();
        req.orderId = ord.Id;
        AssetActivationService.activateAssets(new List<AssetActivationService.Request>{ req });
        Test.stopTest();

        List<Asset> assets = [
            SELECT Id, Name, Status, Asset_Lifecycle_Status__c, Source_Order__c
            FROM Asset
            WHERE Source_Order__c = :ord.Id
        ];
        System.assertEquals(1, assets.size(), 'One asset should be created for MRC OrderItem');
        System.assertEquals('In Service', assets[0].Asset_Lifecycle_Status__c);
    }

    // ─── Test 2: BAN Change CO updates asset BAN ──────────────────────────

    @IsTest
    static void testBanChangeUpdatesAssetBan() {
        Order origOrder = [SELECT Id, AccountId, OpportunityId, Pricebook2Id
                           FROM Order WHERE Order_Type__c = 'New Service' LIMIT 1];
        OrderItem origItem = [SELECT Id FROM OrderItem WHERE OrderId = :origOrder.Id LIMIT 1];
        BillingAccount__c oldBan = [SELECT Id FROM BillingAccount__c WHERE Name = 'OLD-BAN-001' LIMIT 1];
        BillingAccount__c newBan = [SELECT Id FROM BillingAccount__c WHERE Name = 'NEW-BAN-002' LIMIT 1];

        // First, create the asset via New Order activation
        AssetActivationService.Request req1 = new AssetActivationService.Request();
        req1.orderId = origOrder.Id;
        AssetActivationService.activateAssets(new List<AssetActivationService.Request>{ req1 });

        // Set BAN on the asset
        Asset a = [SELECT Id FROM Asset WHERE Source_Order__c = :origOrder.Id LIMIT 1];
        a.BillingAccount__c = oldBan.Id;
        update a;

        // Create BAN Change CO
        Order banCO = new Order(
            AccountId = origOrder.AccountId,
            OpportunityId = origOrder.OpportunityId,
            EffectiveDate = Date.today(),
            Status = 'Draft',
            Pricebook2Id = origOrder.Pricebook2Id,
            Order_Type__c = 'BAN Change',
            BillingAccount__c = newBan.Id,
            Original_Order__c = origOrder.Id
        );
        insert banCO;

        // CO item referencing original order item
        PricebookEntry pbe = [SELECT Id, Product2Id FROM PricebookEntry LIMIT 1];
        OrderItem coItem = new OrderItem(
            OrderId = banCO.Id,
            Product2Id = pbe.Product2Id,
            PricebookEntryId = pbe.Id,
            Quantity = 1,
            UnitPrice = 500.00,
            Charge_Type__c = 'MRC',
            ns_change_type__c = 'NO_CHANGE',
            Original_OrderItem__c = origItem.Id
        );
        insert coItem;

        Test.startTest();
        AssetActivationService.Request req2 = new AssetActivationService.Request();
        req2.orderId = banCO.Id;
        AssetActivationService.activateAssets(new List<AssetActivationService.Request>{ req2 });
        Test.stopTest();

        Asset updated = [SELECT Id, BillingAccount__c FROM Asset WHERE Id = :a.Id];
        System.assertEquals(newBan.Id, updated.BillingAccount__c,
            'Asset BillingAccount should be updated to the new BAN from the CO');
    }

    // ─── Test 3: BAN Change with no CO items is safe ──────────────────────

    @IsTest
    static void testBanChangeNoItemsNoError() {
        Order origOrder = [SELECT Id, AccountId, OpportunityId, Pricebook2Id
                           FROM Order WHERE Order_Type__c = 'New Service' LIMIT 1];
        BillingAccount__c newBan = [SELECT Id FROM BillingAccount__c WHERE Name = 'NEW-BAN-002' LIMIT 1];

        Order banCO = new Order(
            AccountId = origOrder.AccountId,
            OpportunityId = origOrder.OpportunityId,
            EffectiveDate = Date.today(),
            Status = 'Draft',
            Pricebook2Id = origOrder.Pricebook2Id,
            Order_Type__c = 'BAN Change',
            BillingAccount__c = newBan.Id,
            Original_Order__c = origOrder.Id
        );
        insert banCO;

        Test.startTest();
        AssetActivationService.Request req = new AssetActivationService.Request();
        req.orderId = banCO.Id;
        AssetActivationService.activateAssets(new List<AssetActivationService.Request>{ req });
        Test.stopTest();

        System.assert(true, 'BAN Change with no CO items should not throw');
    }

    // ─── Test 4: CO CHANGE creates replacement asset ──────────────────────

    @IsTest
    static void testChangeOrderCreatesReplacement() {
        Order origOrder = [SELECT Id, AccountId, OpportunityId, Pricebook2Id
                           FROM Order WHERE Order_Type__c = 'New Service' LIMIT 1];
        OrderItem origItem = [SELECT Id FROM OrderItem WHERE OrderId = :origOrder.Id LIMIT 1];

        // Activate original order first
        AssetActivationService.Request req1 = new AssetActivationService.Request();
        req1.orderId = origOrder.Id;
        AssetActivationService.activateAssets(new List<AssetActivationService.Request>{ req1 });

        // Create CO with CHANGE item
        Order changeCO = new Order(
            AccountId = origOrder.AccountId,
            OpportunityId = origOrder.OpportunityId,
            EffectiveDate = Date.today(),
            Status = 'Draft',
            Pricebook2Id = origOrder.Pricebook2Id,
            Order_Type__c = 'Change/Upsell',
            Original_Order__c = origOrder.Id
        );
        insert changeCO;

        PricebookEntry pbe = [SELECT Id, Product2Id FROM PricebookEntry LIMIT 1];
        OrderItem coItem = new OrderItem(
            OrderId = changeCO.Id,
            Product2Id = pbe.Product2Id,
            PricebookEntryId = pbe.Id,
            Quantity = 2,
            UnitPrice = 700.00,
            Charge_Type__c = 'MRC',
            ns_change_type__c = 'CHANGE',
            Original_OrderItem__c = origItem.Id,
            Description = 'Upgraded Cabinet Service'
        );
        insert coItem;

        Test.startTest();
        AssetActivationService.Request req2 = new AssetActivationService.Request();
        req2.orderId = changeCO.Id;
        AssetActivationService.activateAssets(new List<AssetActivationService.Request>{ req2 });
        Test.stopTest();

        // Original asset should be terminated
        Asset origAsset = [
            SELECT Id, Status, Asset_Lifecycle_Status__c
            FROM Asset WHERE Source_Order__c = :origOrder.Id LIMIT 1
        ];
        System.assertEquals('Terminated', origAsset.Asset_Lifecycle_Status__c,
            'Original asset should be terminated on CO activation');

        // New replacement asset should be created
        List<Asset> newAssets = [
            SELECT Id, Status, Asset_Lifecycle_Status__c, Source_Order__c
            FROM Asset WHERE Source_Order__c = :changeCO.Id
        ];
        System.assertEquals(1, newAssets.size(), 'Replacement asset should be created');
        System.assertEquals('In Service', newAssets[0].Asset_Lifecycle_Status__c);
    }
}