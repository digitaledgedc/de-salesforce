/**
 * QuoteDiscoveryServiceTest
 *
 * Tests for QuoteDiscoveryService — bulk product-add for the Discover_Products flow.
 *
 * Adapted from a de-full seed test for the de-partial schema/business-rule set:
 *  - Opportunity.StageName uses de-partial's picklist ('2-Prospect', not 'Prospecting').
 *  - de-partial is multi-currency; PricebookEntry.CurrencyIsoCode is required and
 *    Opportunity/Quote currency is pinned to USD (the org's corporate currency) so it
 *    always matches the PricebookEntry rows built here.
 *  - Adds coverage for branches the seed did not exercise: pricebook auto-assignment,
 *    missing-PricebookEntry auto-creation (standard + site), account-pricebook price
 *    overlay, the active-ramp DML-failure -> HandledException path, composite
 *    "productId::attribute" parsing, multi-request invocation, NRC quantity
 *    recalculation, and a 200-record bulk add.
 */
@IsTest
private class QuoteDiscoveryServiceTest {

    @TestSetup
    static void makeData() {
        ProductSellingModel psm = new ProductSellingModel(
            Name = 'QDS Test Selling Model',
            SellingModelType = 'OneTime',
            Status = 'Active'
        );
        insert psm;

        Product2 p1 = new Product2(Name = 'Test Fiber 10G .RC', IsActive = true, ProductCode = 'TST001.RC');
        Product2 p2 = new Product2(Name = 'Test Fiber 20G .RC', IsActive = true, ProductCode = 'TST002.RC');
        Product2 p3 = new Product2(Name = 'Test Missing PBE Product', IsActive = true, ProductCode = 'TST003');
        Product2 p4 = new Product2(Name = 'Test Overlay Product', IsActive = true, ProductCode = 'TST004');
        insert new List<Product2>{ p1, p2, p3, p4 };
        insert new List<ProductSellingModelOption>{
            new ProductSellingModelOption(Product2Id = p1.Id, ProductSellingModelId = psm.Id, IsDefault = true),
            new ProductSellingModelOption(Product2Id = p2.Id, ProductSellingModelId = psm.Id, IsDefault = true),
            new ProductSellingModelOption(Product2Id = p3.Id, ProductSellingModelId = psm.Id, IsDefault = true),
            new ProductSellingModelOption(Product2Id = p4.Id, ProductSellingModelId = psm.Id, IsDefault = true)
        };

        Id stdPbId = Test.getStandardPricebookId();
        insert new List<PricebookEntry>{
            new PricebookEntry(Pricebook2Id = stdPbId, Product2Id = p1.Id, ProductSellingModelId = psm.Id, UnitPrice = 1000, CurrencyIsoCode = 'USD', IsActive = true),
            new PricebookEntry(Pricebook2Id = stdPbId, Product2Id = p2.Id, ProductSellingModelId = psm.Id, UnitPrice = 2000, CurrencyIsoCode = 'USD', IsActive = true),
            new PricebookEntry(Pricebook2Id = stdPbId, Product2Id = p3.Id, ProductSellingModelId = psm.Id, UnitPrice = 0, CurrencyIsoCode = 'USD', IsActive = true),
            new PricebookEntry(Pricebook2Id = stdPbId, Product2Id = p3.Id, ProductSellingModelId = psm.Id, UnitPrice = 999, CurrencyIsoCode = 'INR', IsActive = true),
            new PricebookEntry(Pricebook2Id = stdPbId, Product2Id = p4.Id, ProductSellingModelId = psm.Id, UnitPrice = 0, CurrencyIsoCode = 'USD', IsActive = true)
        };

        Pricebook2 pb = new Pricebook2(Name = 'Test PB', IsActive = true);
        Pricebook2 pbOtherCurrency = new Pricebook2(Name = 'Test PB Other Currency', IsActive = true);
        Pricebook2 acctPb = new Pricebook2(Name = 'Test Account PB', IsActive = true);
        insert new List<Pricebook2>{ pb, pbOtherCurrency, acctPb };

        insert new List<PricebookEntry>{
            new PricebookEntry(Pricebook2Id = pb.Id, Product2Id = p1.Id, ProductSellingModelId = psm.Id, UnitPrice = 1000, CurrencyIsoCode = 'USD', IsActive = true),
            new PricebookEntry(Pricebook2Id = pb.Id, Product2Id = p2.Id, ProductSellingModelId = psm.Id, UnitPrice = 2000, CurrencyIsoCode = 'USD', IsActive = true),
            new PricebookEntry(Pricebook2Id = pb.Id, Product2Id = p3.Id, ProductSellingModelId = psm.Id, UnitPrice = 0, CurrencyIsoCode = 'USD', IsActive = true),
            // Target pricebook price is $0 — should be overlaid with the account price
            new PricebookEntry(Pricebook2Id = pb.Id, Product2Id = p4.Id, ProductSellingModelId = psm.Id, UnitPrice = 0, CurrencyIsoCode = 'USD', IsActive = true),
            // Only a wrong-currency entry exists anywhere for p3 — forces the fallback/auto-create path
            new PricebookEntry(Pricebook2Id = pbOtherCurrency.Id, Product2Id = p3.Id, ProductSellingModelId = psm.Id, UnitPrice = 999, CurrencyIsoCode = 'INR', IsActive = true),
            // Account pricebook carries the real price for p4
            new PricebookEntry(Pricebook2Id = acctPb.Id, Product2Id = p4.Id, ProductSellingModelId = psm.Id, UnitPrice = 500, CurrencyIsoCode = 'USD', IsActive = true)
        };

        Account acct = new Account(Name = 'Test Account QDS', Customer_Pricebook__c = acctPb.Id);
        insert acct;

        Opportunity opp = new Opportunity(
            Name = 'Test Opp QDS', AccountId = acct.Id,
            CloseDate = Date.today().addDays(30), StageName = '2-Prospect',
            CurrencyIsoCode = 'USD'
        );
        insert opp;
        opp.Pricebook2Id = pb.Id;
        update opp;

        Quote q = new Quote(
            Name = 'Test Quote QDS', OpportunityId = opp.Id,
            Pricebook2Id = pb.Id, Status = 'Draft', CurrencyIsoCode = 'USD'
        );
        Quote qNoPb = new Quote(
            Name = 'Test Quote QDS NoPB', OpportunityId = opp.Id,
            Pricebook2Id = null, Status = 'Draft', CurrencyIsoCode = 'USD'
        );
	        insert new List<Quote>{ q, qNoPb };
	    }

