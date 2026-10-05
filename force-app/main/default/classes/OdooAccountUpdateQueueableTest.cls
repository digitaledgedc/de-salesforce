/**
 * OdooAccountUpdateQueueableTest
 * Covers SFDC-361: syncing Account.Portal_Code__c changes to Odoo via the same
 * create_partner endpoint NEW-A uses, plus the AccountTriggerHandler wiring that
 * enqueues this class.
 */
@IsTest
private class OdooAccountUpdateQueueableTest {

    @IsTest
    static void testUnsyncedAccount_CreatesPartner_WritesBackOdooPartnerId() {
        Account acc = new Account(Name = 'AUQ Unsynced Account', Portal_Code__c = '1143-001-TEST');
        insert acc;

        Test.setMock(HttpCalloutMock.class, new MockOdooCallout(200,
            '{"result": {"partner_id": 7001}}'));

        Test.startTest();
        System.enqueueJob(new OdooAccountUpdateQueueable(new List<Id>{ acc.Id }));
        Test.stopTest();

        Account after = [SELECT Odoo_Partner_ID__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals(7001, after.Odoo_Partner_ID__c,
            'partner_id from the response should be written back even for a first-time create');
    }

    @IsTest
    static void testAlreadySyncedAccount_PayloadIncludesExistingPartnerId() {
        Account acc = new Account(
            Name = 'AUQ Synced Account', Portal_Code__c = '1143-002-TEST', Odoo_Partner_ID__c = 8001
        );
        insert acc;

        OdooAccountUpdateQueueable q = new OdooAccountUpdateQueueable(new List<Id>{ acc.Id });
        String payload = q.buildPartnerPayload(
            acc, null, null, 8001, null, new OdooIntegrationSettings__c());

        System.assert(payload.contains('"partner_id":8001'),
            'Update payload should carry the existing Odoo_Partner_ID__c as partner_id');
        System.assert(payload.contains('"ns_portal_code":"1143-002-TEST"'),
            'Update payload should carry the new Portal Code value');
    }

    @IsTest
    static void testUnsyncedAccount_NoPartnerIdInPayload() {
        Account acc = new Account(Name = 'AUQ No Partner Id', Portal_Code__c = '1143-003-TEST');
        insert acc;

        OdooAccountUpdateQueueable q = new OdooAccountUpdateQueueable(new List<Id>{ acc.Id });
        String payload = q.buildPartnerPayload(
            acc, null, null, null, null, new OdooIntegrationSettings__c());

        System.assert(!payload.contains('partner_id'),
            'A first-time sync (no existing Odoo_Partner_ID__c) should omit partner_id entirely');
    }

    @IsTest
    static void testCalloutFailure_LogsIntegrationError() {
        Account acc = new Account(Name = 'AUQ Failure Account', Portal_Code__c = '1143-004-TEST');
        insert acc;

        Test.setMock(HttpCalloutMock.class, new MockOdooCallout(500, 'Internal Server Error'));

        Test.startTest();
        System.enqueueJob(new OdooAccountUpdateQueueable(new List<Id>{ acc.Id }));
        Test.stopTest();

        List<DE_Integration_Error__c> errors = [
            SELECT IP_Reference__c, Record_Id__c FROM DE_Integration_Error__c
            WHERE Record_Id__c = :acc.Id
        ];
        System.assertEquals(1, errors.size(), 'A failed callout should log exactly one error');
        System.assertEquals('ACCT-UPDATE', errors[0].IP_Reference__c);
    }

    @IsTest
    static void testPartnerIdZero_LogsCollisionError() {
        Account acc = new Account(Name = 'AUQ Zero Partner Id', Portal_Code__c = '1143-005-TEST');
        insert acc;

        Test.setMock(HttpCalloutMock.class, new MockOdooCallout(200, '{"result": {"partner_id": 0}}'));

        Test.startTest();
        System.enqueueJob(new OdooAccountUpdateQueueable(new List<Id>{ acc.Id }));
        Test.stopTest();

        List<DE_Integration_Error__c> errors = [
            SELECT Error_Message__c FROM DE_Integration_Error__c WHERE Record_Id__c = :acc.Id
        ];
        System.assertEquals(1, errors.size());
        System.assert(errors[0].Error_Message__c.contains('ns_portal_code'),
            'partner_id=0 should log the same ns_portal_code lookup guidance NEW-A uses');
    }

    @IsTest
    static void testAccountTrigger_PortalCodeChange_EnqueuesSync() {
        Account acc = new Account(Name = 'AUQ Trigger Account', Portal_Code__c = 'OLD-CODE');
        insert acc;

        Test.setMock(HttpCalloutMock.class, new MockOdooCallout(200,
            '{"result": {"partner_id": 7002}}'));

        Test.startTest();
        acc.Portal_Code__c = 'NEW-CODE';
        update acc;
        Test.stopTest();

        Account after = [SELECT Odoo_Partner_ID__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals(7002, after.Odoo_Partner_ID__c,
            'Changing Portal_Code__c on update should enqueue OdooAccountUpdateQueueable via AccountTriggerHandler');
    }

    @IsTest
    static void testAccountTrigger_NoPortalCodeChange_DoesNotCallout() {
        Account acc = new Account(Name = 'AUQ No Change Account', Portal_Code__c = 'SAME-CODE');
        insert acc;

        // No mock set — if a callout were attempted, this test fails with a CalloutException.
        Test.startTest();
        acc.Name = 'AUQ No Change Account Renamed';
        update acc;
        Test.stopTest();

        System.assert(true, 'No callout should be attempted when Portal_Code__c does not change');
    }
}