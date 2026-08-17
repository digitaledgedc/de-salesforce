/**
 * QuoteMrcRollupBatchTest
 *
 * FB-798: minimal coverage for the backfill batch. Confirms it runs against a
 * ramp quote without error and that Total_MRC_2__c ends up recalculated.
 */
@isTest
private class QuoteMrcRollupBatchTest {

    @isTest
    static void testBatchRecalculatesRampQuote() {
        // Inserting a Quote fires the "Quote - After Save - Stage Advance" flow,
        // which pushes the parent Opportunity to Stage 3-Quote+ regardless of the
        // stage it was created at. That triggers VR_OPP_21_Site_Required_At_Quote,
        // so Target_Site__c (and a matching Operation_Country__c, per that field's
        // lookup filter) must be set on the Opportunity up front.
        Site__c idSite = new Site__c(
            Country__c      = 'ID',
            Site_Code__c    = 'ID-QMRBTEST-01',
            Pricebook2__c = Test.getStandardPricebookId()
        );
        insert idSite;

        Opportunity opp = new Opportunity(
            Name                           = 'Batch Test Opp',
            StageName                      = '1-Suspect',
            CloseDate                      = Date.today().addDays(30),
            Feasibility_Status__c          = 'Feasible',
            MEDDPICC_Decision_Criteria__c  = 'Test criteria',
            Deal_Type__c                   = 'New Logo',
            Operation_Country__c           = 'Indonesia',
            CurrencyIsoCode                = 'IDR',
            Target_Site__c                 = idSite.Id
        );
        insert opp;

        Id standardPbId = Test.getStandardPricebookId();
        Quote q = new Quote(Name = 'Batch Test Quote', OpportunityId = opp.Id, Pricebook2Id = standardPbId, CurrencyIsoCode = 'IDR');
        insert q;

        Product2 prod = new Product2(Name = 'Batch Test Product', IsActive = true);
        insert prod;
        // CurrencyIsoCode = 'IDR' — the Indonesia-driven currency automation forces
        // the Opportunity/Quote to IDR, so the PricebookEntry must match or the
        // QuoteLineItem insert below fails on a currency mismatch.
        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = standardPbId, Product2Id = prod.Id, UnitPrice = 0, IsActive = true,
            CurrencyIsoCode = 'IDR'
        );
        insert pbe;

        insert new QuoteLineItem(
            QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = prod.Id,
            Quantity = 2, UnitPrice = 500, Charge_Type__c = 'MRC', Line_Origin__c = 'Ramp',
            Ramp_Phase__c = 1, Ramp_Identifier__c = 'Add'
        );

        Test.startTest();
        Database.executeBatch(new QuoteMrcRollupBatch(), 100);
        Test.stopTest();

        Quote result = [SELECT Total_MRC_2__c FROM Quote WHERE Id = :q.Id];
        System.assertEquals(1000, result.Total_MRC_2__c, 'Batch should recalculate Total_MRC_2__c for the ramp quote');
    }
}