/**
 * AccountTriggerHandler
 * Handles Account trigger context.
 *
 * SFDC-361: on a change to Portal_Code__c, Tax_ID__c, Credit_Limit_MRC__c, Credit_Limit_NRC__c,
 * or Payment_Terms__c, syncs the new value(s) to Odoo ("Boss") via OdooAccountUpdateQueueable —
 * see that class for the endpoint/payload contract.
 *
 * Bypass: set TriggerBypass__mdt record 'AccountTriggerHandler'.Is_Active__c = true
 * to disable the handler without a code deployment.
 */
public with sharing class AccountTriggerHandler {

    public static void handleAfterInsert(List<Account> newList) {
        TriggerBypass__mdt bypass = TriggerBypass__mdt.getInstance('AccountTriggerHandler');
        if (bypass != null && bypass.Is_Active__c) return;
    }

    public static void handleAfterUpdate(List<Account> newList, Map<Id, Account> oldMap) {
        TriggerBypass__mdt bypass = TriggerBypass__mdt.getInstance('AccountTriggerHandler');
        if (bypass != null && bypass.Is_Active__c) return;

        List<Id> odooSyncFieldChangedIds = new List<Id>();
        // Per-account set of which payload-relevant fields actually changed in this update —
        // threaded through to OdooAccountUpdateQueueable so it can send only what changed,
        // instead of every currently-populated field (per Darren's feedback on SFDC-147).
        // Note: whether to enqueue at all is still gated ONLY by the original five
        // Odoo-sync fields below — adding BillingStreet/City/Country/Phone here only narrows
        // what gets included in a payload that was already going to be sent, it does not
        // cause an extra sync to fire just because an address field changed alone.
        Map<Id, Set<String>> changedFieldsByAccountId = new Map<Id, Set<String>>();
        for (Account acc : newList) {
            Account old = oldMap.get(acc.Id);
            Boolean changed =
                (acc.Portal_Code__c != null && acc.Portal_Code__c != old.Portal_Code__c)
                || (acc.Tax_ID__c != null && acc.Tax_ID__c != old.Tax_ID__c)
                || (acc.Credit_Limit_MRC__c != null && acc.Credit_Limit_MRC__c != old.Credit_Limit_MRC__c)
                || (acc.Credit_Limit_NRC__c != null && acc.Credit_Limit_NRC__c != old.Credit_Limit_NRC__c)
                || (acc.Payment_Terms__c != null && acc.Payment_Terms__c != old.Payment_Terms__c);
            if (changed) {
                odooSyncFieldChangedIds.add(acc.Id);

                Set<String> changedFields = new Set<String>();
                if (acc.Portal_Code__c != old.Portal_Code__c) changedFields.add('Portal_Code__c');
                if (acc.Tax_ID__c != old.Tax_ID__c) changedFields.add('Tax_ID__c');
                if (acc.Credit_Limit_MRC__c != old.Credit_Limit_MRC__c) changedFields.add('Credit_Limit_MRC__c');
                if (acc.Credit_Limit_NRC__c != old.Credit_Limit_NRC__c) changedFields.add('Credit_Limit_NRC__c');
                if (acc.Payment_Terms__c != old.Payment_Terms__c) changedFields.add('Payment_Terms__c');
                if (acc.BillingStreet != old.BillingStreet) changedFields.add('BillingStreet');
                if (acc.BillingCity != old.BillingCity) changedFields.add('BillingCity');
                if (acc.BillingCountry != old.BillingCountry) changedFields.add('BillingCountry');
                if (acc.Phone != old.Phone) changedFields.add('Phone');
                changedFieldsByAccountId.put(acc.Id, changedFields);
            }
        }
        if (!odooSyncFieldChangedIds.isEmpty()) {
            System.enqueueJob(new OdooAccountUpdateQueueable(odooSyncFieldChangedIds, changedFieldsByAccountId));
        }
    }
}