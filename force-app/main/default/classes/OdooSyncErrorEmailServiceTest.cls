@IsTest
private class OdooSyncErrorEmailServiceTest {

    @IsTest
    static void sendForIds_sendsEmailWithBody() {
        DE_Integration_Error__c err = new DE_Integration_Error__c(
            IP_Reference__c = 'IP-1',
            Error_Message__c = 'Timeout calling Odoo',
            Status__c = 'Open'
        );
        insert err;

        OdooSyncErrorEmailService.toAddressOverride = 'badal@gokarya.com';

        Test.startTest();
        Integer n = OdooSyncErrorEmailService.sendForIds(new List<Id>{ err.Id });
        Test.stopTest();

        System.assertEquals(1, n, 'One email should be attempted');
        System.assertNotEquals(null, OdooSyncErrorEmailService.lastHtmlBody);
        System.assert(
            OdooSyncErrorEmailService.lastHtmlBody.contains('Timeout calling Odoo'),
            'Body should include error message'
        );
        System.assert(
            OdooSyncErrorEmailService.lastHtmlBody.contains('IP-1'),
            'Body should include integration point'
        );
        System.assert(
            !OdooSyncErrorEmailService.lastHtmlBody.contains('<table'),
            'Body must not use a table'
        );

        err = [SELECT Name FROM DE_Integration_Error__c WHERE Id = :err.Id];
        System.assert(
            OdooSyncErrorEmailService.lastHtmlBody.contains(err.Name),
            'Body should include error number'
        );
    }

    @IsTest
    static void trigger_enqueuesAndSends() {
        OdooSyncErrorEmailService.toAddressOverride = 'badal@gokarya.com';

        Test.startTest();
        DE_Integration_Error__c err = new DE_Integration_Error__c(
            IP_Reference__c = 'IP-4',
            Error_Message__c = 'Change order failed',
            Status__c = 'Open'
        );
        insert err;
        Test.stopTest(); // runs queueable

        System.assertNotEquals(
            null,
            OdooSyncErrorEmailService.lastHtmlBody,
            'After-insert queueable should build and send an email'
        );
        System.assert(
            OdooSyncErrorEmailService.lastHtmlBody.contains('Change order failed'),
            'Body should include the inserted error message'
        );
    }

    @IsTest
    static void queueable_chunksAndProcesses() {
        List<DE_Integration_Error__c> rows = new List<DE_Integration_Error__c>();
        for (Integer i = 0; i < 3; i++) {
            rows.add(new DE_Integration_Error__c(
                IP_Reference__c = 'IP-3',
                Error_Message__c = 'Inventory error ' + i,
                Status__c = 'Open'
            ));
        }
        insert rows;

        OdooSyncErrorEmailService.toAddressOverride = 'badal@gokarya.com';
        List<Id> ids = new List<Id>();
        for (DE_Integration_Error__c r : rows) {
            ids.add(r.Id);
        }

        Test.startTest();
        System.enqueueJob(new OdooSyncErrorEmailService.EmailQueueable(ids));
        Test.stopTest();

        System.assertNotEquals(null, OdooSyncErrorEmailService.lastHtmlBody);
        System.assert(
            OdooSyncErrorEmailService.lastHtmlBody.contains('Inventory error'),
            'Queueable should process and email the chunk'
        );
    }

    @IsTest
    static void sendForIds_emptyList_returnsZero() {
        Test.startTest();
        Integer n = OdooSyncErrorEmailService.sendForIds(new List<Id>());
        Test.stopTest();
        System.assertEquals(0, n);
    }
}