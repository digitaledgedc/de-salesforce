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

    /**
     * Returns the parent-Opportunity fields RampOppService needs to build a
     * ramp child Opportunity. Ramp children are inserted directly at 5-Won,
     * so this selects every field the active stage-gate validation rules
     * check on insert (VR_OPP_21_Site_Required_At_Quote needs Target_Site__c,
     * VR_OPP_20_CurrencyMatchesSubsidiary needs Operation_Country__c /
     * CurrencyIsoCode, DE_Opp_Referral_Partner_Req needs Sales_Motion__c /
     * Referral_Partner__c) plus the identifying fields the child copies as-is.
     * StageName is included so the caller can tell whether the deal
     * Opportunity itself is already 5-Won before updating it again. CloseDate
     * is read explicitly by RampOppService (every phase shares the deal's own
     * close date); Account_Type__c isn't read explicitly but must be selected
     * so clone() carries it onto each phase — omitting it left every phase
     * child's Opportunity Account Type blank (2026-09-22 fix).
     *
     * @param oppIds  Set of parent Opportunity Ids.
     * @return        List of Opportunity records; empty list if oppIds is null/empty.
     */
    public static List<Opportunity> getForRampClone(Set<Id> oppIds) {
        if (oppIds == null || oppIds.isEmpty()) {
            return new List<Opportunity>();
        }
        return [
            SELECT Id,
                   Name,
                   Opportunity_Number__c,
                   StageName,
                   CloseDate,
                   AccountId,
                   OwnerId,
                   CurrencyIsoCode,
                   Operation_Country__c,
                   Target_Site__c,
                   Target_Floor__c,
                   Target_Data_Hall__c,
                   Contract_Term_Months__c,
                   Sales_Motion__c,
                   Referral_Partner__c,
                   Customer_Type__c,
                   Account_Type__c,
                   GoLive_Target_Date__c,
                   Deal_Type__c,
                   Order_Type__c
            FROM Opportunity
            WHERE Id IN :oppIds
            WITH SECURITY_ENFORCED
        ];
    }
}