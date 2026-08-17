trigger InventoryTrigger on Inventory__c (after insert, after update) {
    if (Trigger.isAfter && Trigger.isInsert) {
        InventoryTriggerHandler.handleAfterInsert(Trigger.new);
    }
    if (Trigger.isAfter && Trigger.isUpdate) {
        InventoryTriggerHandler.handleAfterUpdate(Trigger.new, Trigger.oldMap);
    }
}