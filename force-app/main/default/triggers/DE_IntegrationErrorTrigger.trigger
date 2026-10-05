trigger DE_IntegrationErrorTrigger on DE_Integration_Error__c (after insert) {
    if (Trigger.isAfter && Trigger.isInsert) {
        OdooSyncErrorEmailService.handleAfterInsert(Trigger.new);
    }
}