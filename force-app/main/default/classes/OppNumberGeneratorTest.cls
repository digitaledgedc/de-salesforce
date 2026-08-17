@IsTest
private class OppNumberGeneratorTest {

    @TestSetup
    static void setup() {
        Account acct = new Account(Name = 'Test Customer', Operation_Country__c = 'SG');
        insert acct;
    }

    @IsTest
    static void assignNumbers_setsNumberOnNewOpps() {
        Account acct = [SELECT Id FROM Account LIMIT 1];

        List<Opportunity> opps = new List<Opportunity>{
            new Opportunity(
                Name        = 'Test Opp 1',
                AccountId   = acct.Id,
                StageName   = '1 - Suspect',
                CloseDate   = Date.today().addMonths(3)
            ),
            new Opportunity(
                Name        = 'Test Opp 2',
                AccountId   = acct.Id,
                StageName   = '1 - Suspect',
                CloseDate   = Date.today().addMonths(3)
            )
        };

        Test.startTest();
        OppNumberGenerator.assignNumbers(opps);
        Test.stopTest();

        System.assertNotEquals(null, opps[0].Opportunity_Number__c, 'Opp 1 should have a number assigned');
        System.assertNotEquals(null, opps[1].Opportunity_Number__c, 'Opp 2 should have a number assigned');
        System.assertNotEquals(opps[0].Opportunity_Number__c, opps[1].Opportunity_Number__c,
            'Each Opp in the batch must receive a unique number');
    }

    @IsTest
    static void assignNumbers_doesNotOverwriteExistingNumber() {
        Account acct = [SELECT Id FROM Account LIMIT 1];

        Opportunity opp = new Opportunity(
            Name                  = 'Pre-numbered Opp',
            AccountId             = acct.Id,
            StageName             = '1 - Suspect',
            CloseDate             = Date.today().addMonths(3),
            Opportunity_Number__c = '9900001'
        );

        Test.startTest();
        OppNumberGenerator.assignNumbers(new List<Opportunity>{ opp });
        Test.stopTest();

        System.assertEquals('9900001', opp.Opportunity_Number__c,
            'Pre-existing Opportunity_Number__c must not be overwritten');
    }

    @IsTest
    static void assignNumbers_handlesEmptyList() {
        // Should complete without exception
        Test.startTest();
        OppNumberGenerator.assignNumbers(new List<Opportunity>());
        Test.stopTest();
        System.assert(true, 'Empty list call completed without exception');
    }

    @IsTest
    static void assignNumbers_sequencesIncrementWithinBatch() {
        Account acct = [SELECT Id FROM Account LIMIT 1];

        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 5; i++) {
            opps.add(new Opportunity(
                Name      = 'Batch Opp ' + i,
                AccountId = acct.Id,
                StageName = '1 - Suspect',
                CloseDate = Date.today().addMonths(3)
            ));
        }

        Test.startTest();
        OppNumberGenerator.assignNumbers(opps);
        Test.stopTest();

