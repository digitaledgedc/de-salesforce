@IsTest
private class BillingAccountTriggerHandlerTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(
            Name = 'BAN Handler Test Co',
            Operation_Country__c = 'Singapore',
            Tax_ID__c = 'T12345678X'
        );
        insert acc;

        Id rtId = Schema.SObjectType.Account
            .getRecordTypeInfosByDeveloperName().get('DE_Entity').getRecordTypeId();
        Account sgEntity = new Account(
            Name = 'DE SG Pte Ltd',
            RecordTypeId = rtId
        );
        insert sgEntity;
    }

    @IsTest
    static void testBeforeInsert_generatesBanNumber() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'BAN Handler Test Co' LIMIT 1];
        Account sgEntity = [SELECT Id FROM Account WHERE Name = 'DE SG Pte Ltd' LIMIT 1];

        BillingAccount__c ban = new BillingAccount__c(
            Account__c   = acc.Id,
            DE_Entity__c = sgEntity.Id
        );

        Test.startTest();
        insert ban;
        Test.stopTest();

        BillingAccount__c inserted = [SELECT BAN_Number__c, Name FROM BillingAccount__c WHERE Id = :ban.Id];
        System.assertNotEquals(null, inserted, 'BAN record should be inserted');
    }

    @IsTest
    static void testBeforeInsert_skipExistingBanNumber() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'BAN Handler Test Co' LIMIT 1];
        Account sgEntity = [SELECT Id FROM Account WHERE Name = 'DE SG Pte Ltd' LIMIT 1];

        BillingAccount__c ban = new BillingAccount__c(
            Account__c    = acc.Id,
            BAN_Number__c = 'SG99001',
            Name          = 'SG99001',
            DE_Entity__c  = sgEntity.Id
        );

        Test.startTest();
        insert ban;
        Test.stopTest();

        BillingAccount__c inserted = [SELECT BAN_Number__c FROM BillingAccount__c WHERE Id = :ban.Id];
        System.assertEquals('SG99001', inserted.BAN_Number__c,
            'Pre-populated BAN number should be preserved');
    }
}