	    private static Quote qdsQuote() {
	        return [
	            SELECT Id, Pricebook2Id
	            FROM Quote
	            WHERE Opportunity.Account.Name = 'Test Account QDS'
	            AND Pricebook2Id != null
	            ORDER BY CreatedDate ASC
	            LIMIT 1
	        ];
	    }

	    private static Quote qdsQuoteWithoutPricebook() {
	        Account acct = new Account(Name = 'QDS No Pricebook Account');
	        insert acct;

	        Opportunity opp = new Opportunity(
	            Name = 'QDS No Pricebook Opp',
	            AccountId = acct.Id,
	            CloseDate = Date.today().addDays(30),
	            StageName = '2-Prospect',
	            CurrencyIsoCode = 'USD'
	        );
	        insert opp;

	        Quote q = new Quote(
	            Name = 'QDS No Pricebook Quote',
	            OpportunityId = opp.Id,
	            Status = 'Draft',
	            CurrencyIsoCode = 'USD'
	        );
	        insert q;

	        return [
	            SELECT Id, Pricebook2Id
	            FROM Quote
	            WHERE Id = :q.Id
	            LIMIT 1
	        ];
	    }

	    @IsTest
	    static void testAddSingleProduct() {
	        Quote q = qdsQuote();
        Product2 p = [SELECT Id FROM Product2 WHERE ProductCode = 'TST001.RC' LIMIT 1];

        QuoteDiscoveryService.AddProductsRequest req = new QuoteDiscoveryService.AddProductsRequest();
        req.quoteId = q.Id;
        req.pricebookId = q.Pricebook2Id;
        req.selectedProductIds = p.Id;
        req.quantity = 1;

        Test.startTest();
        List<QuoteDiscoveryService.AddProductsResult> results =
            QuoteDiscoveryService.addProductsToQuote(
                new List<QuoteDiscoveryService.AddProductsRequest>{ req }
            );
        Test.stopTest();

        Assert.areEqual(1, results[0].createdCount, 'Should create 1 QLI');
        Assert.isNull(results[0].errorMessage, 'Should have no error');
        Assert.areEqual(1, [SELECT COUNT() FROM QuoteLineItem WHERE QuoteId = :q.Id]);
    }

	    @IsTest
	    static void testAddMultipleProducts() {
	        Quote q = qdsQuote();
        Product2 p1 = [SELECT Id FROM Product2 WHERE ProductCode = 'TST001.RC' LIMIT 1];
        Product2 p2 = [SELECT Id FROM Product2 WHERE ProductCode = 'TST002.RC' LIMIT 1];

        QuoteDiscoveryService.AddProductsRequest req = new QuoteDiscoveryService.AddProductsRequest();
        req.quoteId = q.Id;
        req.pricebookId = q.Pricebook2Id;
        req.selectedProductIds = p1.Id + ';' + p2.Id;
        req.quantity = 3;

        Test.startTest();
        List<QuoteDiscoveryService.AddProductsResult> results =
            QuoteDiscoveryService.addProductsToQuote(
                new List<QuoteDiscoveryService.AddProductsRequest>{ req }
            );
        Test.stopTest();

        Assert.areEqual(2, results[0].createdCount, 'Should create 2 QLIs');
        Assert.isNull(results[0].errorMessage, 'Should have no error');
        Assert.areEqual(2, [SELECT COUNT() FROM QuoteLineItem WHERE QuoteId = :q.Id]);
        Assert.areEqual(3, [SELECT Quantity FROM QuoteLineItem WHERE QuoteId = :q.Id LIMIT 1].Quantity,
            'Quantity should be 3');
    }

	    @IsTest
	    static void testBlankSelectionReturnsZero() {
	        Quote q = qdsQuote();

        QuoteDiscoveryService.AddProductsRequest req = new QuoteDiscoveryService.AddProductsRequest();
        req.quoteId = q.Id;
        req.pricebookId = q.Pricebook2Id;
        req.selectedProductIds = '';
        req.quantity = 1;

        Test.startTest();
        List<QuoteDiscoveryService.AddProductsResult> results =
            QuoteDiscoveryService.addProductsToQuote(
                new List<QuoteDiscoveryService.AddProductsRequest>{ req }
            );
        Test.stopTest();

        Assert.areEqual(0, results[0].createdCount, 'Blank selection should create 0 QLIs');
    }

