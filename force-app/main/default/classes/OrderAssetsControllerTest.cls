@IsTest
private class OrderAssetsControllerTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = 'Test IB Customer', Operation_Country__c = 'Singapore');
        insert acc;

        Opportunity opp = new Opportunity(
            Name      = 'Test IB Opp',
            AccountId = acc.Id,
            StageName = '3-Qualified',
            CloseDate = Date.today().addMonths(3)
        );
        insert opp;

        Id pbId = Test.getStandardPricebookId();

        Product2 mrcProd = new Product2(
            Name = 'Full Cab', IsActive = true, ProductCode = 'CAB.SH.RC',
            QuantityUnitOfMeasure = 'Cab'
        );
        Product2 nrcProd = new Product2(
            Name = 'Full Cab NRC', IsActive = true, ProductCode = 'CAB.SH.NR',
            QuantityUnitOfMeasure = 'Cab'
        );
        insert new List<Product2>{ mrcProd, nrcProd };

        PricebookEntry mrcPbe = new PricebookEntry(
            Pricebook2Id = pbId, Product2Id = mrcProd.Id,
            UnitPrice = 5000, IsActive = true
        );
        PricebookEntry nrcPbe = new PricebookEntry(
            Pricebook2Id = pbId, Product2Id = nrcProd.Id,
            UnitPrice = 1000, IsActive = true
        );
        insert new List<PricebookEntry>{ mrcPbe, nrcPbe };

        Order ord = new Order(
            AccountId    = acc.Id,
            OpportunityId = opp.Id,
            Pricebook2Id = pbId,
            EffectiveDate = Date.today(),
            Status        = 'Draft'
        );
        insert ord;

        OrderItem mrcItem = new OrderItem(
            OrderId          = ord.Id,
            PricebookEntryId = mrcPbe.Id,
            Product2Id       = mrcProd.Id,
            Quantity         = 2,
            UnitPrice        = 5000
        );
        OrderItem nrcItem = new OrderItem(
            OrderId          = ord.Id,
            PricebookEntryId = nrcPbe.Id,
            Product2Id       = nrcProd.Id,
            Quantity         = 2,
            UnitPrice        = 1000,
            Charge_Type__c   = 'NRC'
        );
        insert new List<OrderItem>{ mrcItem, nrcItem };

        Asset ast = new Asset(
            Name            = 'CAB-SG-001',
            AccountId       = acc.Id,
            Product2Id      = mrcProd.Id,
            Source_Order__c  = ord.Id,
            Status          = 'Installed',
            MRC__c          = 5000,
            NRC__c          = 1000,
            Quantity        = 1,
            InstallDate     = Date.today()
        );
        insert ast;
    }

    @IsTest
    static void testGetByOrder() {
        Order ord = [SELECT Id FROM Order LIMIT 1];
        Test.startTest();
        List<Asset> result = OrderAssetsController.getByOrder(ord.Id);
        Test.stopTest();
        System.assertEquals(1, result.size(), 'Should find 1 asset for this order');
        System.assertEquals('CAB-SG-001', result[0].Name);
    }

    @IsTest
    static void testGetByAccount() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Test.startTest();
        List<Asset> result = OrderAssetsController.getByAccount(acc.Id);
        Test.stopTest();
        System.assertEquals(1, result.size(), 'Should find 1 asset for this account');
        System.assertNotEquals(null, result[0].Product2);
    }

    @IsTest
    static void testGetAccountAssetSummary() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Test.startTest();
        Map<String, Object> summary = OrderAssetsController.getAccountAssetSummary(acc.Id);
        Test.stopTest();
        System.assertEquals(1, summary.get('total'), 'Should count 1 asset');
        System.assertEquals(5000, (Decimal)summary.get('totalMrc'), 'MRC should be 5000');
        Map<String, Integer> byStatus = (Map<String, Integer>)summary.get('byStatus');
        System.assert(byStatus.containsKey('Installed'), 'Should have Installed status');
    }

    @IsTest
    static void testGetNrcItems() {
        Order ord = [SELECT Id FROM Order LIMIT 1];
        Test.startTest();
        List<OrderAssetsController.NrcItem> result = OrderAssetsController.getNrcItems(ord.Id);
        Test.stopTest();
        System.assertEquals(1, result.size(), 'Should find 1 NRC order item');
        System.assertEquals('Full Cab NRC', result[0].productName);
    }

    @IsTest
    static void testGetByOrder_noAssets() {
        Test.startTest();
        List<Asset> result = OrderAssetsController.getByOrder(null);
        Test.stopTest();
        System.assertEquals(0, result.size(), 'Null order ID should return empty list');
    }

    @IsTest
    static void testGetByAccount_noAssets() {
        // Use a fake ID that won't match any account
        Account fakeAcc = new Account(Name = 'No Assets Co', Operation_Country__c = 'Japan');
        insert fakeAcc;
        Test.startTest();
        List<Asset> result = OrderAssetsController.getByAccount(fakeAcc.Id);
        Test.stopTest();
        System.assertEquals(0, result.size(), 'Account with no assets should return empty');
    }

    @IsTest
    static void testGetLinkedChangeOrderQuote_found() {
        Asset ast = [SELECT Id, Product2Id FROM Asset LIMIT 1];
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        PricebookEntry pbe = [SELECT Id, Product2Id, Pricebook2Id, UnitPrice FROM PricebookEntry WHERE Product2Id = :ast.Product2Id LIMIT 1];

        Quote q = new Quote(
            Name          = 'Change Order Quote',
            OpportunityId = opp.Id,
            Pricebook2Id  = pbe.Pricebook2Id
        );
        insert q;

        QuoteLineItem qli = new QuoteLineItem(
            QuoteId           = q.Id,
            PricebookEntryId  = pbe.Id,
            Product2Id        = pbe.Product2Id,
            Quantity          = 1,
            UnitPrice         = pbe.UnitPrice,
            Asset__c          = ast.Id,
            Change_Type__c    = 'CHANGE'
        );
        insert qli;

        Quote insertedQuote = [SELECT Id, Name FROM Quote WHERE Id = :q.Id];

        Test.startTest();
        OrderAssetsController.LinkedQuoteInfo info = OrderAssetsController.getLinkedChangeOrderQuote(ast.Id);
        Test.stopTest();

        System.assertNotEquals(null, info, 'Should find the pending change order quote');
        System.assertEquals(insertedQuote.Id, info.quoteId, 'Quote Id should match the linked change order quote');
        System.assertEquals(insertedQuote.Name, info.quoteName, 'Quote name should match the persisted Quote name');
    }

    @IsTest
    static void testGetLinkedChangeOrderQuote_none() {
        Asset ast = [SELECT Id FROM Asset LIMIT 1];
        Test.startTest();
        OrderAssetsController.LinkedQuoteInfo info = OrderAssetsController.getLinkedChangeOrderQuote(ast.Id);
        Test.stopTest();
        System.assertEquals(null, info, 'Asset with no pending change order quote should return null');
    }
}