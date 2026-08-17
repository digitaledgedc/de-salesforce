/**
 * TriggerHandler — GoKarya base class for all Salesforce triggers.
 * All triggers delegate immediately to a handler extending this class.
 * No business logic lives in trigger files.
 *
 * Pattern: SF_PATTERNS.md § Trigger Handler Framework [DRAFT]
 */
public inherited sharing virtual class TriggerHandler {

    public void run() {
        if (Trigger.isBefore) {
            if (Trigger.isInsert)  beforeInsert();
            if (Trigger.isUpdate)  beforeUpdate();
            if (Trigger.isDelete)  beforeDelete();
        } else if (Trigger.isAfter) {
            if (Trigger.isInsert)   afterInsert();
            if (Trigger.isUpdate)   afterUpdate();
            if (Trigger.isDelete)   afterDelete();
            if (Trigger.isUndelete) afterUndelete();
        }
    }

    protected virtual void beforeInsert()  {}
    protected virtual void afterInsert()   {}
    protected virtual void beforeUpdate()  {}
    protected virtual void afterUpdate()   {}
    protected virtual void beforeDelete()  {}
    protected virtual void afterDelete()   {}
    protected virtual void afterUndelete() {}
}