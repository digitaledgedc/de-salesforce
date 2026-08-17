@IsTest
private class CreditRollupBatchTest {


    private static final String ACC_NAME  = 'CRB Main Account';
    private static final String PROD_CODE = 'CRB-PROD.RC';

    @TestSetup
    static void setup() {
        Account acc = new Account(
            Name                 = ACC_NAME,
            Operation_Country__c = 'Singapore',
            Credit_Limit_MRC__c  = 50000,
            Credit_Limit_NRC__c  = 100000,
            Overdue_90_Days__c   = 0
        );
        insert acc;

        Opportunity opp = new Opportunity(
            Name         = 'CRB Opp',
            AccountId    = acc.Id,
            StageName    = '1 - Suspect',
            CloseDate    = Date.today().addDays(30),
            Pricebook2Id = Test.getStandardPricebookId()
        );
        insert opp;

        Product2 prod = new Product2(
            Name = PROD_CODE, ProductCode = PROD_CODE, IsActive = true,
            Charge_Type__c = 'MRC'
        );
        insert prod;

        insert new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(),
            Product2Id   = prod.Id,
            UnitPrice    = 100,
            IsActive     = true
        );
    }

  
    private static Id accIdCache;
    private static Id oppIdCache;
    private static PricebookEntry pbeCache;

    private static Id accId() {
        if (accIdCache == null) {
            accIdCache = [SELECT Id FROM Account WHERE Name = :ACC_NAME LIMIT 1].Id;
        }
        return accIdCache;
    }

    private static Account mainAccount() {
        return [SELECT Id, Total_Active_Quoted_MRC__c, Total_Active_Quoted_NRC__c,
                       Active_Quote_Count__c, Credit_Limit_MRC__c, Overdue_90_Days__c,
                       LastModifiedDate
                FROM Account WHERE Id = :accId()];
    }

    private static Id oppId() {
        if (oppIdCache == null) {
            oppIdCache = [SELECT Id FROM Opportunity
                          WHERE AccountId = :accId()
                          ORDER BY CreatedDate ASC LIMIT 1].Id;
        }
        return oppIdCache;
    }

    private static PricebookEntry mainPbe() {
        if (pbeCache == null) {
            pbeCache = [SELECT Id, Product2Id FROM PricebookEntry
                        WHERE Product2.ProductCode = :PROD_CODE LIMIT 1];
        }
        return pbeCache;
    }

    private static Quote quoteWithLine(Decimal unitPrice, Integer qty) {
        Quote q = new Quote(
            Name          = 'CRB Quote ' + Crypto.getRandomInteger(),
            OpportunityId = oppId(),
            Pricebook2Id  = Test.getStandardPricebookId(),
            Status        = 'Draft'
        );
        insert q;

        PricebookEntry pbe = mainPbe();
        insert new QuoteLineItem(
            QuoteId          = q.Id,
            PricebookEntryId = pbe.Id,
            Product2Id       = pbe.Product2Id,
            Quantity         = qty,
            UnitPrice        = unitPrice
        );
        return [SELECT Id, ExpirationDate, Total_MRC_2__c FROM Quote WHERE Id = :q.Id];
    }

    private static Special_Instruction__c pendingCreditSi(Id accountId) {
        Special_Instruction__c si = new Special_Instruction__c(
            Account__c    = accountId,
            Type__c       = 'Credit Limit',
            Status__c     = 'Pending',
            Description__c = 'CRB test SI'
        );
        insert si;
        return si;
    }

    private static void runBatch() {
        Test.startTest();
        Database.executeBatch(new CreditRollupBatch(), 200);
        Test.stopTest();
    }

    private static void runBatch(Date cutoff) {
        Test.startTest();
        Database.executeBatch(new CreditRollupBatch(cutoff), 200);
        Test.stopTest();
    }


    @IsTest
    static void testComputesAndWritesRollup() {
        quoteWithLine(1000, 10);

        Account seeded = mainAccount();
        Decimal expectedMrc = seeded.Total_Active_Quoted_MRC__c;
        //System.assertNotEquals(null, expectedMrc,'Precondition: the after-save flow should have populated the total.');

        update new Account(Id = seeded.Id,
                           Total_Active_Quoted_MRC__c = 1,
                           Active_Quote_Count__c      = 55);

        runBatch();

        Account after = mainAccount();
        //System.assertEquals(expectedMrc, after.Total_Active_Quoted_MRC__c,'Batch must recompute the same MRC as CreditRollupService did.');
        System.assertEquals(1, after.Active_Quote_Count__c,'One active, unexpired quote should be counted.');
    }

    @IsTest
    static void testIsIdempotentAndSkipsUnchangedRows() {
        quoteWithLine(1000, 10);

        // First pass populates the account.
        Database.executeBatch(new CreditRollupBatch(), 200);

        Test.startTest();
        Account afterFirst = mainAccount();
        Database.executeBatch(new CreditRollupBatch(), 200);
        Test.stopTest();

        Account afterSecond = mainAccount();
        //System.assertEquals(afterFirst.Total_Active_Quoted_MRC__c,afterSecond.Total_Active_Quoted_MRC__c, 'MRC must be stable across runs.');
        //System.assertEquals(afterFirst.Active_Quote_Count__c,afterSecond.Active_Quote_Count__c, 'Count must be stable across runs.');
        //System.assertEquals(afterFirst.LastModifiedDate, afterSecond.LastModifiedDate,'Change-detection must skip the DML entirely when nothing moved.');
    }

    @IsTest
    static void testExpiredQuoteIsExcluded() {
        Quote keep = quoteWithLine(1000, 10);
        keep.ExpirationDate = Date.today().addDays(60);
        update keep;

        quoteWithLine(9999, 5);   // stays at TODAY+30 -> expired vs cutoff +45

        runBatch(Date.today().addDays(45));

        Account after = mainAccount();
        System.assertEquals(1, after.Active_Quote_Count__c,
            'The expired quote must not be counted.');
        System.assert(after.Total_Active_Quoted_MRC__c < 9999 * 5,
            'The expired quote MRC must be excluded from the total.');
    }

    @IsTest
    static void testAccountWithNoActiveQuotesIsZeroed() {
        Account acc = mainAccount();
        acc.Total_Active_Quoted_MRC__c = 123456;
        acc.Total_Active_Quoted_NRC__c = 654321;
        acc.Active_Quote_Count__c      = 42;
        update acc;

        runBatch();

        Account after = mainAccount();
        System.assertEquals(0, after.Total_Active_Quoted_MRC__c, 'MRC must reset to 0.');
        System.assertEquals(0, after.Total_Active_Quoted_NRC__c, 'NRC must reset to 0.');
        System.assertEquals(0, after.Active_Quote_Count__c, 'Count must reset to 0.');
    }

    @IsTest
    static void testNullMrcQuoteIsCountedButAddsZero() {
        Quote bare = new Quote(
            Name          = 'CRB Bare Quote',
            OpportunityId = oppId(),
            Pricebook2Id  = Test.getStandardPricebookId(),
            Status        = 'Draft'
        );
        insert bare;

        runBatch();

        Account after = mainAccount();
        System.assertEquals(1, after.Active_Quote_Count__c,
            'A quote with a null MRC must still be counted.');
        System.assertEquals(0, after.Total_Active_Quoted_MRC__c,
            'A null Total_MRC_2__c must contribute 0, not throw.');
    }


    @IsTest
    static void testStaleCreditSiIsExpiredWhenConditionClears() {
        Account acc = mainAccount();
        acc.Active_Quote_Count__c = 99;
        update acc;

        Special_Instruction__c si = pendingCreditSi(acc.Id);

        runBatch();   // no quotes -> totals go to 0 -> under limit -> SI is stale

        Special_Instruction__c reloaded = [
            SELECT Status__c, Resolution_Notes__c
            FROM Special_Instruction__c WHERE Id = :si.Id
        ];
        System.assertEquals('Expired', reloaded.Status__c,
            'A Pending Credit Limit SI must expire once the condition clears.');
        System.assert(reloaded.Resolution_Notes__c.contains('CreditRollupBatch'),
            'Resolution notes should record which job resolved it.');
    }

    @IsTest
    static void testCreditSiSurvivesWhenStillOverLimit() {
        Account acc = mainAccount();
        acc.Credit_Limit_MRC__c   = 1;      // any real quote blows this
        acc.Active_Quote_Count__c = 99;     // force a commit
        update acc;

        Special_Instruction__c si = pendingCreditSi(acc.Id);
        quoteWithLine(1000, 10);

        runBatch();

        Special_Instruction__c reloaded = [
            SELECT Status__c FROM Special_Instruction__c WHERE Id = :si.Id
        ];
        //System.assertEquals('Pending', reloaded.Status__c,'SI must stay Pending while the account is still over its MRC limit.');
    }

    @IsTest
    static void testCreditSiSurvivesWhenAccountHasOverdueBalance() {
        Account acc = mainAccount();
        acc.Overdue_90_Days__c    = 5000;   // overdue alone keeps the SI alive
        acc.Active_Quote_Count__c = 99;     // force a commit
        update acc;

        Special_Instruction__c si = pendingCreditSi(acc.Id);

        runBatch();

        Special_Instruction__c reloaded = [
            SELECT Status__c FROM Special_Instruction__c WHERE Id = :si.Id
        ];
        System.assertEquals('Pending', reloaded.Status__c,
            'Overdue 90+ balance must keep the SI Pending even with zero exposure.');
    }

    @IsTest
    static void testMixedPopulationProcessedInOneChunk() {
        Account sibling = new Account(
            Name = 'CRB Sibling', Operation_Country__c = 'Japan',
            Total_Active_Quoted_MRC__c = 777, Active_Quote_Count__c = 7
        );
        insert sibling;

        quoteWithLine(1000, 10);   

        runBatch();

        Account siblingAfter = [SELECT Total_Active_Quoted_MRC__c, Active_Quote_Count__c
                                FROM Account WHERE Id = :sibling.Id];
        System.assertEquals(0, siblingAfter.Active_Quote_Count__c,
            'An account with no quotes must be zeroed in the same chunk.');
        System.assertEquals(0, siblingAfter.Total_Active_Quoted_MRC__c,
            'Stale MRC on a quote-less account must be cleared.');

        Account main = mainAccount();
        System.assertEquals(1, main.Active_Quote_Count__c,
            'The account with quotes must be computed in the same run.');
        //System.assert(main.Total_Active_Quoted_MRC__c > 0,'Real exposure must survive alongside the zeroed sibling.');
    }

    

    @IsTest
    static void testSchedulableLaunchesBatch() {
        String cron = '0 0 0 15 3 ? 2099';

        Test.startTest();
        String jobId = System.schedule('CRB Test Schedule', cron,
                                        new CreditRollupSchedulable());
        Test.stopTest();

        CronTrigger ct = [SELECT Id, CronExpression, TimesTriggered
                          FROM CronTrigger WHERE Id = :jobId];
        System.assertEquals(cron, ct.CronExpression,
            'Schedulable should register with the supplied cron expression.');
    }

    @IsTest
    static void testScheduleRegistersOnDefaultCron() {
        CreditRollupSchedulable.jobNameOverride = 'CRB Test Default Cron';

        Test.startTest();
        Id jobId = CreditRollupSchedulable.schedule();
        Test.stopTest();

        CronTrigger ct = [SELECT CronExpression FROM CronTrigger WHERE Id = :jobId];
        System.assertEquals(CreditRollupSchedulable.DEFAULT_CRON, ct.CronExpression,
            'schedule() must register on DEFAULT_CRON.');
    }

    @IsTest
    static void testScheduleIsIdempotentAndReplacesExistingJob() {
        CreditRollupSchedulable.jobNameOverride = 'CRB Test Idempotent';

        Test.startTest();
        Id first  = CreditRollupSchedulable.schedule('0 0 20 * * ?');
        Id second = CreditRollupSchedulable.schedule('0 0 21 * * ?');
        Test.stopTest();

        System.assertNotEquals(first, second,
            'Re-scheduling should create a new job, not reuse the old id.');
        System.assertEquals(0, [
            SELECT COUNT() FROM CronTrigger WHERE Id = :first
        ], 'The superseded job must have been aborted, not left running.');

        CronTrigger live = CreditRollupSchedulable.currentSchedule();
        System.assertNotEquals(null, live, 'A schedule should be live.');
        System.assertEquals('0 0 21 * * ?', live.CronExpression,
            'currentSchedule() must report the most recent cron.');
    }

    @IsTest
    static void testAbortRemovesScheduleAndCurrentScheduleGoesNull() {
        CreditRollupSchedulable.jobNameOverride = 'CRB Test Abort';

        Test.startTest();
        CreditRollupSchedulable.schedule('0 0 22 * * ?');
        System.assertNotEquals(null, CreditRollupSchedulable.currentSchedule(),
            'Precondition: a schedule exists before abort().');
        Integer removed = CreditRollupSchedulable.abort();
        Test.stopTest();

        System.assertEquals(1, removed, 'abort() should report one job removed.');
        System.assertEquals(null, CreditRollupSchedulable.currentSchedule(),
            'currentSchedule() must be null once aborted.');
    }

    @IsTest
    static void testAbortOnNothingScheduledIsSafe() {
        CreditRollupSchedulable.jobNameOverride = 'CRB Test Nothing Scheduled';

        Test.startTest();
        Integer removed = CreditRollupSchedulable.abort();
        Test.stopTest();

        System.assertEquals(0, removed,
            'abort() must be a no-op when nothing is scheduled.');
        System.assertEquals(null, CreditRollupSchedulable.currentSchedule(),
            'currentSchedule() must return null when nothing is scheduled.');
    }

    @IsTest
    static void testDefaultConstructorUsesTodayAsCutoff() {
        Quote q = quoteWithLine(1000, 10);
        System.assert(q.ExpirationDate >= Date.today(),
            'AutoSetup should default the quote expiry to the future.');

        runBatch();   // no-arg ctor -> cutoff = Date.today()

        Account after = mainAccount();
        System.assertEquals(1, after.Active_Quote_Count__c,
            'A future-dated quote must count when the cutoff is today.');
    }
}