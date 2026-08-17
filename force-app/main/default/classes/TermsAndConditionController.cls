public with sharing class TermsAndConditionController {

    @AuraEnabled(cacheable=true)
    public static Boolean isSystemAdmin() {
        return [SELECT Profile.Name FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1]
            .Profile.Name == 'System Administrator';
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> searchAccounts(String searchTerm) {
        if (String.isBlank(searchTerm)) return new List<Map<String, String>>();
        String likeTerm = '%' + searchTerm + '%';
        List<Map<String, String>> results = new List<Map<String, String>>();
        for (Account a : [
            SELECT Id, Name FROM Account
            WHERE Name LIKE :likeTerm
            ORDER BY Name ASC
            LIMIT 10
        ]) {
            Map<String, String> item = new Map<String, String>();
            item.put('id', a.Id);
            item.put('name', a.Name);
            results.add(item);
        }
        return results;
    }

    @AuraEnabled
    public static Id createTandCRecord(
        String tandcName,
        String termsText,
        String customerNames,
        String companyNames,
        String subscriptionManagement
    ) {
        if (String.isBlank(tandcName)) {
            throw new AuraHandledException('Name is required.');
        }
        Id rtId = Schema.SObjectType.Special_Instruction__c
            .getRecordTypeInfosByDeveloperName()
            .get('Terms_and_Conditions')
            .getRecordTypeId();

        Special_Instruction__c si = new Special_Instruction__c();
        si.RecordTypeId = rtId;
        si.put('Type__c',                    'T&C');
        si.put('Status__c',                  'New');
        si.put('TandC_Name__c',              tandcName);
        si.put('Terms_Text__c',              termsText);
        si.put('Customer_Names__c',          customerNames);
        si.put('Company_Names__c',           companyNames);
        si.put('Subscription_Management__c', subscriptionManagement);
        insert si;

        try {
            Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
            req.setObjectId(si.Id);
            req.setSubmitterId(UserInfo.getUserId());
            Approval.process(req);
        } catch (Exception e) {
            throw new AuraHandledException('Record created but approval submission failed: ' + e.getMessage());
        }

        return si.Id;
    }

    @AuraEnabled
    public static void createTermsAndCondition(
        String tcName,
        String termsText,
        String customer,
        String company,
        String subscriptionManagement
    ) {
        if (String.isBlank(tcName)) {
            throw new AuraHandledException('Name is required.');
        }

        // Build a valid unique developer name
        String devName = tcName.replaceAll('[^a-zA-Z0-9]', '_').replaceAll('_+', '_');
        if (devName.endsWith('_')) devName = devName.removeEnd('_');
        if (devName.startsWith('_')) devName = devName.removeStart('_');
        String suffix  = String.valueOf(System.currentTimeMillis()).right(6);
        devName        = devName.left(34) + '_' + suffix;

        Metadata.CustomMetadata cmt = new Metadata.CustomMetadata();
        cmt.fullName = 'Quote_TandC__mdt.' + devName;
        cmt.label    = tcName;

        Map<String, Object> fieldValues = new Map<String, Object>{
            'Name__c'                    => tcName,
            'Terms_Text__c'              => termsText,
            'Customer__c'                => customer,
            'Company__c'                 => company,
            'Subscription_Management__c' => subscriptionManagement,
            'Stage__c'                   => 'New'
        };

        for (String field : fieldValues.keySet()) {
            Metadata.CustomMetadataValue val = new Metadata.CustomMetadataValue();
            val.field = field;
            val.value = fieldValues.get(field);
            cmt.values.add(val);
        }

        Metadata.DeployContainer container = new Metadata.DeployContainer();
        container.addMetadata(cmt);
        Metadata.Operations.enqueueDeployment(container, null);
    }
}