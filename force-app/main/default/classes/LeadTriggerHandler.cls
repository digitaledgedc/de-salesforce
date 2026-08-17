/**
 * LeadTriggerHandler
 * Thin handler — delegates to service classes. No business logic here.
 */
public with sharing class LeadTriggerHandler extends TriggerHandler {

    protected override void beforeInsert() {
        // Dedup flag is set by the Lead_Duplicate_Check before-save flow.
        // No Apex pre-conversion hooks needed for Phase 2.
        // Phase 3+ may add additional beforeInsert logic here.
    }

    protected override void afterInsert() {
        // Interconnect notification for newly created Leads with Interconnect_Required__c = TRUE
        // is handled by a flow. No Apex after-insert logic needed for Phase 2.
    }
}