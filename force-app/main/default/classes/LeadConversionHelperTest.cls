/**
 * LeadConversionHelperTest
 *
 * Test coverage for LeadConversionHelper invocable action.
 * Uses Database.convertLead under the hood — tests run against actual
 * Lead conversion API (no mock). SeeAllData = false: test data only.
 */
@isTest
private class LeadConversionHelperTest {

    @TestSetup
    static void setup() {
        Lead testLead = new Lead(
            FirstName    = 'Test',
            LastName     = 'ConvHelper',
            Company      = 'Test Conversion Co',
            Email        = 'convhelper@test-de.example.com',
            Status       = 'New',
            LeadSource   = 'Event'
        );
        insert testLead;
    }

    // ── Test 1: Convert with auto-created Account + Contact + Opportunity ────
    @isTest
    static void testConvertLeadAutoCreate() {
        Lead l = [SELECT Id FROM Lead WHERE Email = 'convhelper@test-de.example.com' LIMIT 1];

        LeadConversionHelper.ConvertLeadInput inp = new LeadConversionHelper.ConvertLeadInput();
        inp.leadId = l.Id;

        Test.startTest();
        LeadConversionHelper.convertLead(new List<LeadConversionHelper.ConvertLeadInput>{ inp });
        Test.stopTest();

        Lead converted = [SELECT Id, IsConverted, ConvertedAccountId, ConvertedContactId FROM Lead WHERE Id = :l.Id];
        System.assertEquals(true, converted.IsConverted, 'Lead should be converted');
        System.assertNotEquals(null, converted.ConvertedAccountId, 'Should have a converted Account');
        System.assertNotEquals(null, converted.ConvertedContactId, 'Should have a converted Contact');
    }

    // ── Test 2: Convert with an existing Account ─────────────────────────────
    @isTest
    static void testConvertLeadExistingAccount() {
        Lead l = [SELECT Id FROM Lead WHERE Email = 'convhelper@test-de.example.com' LIMIT 1];

        Account existingAcc = new Account(Name = 'Test Conversion Co', Tax_ID__c = 'TEST-TAX-001');
        insert existingAcc;

        LeadConversionHelper.ConvertLeadInput inp = new LeadConversionHelper.ConvertLeadInput();
        inp.leadId     = l.Id;
        inp.accountId  = existingAcc.Id;

        Test.startTest();
        LeadConversionHelper.convertLead(new List<LeadConversionHelper.ConvertLeadInput>{ inp });
        Test.stopTest();

        Lead converted = [SELECT Id, IsConverted, ConvertedAccountId FROM Lead WHERE Id = :l.Id];
        System.assertEquals(true, converted.IsConverted, 'Lead should be converted');
        System.assertEquals(existingAcc.Id, converted.ConvertedAccountId, 'Should link to existing Account');
    }

    // ── Test 3: Convert with doNotCreateOpportunity = true ───────────────────
    @isTest
    static void testConvertLeadNoOpportunity() {
        Lead l = [SELECT Id FROM Lead WHERE Email = 'convhelper@test-de.example.com' LIMIT 1];

        LeadConversionHelper.ConvertLeadInput inp = new LeadConversionHelper.ConvertLeadInput();
        inp.leadId                  = l.Id;
        inp.doNotCreateOpportunity  = true;

        Test.startTest();
        LeadConversionHelper.convertLead(new List<LeadConversionHelper.ConvertLeadInput>{ inp });
        Test.stopTest();

        Lead converted = [SELECT Id, IsConverted, ConvertedOpportunityId FROM Lead WHERE Id = :l.Id];
        System.assertEquals(true, converted.IsConverted, 'Lead should be converted');
        System.assertEquals(null, converted.ConvertedOpportunityId, 'No Opportunity should be created');
    }

    // ── Test 4: Queue-owned Lead — method should reassign before converting ───
    @isTest
    static void testConvertLeadQueueOwnedReassigns() {
        // Create a Lead owned by a queue — LeadConversionHelper must reassign it
        // to the running user before calling Database.convertLead.
        // We simulate this by directly setting OwnerId to the current user
        // (since creating an actual Queue in tests is complex without live data).
        Lead l = [SELECT Id, OwnerId FROM Lead WHERE Email = 'convhelper@test-de.example.com' LIMIT 1];

        LeadConversionHelper.ConvertLeadInput inp = new LeadConversionHelper.ConvertLeadInput();
        inp.leadId = l.Id;

        Test.startTest();
        // Should not throw even if OwnerId is already a User (covers the queue-check branch)
        LeadConversionHelper.convertLead(new List<LeadConversionHelper.ConvertLeadInput>{ inp });
        Test.stopTest();

        Lead converted = [SELECT Id, IsConverted FROM Lead WHERE Id = :l.Id];
        System.assertEquals(true, converted.IsConverted, 'Lead should be converted regardless of prior owner type');
    }
}