@isTest
private class DataQualityCheckTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = 'DQC Test Account');
        insert acc;

        Site__c site = new Site__c(
            Name = 'DQC Test Site', Country__c = 'SG', Site_Code__c = 'DQC-TS1',
            Odoo_Site_ID__c = 100, Odoo_Company_ID__c = 1, Odoo_Country_ID__c = 1, Odoo_Metro_ID__c = 1
        );
        insert site;

        Opportunity opp = new Opportunity(Name = 'DQC Opp', StageName = '1-Suspect', CloseDate = Date.today().addDays(30));
        insert opp;
        Quote q = new Quote(Name = 'DQC Quote', OpportunityId = opp.Id);
        insert q;

        Id spaceRT = Schema.SObjectType.Inventory__c.getRecordTypeInfosByDeveloperName().get('Inventory_Space').getRecordTypeId();
        Id breakerRT = Schema.SObjectType.Inventory__c.getRecordTypeInfosByDeveloperName().get('Inventory_Breaker').getRecordTypeId();

        List<Inventory__c> invs = new List<Inventory__c>();
        // inv1: Space, has account, quote-assigned, has Odoo Space Id, has a Space_Type
        invs.add(new Inventory__c(RecordTypeId = spaceRT, Account__c = acc.Id, Status__c = 'Assigned',
            Site_Id__c = site.Id, Space_Type__c = 'Cabinet', Odoo_Space_ID__c = 'SP1', Assigned_To_Quote__c = q.Id));
        // inv2: Space, no account, no Space_Type (SPACE_NO_TYPE contributor), no Odoo Space Id
        invs.add(new Inventory__c(RecordTypeId = spaceRT, Status__c = 'Available', Site_Id__c = site.Id));
        // inv3: Breaker, has account, has Unit_Reference and Odoo_Inventory_Id
        invs.add(new Inventory__c(RecordTypeId = breakerRT, Account__c = acc.Id, Status__c = 'Installed',
            Site_Id__c = site.Id, Unit_Reference__c = 'BRK-001', Odoo_Inventory_Id__c = 'BK1'));
        // inv4: Breaker, no account, active status, has Unit_Reference, no Odoo_Inventory_Id
        invs.add(new Inventory__c(RecordTypeId = breakerRT, Status__c = 'Installed',
            Site_Id__c = site.Id, Unit_Reference__c = 'BRK-002'));
        // inv5: Breaker, no account, active status, no Unit_Reference at all
        invs.add(new Inventory__c(RecordTypeId = breakerRT, Status__c = 'Installed', Site_Id__c = site.Id));
        // inv6: Space, has account, has a Space_Type
        invs.add(new Inventory__c(RecordTypeId = spaceRT, Account__c = acc.Id, Status__c = 'Assigned',
            Site_Id__c = site.Id, Space_Type__c = 'Cage'));
        // inv7: Space, no account, has Odoo Space Id, has a Space_Type
        invs.add(new Inventory__c(RecordTypeId = spaceRT, Status__c = 'Available',
            Site_Id__c = site.Id, Odoo_Space_ID__c = 'SP2', Space_Type__c = 'Hall'));
        insert invs;
    }

    private static User createMinimumAccessUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
        String uniq = String.valueOf(Datetime.now().getTime()) + Math.round(Math.random() * 100000);
        User u = new User(
            LastName = 'DQCMinAccess',
            Email = 'dqcminaccess' + uniq + '@example.com.invalid',
            Username = 'dqcminaccess' + uniq + '@example.com.invalid',
            Alias = 'dqcma',
            TimeZoneSidKey = 'America/Los_Angeles',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            ProfileId = p.Id,
            LanguageLocaleKey = 'en_US'
        );
        insert u;
        return u;
    }

    @isTest
    static void testRunInventoryAnalysis() {
        Site__c site = [SELECT Id FROM Site__c LIMIT 1];

        Test.startTest();
        String result = DataQualityCheck.runInventoryAnalysis();
        Test.stopTest();

        Assert.isNotNull(result, 'Analysis should return a non-null report string');
        Assert.isTrue(result.contains('TOTAL=7 | WITH_ACCOUNT=3 | NO_ACCOUNT=4'), 'Unexpected total/with-account/no-account counts: ' + result);
        Assert.isTrue(result.contains('RT: Inventory_Space => 4'), 'Unexpected Space record type count: ' + result);
        Assert.isTrue(result.contains('RT: Inventory_Breaker => 3'), 'Unexpected Breaker record type count: ' + result);
        Assert.isTrue(result.contains('NO_ACCT|Available => 2'), 'Unexpected no-account Available count: ' + result);
        Assert.isTrue(result.contains('NO_ACCT|Installed => 2'), 'Unexpected no-account Installed count: ' + result);
        Assert.isTrue(result.contains('HAS_ACCT|Assigned => 2'), 'Unexpected has-account Assigned count: ' + result);
        Assert.isTrue(result.contains('HAS_ACCT|Installed => 1'), 'Unexpected has-account Installed count: ' + result);
        Assert.isTrue(result.contains('NO_ACCT_ACTIVE_SITE|' + site.Id + ' => 2'), 'Unexpected active no-account-by-site count: ' + result);
        Assert.isTrue(result.contains('WITH_QUOTE_ASSIGNMENT=1'), 'Unexpected quote-assignment count: ' + result);
        Assert.isTrue(result.contains('SPACE_NO_TYPE=1'), 'Unexpected space-with-no-type count: ' + result);
        Assert.isTrue(result.contains('NO_SITE=0'), 'Site_Id__c is required, so NO_SITE must be 0: ' + result);
        Assert.isTrue(result.contains('ORPHAN_FLOORS=0 | ORPHAN_HALLS=0'), 'Site__c is required on Floor__c/DataHall__c, so no orphans can exist: ' + result);
    }

    @isTest
    static void testExportBreakerRefs_firstPageAndSkipsNullRefs() {
        Inventory__c brk1 = [SELECT Id, Unit_Reference__c FROM Inventory__c WHERE Unit_Reference__c = 'BRK-001'];
        Inventory__c brk2 = [SELECT Id, Unit_Reference__c FROM Inventory__c WHERE Unit_Reference__c = 'BRK-002'];

        Test.startTest();
        String page0 = DataQualityCheck.exportBreakerRefs(0);
        String page1 = DataQualityCheck.exportBreakerRefs(1);
        Test.stopTest();

        Assert.isTrue(page0.contains(brk1.Id + '|BRK-001'), 'Page 0 should include the breaker with BRK-001: ' + page0);
        Assert.isTrue(page0.contains(brk2.Id + '|BRK-002'), 'Page 0 should include the breaker with BRK-002: ' + page0);
        Assert.areEqual('', page1, 'Page far beyond the total breaker count should be empty');
    }

    @isTest
    static void testBatchUpdateAccounts_unitReferenceAndOdooSpaceIdAndNoMatch() {
        Id targetAccount1 = [SELECT Id FROM Account LIMIT 1].Id;
        Account targetAccount2 = new Account(Name = 'DQC Batch Target 2');
        insert targetAccount2;
        Account noMatchAccount = new Account(Name = 'DQC Batch NoMatch');
        insert noMatchAccount;

        Map<String, Object> mapping1 = new Map<String, Object>{
            String.valueOf(targetAccount1) => new List<String>{ 'BRK-002' },
            String.valueOf(noMatchAccount.Id) => new List<String>{ 'NOT-A-REAL-REF' }
        };
        Test.startTest();
        String result1 = DataQualityCheck.batchUpdateAccounts(JSON.serialize(mapping1), 'Unit_Reference__c');
        Test.stopTest();

        Assert.areEqual('UPDATED=1', result1, 'Only the BRK-002 reference should match an unassigned record');
        Inventory__c brk2 = [SELECT Account__c FROM Inventory__c WHERE Unit_Reference__c = 'BRK-002'];
        Assert.areEqual(targetAccount1, brk2.Account__c, 'BRK-002 should now be linked to targetAccount1');

        Map<String, Object> mapping2 = new Map<String, Object>{
            String.valueOf(targetAccount2.Id) => new List<String>{ 'SP2' }
        };
        String result2 = DataQualityCheck.batchUpdateAccounts(JSON.serialize(mapping2), 'Odoo_Space_ID__c');
        Assert.areEqual('UPDATED=1', result2, 'The SP2 Odoo Space Id should match one unassigned space record');
        Inventory__c sp2 = [SELECT Account__c FROM Inventory__c WHERE Odoo_Space_ID__c = 'SP2'];
        Assert.areEqual(targetAccount2.Id, sp2.Account__c, 'SP2 should now be linked to targetAccount2');
    }

    @isTest
    static void testBatchUpdateAccounts_noUpdatePermission() {
        User minAccessUser = createMinimumAccessUser();
        Id targetAccount = [SELECT Id FROM Account LIMIT 1].Id;
        Map<String, Object> mapping = new Map<String, Object>{ String.valueOf(targetAccount) => new List<String>{ 'BRK-002' } };

        String result;
        System.runAs(minAccessUser) {
            result = DataQualityCheck.batchUpdateAccounts(JSON.serialize(mapping), 'Unit_Reference__c');
        }
        Assert.areEqual('ERROR: No update permission', result, 'A user without Update on Inventory__c should be blocked');
    }

    @isTest
    static void testUpdateInventoryAccounts_positiveNoMatchAndPermissionDenied() {
        Id targetAccount = [SELECT Id FROM Account LIMIT 1].Id;

        Test.startTest();
        Integer updated = DataQualityCheck.updateInventoryAccounts(new List<String>{ 'BRK-002' }, targetAccount);
        Test.stopTest();
        Assert.areEqual(1, updated, 'One unassigned breaker with Unit_Reference BRK-002 should be updated');

        Integer noMatch = DataQualityCheck.updateInventoryAccounts(new List<String>{ 'DOES-NOT-EXIST' }, targetAccount);
        Assert.areEqual(0, noMatch, 'No matching records should short-circuit to 0 without any DML');

        User minAccessUser = createMinimumAccessUser();
        Integer denied;
        System.runAs(minAccessUser) {
            denied = DataQualityCheck.updateInventoryAccounts(new List<String>{ 'BRK-001' }, targetAccount);
        }
        Assert.areEqual(-1, denied, 'A user without Update on Inventory__c should get -1');
    }

    @isTest
    static void testUpdateSpaceAccounts_positiveNoMatchAndPermissionDenied() {
        Id targetAccount = [SELECT Id FROM Account LIMIT 1].Id;

        Test.startTest();
        Integer updated = DataQualityCheck.updateSpaceAccounts(new List<String>{ 'SP2' }, targetAccount);
        Test.stopTest();
        Assert.areEqual(1, updated, 'One unassigned space with Odoo_Space_ID SP2 should be updated');

        Integer noMatch = DataQualityCheck.updateSpaceAccounts(new List<String>{ 'DOES-NOT-EXIST' }, targetAccount);
        Assert.areEqual(0, noMatch, 'No matching records should short-circuit to 0 without any DML');

        User minAccessUser = createMinimumAccessUser();
        Integer denied;
        System.runAs(minAccessUser) {
            denied = DataQualityCheck.updateSpaceAccounts(new List<String>{ 'SP1' }, targetAccount);
        }
        Assert.areEqual(-1, denied, 'A user without Update on Inventory__c should get -1');
    }

    @isTest
    static void testExportAccountsToFile() {
        Account quoted = new Account(Name = 'DQC "Quoted" Co');
        insert quoted;

        Test.startTest();
        Id cvId = DataQualityCheck.exportAccountsToFile();
        Test.stopTest();

        Assert.isNotNull(cvId, 'exportAccountsToFile should return a ContentVersion Id');
        ContentVersion cv = [SELECT Title, PathOnClient, VersionData FROM ContentVersion WHERE Id = :cvId];
        Assert.areEqual('Accounts_Export', cv.Title, 'Unexpected export file title');
        String csv = cv.VersionData.toString();
        Assert.isTrue(csv.startsWith('Id,Name'), 'CSV should start with the header row: ' + csv);
        Assert.isTrue(csv.contains('DQC "Quoted" Co'.replace('"', '""')), 'Embedded quotes in Account Name must be escaped: ' + csv);
    }

    @isTest
    static void testExportBreakerRefsToFile() {
        Id breakerRT = Schema.SObjectType.Inventory__c.getRecordTypeInfosByDeveloperName().get('Inventory_Breaker').getRecordTypeId();
        Site__c site = [SELECT Id FROM Site__c LIMIT 1];
        Inventory__c quotedRefBreaker = new Inventory__c(
            RecordTypeId = breakerRT, Status__c = 'Installed', Site_Id__c = site.Id, Unit_Reference__c = 'BRK"003'
        );
        insert quotedRefBreaker;

        Test.startTest();
        Id cvId = DataQualityCheck.exportBreakerRefsToFile();
        Test.stopTest();

        Assert.isNotNull(cvId, 'exportBreakerRefsToFile should return a ContentVersion Id');
        ContentVersion cv = [SELECT Title, VersionData FROM ContentVersion WHERE Id = :cvId];
        Assert.areEqual('BreakerRefs_Export', cv.Title, 'Unexpected export file title');
        String csv = cv.VersionData.toString();
        Assert.isTrue(csv.startsWith('Id,Unit_Reference'), 'CSV should start with the header row: ' + csv);
        Assert.isTrue(csv.contains('"BRK-001"'), 'BRK-001 should be present quoted: ' + csv);
        Assert.isTrue(csv.contains('"BRK-002"'), 'BRK-002 should be present quoted: ' + csv);
        Assert.isTrue(csv.contains('"BRK""003"'), 'Embedded quotes in Unit_Reference__c must be escaped: ' + csv);
    }

    @isTest
    static void testSampleExternalIds() {
        Test.startTest();
        String result = DataQualityCheck.sampleExternalIds();
        Test.stopTest();

        Assert.isNotNull(result, 'sampleExternalIds should return a non-null report string');
        Assert.isTrue(result.contains('SPACE|SP1|'), 'Should include the sampled space with Odoo_Space_ID SP1: ' + result);
        Assert.isTrue(result.contains('BREAKER|BK1|'), 'Should include the sampled breaker with Odoo_Inventory_Id BK1: ' + result);
        Assert.isTrue(result.contains('SPACE_WITH_ODOO_ID=2 | NO_ID=2'), 'Unexpected space Odoo-id coverage counts: ' + result);
        Assert.isTrue(result.contains('BREAKER_WITH_ODOO_ID=1 | NO_ID=2'), 'Unexpected breaker Odoo-id coverage counts: ' + result);
    }
}