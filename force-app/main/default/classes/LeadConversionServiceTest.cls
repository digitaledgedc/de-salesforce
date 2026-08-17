@IsTest
private class LeadConversionServiceTest {

    private static User makeAdminUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        User u = new User(
            Alias            = 'deadmin',
            Email            = 'de-admin-test@gokarya.test.invalid',
            EmailEncodingKey = 'UTF-8',
            LastName         = 'DEAdmin',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey     = 'en_US',
            ProfileId        = p.Id,
            TimeZoneSidKey   = 'America/Los_Angeles',
            UserName         = 'de-admin-test@gokarya.test.invalid'
        );
        insert u;
        PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'DE_Admin' LIMIT 1];
        insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
        return u;
    }

    @TestSetup
    static void setup() {
        // Existing account for single-country test — Finance_Approval_Phase__c set to avoid VR_ACC_11
        Account acct = new Account(Name = 'Test Account', Operation_Country__c = 'Japan', Finance_Approval_Phase__c = 'Not_Started');
        insert acct;

        String uniqueSuffix = UserInfo.getOrganizationId();

        // Multi-country Lead — will create 2 Accounts (Japan + Korea)
        Lead multiLead = new Lead(
            FirstName = 'Multi',
            LastName = 'Lead',
            Company = 'Multi Co',
            Email = 'multi-lead+' + uniqueSuffix + '@gokarya.test.invalid',
            Phone = '+65 1234 5678',
            Target_Country__c = 'Japan;Korea',
            Customer_Type__c = 'Customer',
            Capacity_kW__c = 500,
            Capacity_Cabinets__c = 10,
            LeadSource = 'Web'
        );

        // Single-country Lead — can use existing account
        Lead singleLead = new Lead(
            FirstName = 'Single',
            LastName = 'Lead',
            Company = 'Single Co',
            Email = 'single-lead+' + uniqueSuffix + '@gokarya.test.invalid',
            Phone = '+65 9876 5432',
            Target_Country__c = 'Japan',
            Customer_Type__c = 'Customer',
            LeadSource = 'Web'
        );

        // Suppress assignment rules to prevent Queue ownership — Database.convertLead
        // requires a User owner or an explicit setOwnerId call.
        Database.DMLOptions dmo = new Database.DMLOptions();
        dmo.assignmentRuleHeader.useDefaultRule = false;
        Database.insert(new List<Lead>{ multiLead, singleLead }, dmo);
    }

    @IsTest
    static void convertLead_multiCountry_createsAccountPerCountry() {
        Lead lead = [SELECT Id FROM Lead WHERE FirstName = 'Multi' LIMIT 1];
        User testUser = makeAdminUser();

        LeadConversionService.ConversionRequest req = new LeadConversionService.ConversionRequest();
        req.leadId = lead.Id;

        Test.startTest();
        List<LeadConversionService.ConversionResult> results;
        System.runAs(testUser) {
            results = LeadConversionService.convertLeads(
                new List<LeadConversionService.ConversionRequest>{ req }
            );
        }
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Expected one result for one request');
        LeadConversionService.ConversionResult result = results[0];
        System.assertEquals(true, result.success, 'Conversion should succeed');
        System.assertNotEquals(null, result.accountId, 'Primary Account Id should be set');
        System.assertNotEquals(null, result.contactId, 'Contact Id should be set');
        System.assertEquals(2, result.accountIds.size(),
            'Expected 2 Accounts — one per target country (Japan, Korea)');
        System.assertEquals(2, result.opportunityIds.size(),
            'Expected 2 Opportunities — one per Account/Country');

        // Verify each Opportunity is on a different Account
        List<Opportunity> opps = [SELECT AccountId, Originating_Lead__c
                                  FROM Opportunity WHERE Id IN :result.opportunityIds];
        Set<Id> oppAccountIds = new Set<Id>();
        for (Opportunity opp : opps) {
            oppAccountIds.add(opp.AccountId);
            System.assertEquals(lead.Id, opp.Originating_Lead__c,
                'Originating_Lead__c should reference the source Lead');
        }
        System.assertEquals(2, oppAccountIds.size(),
            'Each Opportunity should be on a separate Account');

        // Verify Contact is related to both Accounts via AccountContactRelation
        List<AccountContactRelation> acrs = [SELECT AccountId FROM AccountContactRelation
                                             WHERE ContactId = :result.contactId];
        System.assertEquals(2, acrs.size(),
            'Contact should be related to both Accounts (primary + ACR)');
    }

    @IsTest
    static void convertLead_nullLeadId_throwsException() {
        LeadConversionService.ConversionRequest req = new LeadConversionService.ConversionRequest();
        req.leadId = null;

        Test.startTest();
        Boolean exceptionThrown = false;
        try {
            LeadConversionService.convertLeads(new List<LeadConversionService.ConversionRequest>{ req });
        } catch (LeadConversionService.LeadConversionException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('leadId is required'),
                'Exception message should indicate missing leadId');
        }
        Test.stopTest();

        System.assertEquals(true, exceptionThrown, 'Exception should be thrown for null leadId');
    }

    @IsTest
    static void convertLead_singleCountryWithExistingAccount() {
        Lead lead = [SELECT Id FROM Lead WHERE FirstName = 'Single' LIMIT 1];
        Account existingAccount = [SELECT Id FROM Account WHERE Name = 'Test Account' LIMIT 1];
        User testUser = makeAdminUser();

        LeadConversionService.ConversionRequest req = new LeadConversionService.ConversionRequest();
        req.leadId = lead.Id;
        req.accountId = existingAccount.Id;

        Test.startTest();
        List<LeadConversionService.ConversionResult> results;
        System.runAs(testUser) {
            results = LeadConversionService.convertLeads(
                new List<LeadConversionService.ConversionRequest>{ req }
            );
        }
        Test.stopTest();

        LeadConversionService.ConversionResult result = results[0];
        System.assertEquals(true, result.success, 'Conversion with existing account should succeed');
        System.assertEquals(existingAccount.Id, result.accountId,
            'Should use the provided existing account');
        System.assertEquals(1, result.accountIds.size(), 'Should have 1 account');
        System.assertEquals(1, result.opportunityIds.size(),
            'Should have 1 opportunity for single country');
    }

    // ── LeadSelector direct coverage ─────────────────────────────────────────────
    @IsTest
    static void leadSelector_getForConversion_singleAndBulk() {
        Lead lead = [SELECT Id FROM Lead WHERE FirstName = 'Single' LIMIT 1];
        Test.startTest();
        Lead fetchedLead = LeadSelector.getForConversion(lead.Id);
        List<Lead> bulkLeads = LeadSelector.getForConversionBulk(new Set<Id>{ lead.Id });
        String convertedStatus = LeadSelector.getConvertedStatus();
        Test.stopTest();

        System.assertNotEquals(null, fetchedLead, 'Single-record selector should return the Lead');
        System.assertEquals(lead.Id, fetchedLead.Id, 'Selector should return the requested Lead');
        System.assertEquals(1, bulkLeads.size(), 'Bulk selector should return the Lead');
        System.assert(String.isNotBlank(convertedStatus), 'A converted LeadStatus label should be returned');
    }

    @IsTest
    static void leadSelector_getForConversion_noMatchReturnsNull() {
        Lead lead = [SELECT Id FROM Lead WHERE FirstName = 'Single' LIMIT 1];
        // Delete so the id no longer matches — selector should return null, not throw.
        delete lead;
        Test.startTest();
        Lead result = LeadSelector.getForConversion(lead.Id);
        Test.stopTest();
        System.assertEquals(null, result, 'Selector should return null when no Lead matches');
    }
}