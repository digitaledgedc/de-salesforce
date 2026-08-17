/**
 * LeadConversionHelper
 * @InvocableMethod used by F-04 Multi-Country Lead Conversion Screen Flow.
 * Calls the Salesforce Lead conversion API.
 * Not an Odoo integration class — must be deployed before F-04 is activated.
 *
 * without sharing: system operation invoked from a SystemModeWithSharing flow.
 * Access is gated by the ConvertLeads user permission (checked by Database.convertLead)
 * and the Convert button visibility rule on the Lead record page (Status = Sales Approved).
 * with sharing would block AE users who have read-only sharing access to the Lead.
 *
 * All Id parameters are declared as String to prevent System.StringException
 * when Salesforce Flow passes an empty string instead of null for optional fields.
 * isNotBlank() guards ensure empty strings are treated as absent.
 */
public without sharing class LeadConversionHelper {

    public class ConvertLeadInput {
        @InvocableVariable(required=true)  public String  leadId;
        @InvocableVariable(required=true)  public String  accountId;
        @InvocableVariable(required=false) public String  contactId;
        @InvocableVariable(required=false) public String  opportunityId;
        @InvocableVariable(required=false) public Boolean doNotCreateOpportunity;
    }

    @InvocableMethod(
        label='Convert Lead'
        description='Called by F-04 Multi-Country Lead Conversion Screen Flow.'
    )
    public static void convertLead(List<ConvertLeadInput> inputs) {
        // Reassign queue-owned leads to the running user — Database.convertLead requires a User owner
        Set<Id> leadIds = new Set<Id>();
        for (ConvertLeadInput inp : inputs) {
            if (String.isNotBlank(inp.leadId)) {
                leadIds.add((Id) inp.leadId);
            }
        }
        List<Lead> leadsToReassign = new List<Lead>();
        for (Lead l : [SELECT Id, OwnerId FROM Lead WHERE Id IN :leadIds]) {
            if (String.valueOf(l.OwnerId).startsWith('00G')) { leadsToReassign.add(new Lead(Id = l.Id, OwnerId = UserInfo.getUserId()));
            }
        }
        if (!leadsToReassign.isEmpty()) {  update leadsToReassign;
        }

        List<Database.LeadConvert> conversions = new List<Database.LeadConvert>();

        for (ConvertLeadInput inp : inputs) {
            Database.LeadConvert lc = new Database.LeadConvert();
            lc.setLeadId((Id) inp.leadId);
            lc.setAccountId((Id) inp.accountId);
            if (String.isNotBlank(inp.contactId)) {  lc.setContactId((Id) inp.contactId);
            }
            lc.setConvertedStatus('Converted');
            lc.setOwnerId(UserInfo.getUserId());

            if (inp.doNotCreateOpportunity == true) {
                lc.setDoNotCreateOpportunity(true);
            } else if (String.isNotBlank(inp.opportunityId)) { lc.setOpportunityId((Id) inp.opportunityId);   lc.setDoNotCreateOpportunity(false);
            }

            conversions.add(lc);
        }

        List<Database.LeadConvertResult> results =
            Database.convertLead(conversions, true);

        for (Database.LeadConvertResult r : results) {
            if (!r.isSuccess()) {  throw new LeadConversionException(r.getErrors()[0].getMessage());
            }
        }
    }

    public class LeadConversionException extends Exception {}
}