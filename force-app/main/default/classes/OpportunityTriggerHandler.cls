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
         * FB-1041: Ramp child Opportunity creation is implemented, but NOT
         * from this handler. The trigger condition originally scoped here
         * (some Opportunity field change) turned out to be the wrong signal —
         * a ramp child Opportunity corresponds 1:1 with a split ramp-phase
         * Order, not with any Opportunity edit. It is created from
         * RampOrderService.splitRampOrder via RampOppService.createRampChildren,
         * right after each phase's Order/MRC exist and before that Order is
         * activated. See RampOppService.cls for the shape/field mapping and
         * OpportunitySelector.getForRampClone/getChildrenByParentIds for the
         * supporting reads.
         */
    }
}