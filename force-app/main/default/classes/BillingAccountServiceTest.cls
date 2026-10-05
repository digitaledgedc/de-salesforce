@IsTest
private class BillingAccountServiceTest {

    private static final Id DE_ENTITY_RT = Schema.SObjectType.Account
        .getRecordTypeInfosByDeveloperName().get('DE_Entity').getRecordTypeId();

    // --- Test setup -----------------------------------------------------------

    @TestSetup
    static void setup() {
        Account acc = new Account(
            Name = 'Test Account BAN Service',
            Operation_Country__c = 'Singapore'
        );
        insert acc;

        Id rtId = Schema.SObjectType.Account
            .getRecordTypeInfosByDeveloperName().get('DE_Entity').getRecordTypeId();

        // Prefix is resolved from the SUBSIDIARY's Operation_Country__c.
        List<Account> entities = new List<Account>{
            new Account(Name = 'DE SG Pte Ltd', Operation_Country__c = 'Singapore',   RecordTypeId = rtId),
            new Account(Name = 'DE HK Ltd',     Operation_Country__c = 'Hong Kong',   RecordTypeId = rtId),
            new Account(Name = 'DE KR Co Ltd',  Operation_Country__c = 'South Korea', RecordTypeId = rtId),
            new Account(Name = 'DE PH Inc',     Operation_Country__c = 'Philippines', RecordTypeId = rtId),
            new Account(Name = 'DE ID PT',      Operation_Country__c = 'Indonesia',   RecordTypeId = rtId),
            new Account(Name = 'DE JP KK',      Operation_Country__c = 'Japan',       RecordTypeId = rtId)
        };
        insert entities;
    }

    // --- Helper: build a minimal BillingAccount__c in memory only -------------

    private static BillingAccount__c buildBan(String entityName) {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test Account BAN Service' LIMIT 1];
        Id entityId = null;
        if (entityName != null) {
            List<Account> ents = [SELECT Id FROM Account WHERE Name = :entityName AND RecordTypeId = :DE_ENTITY_RT LIMIT 1];
            if (!ents.isEmpty()) entityId = ents[0].Id;
        }
        return new BillingAccount__c(
            Account__c    = acc.Id,
            DE_Entity__c  = entityId
        );
    }

    // --- BAN number generation -- prefix resolution ---------------------------

    @IsTest
    static void testGenerateBanNumbers_sg() {
        BillingAccount__c ban = buildBan('DE SG Pte Ltd');
        List<BillingAccount__c> bans = new List<BillingAccount__c>{ ban };

        Test.startTest();
        BillingAccountService.generateBanNumbers(bans);
        Test.stopTest();

        System.assert(
            ban.BAN_Number__c != null && ban.BAN_Number__c.startsWith('SG'),
            'SG entity should produce SG-prefixed BAN, got: ' + ban.BAN_Number__c
        );
        System.assertEquals(ban.BAN_Number__c, ban.Name,
            'Name must equal BAN_Number__c');
    }

    @IsTest
    static void testGenerateBanNumbers_hk() {
        BillingAccount__c ban = buildBan('DE HK Ltd');
        List<BillingAccount__c> bans = new List<BillingAccount__c>{ ban };

        Test.startTest();
        BillingAccountService.generateBanNumbers(bans);
        Test.stopTest();

        System.assert(
            ban.BAN_Number__c != null && ban.BAN_Number__c.startsWith('HK'),
            'HK entity should produce HK-prefixed BAN, got: ' + ban.BAN_Number__c
        );
    }

    @IsTest
    static void testGenerateBanNumbers_kr() {
        BillingAccount__c ban = buildBan('DE KR Co Ltd');
        List<BillingAccount__c> bans = new List<BillingAccount__c>{ ban };

        Test.startTest();
        BillingAccountService.generateBanNumbers(bans);
        Test.stopTest();

        System.assert(
            ban.BAN_Number__c != null && ban.BAN_Number__c.startsWith('KR'),
            'KR entity should produce KR-prefixed BAN, got: ' + ban.BAN_Number__c
        );
    }

    @IsTest
    static void testGenerateBanNumbers_ph() {
        BillingAccount__c ban = buildBan('DE PH Inc');
        List<BillingAccount__c> bans = new List<BillingAccount__c>{ ban };

        Test.startTest();
        BillingAccountService.generateBanNumbers(bans);
        Test.stopTest();

        System.assert(
            ban.BAN_Number__c != null && ban.BAN_Number__c.startsWith('PH'),
            'PH entity should produce PH-prefixed BAN, got: ' + ban.BAN_Number__c
        );
        System.assertEquals(9, ban.BAN_Number__c.length(),
            'PH BAN number should be 9 characters (PH- + 6-digit sequence)');
    }

