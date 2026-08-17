@IsTest
private class ContactCreateHelperTest {

    @IsTest
    static void createContact_succeeds() {
        Account acct = new Account(Name = 'CCH Test Acct', Operation_Country__c = 'SG');
        insert acct;

        ContactCreateHelper.CreateRequest req = new ContactCreateHelper.CreateRequest();
        req.firstName = 'Test';
        req.lastName  = 'ContactCCH';
        req.email     = 'cch-test+' + UserInfo.getOrganizationId() + '@gokarya.test.invalid';
        req.phone     = '+65 9999 0000';
        req.title     = 'CTO';
        req.accountId = acct.Id;

        Test.startTest();
        List<ContactCreateHelper.CreateResult> results = ContactCreateHelper.createContact(
            new List<ContactCreateHelper.CreateRequest>{ req }
        );
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(true, results[0].success);
        System.assertNotEquals(null, results[0].contactId);

        Contact created = [SELECT FirstName, LastName, Email, AccountId FROM Contact WHERE Id = :results[0].contactId];
        System.assertEquals('Test', created.FirstName);
        System.assertEquals('ContactCCH', created.LastName);
        System.assertEquals(acct.Id, created.AccountId);
    }
}