	    @IsTest
	    static void testProductNotInPricebookIsSkipped() {
	        Quote q = qdsQuote();

        QuoteDiscoveryService.AddProductsRequest req = new QuoteDiscoveryService.AddProductsRequest();
        req.quoteId = q.Id;
        req.pricebookId = q.Pricebook2Id;
        req.selectedProductIds = '01t000000000001AAA'; // valid Product2 prefix, no matching record anywhere
        req.quantity = 1;

        Test.startTest();
        List<QuoteDiscoveryService.AddProductsResult> results =
            QuoteDiscoveryService.addProductsToQuote(
                new List<QuoteDiscoveryService.AddProductsRequest>{ req }
            );
        Test.stopTest();

        Assert.areEqual(0, results[0].createdCount, 'Product not in any pricebook should be skipped');
    }

	    @IsTest
	    static void testDefaultQuantityIsOne() {
	        Quote q = qdsQuote();
        Product2 p = [SELECT Id FROM Product2 WHERE ProductCode = 'TST001.RC' LIMIT 1];

        QuoteDiscoveryService.AddProductsRequest req = new QuoteDiscoveryService.AddProductsRequest();
        req.quoteId = q.Id;
        req.pricebookId = q.Pricebook2Id;
        req.selectedProductIds = p.Id;
        // quantity intentionally omitted

        Test.startTest();
        List<QuoteDiscoveryService.AddProductsResult> results =
            QuoteDiscoveryService.addProductsToQuote(
                new List<QuoteDiscoveryService.AddProductsRequest>{ req }
            );
        Test.stopTest();

        Assert.areEqual(1, results[0].createdCount, 'Should create 1 QLI');
        Assert.areEqual(1, [SELECT Quantity FROM QuoteLineItem WHERE QuoteId = :q.Id LIMIT 1].Quantity,
            'Default quantity should be 1');
    }

	    @IsTest
	    static void testQuoteWithoutPricebookGetsAssigned() {
	        Quote q = qdsQuoteWithoutPricebook();
        Pricebook2 pb = [SELECT Id FROM Pricebook2 WHERE Name = 'Test PB' LIMIT 1];
        Product2 p = [SELECT Id FROM Product2 WHERE ProductCode = 'TST001.RC' LIMIT 1];

        Assert.isNull(q.Pricebook2Id, 'Precondition: quote should start without a pricebook');

        QuoteDiscoveryService.AddProductsRequest req = new QuoteDiscoveryService.AddProductsRequest();
        req.quoteId = q.Id;
        req.pricebookId = pb.Id;
        req.selectedProductIds = p.Id;
        req.quantity = 1;

        Test.startTest();
        List<QuoteDiscoveryService.AddProductsResult> results =
            QuoteDiscoveryService.addProductsToQuote(
                new List<QuoteDiscoveryService.AddProductsRequest>{ req }
            );
        Test.stopTest();

        Assert.areEqual(1, results[0].createdCount, 'Should create 1 QLI');
        Quote refreshed = [SELECT Pricebook2Id FROM Quote WHERE Id = :q.Id];
        Assert.areEqual(pb.Id, refreshed.Pricebook2Id, 'Quote should adopt the pricebook from the request');
    }

	    @IsTest
	    static void testMissingPbeAutoCreatesStandardAndSitePbe() {
	        Quote q = qdsQuote();
        Product2 p3 = [SELECT Id FROM Product2 WHERE ProductCode = 'TST003' LIMIT 1];
        Id stdPbId = Test.getStandardPricebookId();

        QuoteDiscoveryService.AddProductsRequest req = new QuoteDiscoveryService.AddProductsRequest();
        req.quoteId = q.Id;
        req.pricebookId = q.Pricebook2Id;
        req.selectedProductIds = p3.Id;
        req.quantity = 1;

        Test.startTest();
        List<QuoteDiscoveryService.AddProductsResult> results =
            QuoteDiscoveryService.addProductsToQuote(
                new List<QuoteDiscoveryService.AddProductsRequest>{ req }
            );
        Test.stopTest();

        Assert.areEqual(1, results[0].createdCount, 'Should create 1 QLI once PBEs are auto-created');
        Assert.areEqual(1, [
            SELECT COUNT() FROM PricebookEntry
            WHERE Pricebook2Id = :stdPbId AND Product2Id = :p3.Id AND CurrencyIsoCode = 'USD'
        ], 'Standard PBE should have been auto-created');
        Assert.areEqual(1, [
            SELECT COUNT() FROM PricebookEntry
            WHERE Pricebook2Id = :q.Pricebook2Id AND Product2Id = :p3.Id AND CurrencyIsoCode = 'USD' AND IsActive = true
        ], 'Site PBE should have been auto-created in the target pricebook');
    }

