/**
 * OpportunitySelector
 * All SOQL for Opportunity objects. FLS enforced via WITH SECURITY_ENFORCED.
 * No DML here — read-only. Called from handlers and service classes.
 */
public with sharing class OpportunitySelector {

    /**
     * Returns Opportunities by a set of Ids, selecting the fields most commonly
     * needed by handler and service logic.
     *
     * @param oppIds  Set of Opportunity Ids to query.
     * @return        List of Opportunity records; empty list if oppIds is null/empty.
     */
    public static List<Opportunity> getByIds(Set<Id> oppIds) {
        if (oppIds == null || oppIds.isEmpty()) {
            return new List<Opportunity>();
        }
        return [
            SELECT Id,
                   Name,
                   AccountId,
                   OwnerId,
                   StageName,
                   CloseDate,
                   Amount,
                   Opportunity_Number__c,
                   Originating_Lead__c,
                   Parent_Opportunity__c,
                   Order_Type__c,
                   Customer_Type__c,
                   Contract_Term_Months__c,
                   Capacity_kW__c,
                   Capacity_Cabinets__c,
                   GoLive_Target_Date__c
            FROM Opportunity
            WHERE Id IN :oppIds
            WITH SECURITY_ENFORCED
        ];
    }

    /**
     * Returns child (ramp) Opportunities that reference the given parent Ids.
     * Used by RampOppService to check whether children already exist before
     * creating new ones (duplicate-guard).
     *
     * @param parentOppIds  Set of parent Opportunity Ids.
     * @return              List of child Opportunity records.
     */
    public static List<Opportunity> getChildrenByParentIds(Set<Id> parentOppIds) {
        if (parentOppIds == null || parentOppIds.isEmpty()) {
            return new List<Opportunity>();
        }
        return [
            SELECT Id,
                   Name,
                   Parent_Opportunity__c,
                   StageName,
                   CloseDate,
                   Opportunity_Number__c
            FROM Opportunity
            WHERE Parent_Opportunity__c IN :parentOppIds
            WITH SECURITY_ENFORCED
        ];
    }
}