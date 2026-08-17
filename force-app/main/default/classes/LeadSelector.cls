/**
 * LeadSelector
 * All SOQL for Lead objects. FLS enforced via WITH SECURITY_ENFORCED.
 */
public with sharing class LeadSelector {

    public static Lead getForConversion(Id leadId) {
        List<Lead> leads = getForConversionBulk(new Set<Id>{ leadId });
        return leads.isEmpty() ? null : leads[0];
    }

    public static List<Lead> getForConversionBulk(Set<Id> leadIds) {
        return [
            SELECT Id, IsConverted, FirstName, LastName, Email, Phone, Title,
                   Company, Country, Website, LeadSource,
                   Target_Country__c, Capacity_kW__c, Capacity_Cabinets__c,
                   Customer_Type__c, Duplicate_Flag__c, GoLive_Target_Date__c,
                   Product_Interest__c
            FROM Lead
            WHERE Id IN :leadIds
            WITH SECURITY_ENFORCED
        ];
    }

    public static String getConvertedStatus() {
        List<LeadStatus> statuses = [
            SELECT MasterLabel
            FROM LeadStatus
            WHERE IsConverted = true
            LIMIT 1
        ];
        if (statuses.isEmpty()) {
            throw new LeadConversionService.LeadConversionException(
                'No converted LeadStatus found. Configure a converted Lead Status in org Setup.'
            );
        }
        return statuses[0].MasterLabel;
    }
}