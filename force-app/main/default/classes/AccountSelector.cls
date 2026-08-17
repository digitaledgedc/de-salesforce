/**
 * AccountSelector
 * All SOQL for Account objects. FLS enforced via WITH SECURITY_ENFORCED.
 */
public with sharing class AccountSelector {

    public static List<Account> getByName(String name) {
        return getByNames(new Set<String>{ name }).values();
    }

    public static Map<String, Account> getByNames(Set<String> names) {
        Map<String, Account> result = new Map<String, Account>();
        for (Account a : [
            SELECT Id, Name, BillingCountry, Phone, Website,
                   Finance_Approval_Phase__c, Entity_Locked__c
            FROM Account
            WHERE Name IN :names
            WITH SECURITY_ENFORCED
        ]) {
            result.put(a.Name, a);
        }
        return result;
    }

    public static List<Account> getByIds(Set<Id> accountIds) {
        return [
            SELECT Id, Name, BillingCountry, Phone, Website,
                   Finance_Approval_Phase__c, Entity_Locked__c,
                   KYC_Last_Review_Date__c
            FROM Account
            WHERE Id IN :accountIds
            WITH SECURITY_ENFORCED
        ];
    }
}