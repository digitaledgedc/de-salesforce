/**
 * QuoteMrcRollupBatch
 *
 * FB-798 one-time backfill: recalculates Total_MRC_2__c AND Total_Contract_Value_2__c
 * (via QuoteMrcRollupService) for every existing Quote that has at least one ramp
 * line. Non-ramp quotes are skipped — both fields are unaffected by the fix for
 * them (same value either way), so there is no reason to touch them and trigger
 * downstream automation for free.
 *
 * NOTE: updating Quote.Total_MRC_2__c fires Quote_AfterSave_SyncToOpportunity, which
 * pushes Quote_MRC__c (and, for non-Won Opportunities, Amount/MRC__c) to the linked
 * Opportunity. This is expected — it's how the corrected total propagates downstream
 * — but means this batch is a real automation-triggering operation, not a quiet
 * data patch. Run it in a low-traffic window and monitor after execution.
 *
 * Usage:  Database.executeBatch(new QuoteMrcRollupBatch(), 100);
 */
public without sharing class QuoteMrcRollupBatch implements Database.Batchable<SObject> {

    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([
            SELECT Id FROM Quote
            WHERE Id IN (SELECT QuoteId FROM QuoteLineItem WHERE Ramp_Phase__c != null)
        ]);
    }

    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        Set<Id> quoteIds = new Set<Id>();
        for (SObject s : scope) {
            quoteIds.add((Id) s.get('Id'));
        }
        QuoteMrcRollupService.recalculate(quoteIds);
    }

    public void finish(Database.BatchableContext bc) {
    }
}