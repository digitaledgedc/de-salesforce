trigger AccountTrigger on Account (after insert, after update) {
    if (Trigger.isAfter && Trigger.isInsert) {
        AccountTriggerHandler.handleAfterInsert(Trigger.new);
    }
    if (Trigger.isAfter && Trigger.isUpdate) {
        AccountTriggerHandler.handleAfterUpdate(Trigger.new, Trigger.oldMap);
    }
}