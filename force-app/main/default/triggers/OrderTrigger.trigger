trigger OrderTrigger on Order (after insert, after update) {
    if (Trigger.isInsert) {
        OrderTriggerHandler.handleAfterInsert(Trigger.new);
    } else if (Trigger.isUpdate) {
        OrderTriggerHandler.handleAfterUpdate(Trigger.new, Trigger.oldMap);
    }
}