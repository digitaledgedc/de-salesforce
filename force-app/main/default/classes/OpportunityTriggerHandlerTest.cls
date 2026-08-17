/**
 * OpportunityTriggerHandlerTest
 * Covers OpportunityTriggerHandler (beforeInsert number assignment path)
 * and OpportunitySelector (getByIds, getChildrenByParentIds).
 */
@IsTest
private class OpportunityTriggerHandlerTest {

    // ─── @TestSetup ──────────────────────────────────────────────────────────────

    @TestSetup
    static void setup() {
        // Setup objects (User + PermSetAssignment) in their own DML context to avoid
        // MIXED_DML_OPERATION errors when combined with non-setup DML below.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile p = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
            User u = new User(
                Alias             = 'opptest',
                Email             = 'opp-test@gokarya.test.invalid',
                EmailEncodingKey  = 'UTF-8',
                LastName          = 'OppTest',
                LanguageLocaleKey = 'en_US',
                LocaleSidKey      = 'en_US',
                ProfileId         = p.Id,
                TimeZoneSidKey    = 'America/Los_Angeles',
                UserName          = 'opp-test@gokarya.test.invalid'
            );
            insert u;
            PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'DE_Admin' LIMIT 1];
            insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
        }

        Account acct = new Account(Name = 'Digital Edge Test Account', Operation_Country__c = 'Singapore');
        insert acct;
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────────

    private static Account getTestAccount() {
        return [SELECT Id FROM Account WHERE Name = 'Digital Edge Test Account' LIMIT 1];
    }

    private static User getAdminUser() {
        return [SELECT Id FROM User WHERE UserName = 'opp-test@gokarya.test.invalid' LIMIT 1];
    }

    private static Opportunity buildOpp(Id accountId, String name) {
        return new Opportunity(
            Name      = name,
            AccountId = accountId,
            StageName = '1 - Suspect',
            CloseDate = Date.today().addMonths(3)
        );
    }

    // ─── beforeInsert: Opportunity_Number__c is assigned ─────────────────────────

    @IsTest
    static void insert_singleOpp_opportunityNumberIsAssigned() {
        Account acct = getTestAccount();
        Opportunity opp = buildOpp(acct.Id, 'Test Opp 001');

        Test.startTest();
        insert opp;
        Test.stopTest();

        Opportunity inserted = [
            SELECT Opportunity_Number__c
            FROM Opportunity
            WHERE Id = :opp.Id
        ];

        System.assertNotEquals(
            null,
            inserted.Opportunity_Number__c,
            'Opportunity_Number__c should be populated by beforeInsert'
        );
        System.assert(
            inserted.Opportunity_Number__c.length() > 0,
            'Opportunity_Number__c should not be blank'
        );
    }

    @IsTest
    static void insert_bulkOpps_allReceiveUniqueNumbers() {
        Account acct = getTestAccount();
        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 5; i++) {
            opps.add(buildOpp(acct.Id, 'Bulk Opp ' + i));
        }

        Test.startTest();
        insert opps;
        Test.stopTest();

        List<Opportunity> inserted = [
            SELECT Opportunity_Number__c
            FROM Opportunity
            WHERE Id IN :opps
        ];

        Set<String> numbers = new Set<String>();
        for (Opportunity o : inserted) {
            System.assertNotEquals(null, o.Opportunity_Number__c,
                'Every Opp in a bulk insert should receive a number');
            numbers.add(o.Opportunity_Number__c);
        }
        System.assertEquals(5, numbers.size(),
            'All 5 Opportunity numbers should be unique');
    }

    @IsTest
    static void insert_oppWithExistingNumber_numberIsPreserved() {
        Account acct = getTestAccount();
        Opportunity opp = buildOpp(acct.Id, 'Pre-numbered Opp');
        opp.Opportunity_Number__c = '9999999';

        Test.startTest();
        insert opp;
        Test.stopTest();

        Opportunity inserted = [
            SELECT Opportunity_Number__c
            FROM Opportunity
            WHERE Id = :opp.Id
        ];

        System.assertEquals(
            '9999999',
            inserted.Opportunity_Number__c,
            'A pre-existing Opportunity_Number__c should not be overwritten'
        );
    }

    // ─── OpportunitySelector: getByIds ───────────────────────────────────────────

    @IsTest
    static void selector_getByIds_returnsCorrectRecord() {
        Account acct = getTestAccount();
        Opportunity opp = buildOpp(acct.Id, 'Selector Test Opp');
        insert opp;
        User testUser = getAdminUser();

        Test.startTest();
        List<Opportunity> results;
        System.runAs(testUser) {
            results = OpportunitySelector.getByIds(new Set<Id>{ opp.Id });
        }
        Test.stopTest();

        System.assertEquals(1, results.size(), 'getByIds should return exactly one record');
        System.assertEquals(opp.Id, results[0].Id, 'Returned record Id should match');
        System.assertNotEquals(null, results[0].Opportunity_Number__c,
            'Opportunity_Number__c should be populated on the returned record');
    }

    @IsTest
    static void selector_getByIds_emptySet_returnsEmptyList() {
        Test.startTest();
        List<Opportunity> results = OpportunitySelector.getByIds(new Set<Id>());
        Test.stopTest();

        System.assertEquals(0, results.size(),
            'getByIds with an empty set should return an empty list without SOQL');
    }

    // ─── OpportunitySelector: getChildrenByParentIds ─────────────────────────────

    @IsTest
    static void selector_getChildrenByParentIds_returnsChildren() {
        Account acct = getTestAccount();

        Opportunity parent = buildOpp(acct.Id, 'Parent Opp');
        insert parent;

        Opportunity child = buildOpp(acct.Id, 'Child Opp');
        child.Parent_Opportunity__c = parent.Id;
        insert child;

        User testUser = getAdminUser();
        Test.startTest();
        List<Opportunity> children;
        System.runAs(testUser) {
            children = OpportunitySelector.getChildrenByParentIds(new Set<Id>{ parent.Id });
        }
        Test.stopTest();

        System.assertEquals(1, children.size(),
            'getChildrenByParentIds should return the single child Opportunity');
        System.assertEquals(parent.Id, children[0].Parent_Opportunity__c,
            'Returned child should reference the correct parent');
    }

    @IsTest
    static void selector_getChildrenByParentIds_noChildren_returnsEmptyList() {
        Account acct = getTestAccount();
        Opportunity opp = buildOpp(acct.Id, 'Childless Opp');
        insert opp;

        User testUser = getAdminUser();
        Test.startTest();
        List<Opportunity> children;
        System.runAs(testUser) {
            children = OpportunitySelector.getChildrenByParentIds(new Set<Id>{ opp.Id });
        }
        Test.stopTest();

        System.assertEquals(0, children.size(),
            'Opp with no children should return an empty list');
    }

    @IsTest
    static void selector_getChildrenByParentIds_emptySet_returnsEmptyList() {
        Test.startTest();
        List<Opportunity> children = OpportunitySelector.getChildrenByParentIds(new Set<Id>());
        Test.stopTest();

        System.assertEquals(0, children.size(),
            'getChildrenByParentIds with an empty set should return an empty list without SOQL');
    }
}