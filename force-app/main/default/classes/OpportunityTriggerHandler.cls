/**
 * OpportunityTriggerHandler
 * Thin handler — most validation is owned by flows.
 * Business logic is delegated to service/selector classes; no SOQL here.
 *
 * Work item: 3.C1
 */
public with sharing class OpportunityTriggerHandler extends TriggerHandler {

    // ─── beforeInsert ────────────────────────────────────────────────────────────

    protected override void beforeInsert() {
        OppNumberGenerator.assignNumbers((List<Opportunity>) Trigger.new);
    }

    // ─── afterInsert ─────────────────────────────────────────────────────────────

    protected override void afterInsert() {
        // SE Phase 2: grant the tagged Sales Engineer READ on newly-created opps
        // (per-opp tag access across countries; complements the country sharing rules).
        Set<Id> tagged = new Set<Id>();
        for (Opportunity o : (List<Opportunity>) Trigger.new) {
            if (o.Sales_Engineer__c != null) tagged.add(o.Id);
        }
        if (!tagged.isEmpty()) OpportunitySEShareService.grant(tagged);
    }

    // ─── afterUpdate ─────────────────────────────────────────────────────────────

    protected override void afterUpdate() {
        // SE Phase 2: maintain the tagged-SE managed share on reassignment / owner change.
        Map<Id, Opportunity> seOldMap = (Map<Id, Opportunity>) Trigger.oldMap;
        Map<Id, Id> oppToOldSe = new Map<Id, Id>();
        Set<Id> toGrant = new Set<Id>();
        for (Opportunity o : (List<Opportunity>) Trigger.new) {
            Opportunity prior = seOldMap.get(o.Id);
            Boolean seChanged = o.Sales_Engineer__c != prior.Sales_Engineer__c;
            if (seChanged && prior.Sales_Engineer__c != null) {
                oppToOldSe.put(o.Id, prior.Sales_Engineer__c);
            }
            if (o.Sales_Engineer__c != null && (seChanged || o.OwnerId != prior.OwnerId)) {
                toGrant.add(o.Id);
            }
        }
        if (!oppToOldSe.isEmpty()) OpportunitySEShareService.revoke(oppToOldSe);
        if (!toGrant.isEmpty())    OpportunitySEShareService.grant(toGrant);

        /*
         * STUB — Ramp child Opportunity creation
         *
         * This context is the entry point for automatically creating child
         * (ramp) Opportunities when a parent Opportunity meets certain criteria.
         *
         * Work required before implementing:
         *   1. Confirm the trigger condition(s):
         *      - Which field change(s) signal that ramp children should be created?
         *        (e.g. StageName moving to a specific value, a new checkbox/picklist
         *        field such as Ramp_Required__c flipping to true, or Contract_Term_Months__c
         *        being populated above a threshold)
         *      - Should children be created only once, or can additional ramp periods
         *        be added on subsequent updates?
         *   2. Define the child Opportunity shape:
         *      - Which fields are copied from the parent vs. derived?
         *      - How are ramp periods calculated (equal splits, custom schedule)?
         *      - What is the Parent_Opportunity__c lookup expected to reference?
         *   3. Decide the service class: a new RampOppService.cls is the expected home
         *      so that this handler stays thin. The service will call OpportunitySelector
         *      for any needed parent/child reads.
         *   4. Confirm duplicate-guard: prevent re-creating children if they already exist.
         *
         * Placeholder call (replace with real invocation once spec is finalised):
         *
         *   List<Opportunity> newList = (List<Opportunity>) Trigger.new;
         *   Map<Id, Opportunity> oldMap = (Map<Id, Opportunity>) Trigger.oldMap;
         *   RampOppService.createRampChildren(newList, oldMap);
         */
    }
}