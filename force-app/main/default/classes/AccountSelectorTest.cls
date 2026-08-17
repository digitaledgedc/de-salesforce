/**
 * AccountSelectorTest
 * Covers AccountSelector: getByName, getByNames (map path), getByIds.
 */
@IsTest
private class AccountSelectorTest {

    // ─── @TestSetup ──────────────────────────────────────────────────────────────

    @TestSetup
    static void setup() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile p = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
            User u = new User(
                Alias             = 'acctsel',
                Email             = 'acct-selector@gokarya.test.invalid',
                EmailEncodingKey  = 'UTF-8',
                LastName          = 'AcctSelector',
                LanguageLocaleKey = 'en_US',
                LocaleSidKey      = 'en_US',
                ProfileId         = p.Id,
                TimeZoneSidKey    = 'America/Los_Angeles',
                UserName          = 'acct-selector@gokarya.test.invalid'
            );
            insert u;
            PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'DE_Admin' LIMIT 1];
            insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
        }

        insert new List<Account>{
            new Account(Name = 'Selector Account Alpha', Operation_Country__c = 'SG', Finance_Approval_Phase__c = 'Not_Started'),
            new Account(Name = 'Selector Account Beta',  Operation_Country__c = 'SG', Finance_Approval_Phase__c = 'Not_Started')
        };
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────────

    private static User getTestUser() {
        return [SELECT Id FROM User WHERE UserName = 'acct-selector@gokarya.test.invalid' LIMIT 1];
    }

    // ─── getByName ───────────────────────────────────────────────────────────────

    @IsTest
    static void getByName_existingAccount_returnsOne() {
        User u = getTestUser();
        Test.startTest();
        List<Account> results;
        System.runAs(u) {
            results = AccountSelector.getByName('Selector Account Alpha');
        }
        Test.stopTest();

        System.assertEquals(1, results.size(), 'getByName should return exactly one match');
        System.assertEquals('Selector Account Alpha', results[0].Name);
    }

    @IsTest
    static void getByName_noMatch_returnsEmpty() {
        User u = getTestUser();
        Test.startTest();
        List<Account> results;
        System.runAs(u) {
            results = AccountSelector.getByName('Nonexistent Account XYZ');
        }
        Test.stopTest();

        System.assertEquals(0, results.size(), 'getByName with no match should return empty list');
    }

    // ─── getByNames (map path) ───────────────────────────────────────────────────

    @IsTest
    static void getByNames_multipleNames_returnsKeyedMap() {
        User u = getTestUser();
        Test.startTest();
        Map<String, Account> result;
        System.runAs(u) {
            result = AccountSelector.getByNames(
                new Set<String>{ 'Selector Account Alpha', 'Selector Account Beta' }
            );
        }
        Test.stopTest();

        System.assertEquals(2, result.size(), 'Map should contain both accounts');
        System.assert(result.containsKey('Selector Account Alpha'), 'Alpha should be a map key');
        System.assert(result.containsKey('Selector Account Beta'),  'Beta should be a map key');
    }

    @IsTest
    static void getByNames_emptySet_returnsEmptyMap() {
        User u = getTestUser();
        Test.startTest();
        Map<String, Account> result;
        System.runAs(u) {
            result = AccountSelector.getByNames(new Set<String>());
        }
        Test.stopTest();

        System.assertEquals(0, result.size(), 'Empty input should return empty map');
    }

    // ─── getByIds ────────────────────────────────────────────────────────────────

    @IsTest
    static void getByIds_existingIds_returnsRecords() {
        List<Account> accts = [SELECT Id FROM Account WHERE Name LIKE 'Selector Account%'];
        Set<Id> ids = new Map<Id, Account>(accts).keySet();
        User u = getTestUser();

        Test.startTest();
        List<Account> results;
        System.runAs(u) {
            results = AccountSelector.getByIds(ids);
        }
        Test.stopTest();

        System.assertEquals(2, results.size(), 'getByIds should return both accounts');
        System.assertNotEquals(null, results[0].Finance_Approval_Phase__c,
            'Finance_Approval_Phase__c should be included in the query field set');
    }

    @IsTest
    static void getByIds_emptySet_returnsEmptyList() {
        User u = getTestUser();
        Test.startTest();
        List<Account> results;
        System.runAs(u) {
            results = AccountSelector.getByIds(new Set<Id>());
        }
        Test.stopTest();

        System.assertEquals(0, results.size(), 'Empty Id set should return empty list');
    }
}