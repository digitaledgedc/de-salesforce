/**
 * OpportunityTrigger — general Opportunity trigger (GoKarya TriggerHandler framework).
 * Delegates to OpportunityTriggerHandler; no logic here. Add contexts as the handler
 * grows.
 *
 * before insert: OppNumberGenerator.assignNumbers() sets Opportunity_Number__c
 * without looping over existing records (floor-from-label or DESC/LIMIT-1 max lookup —
 * see OppNumberGenerator.cls). This replaces the DE_Opportunity_Number_Generator flow's
 * loop-based counter, which is deactivated to avoid double-assignment and its CPU cost
 * under heavy transactions (e.g. Lead Conversion).
 */
trigger OpportunityTrigger on Opportunity (before insert, after insert, after update) {
    new OpportunityTriggerHandler().run();
}