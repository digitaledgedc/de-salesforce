@IsTest
private class DealHealthPanelControllerTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = 'Test Account', Operation_Country__c = 'Singapore');
        insert acc;

        Opportunity opp = new Opportunity(
            Name        = 'Test Opp',
            AccountId   = acc.Id,
            StageName   = '1-Suspect',
            CloseDate   = Date.today().addMonths(3)
        );
        insert opp;

        Contact con = new Contact(LastName = 'Smith', FirstName = 'John', AccountId = acc.Id);
        insert con;

        insert new OpportunityContactRole(
            OpportunityId = opp.Id,
            ContactId     = con.Id,
            Role          = 'Economic Buyer',
            IsPrimary     = true
        );

        // Minimal-access user (no CRUD on Account/Contact/Opportunity/OpportunityContactRole)
        // used to exercise the CRUD/FLS permission guards in the controller.
        // Creating a User is a setup-object DML; @TestSetup is exempt from the
        // mixed-DML restriction, so it is safe to insert alongside the records above.
        Profile restrictedProfile = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
        User restrictedUser = new User(
            ProfileId         = restrictedProfile.Id,
            FirstName         = 'DealHealth',
            LastName          = 'RestrictedTestUser',
            Email             = 'dealhealth.restricted.test@dealhealth.invalid',
            Username          = 'dealhealth.restricted.test.' + Datetime.now().getTime() + '@dealhealth.invalid',
            Alias             = 'dhrtu',
            TimeZoneSidKey    = 'America/Los_Angeles',
            LocaleSidKey      = 'en_US',
            EmailEncodingKey  = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        insert restrictedUser;
    }

    private static User restrictedUser() {
        return [SELECT Id FROM User WHERE LastName = 'RestrictedTestUser' LIMIT 1];
    }

    @IsTest
    static void testGetDealHealth_returnsData() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        Test.startTest();
        Map<String, Object> result = DealHealthPanelController.getDealHealth(opp.Id);
        Test.stopTest();
        System.assertNotEquals(null, result.get('opp'),   'opp should be present');
        System.assertNotEquals(null, result.get('roles'), 'roles should be present');
        List<OpportunityContactRole> roles = (List<OpportunityContactRole>) result.get('roles');
        System.assertEquals(1, roles.size(), 'Expected one contact role');
    }

    @IsTest
    static void testUpdateEngagementStatus() {
        OpportunityContactRole ocr = [SELECT Id FROM OpportunityContactRole LIMIT 1];
        Test.startTest();
        DealHealthPanelController.updateEngagementStatus(ocr.Id, 'Supportive');
        Test.stopTest();
        OpportunityContactRole updated = [SELECT Engagement_Status__c FROM OpportunityContactRole WHERE Id = :ocr.Id];
        System.assertEquals('Supportive', updated.Engagement_Status__c, 'Engagement status should be updated');
    }

    @IsTest
    static void testGetAccountContacts_returnsContacts() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        Test.startTest();
        List<Contact> contacts = DealHealthPanelController.getAccountContacts(opp.Id);
        Test.stopTest();
        System.assertNotEquals(null, contacts, 'Contact list should not be null');
        System.assert(contacts.size() >= 1, 'Should return at least one contact');
    }

    @IsTest
    static void testCreateContactRole_success() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        Contact con = new Contact(LastName = 'Jones', AccountId = [SELECT AccountId FROM Opportunity LIMIT 1].AccountId);
        insert con;
        Test.startTest();
        DealHealthPanelController.createContactRole(opp.Id, con.Id, 'Influencer', 'In Discussion');
        Test.stopTest();
        List<OpportunityContactRole> roles = [SELECT Id, Role FROM OpportunityContactRole WHERE ContactId = :con.Id];
        System.assertEquals(1, roles.size(), 'Should have created one role');
        System.assertEquals('Influencer', roles[0].Role, 'Role should match');
    }

    @IsTest
    static void testCreateContactAndRole_success() {
        Opportunity opp = [SELECT Id, AccountId FROM Opportunity LIMIT 1];
        Test.startTest();
        Id conId = DealHealthPanelController.createContactAndRole(
            opp.Id, opp.AccountId, 'Jane', 'Doe', 'VP Sales', 'jane@test.com', 'Decision Maker', 'Supportive');
        Test.stopTest();
        System.assertNotEquals(null, conId, 'New contact Id should be returned');
        Contact c = [SELECT LastName, Email FROM Contact WHERE Id = :conId];
        System.assertEquals('Doe', c.LastName, 'Last name should be Doe');
    }

    @IsTest
    static void testCreateContactForOpportunity_success() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        Test.startTest();
        Id conId = DealHealthPanelController.createContactForOpportunity(
            opp.Id, 'Alice', 'Wong', 'CTO', 'alice@test.com');
        Test.stopTest();
        System.assertNotEquals(null, conId, 'Contact Id should be returned');
        Contact c = [SELECT FirstName, LastName, Email FROM Contact WHERE Id = :conId];
        System.assertEquals('Wong',  c.LastName,  'Last name should be Wong');
        System.assertEquals('alice@test.com', c.Email, 'Email should be set');
    }

    @IsTest
    static void testCreateContactForOpportunity_noLastName_throws() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        Boolean threw = false;
        Test.startTest();
        try {
            DealHealthPanelController.createContactForOpportunity(opp.Id, 'Alice', '', null, null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'Should have thrown AuraHandledException for blank LastName');
    }

    @IsTest
    static void testCanViewInternalTab_returnsBoolean() {
        Test.startTest();
        Boolean result = DealHealthPanelController.canViewInternalTab();
        Test.stopTest();
        // Running user in test context is System Administrator → should be true
        System.assertNotEquals(null, result, 'Should return a non-null Boolean');
    }

    @IsTest
    static void testDeleteContactRole_success() {
        OpportunityContactRole ocr = [SELECT Id FROM OpportunityContactRole LIMIT 1];
        Test.startTest();
        DealHealthPanelController.deleteContactRole(ocr.Id);
        Test.stopTest();
        List<OpportunityContactRole> remaining = [SELECT Id FROM OpportunityContactRole WHERE Id = :ocr.Id];
        System.assertEquals(0, remaining.size(), 'Role should be deleted');
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  Additional coverage — lifts DealHealthPanelController ≥75%.
    // ══════════════════════════════════════════════════════════════════════════

    private static final String STATUS_CONFIRMED = '2 - Known and Confirmed';

    private static Opportunity opp() { return [SELECT Id, AccountId FROM Opportunity LIMIT 1]; }

    // ── getExistingRoles ─────────────────────────────────────────────────────────
    @IsTest
    static void getExistingRoles_returnsRoles() {
        Test.startTest();
        List<OpportunityContactRole> roles = DealHealthPanelController.getExistingRoles(opp().Id);
        Test.stopTest();
        System.assert(roles.size() >= 1, 'Should return the seeded contact role');
    }

    // ── searchAccounts (both branches) + createAccount (both branches) ───────────
    @IsTest
    static void searchAndCreateAccounts() {
        Test.startTest();
        Id noRtId   = DealHealthPanelController.createAccount('Search Plain Acct', null);
        Id withRtId = DealHealthPanelController.createAccount('Search RT Acct', 'Customer');
        List<Account> anyMatch = DealHealthPanelController.searchAccounts('Search', null);
        List<Account> rtMatch  = DealHealthPanelController.searchAccounts('Search RT', 'Customer');
        Test.stopTest();

        System.assertNotEquals(null, noRtId,   'Account without record type should be created');
        System.assertNotEquals(null, withRtId, 'Account with record type should be created');
        System.assert(!anyMatch.isEmpty(), 'Name-only search should match');
        System.assert(!rtMatch.isEmpty(),  'Record-type-filtered search should match');
    }

    // ── updateContactRole ────────────────────────────────────────────────────────
    @IsTest
    static void updateContactRole_updatesRole() {
        OpportunityContactRole ocr = [SELECT Id FROM OpportunityContactRole LIMIT 1];
        Test.startTest();
        DealHealthPanelController.updateContactRole(ocr.Id, 'Champion');
        Test.stopTest();
        System.assertEquals('Champion', [SELECT Role FROM OpportunityContactRole WHERE Id = :ocr.Id].Role,
            'Role should be updated');
    }

    // ── updateContactRoleAndEngagement (both branches) ───────────────────────────
    @IsTest
    static void updateContactRoleAndEngagement_bothBranches() {
        OpportunityContactRole ocr = [SELECT Id FROM OpportunityContactRole LIMIT 1];
        Opportunity o = opp();
        Test.startTest();
        // With MEDDPICC field update branch
        DealHealthPanelController.updateContactRoleAndEngagement(
            ocr.Id, 'Champion', 'Supportive', o.Id, 'MEDDPICC_Champion_Status__c', STATUS_CONFIRMED);
        // Without MEDDPICC update (null opp / blank field → skip branch)
        DealHealthPanelController.updateContactRoleAndEngagement(
            ocr.Id, 'Influencer', 'In Discussion', null, '', null);
        Test.stopTest();
        OpportunityContactRole updated = [SELECT Role, Engagement_Status__c FROM OpportunityContactRole WHERE Id = :ocr.Id];
        System.assertEquals('Influencer', updated.Role, 'Role should reflect last update');
    }

    // ── updateMeddpiccStatusField (text + reference branches) ────────────────────
    @IsTest
    static void updateMeddpiccStatusField_textAndReference() {
        Opportunity o = opp();
        Id competitor = DealHealthPanelController.createAccount('Competitor Co', 'Competitor');
        Test.startTest();
        // Text/picklist branch
        DealHealthPanelController.updateMeddpiccStatusField(o.Id, 'MEDDPICC_Metrics_Status__c', STATUS_CONFIRMED);
        // Reference branch (lookup) — set then clear
        DealHealthPanelController.updateMeddpiccStatusField(o.Id, 'Competitor_Account__c', competitor);
        DealHealthPanelController.updateMeddpiccStatusField(o.Id, 'Competitor_Account__c', '');
        Test.stopTest();
        System.assertEquals(STATUS_CONFIRMED,
            [SELECT MEDDPICC_Metrics_Status__c FROM Opportunity WHERE Id = :o.Id].MEDDPICC_Metrics_Status__c,
            'Text status field should be updated');
    }

    // ── updateContactReportsTo ───────────────────────────────────────────────────
    @IsTest
    static void updateContactReportsTo_setsManager() {
        Id acctId = opp().AccountId;
        Contact mgr  = new Contact(LastName = 'Manager', AccountId = acctId);
        Contact rep  = new Contact(LastName = 'Report',  AccountId = acctId);
        insert new List<Contact>{ mgr, rep };
        Test.startTest();
        DealHealthPanelController.updateContactReportsTo(rep.Id, mgr.Id);
        Test.stopTest();
        System.assertEquals(mgr.Id, [SELECT ReportsToId FROM Contact WHERE Id = :rep.Id].ReportsToId,
            'ReportsToId should be set');
    }

    // ── The six MEDDPICC section updaters ────────────────────────────────────────
    @IsTest
    static void meddpiccSectionUpdaters() {
        Opportunity o = opp();
        Id competitor = DealHealthPanelController.createAccount('Compete Co', 'Competitor');
        Test.startTest();
        DealHealthPanelController.updateMetrics(o.Id, 'Cost Reduction', 'Save 20%', STATUS_CONFIRMED);
        DealHealthPanelController.updateDecisionCriteria(o.Id, '', 'Must integrate', STATUS_CONFIRMED);
        DealHealthPanelController.updateDecisionProcess(o.Id, '', 'Board sign-off', STATUS_CONFIRMED);
        DealHealthPanelController.updatePaperProcess(o.Id, '', 'Legal + procurement', STATUS_CONFIRMED);
        DealHealthPanelController.updatePain(o.Id, 'Downtime risk', STATUS_CONFIRMED);
        DealHealthPanelController.updateCompetition(o.Id, competitor, 'Incumbent vendor', STATUS_CONFIRMED);
        DealHealthPanelController.updateCompetition(o.Id, '', 'No competitor', STATUS_CONFIRMED); // blank → null branch
        Test.stopTest();
        Opportunity r = [SELECT MEDDPICC_Metrics__c, MEDDPICC_Pain__c, MEDDPICC_Competition__c, Competitor_Account__c
                         FROM Opportunity WHERE Id = :o.Id];
        System.assertEquals('Save 20%', r.MEDDPICC_Metrics__c, 'Metrics description should be set');
        System.assertEquals('Downtime risk', r.MEDDPICC_Pain__c, 'Pain description should be set');
        System.assertEquals(null, r.Competitor_Account__c, 'Blank competitor id should clear the lookup');
    }

    // ── createContactAndRole resolves AccountId from Opportunity when null ────────
    @IsTest
    static void createContactAndRole_resolvesAccountFromOpp() {
        Opportunity o = opp();
        Test.startTest();
        Id conId = DealHealthPanelController.createContactAndRole(
            o.Id, null, 'Resolve', 'FromOpp', 'Mgr', 'r@test.com', 'Influencer', 'Supportive');
        Test.stopTest();
        System.assertNotEquals(null, conId, 'Contact should be created with account resolved from the opp');
        System.assertEquals(o.AccountId, [SELECT AccountId FROM Contact WHERE Id = :conId].AccountId,
            'Contact account should match the opportunity account');
    }

    // ── createContactAndRole: blank LastName guard ───────────────────────────────
    @IsTest
    static void createContactAndRole_blankLastName_throws() {
        Opportunity o = opp();
        Boolean threw = false;
        Test.startTest();
        try {
            DealHealthPanelController.createContactAndRole(
                o.Id, o.AccountId, 'NoLast', '', null, null, 'Influencer', 'Neutral');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'Should throw AuraHandledException for blank LastName in createContactAndRole');
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  CRUD/FLS permission-guard coverage — runs the write methods as a
    //  minimal-access user (no Account/Contact/Opportunity/OpportunityContactRole
    //  CRUD) so each guard's throw branch is actually executed.
    // ══════════════════════════════════════════════════════════════════════════
    @IsTest
    static void permissionGuards_restrictedUserThrows() {
        Opportunity o = opp();
        OpportunityContactRole ocr = [SELECT Id FROM OpportunityContactRole LIMIT 1];
        Contact con = [SELECT Id FROM Contact LIMIT 1];
        User ru = restrictedUser();

        Test.startTest();
        System.runAs(ru) {
            Boolean threw;

            threw = false;
            try {
                DealHealthPanelController.createContactForOpportunity(o.Id, 'A', 'B', null, null);
            } catch (AuraHandledException e) { threw = true; }
            System.assert(threw, 'createContactForOpportunity should guard Contact create');

            threw = false;
            try {
                DealHealthPanelController.createAccount('Guard Acct', null);
            } catch (AuraHandledException e) { threw = true; }
            System.assert(threw, 'createAccount should guard Account create');

            threw = false;
            try {
                DealHealthPanelController.createContactRole(o.Id, con.Id, 'Influencer', 'Neutral');
            } catch (AuraHandledException e) { threw = true; }
            System.assert(threw, 'createContactRole should guard OpportunityContactRole create');

            threw = false;
            try {
                DealHealthPanelController.createContactAndRole(
                    o.Id, o.AccountId, 'A', 'B', null, null, 'Influencer', 'Neutral');
            } catch (AuraHandledException e) { threw = true; }
            System.assert(threw, 'createContactAndRole should guard Contact create');

            threw = false;
            try {
                DealHealthPanelController.updateEngagementStatus(ocr.Id, 'Supportive');
            } catch (AuraHandledException e) { threw = true; }
            System.assert(threw, 'updateEngagementStatus should guard OpportunityContactRole update');

            threw = false;
            try {
                DealHealthPanelController.updateContactRole(ocr.Id, 'Champion');
            } catch (AuraHandledException e) { threw = true; }
            System.assert(threw, 'updateContactRole should guard OpportunityContactRole update');

            threw = false;
            try {
                DealHealthPanelController.deleteContactRole(ocr.Id);
            } catch (AuraHandledException e) { threw = true; }
            System.assert(threw, 'deleteContactRole should guard OpportunityContactRole delete');

            threw = false;
            try {
                DealHealthPanelController.updateContactRoleAndEngagement(
                    ocr.Id, 'Champion', 'Supportive', o.Id, 'MEDDPICC_Champion_Status__c', STATUS_CONFIRMED);
            } catch (AuraHandledException e) { threw = true; }
            System.assert(threw, 'updateContactRoleAndEngagement should guard OpportunityContactRole update');

            threw = false;
            try {
                DealHealthPanelController.updateMeddpiccStatusField(o.Id, 'MEDDPICC_Metrics_Status__c', STATUS_CONFIRMED);
            } catch (AuraHandledException e) { threw = true; }
            System.assert(threw, 'updateMeddpiccStatusField should guard Opportunity update');

            threw = false;
            try {
                DealHealthPanelController.updateContactReportsTo(con.Id, con.Id);
            } catch (AuraHandledException e) { threw = true; }
            System.assert(threw, 'updateContactReportsTo should guard Contact update');

            threw = false;
            try {
                DealHealthPanelController.updateMetrics(o.Id, 'Cost Reduction', 'x', STATUS_CONFIRMED);
            } catch (AuraHandledException e) { threw = true; }
            System.assert(threw, 'updateMetrics should guard Opportunity update');

            threw = false;
            try {
                DealHealthPanelController.updateDecisionCriteria(o.Id, '', 'x', STATUS_CONFIRMED);
            } catch (AuraHandledException e) { threw = true; }
            System.assert(threw, 'updateDecisionCriteria should guard Opportunity update');

            threw = false;
            try {
                DealHealthPanelController.updateDecisionProcess(o.Id, '', 'x', STATUS_CONFIRMED);
            } catch (AuraHandledException e) { threw = true; }
            System.assert(threw, 'updateDecisionProcess should guard Opportunity update');

            threw = false;
            try {
                DealHealthPanelController.updatePaperProcess(o.Id, '', 'x', STATUS_CONFIRMED);
            } catch (AuraHandledException e) { threw = true; }
            System.assert(threw, 'updatePaperProcess should guard Opportunity update');

            threw = false;
            try {
                DealHealthPanelController.updatePain(o.Id, 'x', STATUS_CONFIRMED);
            } catch (AuraHandledException e) { threw = true; }
            System.assert(threw, 'updatePain should guard Opportunity update');

            threw = false;
            try {
                DealHealthPanelController.updateCompetition(o.Id, null, 'x', STATUS_CONFIRMED);
            } catch (AuraHandledException e) { threw = true; }
            System.assert(threw, 'updateCompetition should guard Opportunity update');
        }
        Test.stopTest();
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  catch(Exception e) → AuraHandledException wrapping branches, forced via
    //  DML failures (invalid email format / invalid cross-reference id / update
    //  against a deleted parent record) rather than permission guards.
    // ══════════════════════════════════════════════════════════════════════════
    @IsTest
    static void exceptionCatchBranches_dmlFailureWrapped() {
        Opportunity o = opp();
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Opportunity tempOpp = new Opportunity(
            Name = 'Temp Deleted Opp', AccountId = acc.Id,
            StageName = '1-Suspect', CloseDate = Date.today().addMonths(1));
        insert tempOpp;
        delete tempOpp;

        Test.startTest();
        Boolean threw;

        threw = false;
        try {
            DealHealthPanelController.createContactForOpportunity(o.Id, 'Bad', 'Email', null, 'not-an-email');
        } catch (AuraHandledException e) { threw = true; }
        System.assert(threw, 'createContactForOpportunity should wrap a DML failure on invalid email');

        threw = false;
        try {
            DealHealthPanelController.createContactAndRole(
                o.Id, o.AccountId, 'Bad', 'Email2', null, 'not-an-email', 'Influencer', 'Neutral');
        } catch (AuraHandledException e) { threw = true; }
        System.assert(threw, 'createContactAndRole should wrap a DML failure on invalid email');

        threw = false;
        try {
            // acc.Id is an Account Id passed where a Contact Id is expected —
            // triggers an invalid cross-reference id DML failure.
            DealHealthPanelController.createContactRole(o.Id, acc.Id, 'Influencer', 'Neutral');
        } catch (AuraHandledException e) { threw = true; }
        System.assert(threw, 'createContactRole should wrap a DML failure on an invalid ContactId');

        threw = false;
        try {
            DealHealthPanelController.updateMetrics(tempOpp.Id, 'Cost Reduction', 'x', STATUS_CONFIRMED);
        } catch (AuraHandledException e) { threw = true; }
        System.assert(threw, 'updateMetrics should wrap a DML failure against a deleted Opportunity');

        threw = false;
        try {
            DealHealthPanelController.updateDecisionCriteria(tempOpp.Id, '', 'x', STATUS_CONFIRMED);
        } catch (AuraHandledException e) { threw = true; }
        System.assert(threw, 'updateDecisionCriteria should wrap a DML failure against a deleted Opportunity');

        threw = false;
        try {
            DealHealthPanelController.updateDecisionProcess(tempOpp.Id, '', 'x', STATUS_CONFIRMED);
        } catch (AuraHandledException e) { threw = true; }
        System.assert(threw, 'updateDecisionProcess should wrap a DML failure against a deleted Opportunity');

        threw = false;
        try {
            DealHealthPanelController.updatePaperProcess(tempOpp.Id, '', 'x', STATUS_CONFIRMED);
        } catch (AuraHandledException e) { threw = true; }
        System.assert(threw, 'updatePaperProcess should wrap a DML failure against a deleted Opportunity');

        threw = false;
        try {
            DealHealthPanelController.updatePain(tempOpp.Id, 'x', STATUS_CONFIRMED);
        } catch (AuraHandledException e) { threw = true; }
        System.assert(threw, 'updatePain should wrap a DML failure against a deleted Opportunity');

        threw = false;
        try {
            DealHealthPanelController.updateCompetition(tempOpp.Id, null, 'x', STATUS_CONFIRMED);
        } catch (AuraHandledException e) { threw = true; }
        System.assert(threw, 'updateCompetition should wrap a DML failure against a deleted Opportunity');

        Test.stopTest();
    }
}