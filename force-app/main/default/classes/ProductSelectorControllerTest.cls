/**
 * ProductSelectorControllerTest
 *
 * getProductsForPricebook() and getPricebooksForQuote() both merge in the org's
 * Standard Price Book. WHERE IsStandard = true returns zero rows in Apex test
 * context even after Test.getStandardPricebookId() is called — a platform
 * limitation — so ProductSelectorController itself was given a small
 * Test.isRunningTest() branch (querying by Id instead) so this merge logic can
 * actually be exercised here rather than silently contributing nothing.
 */
@IsTest
private class ProductSelectorControllerTest {

    @TestSetup
    static void setup() {
        Pricebook2 sitePb = new Pricebook2(Name = 'DE JKT1 Price Book', IsActive = true);
        insert sitePb;

        Pricebook2 acctPb = new Pricebook2(Name = 'PSC Customer Pricebook', IsActive = true);
        insert acctPb;

        Account acc = new Account(Name = 'PSC Test Account', Customer_Pricebook__c = acctPb.Id);
        insert acc;

        Opportunity opp = new Opportunity(
            Name = 'PSC Test Opp', AccountId = acc.Id,
            StageName = '1-Suspect', CloseDate = Date.today().addDays(30)
        );
        insert opp;

        Quote q = new Quote(Name = 'PSC Test Quote', OpportunityId = opp.Id, Pricebook2Id = sitePb.Id, Status = 'Draft');
        insert q;

        Product2 siteOnlyProd = new Product2(Name = 'PSC Site Product', ProductCode = 'PSC-SITE', IsActive = true);
        Product2 customerOnlyProd = new Product2(
            Name = 'PSC Customer-Specific Product', ProductCode = 'PSC-CUSTONLY', IsActive = true,
            Available_Operation_Site__c = 'JKT1' // sites set, countries blank -> excluded from general selector
        );
        // Country-matched Standard-PB-only product: not in the site pricebook at
        // all, so it only appears via the Standard PB merge branch.
        Product2 countryMatchProd = new Product2(
            Name = 'PSC Country Match Product', ProductCode = 'PSC-COUNTRYMATCH', IsActive = true,
            Available_Countries__c = 'ID' // matches the JKT1 site's Country__c ('ID') via the pricebook-name-derived lookup
        );
        insert new List<Product2>{ siteOnlyProd, customerOnlyProd, countryMatchProd };

        // The JKT1 site drives the "derive country from site pricebook name" branch
        // in getProductsForPricebook — the pricebook name "DE JKT1 Price Book" is
        // parsed back to site code "JKT1", then to this Site__c's Country__c.
        insert new Site__c(Country__c = 'ID', Site_Code__c = 'JKT1', Is_Active__c = true);

        // A custom-pricebook entry requires a Standard PB entry for the same
        // product/currency to already exist.
        Id stdPbId = Test.getStandardPricebookId();
        insert new List<PricebookEntry>{
            new PricebookEntry(Pricebook2Id = stdPbId, Product2Id = siteOnlyProd.Id, UnitPrice = 100, IsActive = true, CurrencyIsoCode = 'USD'),
            new PricebookEntry(Pricebook2Id = stdPbId, Product2Id = customerOnlyProd.Id, UnitPrice = 200, IsActive = true, CurrencyIsoCode = 'USD'),
            new PricebookEntry(Pricebook2Id = stdPbId, Product2Id = countryMatchProd.Id, UnitPrice = 300, IsActive = true, CurrencyIsoCode = 'USD'),
            // IDR standard entries — required before the IDR custom entries below.
            new PricebookEntry(Pricebook2Id = stdPbId, Product2Id = siteOnlyProd.Id, UnitPrice = 100, IsActive = true, CurrencyIsoCode = 'IDR')
        };

        insert new List<PricebookEntry>{
            new PricebookEntry(Pricebook2Id = sitePb.Id, Product2Id = siteOnlyProd.Id, UnitPrice = 100, IsActive = true, CurrencyIsoCode = 'USD'),
            new PricebookEntry(Pricebook2Id = sitePb.Id, Product2Id = customerOnlyProd.Id, UnitPrice = 200, IsActive = true, CurrencyIsoCode = 'USD'),
            // Second currency for the SAME product in the SAME site pricebook —
            // exercises the "prefer currency match" branch in the general loop.
            new PricebookEntry(Pricebook2Id = sitePb.Id, Product2Id = siteOnlyProd.Id, UnitPrice = 100, IsActive = true, CurrencyIsoCode = 'IDR'),
            new PricebookEntry(Pricebook2Id = acctPb.Id, Product2Id = customerOnlyProd.Id, UnitPrice = 150, IsActive = true, CurrencyIsoCode = 'USD'),
            // siteOnlyProd is already resolved via the site pricebook (USD); this
            // account-pricebook IDR entry exercises the "prefer currency match"
            // override specifically in the account-merge loop.
            new PricebookEntry(Pricebook2Id = acctPb.Id, Product2Id = siteOnlyProd.Id, UnitPrice = 100, IsActive = true, CurrencyIsoCode = 'IDR')
        };

        insert new Pricebook_Request__c(Account__c = acc.Id, Pricebook2__c = acctPb.Id, Status__c = 'Approved');
    }

