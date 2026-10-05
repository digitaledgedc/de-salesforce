/**
 * NrcPairingServiceTest
 *
 * Tests for NrcPairingService — automatic .NR installation charge pairing.
 */
@IsTest
private class NrcPairingServiceTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(
            Name = 'NRC Test Account',
            BillingCountry = 'Singapore',
            Operation_Country__c = 'Singapore',
            RecordTypeId = [SELECT Id FROM RecordType WHERE SObjectType = 'Account' AND DeveloperName = 'Customer' LIMIT 1].Id
        );
        insert acc;

        Opportunity opp = new Opportunity(
            Name = 'NRC Test Opp',
            AccountId = acc.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;

        // NRC products inserted first so their Ids are available to wire onto the
        // MRC products' Paired_NRC_Product__c — pairing now keys off that field
        // only, not the .RC/.NR code convention.
        Product2 nrcProd = new Product2(
            Name = 'Test NRC Installation',
            ProductCode = 'TEST001.NR',
            IsActive = true
        );
        insert nrcProd;

        // Paired NRC target for the "unpaired" MRC — deliberately given no
        // PricebookEntry in the custom pricebook so pairing skips on missing PBE.
        Product2 unpairedNrc = new Product2(
            Name = 'Test Unpaired NRC',
            ProductCode = 'TEST002.NR',
            IsActive = true
        );
        insert unpairedNrc;

        // MRC product
        Product2 mrcProd = new Product2(
            Name = 'Test MRC Cabinet',
            ProductCode = 'TEST001.RC',
            IsActive = true,
            Paired_NRC_Product__c = nrcProd.Id
        );
        insert mrcProd;

        // Non-paired MRC product (paired NRC product exists but has no PricebookEntry)
        Product2 unpaired = new Product2(
            Name = 'Test Unpaired MRC',
            ProductCode = 'TEST002.RC',
            IsActive = true,
            Paired_NRC_Product__c = unpairedNrc.Id
        );
        insert unpaired;

        // Product with no Paired_NRC_Product__c configured
        Product2 otherProd = new Product2(
            Name = 'Test Other Product',
            ProductCode = 'TEST003.GEN',
            IsActive = true
        );
        insert otherProd;

        // Standard pricebook entries (required before custom pricebook entries)
        Id stdPbId = Test.getStandardPricebookId();
        insert new List<PricebookEntry>{
            new PricebookEntry(Pricebook2Id = stdPbId, Product2Id = mrcProd.Id, UnitPrice = 1000.00, IsActive = true),
            new PricebookEntry(Pricebook2Id = stdPbId, Product2Id = nrcProd.Id, UnitPrice = 1650.00, IsActive = true),
            new PricebookEntry(Pricebook2Id = stdPbId, Product2Id = unpaired.Id, UnitPrice = 500.00, IsActive = true),
            new PricebookEntry(Pricebook2Id = stdPbId, Product2Id = otherProd.Id, UnitPrice = 200.00, IsActive = true)
        };

        Pricebook2 pb = new Pricebook2(Name = 'NRC Test PB', IsActive = true);
        insert pb;

        // Custom pricebook entries — NRC for TEST001 only (TEST002.NR deliberately absent)
        insert new List<PricebookEntry>{
            new PricebookEntry(Pricebook2Id = pb.Id, Product2Id = mrcProd.Id, UnitPrice = 1000.00, IsActive = true),
            new PricebookEntry(Pricebook2Id = pb.Id, Product2Id = nrcProd.Id, UnitPrice = 1650.00, IsActive = true),
            new PricebookEntry(Pricebook2Id = pb.Id, Product2Id = unpaired.Id, UnitPrice = 500.00, IsActive = true),
            new PricebookEntry(Pricebook2Id = pb.Id, Product2Id = otherProd.Id, UnitPrice = 200.00, IsActive = true)
        };

        Quote q = new Quote(
            Name = 'NRC Test Quote',
            OpportunityId = opp.Id,
            Pricebook2Id = pb.Id,
            CurrencyIsoCode = 'USD'
        );
        insert q;
    }

    // ── Integration tests ────────────────────────────────────────────────────

    /**
     * Service creates the paired NRC QLI when called for an MRC QLI.
     * Flow invocation is tested end-to-end in the org; here we validate the
     * service logic directly so coverage is stable regardless of flow deploy order.
     */
    @IsTest
    static void testNrcPairedOnMrcInsert() {
        Quote q = [SELECT Id, Pricebook2Id FROM Quote LIMIT 1];
        PricebookEntry mrcPbe = [
            SELECT Id FROM PricebookEntry
            WHERE Pricebook2Id = :q.Pricebook2Id
            AND Product2.ProductCode = 'TEST001.RC'
            LIMIT 1
        ];

        QuoteLineItem mrcQli = new QuoteLineItem(
            QuoteId = q.Id,
            PricebookEntryId = mrcPbe.Id,
            Quantity = 1,
            UnitPrice = 1000.00
        );
        insert mrcQli;

        Test.startTest();
        NrcPairingService.pairNrcToMrc(new Set<Id>{ mrcQli.Id });
        Test.stopTest();

        List<QuoteLineItem> nrcLines = [
            SELECT Id, Product2.ProductCode, UnitPrice
            FROM QuoteLineItem
            WHERE QuoteId = :q.Id
            AND Product2.ProductCode = 'TEST001.NR'
        ];
        System.assertEquals(1, nrcLines.size(), 'NRC QLI should be created by service');
        System.assertEquals(1650.00, nrcLines[0].UnitPrice, 'NRC should carry pricebook price');
    }

    /**
     * Calling pairNrcToMrc when NRC already exists must not create a duplicate.
     */
    @IsTest
    static void testNoDuplicateOnRerun() {
        Quote q = [SELECT Id, Pricebook2Id FROM Quote LIMIT 1];
        PricebookEntry mrcPbe = [
            SELECT Id FROM PricebookEntry
            WHERE Pricebook2Id = :q.Pricebook2Id
            AND Product2.ProductCode = 'TEST001.RC'
            LIMIT 1
        ];
        PricebookEntry nrcPbe = [
            SELECT Id FROM PricebookEntry
            WHERE Pricebook2Id = :q.Pricebook2Id
            AND Product2.ProductCode = 'TEST001.NR'
            LIMIT 1
        ];

        QuoteLineItem mrcQli = new QuoteLineItem(
            QuoteId = q.Id, PricebookEntryId = mrcPbe.Id, Quantity = 1, UnitPrice = 1000.00
        );
        insert mrcQli;

        // Manually insert NRC to simulate "already paired" state
        insert new QuoteLineItem(
            QuoteId = q.Id, PricebookEntryId = nrcPbe.Id, Quantity = 1, UnitPrice = 1650.00
        );

        Test.startTest();
        NrcPairingService.pairNrcToMrc(new Set<Id>{ mrcQli.Id });
        Test.stopTest();

        Integer nrcCount = [
            SELECT COUNT() FROM QuoteLineItem
            WHERE QuoteId = :q.Id AND Product2.ProductCode = 'TEST001.NR'
        ];
        System.assertEquals(1, nrcCount, 'No duplicate NRC should be created');
    }

    /**
     * MRC product with no matching NRC in the pricebook — service skips silently.
     */
    @IsTest
    static void testMrcWithNoPricebookNrcSkipped() {
        Quote q = [SELECT Id, Pricebook2Id FROM Quote LIMIT 1];
        PricebookEntry unpairedPbe = [
            SELECT Id FROM PricebookEntry
            WHERE Pricebook2Id = :q.Pricebook2Id
            AND Product2.ProductCode = 'TEST002.RC'
            LIMIT 1
        ];

        QuoteLineItem qli = new QuoteLineItem(
            QuoteId = q.Id, PricebookEntryId = unpairedPbe.Id, Quantity = 1, UnitPrice = 500.00
        );

        Test.startTest();
        insert qli;
        Test.stopTest();

        Integer nrcCount = [
            SELECT COUNT() FROM QuoteLineItem
            WHERE QuoteId = :q.Id AND Product2.ProductCode = 'TEST002.NR'
        ];
        System.assertEquals(0, nrcCount, 'No NRC created when pricebook entry absent');
    }

    /**
     * Non-.RC product — service skips.
     */
    @IsTest
    static void testNonRcProductSkipped() {
        Quote q = [SELECT Id, Pricebook2Id FROM Quote LIMIT 1];
        PricebookEntry otherPbe = [
            SELECT Id FROM PricebookEntry
            WHERE Pricebook2Id = :q.Pricebook2Id
            AND Product2.ProductCode = 'TEST003.GEN'
            LIMIT 1
        ];

        QuoteLineItem qli = new QuoteLineItem(
            QuoteId = q.Id, PricebookEntryId = otherPbe.Id, Quantity = 1, UnitPrice = 200.00
        );

        Test.startTest();
        insert qli;
        NrcPairingService.pairNrcToMrc(new Set<Id>{ qli.Id });
        Test.stopTest();

        Integer total = [SELECT COUNT() FROM QuoteLineItem WHERE QuoteId = :q.Id AND Product2.ProductCode LIKE '%.NR'];
        System.assertEquals(0, total, 'Non-.RC product should not trigger NRC creation');
    }

    /**
     * Null input handled gracefully.
     */
    @IsTest
    static void testNullInputHandled() {
        Test.startTest();
        NrcPairingService.pairNrcToMrc(null);
        Test.stopTest();
        System.assert(true, 'Null input should not throw');
    }

    /**
     * Empty input handled gracefully.
     */
    @IsTest
    static void testEmptyInputHandled() {
        Test.startTest();
        NrcPairingService.pairNrcToMrc(new Set<Id>());
        Test.stopTest();
        System.assert(true, 'Empty input should not throw');
    }

    /**
     * Invocable method wrapper executes without error.
     */
    @IsTest
    static void testInvocableMethod() {
        Quote q = [SELECT Id, Pricebook2Id FROM Quote LIMIT 1];
        PricebookEntry mrcPbe = [
            SELECT Id FROM PricebookEntry
            WHERE Pricebook2Id = :q.Pricebook2Id AND Product2.ProductCode = 'TEST001.RC' LIMIT 1
        ];
        QuoteLineItem qli = new QuoteLineItem(
            QuoteId = q.Id, PricebookEntryId = mrcPbe.Id, Quantity = 1, UnitPrice = 1000.00
        );
        insert qli;

        Test.startTest();
        NrcPairingService.pairNrcProducts(new List<Id>{ qli.Id });
        Test.stopTest();
        System.assert(true, 'Invocable entry point should not throw');
    }
}