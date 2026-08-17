/**
 * Opportunity tag-driven managed sharing (SE Phase 2, 2026-06-17).
 * Grants the user in Opportunity.Sales_Engineer__c READ on that Opportunity,
 * regardless of country — complements the Phase-1 country sharing rules so a
 * tagged SE can reach an opp OUTSIDE their own country (hyperscale "By Account",
 * cross-country coverage, reassignment).
 *
 * Opportunity OWD = Private. Standard object => RowCause must be 'Manual'.
 * SURGICAL: never blanket-deletes Manual shares ('Manual' is a superset that
 * includes user-created manual shares). Reassignment removes ONLY the prior SE.
 */
public without sharing class OpportunitySEShareService {

    /** Ensure the current Sales_Engineer__c user has a Read share on each opp (idempotent). */
    public static void grant(Set<Id> oppIds) {
        if (oppIds == null || oppIds.isEmpty()) return;
        Map<Id,Opportunity> opps = new Map<Id,Opportunity>([
            SELECT Id, OwnerId, Sales_Engineer__c
            FROM Opportunity
            WHERE Id IN :oppIds AND Sales_Engineer__c != null
        ]);
        if (opps.isEmpty()) return;

        Set<String> existing = new Set<String>();
        for (OpportunityShare s : [
            SELECT OpportunityId, UserOrGroupId FROM OpportunityShare
            WHERE OpportunityId IN :opps.keySet() AND RowCause = 'Manual'
        ]) {
            existing.add(s.OpportunityId + '|' + s.UserOrGroupId);
        }

        List<OpportunityShare> toIns = new List<OpportunityShare>();
        for (Opportunity o : opps.values()) {
            Id se = o.Sales_Engineer__c;
            if (se == o.OwnerId) continue;                    // owner already has full access
            if (existing.contains(o.Id + '|' + se)) continue; // already shared
            toIns.add(new OpportunityShare(
                OpportunityId = o.Id, UserOrGroupId = se,
                OpportunityAccessLevel = 'Read', RowCause = 'Manual'));
        }
        if (!toIns.isEmpty()) Database.insert(toIns, false); // tolerate dupes / row locks
    }

    /** Remove ONLY the prior SE's Read share per opp (surgical — leaves other manual shares). */
    public static void revoke(Map<Id,Id> oppToOldSe) {
        if (oppToOldSe == null || oppToOldSe.isEmpty()) return;
        List<OpportunityShare> toDel = new List<OpportunityShare>();
        for (OpportunityShare s : [
            SELECT Id, OpportunityId, UserOrGroupId FROM OpportunityShare
            WHERE OpportunityId IN :oppToOldSe.keySet() AND RowCause = 'Manual'
        ]) {
            if (oppToOldSe.get(s.OpportunityId) == s.UserOrGroupId) toDel.add(s);
        }
        if (!toDel.isEmpty()) Database.delete(toDel, false);
    }
}