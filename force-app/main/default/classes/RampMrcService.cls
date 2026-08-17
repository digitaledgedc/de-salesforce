/**
 * RampMrcService
 *
 * Returns the "steady-state" MRC for a ramp quote — the gross MRC of the FINAL
 * (highest) ramp phase, which is what the customer actually pays per month at full
 * ramp. Returns null when the quote is not a ramp, so callers fall back to the
 * existing gross Total_MRC behaviour.
 *
 * Used by Quote_AfterSave_SyncToOpportunity to set Opportunity.MRC__c correctly on
 * ramp deals (the gross Total_MRC double-counts phases). Non-ramp and change-order
 * paths are unaffected — this returns null for anything without ramp phases.
 *
 * Bulk-safe: two aggregate queries total, regardless of input size.
 */
public with sharing class RampMrcService {

    public class Request {
        @InvocableVariable(required=true description='Id of the Quote to evaluate')
        public Id quoteId;
    }

    public class Result {
        @InvocableVariable(description='Final-phase (steady-state) gross MRC; null if the quote is not a ramp')
        public Decimal steadyStateMRC;
    }

    @InvocableMethod(
        label='Get Ramp Steady-State MRC'
        description='Returns the final-phase MRC for a ramp quote (the steady-state monthly); null if the quote has no ramp phases.'
        category='Quote'
    )
    public static List<Result> getSteadyStateMRC(List<Request> requests) {
        Set<Id> quoteIds = new Set<Id>();
        for (Request r : requests) {
            if (r != null && r.quoteId != null) quoteIds.add(r.quoteId);
        }

        // Pull all MRC ramp lines in ONE query and aggregate in memory — Ramp_Phase__c
        // (a Number field) can't be used in a SOQL GROUP BY. Bulk-safe: one query total.
        Map<Id, Decimal> maxPhaseByQuote = new Map<Id, Decimal>();
        Map<String, Decimal> sumByQuotePhase = new Map<String, Decimal>();  // key: quoteId|phase
        for (QuoteLineItem qli : [
            SELECT QuoteId, Ramp_Phase__c, MRC_Amount__c
            FROM QuoteLineItem
            WHERE QuoteId IN :quoteIds AND Ramp_Phase__c != null AND Charge_Type__c = 'MRC'
        ]) {
            Decimal ph = qli.Ramp_Phase__c;
            Decimal amt = (qli.MRC_Amount__c != null) ? qli.MRC_Amount__c : 0;
            Decimal curMax = maxPhaseByQuote.get(qli.QuoteId);
            if (curMax == null || ph > curMax) maxPhaseByQuote.put(qli.QuoteId, ph);
            String key = qli.QuoteId + '|' + String.valueOf(ph);
            sumByQuotePhase.put(key, (sumByQuotePhase.containsKey(key) ? sumByQuotePhase.get(key) : 0) + amt);
        }

        List<Result> results = new List<Result>();
        for (Request r : requests) {
            Result res = new Result();
            Decimal ss = null;
            if (r != null && r.quoteId != null && maxPhaseByQuote.containsKey(r.quoteId)) {
                Decimal mx = maxPhaseByQuote.get(r.quoteId);
                ss = sumByQuotePhase.get(r.quoteId + '|' + String.valueOf(mx));  // null-safe: key exists
            }
            res.steadyStateMRC = ss;   // null for non-ramp quotes
            results.add(res);
        }
        return results;
    }
}