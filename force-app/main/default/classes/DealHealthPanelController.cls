public with sharing class DealHealthPanelController {

    // ── Internal tab visibility (profile-gated) ─────────────────────

    private static final Set<String> INTERNAL_TAB_PROFILES = new Set<String>{
        'System Administrator', 'DE Regional Manager'
    };

    @AuraEnabled(cacheable=true)
    public static Boolean canViewInternalTab() {
        String profileName = [SELECT Profile.Name FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1].Profile.Name;
        return INTERNAL_TAB_PROFILES.contains(profileName);
    }

    // ── External view ───────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getDealHealth(Id opportunityId) {
        // Security.stripInaccessible silently drops inaccessible fields instead of throwing —
        // WITH SECURITY_ENFORCED would throw if any field lacks FLS for the running user.
        List<Opportunity> opps = (List<Opportunity>) Security.stripInaccessible(
            AccessType.READABLE,
            [SELECT Id, Name, StageName, AccountId, MEDDPICC_Score__c,
                    MEDDPICC_Metrics_Status__c, MEDDPICC_Metrics__c, Metric_Category__c,
                    MEDDPICC_Economic_Buyer__c, MEDDPICC_Economic_Buyer_Status__c,
                    MEDDPICC_Decision_Criteria__c, Decision_Criteria_Options__c, MEDDPICC_Decision_Criteria_Status__c,
                    MEDDPICC_Decision_Process__c, Decision_Process_Stages__c, MEDDPICC_Decision_Process_Status__c,
                    MEDDPICC_Paper_Process__c, Paper_Process_Steps__c, MEDDPICC_Paper_Process_Status__c,
                    MEDDPICC_Pain__c, MEDDPICC_Pain_Status__c,
                    MEDDPICC_Champion__c, MEDDPICC_Champion_Status__c,
                    MEDDPICC_Competition__c, MEDDPICC_Competition_Status__c,
                    Competitor_Account__c, Competitor_Account__r.Name,
                    OwnerId, Owner.Name,
                    CurrencyIsoCode,
                    MRC__c, NRC__c, Booking_Amount__c,
                    Booking_Bucket__c, Quota_Relief_Pct__c, Commission_Pct__c,
                    Commission_Payout_Method__c,
                    SP1_Split_Pct__c, SP1_QR_Pct__c,
                    SP2_Split_Pct__c, SP2_QR_Pct__c,
                    Salesperson_2__c, Salesperson_2__r.Name,
                    SP3_Split_Pct__c, SP3_QR_Pct__c,
                    Salesperson_3__c, Salesperson_3__r.Name
             FROM Opportunity WHERE Id = :opportunityId LIMIT 1]
        ).getRecords();

        List<OpportunityContactRole> roles = (List<OpportunityContactRole>) Security.stripInaccessible(
            AccessType.READABLE,
            [SELECT Id, ContactId, Contact.Name, Contact.Title,
                    Role, IsPrimary, Engagement_Status__c
             FROM OpportunityContactRole
             WHERE OpportunityId = :opportunityId
             ORDER BY IsPrimary DESC, Role ASC]
        ).getRecords();

        Map<String, Object> result = new Map<String, Object>();
        result.put('opp',   opps.isEmpty() ? null : opps[0]);
        result.put('roles', roles);
        return result;
    }

    @AuraEnabled(cacheable=true)
    public static List<OpportunityContactRole> getExistingRoles(Id opportunityId) {
        return (List<OpportunityContactRole>) Security.stripInaccessible(
            AccessType.READABLE,
            [SELECT Id, Contact.Name, Role, Engagement_Status__c, IsPrimary
             FROM OpportunityContactRole
             WHERE OpportunityId = :opportunityId
             ORDER BY IsPrimary DESC, Role ASC]
        ).getRecords();
    }

    @AuraEnabled(cacheable=true)
    public static List<Contact> getAccountContacts(Id opportunityId) {
        List<Opportunity> opps = (List<Opportunity>) Security.stripInaccessible(
            AccessType.READABLE,
            [SELECT AccountId FROM Opportunity WHERE Id = :opportunityId LIMIT 1]
        ).getRecords();
        if (opps.isEmpty() || opps[0].AccountId == null) return new List<Contact>();
        return (List<Contact>) Security.stripInaccessible(
            AccessType.READABLE,
            [SELECT Id, Name, Title, Email FROM Contact
             WHERE AccountId = :opps[0].AccountId
             ORDER BY Name LIMIT 200]
        ).getRecords();
    }

    @AuraEnabled
    public static Id createContactForOpportunity(Id opportunityId,
                                                  String firstName, String lastName,
                                                  String title, String email) {
        if (!Schema.sObjectType.Contact.isCreateable()) {
            throw new AuraHandledException('Insufficient permissions to create a Contact.');
        }
        if (String.isBlank(lastName)) {
            throw new AuraHandledException('Last Name is required.');
        }
        List<Opportunity> opps = [SELECT AccountId FROM Opportunity WHERE Id = :opportunityId LIMIT 1];
        if (opps.isEmpty() || opps[0].AccountId == null) {
            throw new AuraHandledException('Opportunity has no associated Account — cannot create contact.');
        }
        try {
            Contact c = new Contact(
                AccountId = opps[0].AccountId,
                FirstName = String.isBlank(firstName) ? null : firstName,
                LastName  = lastName,
                Title     = String.isBlank(title)     ? null : title,
                Email     = String.isBlank(email)     ? null : email
            );
            insert c;
            return c.Id;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<Account> searchAccounts(String searchTerm, String recordTypeName) {
        String pattern = '%' + searchTerm + '%';
        if (String.isBlank(recordTypeName)) {
            return (List<Account>) Security.stripInaccessible(
                AccessType.READABLE,
                [SELECT Id, Name, Type FROM Account
                 WHERE Name LIKE :pattern
                 ORDER BY Name LIMIT 10]
            ).getRecords();
        }
        return (List<Account>) Security.stripInaccessible(
            AccessType.READABLE,
            [SELECT Id, Name, Type FROM Account
             WHERE Name LIKE :pattern
             AND RecordType.DeveloperName = :recordTypeName
             ORDER BY Name LIMIT 10]
        ).getRecords();
    }

    @AuraEnabled
    public static Id createAccount(String name, String recordTypeName) {
        if (!Schema.sObjectType.Account.isCreateable()) {
            throw new AuraHandledException('Insufficient permissions to create Account.');
        }
        Account acct = new Account(Name = name);
        if (String.isNotBlank(recordTypeName)) {
            Map<String, Schema.RecordTypeInfo> rtMap =
                Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName();
            Schema.RecordTypeInfo rti = rtMap.get(recordTypeName);
            if (rti != null && rti.isAvailable()) {
                acct.RecordTypeId = rti.getRecordTypeId();
            }
        }
        insert acct;
        return acct.Id;
    }

    @AuraEnabled
    public static void createContactRole(Id opportunityId, Id contactId,
                                          String role, String engagementStatus) {
        if (!Schema.sObjectType.OpportunityContactRole.isCreateable()) {
            throw new AuraHandledException('Insufficient permissions to add stakeholder.');
        }
        try {
            OpportunityContactRole ocr = new OpportunityContactRole(
                OpportunityId        = opportunityId,
                ContactId            = contactId,
                Role                 = role,
                Engagement_Status__c = engagementStatus
            );
            insert ocr;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static Id createContactAndRole(Id opportunityId, Id accountId,
                                           String firstName, String lastName,
                                           String title, String email,
                                           String role, String engagementStatus) {
        if (!Schema.sObjectType.Contact.isCreateable()) {
            throw new AuraHandledException('Insufficient permissions to create a Contact.');
        }
        if (!Schema.sObjectType.OpportunityContactRole.isCreateable()) {
            throw new AuraHandledException('Insufficient permissions to add stakeholder.');
        }
        if (String.isBlank(lastName)) {
            throw new AuraHandledException('Last Name is required.');
        }
        // Resolve AccountId from the Opportunity if not provided by the LWC
        // (stripInaccessible on getDealHealth may strip AccountId for users
        // whose profile lacks FLS on Opportunity.AccountId).
        if (accountId == null && opportunityId != null) {
            List<Opportunity> opps = [SELECT AccountId FROM Opportunity WHERE Id = :opportunityId LIMIT 1];
            if (!opps.isEmpty()) {
                accountId = opps[0].AccountId;
            }
        }
        if (accountId == null) {
            throw new AuraHandledException('Opportunity has no associated Account — cannot create contact.');
        }
        try {
            Contact c = new Contact(
                AccountId = accountId,
                FirstName = firstName,
                LastName  = lastName,
                Title     = title,
                Email     = email
            );
            insert c;
            OpportunityContactRole ocr = new OpportunityContactRole(
                OpportunityId        = opportunityId,
                ContactId            = c.Id,
                Role                 = role,
                Engagement_Status__c = engagementStatus
            );
            insert ocr;
            return c.Id;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static void updateEngagementStatus(Id roleId, String status) {
        if (!Schema.sObjectType.OpportunityContactRole.isUpdateable()) {
            throw new AuraHandledException('Insufficient permissions to update Contact Role.');
        }
        OpportunityContactRole ocr = new OpportunityContactRole(
            Id = roleId,
            Engagement_Status__c = status
        );
        update ocr;
    }

    @AuraEnabled
    public static void updateContactRole(Id roleId, String role) {
        if (!Schema.sObjectType.OpportunityContactRole.isUpdateable()) {
            throw new AuraHandledException('Insufficient permissions to update Contact Role.');
        }
        OpportunityContactRole ocr = new OpportunityContactRole(
            Id = roleId,
            Role = role
        );
        update ocr;
    }

    @AuraEnabled
    public static void deleteContactRole(Id roleId) {
        if (!Schema.sObjectType.OpportunityContactRole.isDeletable()) {
            throw new AuraHandledException('Insufficient permissions to remove stakeholder.');
        }
        delete new OpportunityContactRole(Id = roleId);
    }

    @AuraEnabled
    public static void updateContactRoleAndEngagement(Id roleId, String role, String engagementStatus,
                                                      Id opportunityId, String meddpiccStatusField, String meddpiccStatus) {
        if (!Schema.sObjectType.OpportunityContactRole.isUpdateable()) {
            throw new AuraHandledException('Insufficient permissions to update Contact Role.');
        }
        OpportunityContactRole ocr = new OpportunityContactRole(
            Id = roleId,
            Role = role,
            Engagement_Status__c = engagementStatus
        );
        update ocr;
        if (opportunityId != null && String.isNotBlank(meddpiccStatusField) && meddpiccStatus != null) {
            if (!Schema.sObjectType.Opportunity.isUpdateable()) {
                throw new AuraHandledException('Insufficient permissions to update Opportunity.');
            }
            Opportunity opp = new Opportunity(Id = opportunityId);
            opp.put(meddpiccStatusField, meddpiccStatus);
            update opp;
        }
    }

    @AuraEnabled
    public static void updateMeddpiccStatusField(Id opportunityId, String fieldName, String status) {
        if (!Schema.sObjectType.Opportunity.isUpdateable()) {
            throw new AuraHandledException('Insufficient permissions to update Opportunity.');
        }
        Opportunity opp = new Opportunity(Id = opportunityId);
        // Lookup fields require an Id value; Text fields take the String as-is.
        Schema.SObjectField fld = Schema.sObjectType.Opportunity.fields.getMap().get(fieldName);
        if (fld != null && fld.getDescribe().getType() == Schema.DisplayType.REFERENCE) {
            opp.put(fieldName, String.isBlank(status) ? null : (Id) status);
        } else {
            opp.put(fieldName, status);
        }
        update opp;
    }

    @AuraEnabled
    public static void updateContactReportsTo(Id contactId, Id reportsToId) {
        if (!Schema.sObjectType.Contact.isUpdateable()) {
            throw new AuraHandledException('Insufficient permissions to update Contact.');
        }
        Contact c = new Contact(Id = contactId, ReportsToId = reportsToId);
        update c;
    }

    @AuraEnabled
    public static void updateMetrics(Id opportunityId, String category,
                                     String description, String status) {
        if (!Schema.sObjectType.Opportunity.isUpdateable()) {
            throw new AuraHandledException('Insufficient permissions to update Opportunity.');
        }
        try {
            Opportunity opp = new Opportunity(
                Id = opportunityId,
                Metric_Category__c = category,
                MEDDPICC_Metrics__c = description,
                MEDDPICC_Metrics_Status__c = status
            );
            update opp;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static void updateDecisionCriteria(Id opportunityId, String options,
                                              String description, String status) {
        if (!Schema.sObjectType.Opportunity.isUpdateable()) {
            throw new AuraHandledException('Insufficient permissions to update Opportunity.');
        }
        try {
            Opportunity opp = new Opportunity(
                Id = opportunityId,
                Decision_Criteria_Options__c = options,
                MEDDPICC_Decision_Criteria__c         = description,
                MEDDPICC_Decision_Criteria_Status__c  = status
            );
            update opp;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static void updateDecisionProcess(Id opportunityId, String stages,
                                             String description, String status) {
        if (!Schema.sObjectType.Opportunity.isUpdateable()) {
            throw new AuraHandledException('Insufficient permissions to update Opportunity.');
        }
        try {
            Opportunity opp = new Opportunity(
                Id = opportunityId,
                Decision_Process_Stages__c = stages,
                MEDDPICC_Decision_Process__c        = description,
                MEDDPICC_Decision_Process_Status__c = status
            );
            update opp;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static void updatePaperProcess(Id opportunityId, String steps,
                                          String description, String status) {
        if (!Schema.sObjectType.Opportunity.isUpdateable()) {
            throw new AuraHandledException('Insufficient permissions to update Opportunity.');
        }
        try {
            Opportunity opp = new Opportunity(
                Id = opportunityId,
                Paper_Process_Steps__c = steps,
                MEDDPICC_Paper_Process__c       = description,
                MEDDPICC_Paper_Process_Status__c = status
            );
            update opp;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static void updatePain(Id opportunityId, String description, String status) {
        if (!Schema.sObjectType.Opportunity.isUpdateable()) {
            throw new AuraHandledException('Insufficient permissions to update Opportunity.');
        }
        try {
            Opportunity opp = new Opportunity(
                Id = opportunityId,
                MEDDPICC_Pain__c        = description,
                MEDDPICC_Pain_Status__c = status
            );
            update opp;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static void updateCompetition(Id opportunityId, String competitorAccountId,
                                         String description, String status) {
        if (!Schema.sObjectType.Opportunity.isUpdateable()) {
            throw new AuraHandledException('Insufficient permissions to update Opportunity.');
        }
        try {
            Opportunity opp = new Opportunity(
                Id = opportunityId,
                Competitor_Account__c = String.isBlank(competitorAccountId) ? null : (Id) competitorAccountId,
                MEDDPICC_Competition__c        = description,
                MEDDPICC_Competition_Status__c = status
            );
            update opp;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }
}