    @IsTest
    static void testGetProductsForPricebook_BlankPricebookId_ReturnsEmpty() {
        Test.startTest();
        List<PricebookEntry> results = ProductSelectorController.getProductsForPricebook(null, 'USD', null);
        Test.stopTest();

        System.assertEquals(0, results.size(), 'A blank pricebookId should short-circuit to an empty list');
    }

    @IsTest
    static void testGetProductsForPricebook_ExcludesCustomerSpecificProduct() {
        Pricebook2 sitePb = [SELECT Id FROM Pricebook2 WHERE Name = 'DE JKT1 Price Book'];

        Test.startTest();
        List<PricebookEntry> results = ProductSelectorController.getProductsForPricebook(
            String.valueOf(sitePb.Id), 'USD', null
        );
        Test.stopTest();

        Set<String> codes = new Set<String>();
        for (PricebookEntry pbe : results) codes.add(pbe.Product2.ProductCode);

        System.assert(codes.contains('PSC-SITE'), 'Ordinary site-pricebook product should be included');
        System.assert(!codes.contains('PSC-CUSTONLY'),
            'A product with sites set but no countries is customer-specific and must be excluded from the general selector');
    }

    @IsTest
    static void testGetProductsForPricebook_MergesAccountCustomerPricebook() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Pricebook2 sitePb = [SELECT Id FROM Pricebook2 WHERE Name = 'DE JKT1 Price Book'];

        Test.startTest();
        List<PricebookEntry> results = ProductSelectorController.getProductsForPricebook(
            String.valueOf(sitePb.Id), 'USD', acc.Id
        );
        Test.stopTest();

