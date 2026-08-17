trigger BillingAccountTrigger on BillingAccount__c (before insert) {
    if (Trigger.isBefore && Trigger.isInsert) {
        BillingAccountTriggerHandler.handleBeforeInsert(Trigger.new);
    }
}