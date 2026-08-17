@IsTest
private class PricebookRequestControllerTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = 'PBR Ctrl Test Co', Operation_Country__c = 'Singapore');
        insert acc;

        Opportunity opp = new Opportunity(
            Name      = 'PBR Ctrl Opp',
            AccountId = acc.Id,
            StageName = '3-Qualified',
            CloseDate = Date.today().addMonths(3)
        );
        insert opp;

        Id pbId = Test.getStandardPricebookId();

        Product2 prod1 = new Product2(
            Name        = 'Cabinet 1U',
            IsActive    = true,
            ProductCode = 'CAB.1U.001'
        );
        Product2 prod2 = new Product2(
            Name        = 'Cross Connect',
            IsActive    = true,
            ProductCode = 'XC.001'
        );
        insert new List<Product2>{ prod1, prod2 };

        PricebookEntry pbe1 = new PricebookEntry(
            Pricebook2Id = pbId,
            Product2Id   = prod1.Id,
            UnitPrice    = 500,
            IsActive     = true
        );
        PricebookEntry pbe2 = new PricebookEntry(
            Pricebook2Id = pbId,
            Product2Id   = prod2.Id,
            UnitPrice    = 150,
            IsActive     = true
        );
        insert new List<PricebookEntry>{ pbe1, pbe2 };

        Quote q = new Quote(
            Name           = 'PBR Test Quote',
            OpportunityId  = opp.Id,
            Pricebook2Id   = pbId,
            Status         = 'Draft',
            ExpirationDate = Date.today().addDays(30)
        );
        insert q;

        // Approved pricebook request for getApprovedPricebooksForAccount
        Pricebook2 customPb = new Pricebook2(Name = 'Custom PB for Test', IsActive = true);
        insert customPb;

        Pricebook_Request__c approvedReq = new Pricebook_Request__c(
            Account__c    = acc.Id,
            Status__c     = 'Approved',
            Currency__c   = 'USD',
            Pricebook2__c = customPb.Id
        );
        insert approvedReq;
    }

    @IsTest
    static void testGetQuoteContext() {
        Quote q = [SELECT Id FROM Quote LIMIT 1];

        Test.startTest();
        PricebookRequestController.QuoteContext ctx =
            PricebookRequestController.getQuoteContext(q.Id);
        Test.stopTest();

        System.assertNotEquals(null, ctx.quoteId);
        System.assertEquals('PBR Ctrl Test Co', ctx.accountName);
        System.assertNotEquals(null, ctx.currentPricebookId);
    }

    @IsTest
    static void testSearchProducts() {
        Id pbId = Test.getStandardPricebookId();

        Test.startTest();
        List<PricebookRequestController.ProductRow> results =
            PricebookRequestController.searchProducts(pbId, 'Cabinet');
        Test.stopTest();

        System.assert(!results.isEmpty(), 'Should find Cabinet product');
        System.assertEquals('CAB.1U.001', results[0].productCode);
    }

    @IsTest
    static void testSearchProducts_blankTerm() {
        Id pbId = Test.getStandardPricebookId();

        Test.startTest();
        List<PricebookRequestController.ProductRow> results =
            PricebookRequestController.searchProducts(pbId, '');
        Test.stopTest();

        System.assert(results.size() >= 2, 'Blank search should return all products');
    }

    @IsTest
    static void testGetCatalogProducts() {
        Id pbId = Test.getStandardPricebookId();

        Test.startTest();
        List<PricebookRequestController.ProductRow> results =
            PricebookRequestController.getCatalogProducts(pbId, null);
        Test.stopTest();

        System.assert(results.size() >= 2, 'Should return at least 2 products');
    }

    @IsTest
    static void testGetCatalogProducts_nullPricebook() {
        Test.startTest();
        List<PricebookRequestController.ProductRow> results =
            PricebookRequestController.getCatalogProducts(null, null);
        Test.stopTest();

        System.assertEquals(0, results.size(), 'Null pricebook should return empty list');
    }

    @IsTest
    static void testGetProductsByIds() {
        Id pbId = Test.getStandardPricebookId();
        Product2 prod = [SELECT Id FROM Product2 WHERE ProductCode = 'CAB.1U.001' LIMIT 1];

        Test.startTest();
        List<PricebookRequestController.ProductRow> results =
            PricebookRequestController.getProductsByIds(String.valueOf(prod.Id), pbId, 'USD');
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Should find 1 product by ID');
        System.assertEquals('Cabinet 1U', results[0].productName);
    }

    @IsTest
    static void testGetProductsByIds_blank() {
        Id pbId = Test.getStandardPricebookId();

        Test.startTest();
        List<PricebookRequestController.ProductRow> results =
            PricebookRequestController.getProductsByIds('', pbId, 'USD');
        Test.stopTest();

        System.assertEquals(0, results.size(), 'Blank IDs should return empty list');
    }

    @IsTest
    static void testGetAvailablePricebooks() {
        Test.startTest();
        List<PricebookRequestController.PricebookOption> opts =
            PricebookRequestController.getAvailablePricebooks();
        Test.stopTest();

        System.assert(!opts.isEmpty(), 'Should return at least one pricebook');
    }

    @IsTest
    static void testGetApprovedPricebooksForAccount() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'PBR Ctrl Test Co' LIMIT 1];

        Test.startTest();
        List<PricebookRequestController.PricebookOption> opts =
            PricebookRequestController.getApprovedPricebooksForAccount(acc.Id);
        Test.stopTest();

        System.assertEquals(1, opts.size(), 'Should find 1 approved custom pricebook');
        System.assert(opts[0].isCustom, 'Pricebook should be marked as custom');
    }

    @IsTest
    static void testCreateAndSubmit() {
        Quote q = [SELECT Id, AccountId FROM Quote LIMIT 1];
        Product2 prod = [SELECT Id FROM Product2 WHERE ProductCode = 'CAB.1U.001' LIMIT 1];

        String linesJson = '[{"productId":"' + prod.Id + '","productName":"Cabinet 1U","unitPrice":450}]';

        Test.startTest();
        Id reqId = PricebookRequestController.submitPricebookRequest(
            q.Id, q.AccountId, null, 'USD', linesJson, 'Test notes', UserInfo.getUserId()
        );
        Test.stopTest();

        System.assertNotEquals(null, reqId, 'Should return Pricebook_Request__c Id');

        Pricebook_Request__c req = [
            SELECT Status__c, Product_Summary__c
            FROM Pricebook_Request__c
            WHERE Id = :reqId
        ];
        System.assertEquals('Pending Approval', req.Status__c);
        System.assert(req.Product_Summary__c.contains('Cabinet 1U'),
            'Product summary should contain product name');

        List<Pricebook_Request_Line__c> reqLines = [
            SELECT Unit_Price__c FROM Pricebook_Request_Line__c
            WHERE Pricebook_Request__c = :reqId
        ];
        System.assertEquals(1, reqLines.size(), 'Should have 1 request line');
        System.assertEquals(450, reqLines[0].Unit_Price__c);
    }

    @IsTest
    static void testCreateAndSubmit_noLines() {
        Quote q = [SELECT Id, AccountId FROM Quote LIMIT 1];

        Test.startTest();
        Boolean caught = false;
        try {
            PricebookRequestController.submitPricebookRequest(
                q.Id, q.AccountId, null, 'USD', '[]', null, UserInfo.getUserId()
            );
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();

        System.assert(caught, 'Should throw for empty lines');
    }

    @IsTest
    static void testCreateAndSubmit_noApprover() {
        Quote q = [SELECT Id, AccountId FROM Quote LIMIT 1];
        Product2 prod = [SELECT Id FROM Product2 WHERE ProductCode = 'CAB.1U.001' LIMIT 1];

        String linesJson = '[{"productId":"' + prod.Id + '","productName":"Cabinet 1U","unitPrice":450}]';

        Test.startTest();
        Boolean caught = false;
        try {
            PricebookRequestController.submitPricebookRequest(
                q.Id, q.AccountId, null, 'USD', linesJson, null, null
            );
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();

        System.assert(caught, 'Should throw for null approver');
    }
}