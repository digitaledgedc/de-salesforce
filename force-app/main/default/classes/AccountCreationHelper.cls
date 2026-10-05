/**
 * AccountCreationHelper
 * Invocable action used by Lead_Convert_MultiCountryConversion flow to create Accounts
 * while bypassing duplicate rules (DMLOptions.DuplicateRuleHeader.allowSave = true).
 *
 * Flow's recordCreates element cannot set DMLOptions, so account creation is delegated here.
 */
public with sharing class AccountCreationHelper {

    public class AccountInput {
        @InvocableVariable(required=true label='Account Name')
        public String name;

        @InvocableVariable(label='Type')
        public String type;

        @InvocableVariable(label='Status')
        public String status;

        @InvocableVariable(label='KYC Status')
        public String kycStatus;

        @InvocableVariable(label='Finance Approval Status')
        public String financeApprovalStatus;

        @InvocableVariable(label='Operation Country')
        public String operationCountry;

        @InvocableVariable(label='Owner Id')
        public Id ownerId;

        @InvocableVariable(label='Parent Account Id')
        public String parentId;

        @InvocableVariable(label='Registered Address')
        public String registeredAddress;
    }

    public class AccountOutput {
        @InvocableVariable(label='Account Id')
        public Id accountId;

        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    @InvocableMethod(label='Create Account Bypass Duplicates' description='Creates an Account with duplicate rule bypass. Returns existing account Id if name already exists.')
    public static List<AccountOutput> createAccount(List<AccountInput> inputs) {
        List<AccountOutput> outputs = new List<AccountOutput>();

        // Build all Account records up front
        List<Account> accountsToInsert = new List<Account>();
        for (AccountInput inp : inputs) {
            Account acc = new Account();
            acc.Name = inp.name;
            if (inp.type != null)                   acc.Type = inp.type;
            if (inp.type != null)                   acc.Account_Tier__c = inp.type;
            if (inp.status != null)                 acc.Status__c = inp.status;
            if (inp.kycStatus != null)              acc.KYC_Status__c = inp.kycStatus;
            if (inp.operationCountry != null)       acc.Operation_Country__c = inp.operationCountry;
            if (inp.registeredAddress != null)      acc.Registered_Address__c = inp.registeredAddress;
            if (inp.ownerId != null)                acc.OwnerId = inp.ownerId;
            if (String.isNotBlank(inp.parentId))    acc.ParentId = Id.valueOf(inp.parentId);
            accountsToInsert.add(acc);
        }

        // Single DML with duplicate bypass
        Database.DMLOptions opts = new Database.DMLOptions();
        opts.DuplicateRuleHeader.allowSave = true;
        opts.DuplicateRuleHeader.runAsCurrentUser = true;
        List<Database.SaveResult> saveResults = Database.insert(accountsToInsert, opts);

        // Collect names of any failed inserts for a single fallback query
        Set<String> failedNames = new Set<String>();
        for (Integer i = 0; i < saveResults.size(); i++) {
            if (!saveResults[i].isSuccess()) {
                failedNames.add(inputs[i].name);
            }
        }

        // Single fallback SOQL for failed inserts
        Map<String, Id> existingByName = new Map<String, Id>();
        if (!failedNames.isEmpty()) {
            for (Account a : [SELECT Id, Name FROM Account WHERE Name IN :failedNames]) {
                existingByName.put(a.Name, a.Id);
            }
        }

        // Build outputs
        for (Integer i = 0; i < inputs.size(); i++) {
            AccountOutput out = new AccountOutput();
            Database.SaveResult sr = saveResults[i];

            if (sr.isSuccess()) {
                out.accountId = sr.getId();
            } else if (existingByName.containsKey(inputs[i].name)) {
                out.accountId = existingByName.get(inputs[i].name);
            } else {
                out.errorMessage = sr.getErrors()[0].getMessage();
            }
            outputs.add(out);
        }

        return outputs;
    }
}