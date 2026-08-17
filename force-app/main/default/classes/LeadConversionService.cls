/**
 * LeadConversionService
 *
 * Handles multi-country Lead conversion for Digital Edge.
 * When a Lead has multiple values in Target_Country__c, converts to:
 *   - 1 Account per Target_Country__c value (each gets the corresponding country)
 *   - 1 Contact (primary on first Account, AccountContactRelation on others)
 *   - 1 Opportunity per Account/Country
 *
 * Called from the Lead Conversion screen flow.
 * NOT called from the standard Lead conversion path — this replaces it.
 *
 * Architect decision: Screen Flow calls this service. The flow handles the UI
 * (confirmation screen, country selection review). This class handles all DML.
 */
public with sharing class LeadConversionService {

    public class LeadConversionException extends Exception {}

    /**
     * Invocable entry point for the Lead Conversion screen flow and data migration.
     * Bulk-safe: all SOQL and DML run once for the entire batch regardless of list size.
     */
    @InvocableMethod(label='Convert Lead (Multi-Country)' description='Converts a Lead into Account, Contact, and one Opportunity per Target Country. Called from Lead Conversion screen flow.')
    public static List<ConversionResult> convertLeads(List<ConversionRequest> requests) {

        // --- 1. Validate and collect Lead IDs ---
        Set<Id> leadIds = new Set<Id>();
        for (ConversionRequest req : requests) {
            if (req.leadId == null) {
                throw new LeadConversionException('leadId is required.');
            }
            leadIds.add(req.leadId);
        }

        // --- 2. Bulk load Leads (1 SOQL) ---
        Map<Id, Lead> leadMap = new Map<Id, Lead>(LeadSelector.getForConversionBulk(leadIds));
        for (ConversionRequest req : requests) {
            Lead lead = leadMap.get(req.leadId);
            if (lead == null) {throw new LeadConversionException('Lead not found: ' + req.leadId);
            }
            if (lead.IsConverted) {throw new LeadConversionException('Lead is already converted: ' + req.leadId);
            }
        }

        // --- 3. Parse countries per Lead ---
        Map<Id, List<String>> leadToCountries = new Map<Id, List<String>>();
        for (ConversionRequest req : requests) {
            Lead lead = leadMap.get(req.leadId);
            List<String> countries = parseMultiSelect(lead.Target_Country__c);
            if (countries.isEmpty()) { countries.add('Unknown'); }
            leadToCountries.put(req.leadId, countries);
        }

        // --- 4. Build Accounts — one per country per Lead ---
        // Primary account = first country. Additional accounts for remaining countries.
        // When an existing accountId is provided AND only one country exists, use that account.
        Map<Id, List<Account>> leadToAccounts = new Map<Id, List<Account>>();
        List<Account> accountsToInsert = new List<Account>();
        for (ConversionRequest req : requests) {
            Lead lead = leadMap.get(req.leadId);
            List<String> countries = leadToCountries.get(req.leadId);
            List<Account> accounts = new List<Account>();
            if (req.accountId != null && countries.size() == 1) {
                accounts.add(new Account(Id = req.accountId));
            } else {
                for (String country : countries) {
                    Account acct = buildAccountForCountry(lead, country);
                    accounts.add(acct);
                    accountsToInsert.add(acct);
                }
            }
            leadToAccounts.put(req.leadId, accounts);
        }

        // --- 5. Insert new Accounts (1 DML) ---
        if (!accountsToInsert.isEmpty()) {
            if (!Schema.sObjectType.Account.isCreateable()) { throw new LeadConversionException('Insufficient permissions to create Account.');
            }
            insert accountsToInsert;
        }

        // --- 6. Build and insert Contacts — one per Lead, linked to primary Account ---
        Map<Id, Contact> leadToContact = new Map<Id, Contact>();
        List<Contact> contactsToInsert = new List<Contact>();
        for (ConversionRequest req : requests) {
            Lead lead = leadMap.get(req.leadId);
            Account primaryAcct = leadToAccounts.get(req.leadId)[0];
            if (req.contactId != null) {  leadToContact.put(req.leadId, new Contact(Id = req.contactId));
            } else {
                Contact con = buildContact(lead, primaryAcct.Id);
                leadToContact.put(req.leadId, con);
                contactsToInsert.add(con);
            }
        }
        if (!contactsToInsert.isEmpty()) {
            if (!Schema.sObjectType.Contact.isCreateable()) {  throw new LeadConversionException('Insufficient permissions to create Contact.');
            }
            Database.DMLOptions dmlOpts = new Database.DMLOptions();
            dmlOpts.DuplicateRuleHeader.AllowSave = true;
            List<Database.SaveResult> saveResults = Database.insert(contactsToInsert, dmlOpts);
            for (Database.SaveResult sr : saveResults) {
                if (!sr.isSuccess()) {  String errMsg = sr.getErrors()[0].getMessage();  throw new LeadConversionException('Contact insert failed: ' + errMsg);
                }
            }
        }

        // --- 6b. Create AccountContactRelation for non-primary accounts ---
        List<AccountContactRelation> acrsToInsert = new List<AccountContactRelation>();
        for (ConversionRequest req : requests) {
            List<Account> accounts = leadToAccounts.get(req.leadId);
            Contact con = leadToContact.get(req.leadId);
            for (Integer j = 1; j < accounts.size(); j++) {
                AccountContactRelation acr = new AccountContactRelation();
                acr.AccountId = accounts[j].Id;
                acr.ContactId = con.Id;
                acr.Roles = 'Business User';
                acrsToInsert.add(acr);
            }
        }
        if (!acrsToInsert.isEmpty()) {
            insert acrsToInsert;
        }

        // --- 7. Build and insert Opportunities — one per Account/Country ---
        Map<Id, List<Opportunity>> leadToOpps = new Map<Id, List<Opportunity>>();
        List<Opportunity> allOpps = new List<Opportunity>();
        for (ConversionRequest req : requests) {
            Lead lead = leadMap.get(req.leadId);
            List<Account> accounts = leadToAccounts.get(req.leadId);
            List<String> countries = leadToCountries.get(req.leadId);
            List<Opportunity> opps = new List<Opportunity>();
            for (Integer j = 0; j < countries.size(); j++) {
                Account acct = accounts[j];
                Opportunity opp = buildOpportunity(lead, acct.Id, countries[j]);
                opps.add(opp);
                allOpps.add(opp);
            }
            leadToOpps.put(req.leadId, opps);
        }
        if (!allOpps.isEmpty()) {
            if (!Schema.sObjectType.Opportunity.isCreateable()) {  throw new LeadConversionException('Insufficient permissions to create Opportunity.');
            }
            insert allOpps;
        }

        // --- 8. Get converted status (1 SOQL) ---
        String convertedStatus = LeadSelector.getConvertedStatus();

        // --- 9. Build LeadConvert list — uses primary Account/Contact/Opp ---
        List<Database.LeadConvert> lcList = new List<Database.LeadConvert>();
        for (ConversionRequest req : requests) {
            Lead lead = leadMap.get(req.leadId);
            List<Opportunity> opps = leadToOpps.get(req.leadId);
            Account primaryAcct = leadToAccounts.get(req.leadId)[0];
            Database.LeadConvert lc = new Database.LeadConvert();
            lc.setLeadId(lead.Id);
            lc.setAccountId(primaryAcct.Id);
            lc.setContactId(leadToContact.get(req.leadId).Id);
            lc.setOpportunityId(opps[0].Id);
            lc.setConvertedStatus(convertedStatus);
            lc.setDoNotCreateOpportunity(false);
            lc.setOwnerId(UserInfo.getUserId());
            lcList.add(lc);
        }

        // --- 10. Convert all Leads in one call ---
        List<Database.LeadConvertResult> lcrList = Database.convertLead(lcList);

        // --- 11. Map results back in request order ---
        List<ConversionResult> results = new List<ConversionResult>();
        for (Integer i = 0; i < requests.size(); i++) {
            Id leadId = requests[i].leadId;
            Database.LeadConvertResult lcr = lcrList[i];
            if (!lcr.isSuccess()) {throw new LeadConversionException('Lead conversion failed for ' + leadId + ': ' + lcr.getErrors()[0].getMessage()
                );
            }
            ConversionResult result = new ConversionResult();
            result.success = true;
            result.accountId = leadToAccounts.get(leadId)[0].Id;
            result.contactId = leadToContact.get(leadId).Id;
            result.opportunityIds = new List<Id>();
            for (Opportunity opp : leadToOpps.get(leadId)) {
                result.opportunityIds.add(opp.Id);
            }
            result.accountIds = new List<Id>();
            for (Account acct : leadToAccounts.get(leadId)) {
                result.accountIds.add(acct.Id);
            }
            results.add(result);
        }
        return results;
    }

    /**
     * Single-lead convenience wrapper. Delegates to convertLeads() — bulk-safe.
     */
    public static ConversionResult convertSingleLead(ConversionRequest req) {return convertLeads(new List<ConversionRequest>{ req })[0];
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Private helpers
    // ─────────────────────────────────────────────────────────────────────────

    private static Account buildAccountForCountry(Lead lead, String country) {
        Account acct = new Account();
        acct.Name = lead.Company;
        acct.BillingCountry = lead.Country;
        acct.Phone = lead.Phone;
        acct.Website = lead.Website;
        acct.Operation_Country__c = toOperationCountry(country);
        acct.Finance_Approval_Phase__c = 'Not_Started';
        return acct;
    }

    private static Contact buildContact(Lead lead, Id accountId) {
        Contact con = new Contact();
        con.AccountId = accountId;
        con.FirstName = lead.FirstName;
        con.LastName = lead.LastName;
        con.Email = lead.Email;
        con.Phone = lead.Phone;
        con.Title = lead.Title;
        return con;
    }

    private static Opportunity buildOpportunity(Lead lead, Id accountId, String country) {
        Opportunity opp = new Opportunity();
        opp.AccountId = accountId;
        opp.Name = lead.Company + ' – ' + country;
        opp.StageName = '1 - Suspect';
        opp.CloseDate = Date.today().addDays(90);
        opp.Originating_Lead__c = lead.Id;
        opp.LeadSource = lead.LeadSource;
        if (lead.Capacity_kW__c != null) {
            opp.Capacity_kW__c = lead.Capacity_kW__c;
        }
        if (lead.Capacity_Cabinets__c != null) {
            opp.Capacity_Cabinets__c = lead.Capacity_Cabinets__c;
        }
        if (lead.Customer_Type__c != null) {
            opp.Customer_Type__c = lead.Customer_Type__c;
        }
        if (lead.GoLive_Target_Date__c != null) { opp.GoLive_Target_Date__c = lead.GoLive_Target_Date__c;
        }
        if (lead.Product_Interest__c != null) { opp.Product_Interest__c = lead.Product_Interest__c;
        }
        return opp;
    }

    private static List<String> parseMultiSelect(String mspValue) {
        List<String> values = new List<String>();
        if (String.isBlank(mspValue)) { return values;
        }
        for (String v : mspValue.split(';')) {
            String trimmed = v.trim();
            if (!String.isBlank(trimmed)) {
                values.add(trimmed);
            }
        }
        return values;
    }

    // Operation_Country__c picklist uses full country names matching Odoo
    private static final Set<String> VALID_OPERATION_COUNTRIES = new Set<String>{
        'Korea', 'Japan', 'China', 'Indonesia', 'Philippines',
        'Global', 'India', 'Thailand', 'Bangladesh', 'Malaysia'
    };

    private static String toOperationCountry(String countryName) {
        if (VALID_OPERATION_COUNTRIES.contains(countryName)) {
            return countryName;
        }  return null;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Inner classes
    // ─────────────────────────────────────────────────────────────────────────

    public class ConversionRequest {
        @InvocableVariable(label='Lead Id' required=true)
        public Id leadId;

        @InvocableVariable(label='Existing Account Id (optional — skip account creation)')
        public Id accountId;

        @InvocableVariable(label='Existing Contact Id (optional — skip contact creation)')
        public Id contactId;
    }

    public class ConversionResult {
        @InvocableVariable(label='Success')
        public Boolean success;

        @InvocableVariable(label='Account Id')
        public Id accountId;

        @InvocableVariable(label='Contact Id')
        public Id contactId;

        @InvocableVariable(label='Opportunity Ids')
        public List<Id> opportunityIds;

        @InvocableVariable(label='Account Ids')
        public List<Id> accountIds;
    }
}