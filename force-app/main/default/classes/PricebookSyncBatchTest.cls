/**
 * PricebookSyncBatchTest
 * Covers the three core outcomes of PricebookSyncBatch.execute(): creating a
 * missing Standard PB entry + site PBE from scratch, copying an existing
 * Standard PB price onto a new site PBE without re-creating the Standard one,
 * and skipping a product whose site PBE already exists.
 */
@IsTest
private class PricebookSyncBatchTest {

    @TestSetup
    static void setup() {
        Pricebook2 sitePb = new Pricebook2(Name = 'PSB Test Site Pricebook', IsActive = true);
        insert sitePb;

        Site__c site = new Site__c(
            Country__c      = 'ID',
            Site_Code__c    = 'JKT1',
            Pricebook2__c   = sitePb.Id,
            Is_Active__c    = true
        );
        insert site;

        // Product A: no PricebookEntries anywhere yet — exercises the
        // "create Standard PBE at $0, then copy to site PBE" path.
        Product2 prodNoEntries = new Product2(
            Name = 'PSB No Entries', ProductCode = 'PSB-NOENTRY',
            IsActive = true, Available_Countries__c = 'ID'
        );

        // Product B: already has a Standard PB entry with a real price —
        // exercises "copy existing Standard price, don't re-create it".
        Product2 prodWithStdEntry = new Product2(
            Name = 'PSB With Std Entry', ProductCode = 'PSB-STDENTRY',
            IsActive = true, Available_Operation_Site__c = 'JKT1'
        );

        // Product C: already fully synced (site PBE already exists) —
        // exercises the "skip, already present" path.
        Product2 prodAlreadySynced = new Product2(
            Name = 'PSB Already Synced', ProductCode = 'PSB-SYNCED',
            IsActive = true, Available_Countries__c = 'ID'
        );

        insert new List<Product2>{ prodNoEntries, prodWithStdEntry, prodAlreadySynced };

        Id stdPbId = Test.getStandardPricebookId();
        insert new PricebookEntry(
            Pricebook2Id = stdPbId, Product2Id = prodWithStdEntry.Id,
            UnitPrice = 500, IsActive = true, CurrencyIsoCode = 'IDR'
        );

        insert new List<PricebookEntry>{
            new PricebookEntry(Pricebook2Id = stdPbId, Product2Id = prodAlreadySynced.Id,
                                UnitPrice = 250, IsActive = true, CurrencyIsoCode = 'IDR'),
            new PricebookEntry(Pricebook2Id = sitePb.Id, Product2Id = prodAlreadySynced.Id,
                                UnitPrice = 250, IsActive = true, CurrencyIsoCode = 'IDR')
        };
    }

    @IsTest
    static void testNoExistingEntries_CreatesStandardAndSitePBEAtZero() {
        Product2 prod = [SELECT Id FROM Product2 WHERE ProductCode = 'PSB-NOENTRY'];
        Site__c site = [SELECT Pricebook2__c FROM Site__c LIMIT 1];

        // Test.getStandardPricebookId() unlocks SOQL visibility of the Standard
        // Price Book, but only for the test method it's called in — calling it in
        // @TestSetup does not carry over. PricebookSyncBatch.start() queries the
        // Standard Price Book directly, so this must run before the batch does.
        Test.getStandardPricebookId();

        Test.startTest();
        Database.executeBatch(new PricebookSyncBatch(), 100);
        Test.stopTest();

        PricebookEntry stdPbe = [
            SELECT UnitPrice FROM PricebookEntry
            WHERE Product2Id = :prod.Id AND Pricebook2Id = :Test.getStandardPricebookId()
        ];
        System.assertEquals(0, stdPbe.UnitPrice, 'Missing Standard PBE should be created at $0');

        PricebookEntry sitePbe = [
            SELECT UnitPrice FROM PricebookEntry
            WHERE Product2Id = :prod.Id AND Pricebook2Id = :site.Pricebook2__c
        ];
        System.assertEquals(0, sitePbe.UnitPrice, 'Site PBE should copy the (newly $0) Standard price');
    }

    @IsTest
    static void testExistingStandardEntry_CopiesPriceWithoutDuplicating() {
        Product2 prod = [SELECT Id FROM Product2 WHERE ProductCode = 'PSB-STDENTRY'];
        Site__c site = [SELECT Pricebook2__c FROM Site__c LIMIT 1];

        // Test.getStandardPricebookId() unlocks SOQL visibility of the Standard
        // Price Book, but only for the test method it's called in — calling it in
        // @TestSetup does not carry over. PricebookSyncBatch.start() queries the
        // Standard Price Book directly, so this must run before the batch does.
        Test.getStandardPricebookId();

        Test.startTest();
        Database.executeBatch(new PricebookSyncBatch(), 100);
        Test.stopTest();

        Integer stdCount = [
            SELECT COUNT() FROM PricebookEntry
            WHERE Product2Id = :prod.Id AND Pricebook2Id = :Test.getStandardPricebookId()
        ];
        System.assertEquals(1, stdCount, 'Existing Standard PBE must not be duplicated');

        PricebookEntry sitePbe = [
            SELECT UnitPrice FROM PricebookEntry
            WHERE Product2Id = :prod.Id AND Pricebook2Id = :site.Pricebook2__c
        ];
        System.assertEquals(500, sitePbe.UnitPrice,
            'New site PBE should copy the existing Standard PB price (500), not $0');
    }

    @IsTest
    static void testAlreadySyncedProduct_IsSkipped_NoDuplicateSitePbe() {
        Product2 prod = [SELECT Id FROM Product2 WHERE ProductCode = 'PSB-SYNCED'];
        Site__c site = [SELECT Pricebook2__c FROM Site__c LIMIT 1];

        // Test.getStandardPricebookId() unlocks SOQL visibility of the Standard
        // Price Book, but only for the test method it's called in — calling it in
        // @TestSetup does not carry over. PricebookSyncBatch.start() queries the
        // Standard Price Book directly, so this must run before the batch does.
        Test.getStandardPricebookId();

        Test.startTest();
        Database.executeBatch(new PricebookSyncBatch(), 100);
        Test.stopTest();

        Integer siteCount = [
            SELECT COUNT() FROM PricebookEntry
            WHERE Product2Id = :prod.Id AND Pricebook2Id = :site.Pricebook2__c
        ];
        System.assertEquals(1, siteCount, 'A product already synced to the site pricebook must not get a duplicate PBE');
    }
}