        Set<String> numbers = new Set<String>();
        for (Opportunity opp : opps) {
            System.assertNotEquals(null, opp.Opportunity_Number__c, 'Each Opp must have a number');
            numbers.add(opp.Opportunity_Number__c);
        }
        System.assertEquals(5, numbers.size(), 'All 5 Opps must have distinct numbers');
    }

    // Inserts an Opportunity carrying a preset Opportunity_Number__c (the before-insert
    // trigger skips records that already have a number), so the DB has committed
    // numbered Opps for getNextSequence's COUNT/MAX queries to read.
    private static void insertNumberedOpp(String oppNumber) {
        Account acct = [SELECT Id FROM Account LIMIT 1];
        insert new Opportunity(
            Name                  = 'Seed ' + oppNumber,
            AccountId             = acct.Id,
            StageName             = '1-Suspect',
            CloseDate             = Date.today().addMonths(3),
            Opportunity_Number__c = oppNumber
        );
    }

    // ── Step 3: floor number already taken → continue from the DB max ────────────
    @IsTest
    static void assignNumbers_floorTaken_continuesFromDbMax() {
        String yr          = String.valueOf(Date.today().year()).right(2);
        Integer floorSeq   = Integer.valueOf(System.Label.OppNumber_StartingSequence) + 1;
        String floorNumber = yr + String.valueOf(floorSeq).leftPad(4, '0');
        insertNumberedOpp(floorNumber); // floor now exists → forces the DB-max path

        Account acct = [SELECT Id FROM Account LIMIT 1];
        Opportunity opp = new Opportunity(Name = 'Next Opp', AccountId = acct.Id,
            StageName = '1-Suspect', CloseDate = Date.today().addMonths(3));

        Test.startTest();
        OppNumberGenerator.assignNumbers(new List<Opportunity>{ opp });
        Test.stopTest();

        String expected = yr + String.valueOf(floorSeq + 1).leftPad(4, '0');
        System.assertEquals(expected, opp.Opportunity_Number__c,
            'When the floor number is taken, the next number should continue from the DB max');
    }

    // ── Step 0: year rollover → restart at 0001, ignoring the Custom Label ───────
    // isYearRollover(yearPrefix) takes the year as a parameter, so this is tested
    // directly against a hypothetical future year rather than through Date.today() —
    // real wall-clock time won't reach 2027 for a while, and the launch year (2026,
    // whatever the real "today" is while this test runs) must never report a rollover.
    @IsTest
    static void isYearRollover_futureYear_trueWhenNoRecordsYet() {
        String prevYr = String.valueOf(Date.today().year() - 1).right(2);
        // A numbered Opp exists, but only under a prior year's prefix.
        insertNumberedOpp(prevYr + '0100');

        Test.startTest();
        Boolean rollover = OppNumberGenerator.isYearRollover('27');
        Test.stopTest();

        System.assertEquals(true, rollover,
            'A year with no numbered Opps yet, after prior-year data exists, is a genuine rollover');
    }

    @IsTest
    static void isYearRollover_launchYear_alwaysFalseEvenWithOnlyPriorYearData() {
        String prevYr = String.valueOf(Date.today().year() - 1).right(2);
        // Same setup as the future-year case — only prior-year data exists — but for
        // the launch year ("26") this must NEVER report a rollover.
        insertNumberedOpp(prevYr + '0100');

        Test.startTest();
        Boolean rollover = OppNumberGenerator.isYearRollover('26');
        Test.stopTest();

        System.assertEquals(false, rollover,
            'The launch year must defer to the Custom Label floor, not auto-restart, even with only prior-year data present');
    }

    @IsTest
    static void assignNumbers_launchYear_defersToLabelNotRestartWithOnlyPriorYearData() {
        String yr     = String.valueOf(Date.today().year()).right(2);
        String prevYr = String.valueOf(Date.today().year() - 1).right(2);
        // A numbered Opp exists, but only under last year's prefix.
        insertNumberedOpp(prevYr + '0100');

        Account acct = [SELECT Id FROM Account LIMIT 1];
        Opportunity opp = new Opportunity(Name = 'Launch Year Opp', AccountId = acct.Id,
            StageName = '1-Suspect', CloseDate = Date.today().addMonths(3));

        Test.startTest();
        OppNumberGenerator.assignNumbers(new List<Opportunity>{ opp });
        Test.stopTest();

        // While the real "today" falls within the launch year, assignNumbers must defer
        // to the Custom Label floor rather than restarting at 0001 — computed dynamically
        // here so the test stays valid regardless of the label's current value.
        Integer expectedFloor = Integer.valueOf(System.Label.OppNumber_StartingSequence) + 1;
        String expected = yr + String.valueOf(expectedFloor).leftPad(4, '0');
        System.assertEquals(expected, opp.Opportunity_Number__c,
            'The launch year must not restart at 0001 just because no current-year Opps exist yet');
    }

    // ── Step 3 fallback: floor taken, but the DB-max match has a non-numeric
    // sequence portion → Integer.valueOf throws and the catch falls back to
    // the floor sequence instead of the (unparseable) DB max ─────────────────
    @IsTest
    static void assignNumbers_floorTaken_nonNumericMaxFallsBackToFloor() {
        String yr          = String.valueOf(Date.today().year()).right(2);
        Integer floorSeq   = Integer.valueOf(System.Label.OppNumber_StartingSequence) + 1;
        String floorNumber = yr + String.valueOf(floorSeq).leftPad(4, '0');
        insertNumberedOpp(floorNumber); // floor now exists → forces the DB-max path

        // Same year prefix, same overall length as the mask ("YY____"), but the
        // sequence portion is letters, not digits. Letters text-sort above digits,
        // so this record wins the ORDER BY ... DESC LIMIT 1 "recent" query, and its
        // Integer.valueOf(seqStr) call throws TypeException.
        insertNumberedOpp(yr + 'ZZZZ');

        Account acct = [SELECT Id FROM Account LIMIT 1];
        Opportunity opp = new Opportunity(Name = 'Next Opp Non-Numeric Max', AccountId = acct.Id,
            StageName = '1-Suspect', CloseDate = Date.today().addMonths(3));

        Test.startTest();
        OppNumberGenerator.assignNumbers(new List<Opportunity>{ opp });
        Test.stopTest();

        System.assertEquals(floorNumber, opp.Opportunity_Number__c,
            'When the DB-max sequence portion is non-numeric, the generator must fall back to the floor number');
    }

    // ── isYearRollover: a genuinely fresh org (no Opportunity ever numbered,
    // in any year) must NOT report a rollover, even for a future year — this
    // lets the Custom Label still set its one-time starting point rather than
    // the auto-restart-to-1 behavior kicking in ───────────────────────────────
    @IsTest
    static void isYearRollover_freshOrg_falseWhenNoRecordsEverNumbered() {
        // No Opportunities inserted at all in this test's transaction.
        Test.startTest();
        Boolean rollover = OppNumberGenerator.isYearRollover('27');
        Test.stopTest();

        System.assertEquals(false, rollover,
            'A fresh org with no numbered Opportunities at all must not report a year rollover');
    }
}