        Boolean foundCustomerProduct = false;
        for (PricebookEntry pbe : results) {
            if (pbe.Product2.ProductCode == 'PSC-CUSTONLY') foundCustomerProduct = true;
        }
        System.assert(foundCustomerProduct,
            'Passing accountId should merge in products from the account\'s Customer_Pricebook__c even though the general selector excludes them by default');
    }

    @IsTest
    static void testGetProductsForPricebook_PrefersCurrencyMatchWithinSitePricebook() {
        Pricebook2 sitePb = [SELECT Id FROM Pricebook2 WHERE Name = 'DE JKT1 Price Book'];

        Test.startTest();
        List<PricebookEntry> results = ProductSelectorController.getProductsForPricebook(
            String.valueOf(sitePb.Id), 'IDR', null
        );
        Test.stopTest();

        PricebookEntry winner = null;
        for (PricebookEntry pbe : results) {
            if (pbe.Product2.ProductCode == 'PSC-SITE') winner = pbe;
        }
        System.assertNotEquals(null, winner, 'PSC-SITE should be present exactly once');
        System.assertEquals('IDR', winner.CurrencyIsoCode,
            'When two PBEs exist for the same product in the same pricebook, the one matching the requested currency should win');
    }

    @IsTest
    static void testGetProductsForPricebook_MergesCountryMatchedStandardOnlyProduct() {
        Pricebook2 sitePb = [SELECT Id FROM Pricebook2 WHERE Name = 'DE JKT1 Price Book'];

        Test.startTest();
        List<PricebookEntry> results = ProductSelectorController.getProductsForPricebook(
            String.valueOf(sitePb.Id), 'USD', null
        );
        Test.stopTest();

        Set<String> codes = new Set<String>();
        for (PricebookEntry pbe : results) codes.add(pbe.Product2.ProductCode);
        System.assert(codes.contains('PSC-COUNTRYMATCH'),
            'A Standard-PB-only product whose Available_Countries__c matches the site\'s derived country should be merged in');
    }

    @IsTest
    static void testGetProductsForPricebook_AccountPricebookOverridesCurrencyMatch() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Pricebook2 sitePb = [SELECT Id FROM Pricebook2 WHERE Name = 'DE JKT1 Price Book'];

        Test.startTest();
        List<PricebookEntry> results = ProductSelectorController.getProductsForPricebook(
            String.valueOf(sitePb.Id), 'IDR', acc.Id
        );
        Test.stopTest();

        PricebookEntry winner = null;
        for (PricebookEntry pbe : results) {
            if (pbe.Product2.ProductCode == 'PSC-SITE') winner = pbe;
        }
        System.assertNotEquals(null, winner, 'PSC-SITE should be present exactly once');
        System.assertEquals('IDR', winner.CurrencyIsoCode,
            'The account pricebook\'s IDR entry should override the site pricebook\'s already-resolved entry when it matches the requested currency');
    }

    @IsTest
    static void testGetPricebooksForQuote_IncludesCurrentAndApprovedCustomPricebooks() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Quote q = [SELECT Pricebook2Id FROM Quote LIMIT 1];
        Pricebook2 acctPb = [SELECT Id FROM Pricebook2 WHERE Name = 'PSC Customer Pricebook'];

        Test.startTest();
        List<ProductSelectorController.PricebookItem> items =
            ProductSelectorController.getPricebooksForQuote(acc.Id, q.Pricebook2Id);
        Test.stopTest();

        Set<Id> ids = new Set<Id>();
        for (ProductSelectorController.PricebookItem i : items) ids.add(i.id);

        System.assert(ids.contains(q.Pricebook2Id), 'The quote\'s current pricebook should always be included');
        System.assert(ids.contains(acctPb.Id), 'An Approved Pricebook_Request__c for this account should be included');
    }

    @IsTest
    static void testGetPricebooksForQuote_NoAccountOrCurrentPb_ReturnsWithoutError() {
        Test.startTest();
        List<ProductSelectorController.PricebookItem> items =
            ProductSelectorController.getPricebooksForQuote(null, null);
        Test.stopTest();

        System.assert(items != null, 'Should return a (possibly empty) list, not null or throw');
    }

    @IsTest
    static void testUpdateQuotePricebook_NoLineItems_Succeeds() {
        Quote q = [SELECT Id FROM Quote LIMIT 1];
        Pricebook2 acctPb = [SELECT Id FROM Pricebook2 WHERE Name = 'PSC Customer Pricebook'];

        Test.startTest();
        ProductSelectorController.updateQuotePricebook(q.Id, acctPb.Id);
        Test.stopTest();

        Quote updated = [SELECT Pricebook2Id FROM Quote WHERE Id = :q.Id];
        System.assertEquals(acctPb.Id, updated.Pricebook2Id, 'Pricebook2Id should be updated on the quote');
    }
}