    @IsTest
    static void testGenerateBanNumbers_id() {
        BillingAccount__c ban = buildBan('DE ID PT');
        List<BillingAccount__c> bans = new List<BillingAccount__c>{ ban };

        Test.startTest();
        BillingAccountService.generateBanNumbers(bans);
        Test.stopTest();

        System.assert(
            ban.BAN_Number__c != null && ban.BAN_Number__c.startsWith('ID'),
            'ID entity should produce ID-prefixed BAN, got: ' + ban.BAN_Number__c
        );
    }

    @IsTest
    static void testGenerateBanNumbers_jp() {
        BillingAccount__c ban = buildBan('DE JP KK');
        List<BillingAccount__c> bans = new List<BillingAccount__c>{ ban };

        Test.startTest();
        BillingAccountService.generateBanNumbers(bans);
        Test.stopTest();

        System.assert(
            ban.BAN_Number__c != null && ban.BAN_Number__c.startsWith('JP'),
            'JP entity should produce JP-prefixed BAN, got: ' + ban.BAN_Number__c
        );
        System.assertEquals(9, ban.BAN_Number__c.length(),
            'JP BAN number should be 9 characters (JP- + 6-digit sequence)');
    }

    // --- Sequential numbering -------------------------------------------------

    @IsTest
    static void testGenerateBanNumbers_sequential() {
        List<BillingAccount__c> bans = new List<BillingAccount__c>{
            buildBan('DE SG Pte Ltd'),
            buildBan('DE SG Pte Ltd'),
            buildBan('DE SG Pte Ltd')
        };

        Test.startTest();
        BillingAccountService.generateBanNumbers(bans);
        Test.stopTest();

        Set<String> nums = new Set<String>{
            bans[0].BAN_Number__c, bans[1].BAN_Number__c, bans[2].BAN_Number__c
        };
        System.assertEquals(3, nums.size(), 'Each BAN must receive a unique number');

        for (BillingAccount__c ban : bans) {
            System.assert(ban.BAN_Number__c.startsWith('SG'),
                'Expected SG prefix, got: ' + ban.BAN_Number__c);
            System.assertEquals(8, ban.BAN_Number__c.length(),
                'SG BAN number should be 8 characters (SG- + 5 digits)');
        }
    }

    // --- Skip if BAN_Number__c already set ------------------------------------

    @IsTest
    static void testGenerateBanNumbers_skipsExisting() {
        BillingAccount__c ban = buildBan('DE SG Pte Ltd');
        ban.BAN_Number__c = 'SG_LEGACY_001';

        List<BillingAccount__c> bans = new List<BillingAccount__c>{ ban };

        Test.startTest();
        BillingAccountService.generateBanNumbers(bans);
        Test.stopTest();

        System.assertEquals('SG_LEGACY_001', ban.BAN_Number__c,
            'Pre-populated BAN_Number__c must not be overwritten');
    }

    // --- No subsidiary -- leave unresolved, do not throw or mis-prefix --------

    @IsTest
    static void testGenerateBanNumbers_noEntity() {
        BillingAccount__c ban = buildBan(null);
        List<BillingAccount__c> bans = new List<BillingAccount__c>{ ban };

        Test.startTest();
        BillingAccountService.generateBanNumbers(bans);
        Test.stopTest();

        // No DE_Entity (subsidiary) → cannot resolve a country prefix. Must be left
        // unresolved for manual assignment, NOT stamped from the partner account.
        System.assertEquals(null, ban.BAN_Number__c,
            'BAN with no subsidiary must be left unresolved, got: ' + ban.BAN_Number__c);
    }

    // --- Subsidiary country drives the prefix, not the partner account --------

    @IsTest
    static void testGenerateBanNumbers_subsidiaryCountryWins() {
        // Partner Account is 'Singapore'; subsidiary is Indonesia. Prefix must be ID.
        BillingAccount__c ban = buildBan('DE ID PT');
        List<BillingAccount__c> bans = new List<BillingAccount__c>{ ban };

        Test.startTest();
        BillingAccountService.generateBanNumbers(bans);
        Test.stopTest();

        System.assert(
            ban.BAN_Number__c != null && ban.BAN_Number__c.startsWith('ID'),
            'Indonesian subsidiary with Singapore partner must produce ID prefix, got: ' + ban.BAN_Number__c
        );
    }

    // --- Entity-fragment override (real CMT config: CN -> 'Chuanjun') ---------
    // No test entity name so far contains a configured Entity_Fragment__c, so the
    // override branch in resolvePrefix() has never fired. Note: custom metadata
    // records can't be created via DML even in test context in this org (verified:
    // "DML operation Insert not allowed on BAN_Prefix_Config__mdt"), so this test
    // relies on the real, already-deployed CN config rather than test-only metadata.

