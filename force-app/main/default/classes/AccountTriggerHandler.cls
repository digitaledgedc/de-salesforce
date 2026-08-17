/**
 * AccountTriggerHandler
 * Handles Account trigger context.
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
    }
}