	    @IsTest
	    static void testAccountPricebookOverlayForZeroPricedPbe() {
	        Quote q = qdsQuote();
        Product2 p4 = [SELECT Id FROM Product2 WHERE ProductCode = 'TST004' LIMIT 1];

        QuoteDiscoveryService.AddProductsRequest req = new QuoteDiscoveryService.AddProductsRequest();
        req.quoteId = q.Id;
        req.pricebookId = q.Pricebook2Id;
        req.selectedProductIds = p4.Id;
        req.quantity = 1;

        Test.startTest();
        List<QuoteDiscoveryService.AddProductsResult> results =
            QuoteDiscoveryService.addProductsToQuote(
                new List<QuoteDiscoveryService.AddProductsRequest>{ req }
            );
        Test.stopTest();

        Assert.areEqual(1, results[0].createdCount, 'Should create 1 QLI');
        QuoteLineItem qli = [SELECT UnitPrice, List_Price__c FROM QuoteLineItem WHERE QuoteId = :q.Id LIMIT 1];
        Assert.areEqual(500, qli.UnitPrice, 'Zero-priced site PBE should be overlaid with the account price');
        Assert.areEqual(500, qli.List_Price__c, 'List price should also reflect the overlay price');
    }

	    @IsTest
	    static void testAttributeValueParsing() {
	        Quote q = qdsQuote();
        Product2 p1 = [SELECT Id FROM Product2 WHERE ProductCode = 'TST001.RC' LIMIT 1];

        QuoteDiscoveryService.AddProductsRequest req = new QuoteDiscoveryService.AddProductsRequest();
        req.quoteId = q.Id;
        req.pricebookId = q.Pricebook2Id;
        req.selectedProductIds = p1.Id + '::6kVA';
        req.quantity = 2;

        Test.startTest();
        List<QuoteDiscoveryService.AddProductsResult> results =
            QuoteDiscoveryService.addProductsToQuote(
                new List<QuoteDiscoveryService.AddProductsRequest>{ req }
            );
        Test.stopTest();

        Assert.areEqual(1, results[0].createdCount, 'Should create 1 QLI');
        QuoteLineItem qli = [SELECT Product_Attribute_Value__c FROM QuoteLineItem WHERE QuoteId = :q.Id LIMIT 1];
        Assert.areEqual('6kVA', qli.Product_Attribute_Value__c, 'Attribute value should be parsed from the composite id');
    }

	    @IsTest
	    static void testMultipleRequestsInOneInvocation() {
	        Quote q = qdsQuote();
        Product2 p1 = [SELECT Id FROM Product2 WHERE ProductCode = 'TST001.RC' LIMIT 1];
        Product2 p2 = [SELECT Id FROM Product2 WHERE ProductCode = 'TST002.RC' LIMIT 1];

        QuoteDiscoveryService.AddProductsRequest req1 = new QuoteDiscoveryService.AddProductsRequest();
        req1.quoteId = q.Id;
        req1.pricebookId = q.Pricebook2Id;
        req1.selectedProductIds = p1.Id;
        req1.quantity = 2;

        QuoteDiscoveryService.AddProductsRequest req2 = new QuoteDiscoveryService.AddProductsRequest();
        req2.quoteId = q.Id;
        req2.pricebookId = q.Pricebook2Id;
        req2.selectedProductIds = p2.Id;
        req2.quantity = 3;

        Test.startTest();
        List<QuoteDiscoveryService.AddProductsResult> results =
            QuoteDiscoveryService.addProductsToQuote(
                new List<QuoteDiscoveryService.AddProductsRequest>{ req1, req2 }
            );
        Test.stopTest();

        Assert.areEqual(2, results.size(), 'Should return one result per request');
        Assert.areEqual(1, results[0].createdCount, 'First request should create 1 QLI');
        Assert.areEqual(1, results[1].createdCount, 'Second request should create 1 QLI');
        Assert.areEqual(2, [SELECT COUNT() FROM QuoteLineItem WHERE QuoteId = :q.Id]);
    }

	    @IsTest
	    static void testHandledExceptionOnActiveRampBlocksInsert() {
	        Quote q = qdsQuote();
        Product2 p1 = [SELECT Id FROM Product2 WHERE ProductCode = 'TST001.RC' LIMIT 1];
        PricebookEntry pbe1 = [
            SELECT Id FROM PricebookEntry WHERE Pricebook2Id = :q.Pricebook2Id AND Product2Id = :p1.Id LIMIT 1
        ];

        // An existing Ramp-origin line on the quote blocks any further non-ramp insert
        // (QuoteLineItemTriggerHandler.blockNonRampInserts), which surfaces as a DmlException
        // that QuoteDiscoveryService converts into a HandledException.
        insert new QuoteLineItem(
            QuoteId = q.Id, Product2Id = p1.Id, PricebookEntryId = pbe1.Id,
            Quantity = 1, UnitPrice = 1000, List_Price__c = 1000, Line_Origin__c = 'Ramp'
        );

        QuoteDiscoveryService.AddProductsRequest req = new QuoteDiscoveryService.AddProductsRequest();
        req.quoteId = q.Id;
        req.pricebookId = q.Pricebook2Id;
        req.selectedProductIds = p1.Id;
        req.quantity = 1;

        Boolean threw = false;
        Test.startTest();
        try {
            QuoteDiscoveryService.addProductsToQuote(
                new List<QuoteDiscoveryService.AddProductsRequest>{ req }
            );
        } catch (QuoteDiscoveryService.HandledException e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('ramp'), 'Should surface the ramp-block DML error message: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Expected a HandledException when the quote has an active ramp schedule');
    }

