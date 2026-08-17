/**
 * BillingAccountTriggerHandler
 * Handles BillingAccount__c trigger context.
 *
 * before insert — auto-generates country-prefixed BAN numbers via BillingAccountService.
 *
 * Bypass: set TriggerBypass__mdt record 'BillingAccountTriggerHandler'.Is_Active__c = true
 * to disable the handler without a code deployment.
 */
public with sharing class BillingAccountTriggerHandler {

    // ─── Before Insert ────────────────────────────────────────────────────────

    public static void handleBeforeInsert(List<BillingAccount__c> newList) {
        TriggerBypass__mdt bypass = TriggerBypass__mdt.getInstance('BillingAccountTriggerHandler');
        if (bypass != null && bypass.Is_Active__c) return;

        BillingAccountService.generateBanNumbers(newList);
    }
}