    @IsTest
    static void testGenerateBanNumbers_entityFragmentOverride_cn() {
        Id rtId = DE_ENTITY_RT;
        Account cnEntity = new Account(
            Name                 = 'Chuanjun Trading Pte Ltd',
            Operation_Country__c = 'China',
            RecordTypeId         = rtId
        );
        insert cnEntity;

        Account acc = [SELECT Id FROM Account WHERE Name = 'Test Account BAN Service' LIMIT 1];
        BillingAccount__c ban = new BillingAccount__c(
            Account__c   = acc.Id,
            DE_Entity__c = cnEntity.Id
        );

        Test.startTest();
        BillingAccountService.generateBanNumbers(new List<BillingAccount__c>{ ban });
        Test.stopTest();

        System.assert(
            ban.BAN_Number__c != null && ban.BAN_Number__c.startsWith('CN'),
            'Entity name containing the configured "Chuanjun" fragment must resolve via the ' +
            'fragment override to a CN-prefixed BAN, got: ' + ban.BAN_Number__c
        );
    }

    // --- First-time counter creation seeds from pre-existing legacy BAN numbers --
    // Each test method runs in its own isolated transaction (BAN_Counter__c rows
    // created by other tests aren't visible here), so this is genuinely the first
    // time the SG counter is created within this transaction. A legacy-formatted
    // BillingAccount__c inserted beforehand forces reserveSequenceBlock's seed logic
    // to scan for and fast-forward past it.

    @IsTest
    static void testGenerateBanNumbers_firstTimeCounter_seedsFromLegacyBanNumbers() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test Account BAN Service' LIMIT 1];

        insert new BillingAccount__c(
            Account__c    = acc.Id,
            BAN_Number__c = 'SG-00007'
        );

        BillingAccount__c ban = buildBan('DE SG Pte Ltd');

        Test.startTest();
        BillingAccountService.generateBanNumbers(new List<BillingAccount__c>{ ban });
        Test.stopTest();

        System.assertEquals('SG-00008', ban.BAN_Number__c,
            'New SG BAN must continue the sequence after the pre-existing legacy SG-00007 ' +
            'record, got: ' + ban.BAN_Number__c);
    }

    // --- Subsidiary country not present in the country->code map --------------

    @IsTest
    static void testGenerateBanNumbers_unmappedCountry_leavesUnresolved() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test Account BAN Service' LIMIT 1];

        Account unmappedEntity = new Account(
            Name                 = 'DE VN Co',
            Operation_Country__c = 'Vietnam', // not present in COUNTRY_TO_CODE
            RecordTypeId         = DE_ENTITY_RT
        );
        insert unmappedEntity;

        BillingAccount__c ban = new BillingAccount__c(
            Account__c   = acc.Id,
            DE_Entity__c = unmappedEntity.Id
        );

        Test.startTest();
        BillingAccountService.generateBanNumbers(new List<BillingAccount__c>{ ban });
        Test.stopTest();

        System.assertEquals(null, ban.BAN_Number__c,
            'Subsidiary with an operation country outside the known map must be left ' +
            'unresolved rather than mis-prefixed, got: ' + ban.BAN_Number__c);
    }

    // --- Empty list is a no-op ------------------------------------------------

    @IsTest
    static void testGenerateBanNumbers_emptyList() {
        Test.startTest();
        BillingAccountService.generateBanNumbers(new List<BillingAccount__c>());
        Test.stopTest();
    }

    // --- Trigger integration: insert fires before-insert numbering ------------

    @IsTest
    static void testTriggerInsert_assignsBanNumber() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test Account BAN Service' LIMIT 1];
        Account sgEntity = [SELECT Id FROM Account WHERE Name = 'DE SG Pte Ltd' LIMIT 1];
        Contact con = new Contact(LastName = 'BillingCon', AccountId = acc.Id);
        insert con;

        BillingAccount__c ban = new BillingAccount__c(
            Account__c             = acc.Id,
            DE_Entity__c           = sgEntity.Id,
            Billing_Contact__c     = con.Id,
            InvoiceDeliveryMode__c = 'Online'
        );

        Test.startTest();
        insert ban;
        Test.stopTest();

        BillingAccount__c saved = [SELECT BAN_Number__c, Name FROM BillingAccount__c WHERE Id = :ban.Id];
        System.assert(
            saved.BAN_Number__c != null && saved.BAN_Number__c.startsWith('SG'),
            'Trigger insert should have set SG-prefixed BAN number, got: ' + saved.BAN_Number__c
        );
        System.assertEquals(saved.BAN_Number__c, saved.Name,
            'Name must equal BAN_Number__c after insert');
    }
}