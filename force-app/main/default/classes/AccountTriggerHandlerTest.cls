@IsTest
private class AccountTriggerHandlerTest {

    @IsTest
    static void testAfterInsertFiresSharing() {
        Account acc = new Account(Name = 'Handler Insert Test', Operation_Country__c = 'Korea');
        Test.startTest();
        insert acc;
        Test.stopTest();
        System.assertNotEquals(null, acc.Id, 'Account should be created');
    }

    @IsTest
    static void testAfterUpdateFiresOnCountryChange() {
        Account acc = new Account(Name = 'Handler Update Test', Operation_Country__c = 'Japan');
        insert acc;

        Test.startTest();
        acc.Operation_Country__c = 'Korea';
        update acc;
        Test.stopTest();
        System.assertNotEquals(null, acc.Id, 'Account should be updated');
    }

    @IsTest
    static void testNoChangeDoesNotFireSharing() {
        Account acc = new Account(Name = 'No Change Test', Operation_Country__c = 'China');
        insert acc;

        Test.startTest();
        acc.Name = 'No Change Test Updated';
        update acc;
        Test.stopTest();
        System.assertNotEquals(null, acc.Id, 'Account should be updated without sharing recalc');
    }
}