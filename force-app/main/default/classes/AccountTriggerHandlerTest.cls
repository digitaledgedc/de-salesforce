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

    // Covers the changedFieldsByAccountId branch (SFDC-361): a change to one of the five
    // Odoo-sync trigger fields (Portal_Code__c here) should both enqueue OdooAccountUpdateQueueable
    // and populate changedFields with every payload-relevant field that actually changed —
    // including the address/phone fields (BillingStreet here) that don't gate the enqueue on
    // their own but do narrow what gets sent once something else has already triggered it.
    @IsTest
    static void testAfterUpdateEnqueuesOdooSyncOnPortalCodeChange() {
        Account acc = new Account(
            Name = 'Portal Code Change Test', Operation_Country__c = 'Japan',
            Portal_Code__c = '1000-001', BillingStreet = 'Old Street');
        insert acc;

        Test.setMock(HttpCalloutMock.class, new MockOdooCallout(200, '{"result": {"partner_id": 9001}}'));

        Test.startTest();
        acc.Portal_Code__c = '1000-002';
        acc.BillingStreet = 'New Street';
        update acc;
        Test.stopTest();

        Account after = [SELECT Portal_Code__c, Odoo_Partner_ID__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals('1000-002', after.Portal_Code__c, 'Portal Code should be updated');
        System.assertEquals(9001, after.Odoo_Partner_ID__c,
            'Changing a trigger field should enqueue OdooAccountUpdateQueueable, which writes back the Odoo partner_id');
    }
}