	    @IsTest
	    static void testNrcQuantityRecalculation() {
	        Quote q = qdsQuote();
        Id pbId = q.Pricebook2Id;

        Product2 pNrc = new Product2(Name = 'Test Install Charge', IsActive = true, ProductCode = 'TST-NRC-01');
        Product2 pMrc = new Product2(Name = 'Test Cabinet MRC', IsActive = true, ProductCode = 'TST-CAB-01');
        insert new List<Product2>{ pNrc, pMrc };
        pMrc.Paired_NRC_Product__c = pNrc.Id;
        update pMrc;

        ProductSellingModel psm = [SELECT Id FROM ProductSellingModel WHERE Name = 'QDS Test Selling Model' LIMIT 1];
        insert new List<ProductSellingModelOption>{
            new ProductSellingModelOption(Product2Id = pMrc.Id, ProductSellingModelId = psm.Id, IsDefault = true),
            new ProductSellingModelOption(Product2Id = pNrc.Id, ProductSellingModelId = psm.Id, IsDefault = true)
        };
        insert new List<PricebookEntry>{
            new PricebookEntry(Pricebook2Id = Test.getStandardPricebookId(), Product2Id = pMrc.Id, ProductSellingModelId = psm.Id, UnitPrice = 100, CurrencyIsoCode = 'USD', IsActive = true),
            new PricebookEntry(Pricebook2Id = Test.getStandardPricebookId(), Product2Id = pNrc.Id, ProductSellingModelId = psm.Id, UnitPrice = 50, CurrencyIsoCode = 'USD', IsActive = true)
        };

        PricebookEntry pbeMrc = new PricebookEntry(Pricebook2Id = pbId, Product2Id = pMrc.Id, ProductSellingModelId = psm.Id, UnitPrice = 100, CurrencyIsoCode = 'USD', IsActive = true);
        PricebookEntry pbeNrc = new PricebookEntry(Pricebook2Id = pbId, Product2Id = pNrc.Id, ProductSellingModelId = psm.Id, UnitPrice = 50, CurrencyIsoCode = 'USD', IsActive = true);
        insert new List<PricebookEntry>{ pbeMrc, pbeNrc };

        QuoteLineItem existingNrcLine = new QuoteLineItem(
            QuoteId = q.Id, Product2Id = pNrc.Id, PricebookEntryId = pbeNrc.Id,
            Quantity = 1, UnitPrice = 50, List_Price__c = 50,
            Charge_Type__c = 'NRC', Is_Auto_NRC__c = true
        );
        insert existingNrcLine;

        QuoteDiscoveryService.AddProductsRequest req = new QuoteDiscoveryService.AddProductsRequest();
        req.quoteId = q.Id;
        req.pricebookId = pbId;
        req.selectedProductIds = pMrc.Id;
        req.quantity = 5;

        Test.startTest();
        List<QuoteDiscoveryService.AddProductsResult> results =
            QuoteDiscoveryService.addProductsToQuote(
                new List<QuoteDiscoveryService.AddProductsRequest>{ req }
            );
        Test.stopTest();

        Assert.areEqual(1, results[0].createdCount, 'Should create 1 MRC line');
        QuoteLineItem refreshedNrc = [SELECT Quantity FROM QuoteLineItem WHERE Id = :existingNrcLine.Id];
        Assert.areEqual(5, refreshedNrc.Quantity, 'Paired NRC quantity should be recalculated to match the new MRC quantity');
    }

	    @IsTest
	    static void testBulkAddTwoHundredProducts() {
	        Quote q = qdsQuote();
        Id pbId = q.Pricebook2Id;

        List<Product2> bulkProducts = new List<Product2>();
        for (Integer i = 0; i < 200; i++) {
            bulkProducts.add(new Product2(Name = 'Bulk Product ' + i, IsActive = true, ProductCode = 'BULK-' + i));
        }
        insert bulkProducts;

        ProductSellingModel psm = [SELECT Id FROM ProductSellingModel WHERE Name = 'QDS Test Selling Model' LIMIT 1];
        List<ProductSellingModelOption> bulkOptions = new List<ProductSellingModelOption>();
        for (Product2 p : bulkProducts) {
            bulkOptions.add(new ProductSellingModelOption(Product2Id = p.Id, ProductSellingModelId = psm.Id, IsDefault = true));
        }
        insert bulkOptions;

        List<PricebookEntry> bulkStdPbes = new List<PricebookEntry>();
        for (Product2 p : bulkProducts) {
            bulkStdPbes.add(new PricebookEntry(Pricebook2Id = Test.getStandardPricebookId(), Product2Id = p.Id, ProductSellingModelId = psm.Id, UnitPrice = 10, CurrencyIsoCode = 'USD', IsActive = true));
        }
        insert bulkStdPbes;

        List<PricebookEntry> bulkPbes = new List<PricebookEntry>();
        for (Product2 p : bulkProducts) {
            bulkPbes.add(new PricebookEntry(Pricebook2Id = pbId, Product2Id = p.Id, ProductSellingModelId = psm.Id, UnitPrice = 10, CurrencyIsoCode = 'USD', IsActive = true));
        }
        insert bulkPbes;

        List<String> idStrings = new List<String>();
        for (Product2 p : bulkProducts) {
            idStrings.add(String.valueOf(p.Id));
        }

        QuoteDiscoveryService.AddProductsRequest req = new QuoteDiscoveryService.AddProductsRequest();
        req.quoteId = q.Id;
        req.pricebookId = pbId;
        req.selectedProductIds = String.join(idStrings, ';');
        req.quantity = 1;

        Test.startTest();
        List<QuoteDiscoveryService.AddProductsResult> results =
            QuoteDiscoveryService.addProductsToQuote(
                new List<QuoteDiscoveryService.AddProductsRequest>{ req }
            );
        Test.stopTest();

        Assert.areEqual(200, results[0].createdCount, 'Should bulk-create 200 QLIs');
        Assert.areEqual(200, [SELECT COUNT() FROM QuoteLineItem WHERE QuoteId = :q.Id]);
    }

