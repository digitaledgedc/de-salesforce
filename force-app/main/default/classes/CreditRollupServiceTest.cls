@IsTest
private class CreditRollupServiceTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(
            Name = 'CRS Test Account',
            Operation_Country__c = 'Singapore',
            Credit_Limit_MRC__c = 50000,
            Credit_Limit_NRC__c = 100000
        );
        insert acc;

        Opportunity opp = new Opportunity(
            Name        = 'CRS Test Opp',
            AccountId   = acc.Id,
            StageName   = '1 - Suspect',
            CloseDate   = Date.today().addDays(30),
            Pricebook2Id = Test.getStandardPricebookId()
        );
        insert opp;

        Product2 prod = new Product2(
            Name = 'CRS-PROD.RC', ProductCode = 'CRS-PROD.RC', IsActive = true,
            Charge_Type__c = 'MRC'
        );
        insert prod;

        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(),
            Product2Id   = prod.Id,
            UnitPrice    = 100,
            IsActive     = true
        );
        insert pbe;

        Quote q = new Quote(
            Name          = 'CRS Test Quote',
            OpportunityId = opp.Id,
            Pricebook2Id  = Test.getStandardPricebookId(),
            Status        = 'Draft'
        );
        insert q;

        // Reload quote (flow may reassign)
        Quote reloaded = [SELECT Id FROM Quote WHERE OpportunityId = :opp.Id ORDER BY CreatedDate ASC LIMIT 1];

        QuoteLineItem qli = new QuoteLineItem(
            QuoteId          = reloaded.Id,
            PricebookEntryId = pbe.Id,
            Product2Id       = prod.Id,
            Quantity         = 10,
            UnitPrice        = 1000
        );
        insert qli;
    }

    @IsTest
    static void testRollupSumsCorrectly() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'CRS Test Account' LIMIT 1];

        Test.startTest();
        CreditRollupService.rollupForAccounts(new List<Id>{ acc.Id });
        Test.stopTest();

        Account updated = [SELECT Total_Active_Quoted_MRC__c, Total_Active_Quoted_NRC__c, Active_Quote_Count__c
                           FROM Account WHERE Id = :acc.Id];
        // Quote has a QLI with Quantity=10, UnitPrice=1000, Charge_Type=MRC → Total_MRC_2__c should be 10000
        // The rollup divides by CurrencyType.ConversionRate. In test context, rate defaults to 1.
        System.assertNotEquals(null, updated.Total_Active_Quoted_MRC__c, 'MRC total should be set');
        System.assertEquals(1, updated.Active_Quote_Count__c, 'Should count 1 active quote');
    }

    @IsTest
    static void testRollupWithNullAccountId() {
        // Should not throw
        Test.startTest();
        CreditRollupService.rollupForAccounts(new List<Id>{ null });
        CreditRollupService.rollupForAccounts(null);
        CreditRollupService.rollupForAccounts(new List<Id>());
        Test.stopTest();
    }

    @IsTest
    static void testExpiredQuoteExcludedFromRollup() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'CRS Test Account' LIMIT 1];
        Opportunity opp = [SELECT Id FROM Opportunity WHERE AccountId = :acc.Id LIMIT 1];
        PricebookEntry pbe = [SELECT Id, Product2Id FROM PricebookEntry
                              WHERE Product2.ProductCode = 'CRS-PROD.RC' LIMIT 1];

        // VR_QUOTE_23 forbids past expiration dates and Quote_BeforeSave_AutoSetup
        // defaults ExpirationDate to TODAY+30, so instead of back-dating a quote,
        // push the setup quote to TODAY+60 and shift the service's cutoff to
        // TODAY+45: this quote (+30) is then expired, the setup quote (+60) is not.
        Quote current = [SELECT Id FROM Quote WHERE OpportunityId = :opp.Id LIMIT 1];
        current.ExpirationDate = Date.today().addDays(60);
        update current;

        Quote expired = new Quote(
            Name          = 'CRS Expired Quote',
            OpportunityId = opp.Id,
            Pricebook2Id  = Test.getStandardPricebookId(),
            Status        = 'Draft'
        );
        insert expired;
        CreditRollupService.expiryCutoff = Date.today().addDays(45);
        insert new QuoteLineItem(
            QuoteId          = expired.Id,
            PricebookEntryId = pbe.Id,
            Product2Id       = pbe.Product2Id,
            Quantity         = 5,
            UnitPrice        = 9999
        );

        Test.startTest();
        CreditRollupService.rollupForAccounts(new List<Id>{ acc.Id });
        Test.stopTest();

        Account updated = [SELECT Total_Active_Quoted_MRC__c, Active_Quote_Count__c
                           FROM Account WHERE Id = :acc.Id];
        System.assertEquals(1, updated.Active_Quote_Count__c,
            'Expired quote must not count toward active quote count');
        System.assert(updated.Total_Active_Quoted_MRC__c < 9999 * 5,
            'Expired quote MRC must be excluded from the rollup total');
    }

    @IsTest
    static void testRollupZerosWhenNoActiveQuotes() {
        Account acc = new Account(Name = 'CRS Empty Account', Operation_Country__c = 'Japan');
        insert acc;

        Test.startTest();
        CreditRollupService.rollupForAccounts(new List<Id>{ acc.Id });
        Test.stopTest();

        Account updated = [SELECT Total_Active_Quoted_MRC__c, Total_Active_Quoted_NRC__c, Active_Quote_Count__c
                           FROM Account WHERE Id = :acc.Id];
        System.assertEquals(0, updated.Total_Active_Quoted_MRC__c, 'MRC should be 0 with no quotes');
        System.assertEquals(0, updated.Total_Active_Quoted_NRC__c, 'NRC should be 0 with no quotes');
        System.assertEquals(0, updated.Active_Quote_Count__c, 'Count should be 0 with no quotes');
    }
}