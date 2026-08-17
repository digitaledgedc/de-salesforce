/**
 * SystemQuoteUpdater
 *
 * Without-sharing utility for updating locked records.
 * Used when finance users need to update records locked by
 * active approval processes (Quote, Special_Instruction__c).
 *
 * Runs in system context so Approval.unlock/lock succeeds
 * regardless of the running user's permissions.
 */
public without sharing class SystemQuoteUpdater {

    public static void unlockUpdateRelock(Id recordId, String fieldName, Object fieldValue) {
        Approval.unlock(recordId);
        SObject rec = recordId.getSObjectType().newSObject(recordId);
        rec.put(fieldName, fieldValue);
        update rec;
        Approval.lock(recordId);
    }

    public static void unlockUpdateRelock(SObject rec) {
        Approval.unlock(rec.Id);
        update rec;
        Approval.lock(rec.Id);
    }
}