    /**
     * Targets the "Sync Sales Price = List Price where kVA pricing set List Price
     * but Sales Price stayed $0" block (~line 286-297). QuoteLineItemTriggerHandler
     * (active org trigger, not in this repo's local metadata) resolves
     * Product_Attribute_Value__c against the real Product_Pricing_Tier__mdt custom
     * metadata and overwrites List_Price__c whenever a tier matches — but only
     * defaults Sales Price (UnitPrice) to List Price when Change_Type__c = 'NEW',
     * which QuoteDiscoveryService never sets. Inserting a QLI with UnitPrice=0 and
     * an attribute value that resolves to a priced tier reproduces the exact
     * divergence QuoteDiscoveryService's own post-insert fix-up is designed to catch.
     * Depends on the real org CMT record Product_Pricing_Tier__mdt.CAB001_RC_2kVA_USD
     * (Product_Code__c='CAB001.RC', Attribute_Value__c='2kVA', Site_Code__c=blank,
     * Currency_Code__c='USD', Price__c=920) confirmed present via
     * `sf data query "SELECT ... FROM Product_Pricing_Tier__mdt"` — if that CMT
     * record is ever renamed/removed/repriced this test will need updating.
     */
    @IsTest
    static void testKvaPricingTierSyncsZeroSalesPriceToListPrice() {
        Quote q = qdsQuote();
        ProductSellingModel psm = [SELECT Id FROM ProductSellingModel WHERE Name = 'QDS Test Selling Model' LIMIT 1];

        Product2 pKva = new Product2(Name = 'Test kVA Cabinet Product', IsActive = true, ProductCode = 'CAB001.RC');
        insert pKva;
        insert new ProductSellingModelOption(Product2Id = pKva.Id, ProductSellingModelId = psm.Id, IsDefault = true);
        // A standard PBE (same selling model + currency) must exist before any
        // custom/site-pricebook PBE can be created for this product/currency.
        insert new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(), Product2Id = pKva.Id, ProductSellingModelId = psm.Id,
            UnitPrice = 0, CurrencyIsoCode = 'USD', IsActive = true
        );
        insert new PricebookEntry(
            Pricebook2Id = q.Pricebook2Id, Product2Id = pKva.Id, ProductSellingModelId = psm.Id,
            UnitPrice = 0, CurrencyIsoCode = 'USD', IsActive = true
        );

        QuoteDiscoveryService.AddProductsRequest req = new QuoteDiscoveryService.AddProductsRequest();
        req.quoteId = q.Id;
        req.pricebookId = q.Pricebook2Id;
        req.selectedProductIds = pKva.Id + '::2kVA';
        req.quantity = 1;

        Test.startTest();
        List<QuoteDiscoveryService.AddProductsResult> results =
            QuoteDiscoveryService.addProductsToQuote(
                new List<QuoteDiscoveryService.AddProductsRequest>{ req }
            );
        Test.stopTest();

