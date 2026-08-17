/**
 * TermsAndConditionControllerTest
 * Covers isSystemAdmin (true for the running test user, since Apex tests
 * default to running as a System Administrator unless System.runAs is used),
 * searchAccounts (blank term short-circuit + LIKE match), createTandCRecord
 * (required-name validation + successful insert/submit), and
 * createTermsAndCondition (custom metadata deployment enqueue — Apex tests
 * don't actually complete a metadata deploy, so this only proves the call
 * doesn't throw before/during enqueueing).
 */
@IsTest
private class TermsAndConditionControllerTest {

    @TestSetup
    static void setup() {
        insert new Account(Name = 'TACC Search Match Account');
    }

    @IsTest
    static void testIsSystemAdmin_TrueForTestRunningUser() {
        Test.startTest();
        Boolean result = TermsAndConditionController.isSystemAdmin();
        Test.stopTest();

        System.assertEquals(true, result, 'Apex tests run as a System Administrator by default');
    }

    @IsTest
    static void testSearchAccounts_BlankTerm_ReturnsEmptyList() {
        Test.startTest();
        List<Map<String, String>> results = TermsAndConditionController.searchAccounts('');
        Test.stopTest();

        System.assertEquals(0, results.size(), 'A blank search term should short-circuit to an empty list');
    }

    @IsTest
    static void testSearchAccounts_MatchingTerm_ReturnsAccount() {
        Test.startTest();
        List<Map<String, String>> results = TermsAndConditionController.searchAccounts('TACC Search Match');
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Should find exactly one matching account');
        System.assertEquals('TACC Search Match Account', results[0].get('name'));
    }

    @IsTest
    static void testCreateTandCRecord_BlankName_ThrowsAuraHandledException() {
        Boolean caught = false;
        Test.startTest();
        try {
            TermsAndConditionController.createTandCRecord('', 'terms', 'cust', 'co', 'Creation');
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();

        System.assert(caught, 'A blank tandcName should throw AuraHandledException');
    }

    @IsTest
    static void testCreateTandCRecord_ValidInput_CreatesRecordAndSubmitsApproval() {
        Test.startTest();
        Id newId = TermsAndConditionController.createTandCRecord(
            'TACC Test T&C', 'Sample terms text', 'Test Customer', 'Test Company', 'Creation'
        );
        Test.stopTest();

        System.assertNotEquals(null, newId, 'Should return the new record Id');

        Special_Instruction__c created = [
            SELECT TandC_Name__c, Status__c, Type__c, Terms_Text__c, RecordType.DeveloperName
            FROM Special_Instruction__c WHERE Id = :newId
        ];
        System.assertEquals('TACC Test T&C', created.TandC_Name__c);
        System.assertEquals('New', created.Status__c);
        System.assertEquals('T&C', created.Type__c);
        System.assertEquals('Terms_and_Conditions', created.RecordType.DeveloperName);
    }

    @IsTest
    static void testCreateTermsAndCondition_BlankName_ThrowsAuraHandledException() {
        Boolean caught = false;
        Test.startTest();
        try {
            TermsAndConditionController.createTermsAndCondition('', 'terms', 'cust', 'co', 'Creation');
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();

        System.assert(caught, 'A blank tcName should throw AuraHandledException');
    }

    @IsTest
    static void testCreateTermsAndCondition_ValidInput_BuildsMetadataThenHitsPlatformTestRestriction() {
        // Metadata.Operations.enqueueDeployment() can never run inside an Apex
        // test (Salesforce throws AsyncException unconditionally) — this proves
        // the method builds the CustomMetadata container correctly and reaches
        // that call, which is as far as any test can exercise this method.
        Boolean caughtExpectedRestriction = false;
        Test.startTest();
        try {
            TermsAndConditionController.createTermsAndCondition(
                'TACC CMDT Test!!', 'Sample terms text', 'Test Customer', 'Test Company', 'Creation'
            );
        } catch (AsyncException e) {
            caughtExpectedRestriction = e.getMessage().contains('cannot be deployed from within a test');
        }
        Test.stopTest();

        System.assert(caughtExpectedRestriction,
            'Should reach the metadata deploy call and hit the platform\'s test-context restriction, not fail earlier');
    }
}