        Assert.areEqual(1, results[0].createdCount, 'Should create 1 QLI');
        QuoteLineItem qli = [
            SELECT UnitPrice, List_Price__c, Product_Attribute_Value__c
            FROM QuoteLineItem WHERE QuoteId = :q.Id AND Product2Id = :pKva.Id LIMIT 1
        ];
        Assert.areEqual('2kVA', qli.Product_Attribute_Value__c, 'Attribute value should be stamped from the composite id');
        Assert.isTrue(qli.List_Price__c > 0, 'CMT price tier should have set a non-zero List Price: ' + qli.List_Price__c);
        Assert.areEqual(qli.List_Price__c, qli.UnitPrice,
            'Sales Price should be synced to List Price when kVA pricing left Sales Price at $0');
    }

    /**
     * Targets the "missing PricebookEntry" resolution Steps 1-3 (~lines 128-197)
     * for the branches the other missing-PBE test does not reach:
     *  - Step 1 (account-pricebook same-currency match, lines 134-135) — p6 has NO
     *    PBE anywhere except the account pricebook.
     *  - Step 2 (any-currency fallback, lines 149-151) — p7 has NO PBE in the site
     *    or account pricebook, only a PBE in a completely different pricebook/currency.
     *  - Step 3's actual PBE-creation branches (lines 158-195) — unlike the sibling
     *    test (whose product already had a standard PBE from @TestSetup, so the
     *    "create new standard PBE" branch never actually ran), p6/p7 have NO
     *    standard PBE at all, forcing the real create-and-reselect code path.
     */
    @IsTest
    static void testMissingProductsResolveViaAccountPricebookAndAnyCurrencyFallback() {
        Quote q = qdsQuote();
        Id stdPbId = Test.getStandardPricebookId();
        ProductSellingModel psm = [SELECT Id FROM ProductSellingModel WHERE Name = 'QDS Test Selling Model' LIMIT 1];
        Pricebook2 acctPb = [SELECT Id FROM Pricebook2 WHERE Name = 'Test Account PB' LIMIT 1];
        Pricebook2 pbOther = [SELECT Id FROM Pricebook2 WHERE Name = 'Test PB Other Currency' LIMIT 1];

        Product2 p6 = new Product2(Name = 'Test Acct PB Fallback', IsActive = true, ProductCode = 'TST006');
        Product2 p7 = new Product2(Name = 'Test Any Currency Fallback', IsActive = true, ProductCode = 'TST007');
        insert new List<Product2>{ p6, p7 };
        insert new List<ProductSellingModelOption>{
            new ProductSellingModelOption(Product2Id = p6.Id, ProductSellingModelId = psm.Id, IsDefault = true),
            new ProductSellingModelOption(Product2Id = p7.Id, ProductSellingModelId = psm.Id, IsDefault = true)
        };

        // A standard PBE (same selling model + currency) must exist before any
        // custom/site-pricebook PBE can be created for that product/currency —
        // one standard PBE per currency actually used below (USD for p6, INR for p7).
        // These deliberately do NOT go in the quote's own site pricebook (pb), so
        // p6/p7 remain "missing" there and still exercise the fallback logic.
        //
        // IMPORTANT: left WITHOUT ProductSellingModelId (nillable field), matching
        // QuoteDiscoveryService's own auto-created standard/site PBEs (lines ~170-186),
        // which never set it either. Since p6 already has a standard PBE in the quote's
        // currency (USD) once we seed it here, the production code's hasStdPbe check
        // skips creating a new one for p6 — so the site PBE it creates later (also with
        // no selling model) can only satisfy the platform's "same selling model and
        // currency" rule if the one pre-existing standard PBE it finds is ALSO
        // selling-model-less. Setting ProductSellingModelId = psm.Id here caused a
        // mismatch (non-null vs. the null the production code uses) and threw
        // STANDARD_PRICE_NOT_DEFINED from inside QuoteDiscoveryService's own site-PBE
        // insert (line ~188), not from this setup.
        insert new List<PricebookEntry>{
            new PricebookEntry(Pricebook2Id = Test.getStandardPricebookId(), Product2Id = p6.Id, UnitPrice = 700, CurrencyIsoCode = 'USD', IsActive = true),
            new PricebookEntry(Pricebook2Id = Test.getStandardPricebookId(), Product2Id = p7.Id, UnitPrice = 555, CurrencyIsoCode = 'INR', IsActive = true)
        };

        // p6: only exists in the account pricebook (same currency as the quote).
        // Also selling-model-less, to match the standard PBE seeded above.
        insert new PricebookEntry(
            Pricebook2Id = acctPb.Id, Product2Id = p6.Id,
            UnitPrice = 700, CurrencyIsoCode = 'USD', IsActive = true
        );
        // p7: only exists in an unrelated pricebook, in a different currency —
        // not resolvable via the site or account pricebook, only the any-currency fallback
        insert new PricebookEntry(
            Pricebook2Id = pbOther.Id, Product2Id = p7.Id,
            UnitPrice = 555, CurrencyIsoCode = 'INR', IsActive = true
        );

        QuoteDiscoveryService.AddProductsRequest req = new QuoteDiscoveryService.AddProductsRequest();
        req.quoteId = q.Id;
        req.pricebookId = q.Pricebook2Id;
        req.selectedProductIds = p6.Id + ';' + p7.Id;
        req.quantity = 1;

        Test.startTest();
        List<QuoteDiscoveryService.AddProductsResult> results =
            QuoteDiscoveryService.addProductsToQuote(
                new List<QuoteDiscoveryService.AddProductsRequest>{ req }
            );
        Test.stopTest();

        Assert.areEqual(2, results[0].createdCount, 'Both fallback-resolved products should create a QLI');
        // p6 already had its mandatory USD standard PBE pre-created above (required by the
        // platform before the account-pricebook custom PBE could be inserted), so the
        // service's own "create missing standard PBE" branch is exercised via p7 instead,
        // which only had an INR standard PBE going in — the service must create a new
        // USD one before it can create the USD site PBE.
        Assert.areEqual(1, [
            SELECT COUNT() FROM PricebookEntry WHERE Pricebook2Id = :stdPbId AND Product2Id = :p7.Id AND CurrencyIsoCode = 'USD'
        ], 'A brand-new USD standard PBE should have been created for p7 (it only had an INR one before)');
        Assert.areEqual(1, [
            SELECT COUNT() FROM PricebookEntry WHERE Pricebook2Id = :q.Pricebook2Id AND Product2Id = :p6.Id AND IsActive = true
        ], 'A brand-new site PBE should have been created for p6');
        Assert.areEqual(1, [
            SELECT COUNT() FROM PricebookEntry WHERE Pricebook2Id = :q.Pricebook2Id AND Product2Id = :p7.Id AND IsActive = true
        ], 'A brand-new site PBE should have been created for p7');

        QuoteLineItem qli6 = [SELECT UnitPrice FROM QuoteLineItem WHERE QuoteId = :q.Id AND Product2Id = :p6.Id LIMIT 1];
        Assert.areEqual(700, qli6.UnitPrice, 'Account-pricebook fallback price should carry through to the new site PBE and QLI');

        QuoteLineItem qli7 = [SELECT UnitPrice FROM QuoteLineItem WHERE QuoteId = :q.Id AND Product2Id = :p7.Id LIMIT 1];
        Assert.areEqual(0, qli7.UnitPrice, 'Any-currency fallback with no usable price defaults the new PBE/QLI to $0');
    }

    /**
     * Targets the NRC-quantity-recalculation mismatch-update branch (~line 280),
     * which only fires when the sum of MRC line quantities differs from the
     * existing paired NRC line's quantity. NrcPairingService (verified via its
     * source: it inserts a brand-new NRC line only when none already exists for
     * that Quote+ProductCode key, and does nothing else — it never adjusts an
     * already-paired existing NRC line's quantity) will not interfere here since
     * existingNrcLine is pre-created before the service call ("already paired").
     * A separate, explicitly Charge_Type__c='MRC' line is pre-created (rather than
     * relying solely on the newly-inserted line, whose Charge_Type__c is always
     * null) so the recalculated sum deterministically differs from the stale
     * NRC quantity regardless of how the WHERE clause's `!=` comparisons treat nulls.
     */
    @IsTest
    static void testNrcRecalcUpdatesQuantityWhenMismatchPersists() {
        Quote q = qdsQuote();
        Id pbId = q.Pricebook2Id;

        Product2 pNrc2 = new Product2(Name = 'Test Install Charge 2', IsActive = true, ProductCode = 'TST-NRC-02');
        Product2 pMrc2 = new Product2(Name = 'Test Cabinet MRC 2', IsActive = true, ProductCode = 'TST-CAB-02');
        insert new List<Product2>{ pNrc2, pMrc2 };
        pMrc2.Paired_NRC_Product__c = pNrc2.Id;
        update pMrc2;

        ProductSellingModel psm = [SELECT Id FROM ProductSellingModel WHERE Name = 'QDS Test Selling Model' LIMIT 1];
        insert new List<ProductSellingModelOption>{
            new ProductSellingModelOption(Product2Id = pMrc2.Id, ProductSellingModelId = psm.Id, IsDefault = true),
            new ProductSellingModelOption(Product2Id = pNrc2.Id, ProductSellingModelId = psm.Id, IsDefault = true)
        };
        insert new List<PricebookEntry>{
            new PricebookEntry(Pricebook2Id = Test.getStandardPricebookId(), Product2Id = pMrc2.Id, ProductSellingModelId = psm.Id, UnitPrice = 100, CurrencyIsoCode = 'USD', IsActive = true),
            new PricebookEntry(Pricebook2Id = Test.getStandardPricebookId(), Product2Id = pNrc2.Id, ProductSellingModelId = psm.Id, UnitPrice = 50, CurrencyIsoCode = 'USD', IsActive = true)
        };

        PricebookEntry pbeMrc2 = new PricebookEntry(Pricebook2Id = pbId, Product2Id = pMrc2.Id, ProductSellingModelId = psm.Id, UnitPrice = 100, CurrencyIsoCode = 'USD', IsActive = true);
        PricebookEntry pbeNrc2 = new PricebookEntry(Pricebook2Id = pbId, Product2Id = pNrc2.Id, ProductSellingModelId = psm.Id, UnitPrice = 50, CurrencyIsoCode = 'USD', IsActive = true);
        insert new List<PricebookEntry>{ pbeMrc2, pbeNrc2 };

        // Pre-existing MRC line with an explicit (non-null) Charge_Type__c so it is
        // unambiguously included in the recalculated sum.
        insert new QuoteLineItem(
            QuoteId = q.Id, Product2Id = pMrc2.Id, PricebookEntryId = pbeMrc2.Id,
            Quantity = 10, UnitPrice = 100, List_Price__c = 100, Charge_Type__c = 'MRC'
        );

        // Existing paired NRC line whose quantity is already stale relative to the
        // MRC total above — forces the mismatch-update branch once the service call
        // triggers a fresh recalculation.
        QuoteLineItem existingNrcLine = new QuoteLineItem(
            QuoteId = q.Id, Product2Id = pNrc2.Id, PricebookEntryId = pbeNrc2.Id,
            Quantity = 3, UnitPrice = 50, List_Price__c = 50,
            Charge_Type__c = 'NRC', Is_Auto_NRC__c = true
        );
        insert existingNrcLine;

        QuoteDiscoveryService.AddProductsRequest req = new QuoteDiscoveryService.AddProductsRequest();
        req.quoteId = q.Id;
        req.pricebookId = pbId;
        req.selectedProductIds = pMrc2.Id;
        req.quantity = 2;

        Test.startTest();
        QuoteDiscoveryService.addProductsToQuote(
            new List<QuoteDiscoveryService.AddProductsRequest>{ req }
        );
        Test.stopTest();

        QuoteLineItem refreshedNrc = [SELECT Quantity FROM QuoteLineItem WHERE Id = :existingNrcLine.Id];
        Assert.areNotEqual(3, refreshedNrc.Quantity,
            'Paired NRC quantity should be recalculated once a real mismatch persists into QuoteDiscoveryService\'s own recalc block');
        Assert.isTrue(refreshedNrc.Quantity >= 10,
            'Recalculated quantity should fold in the pre-existing explicit-MRC line quantity: ' + refreshedNrc.Quantity);
    }
}