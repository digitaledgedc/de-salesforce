/**
 * QuoteMrcRollupService
 *
 * Recalculates Quote.Total_MRC__c and Quote.Total_Contract_Value__c (FB-798),
 * replacing the old Roll-Up Summary (Total_MRC__c) and formula
 * (Total_Contract_Value__c = Total_MRC__c * Contract_Term_Months__c) — both of
 * which double/triple-count and mis-value ramp deals.
 *
 * ─── Total_MRC__c (steady-state snapshot) ──────────────────────────────────
 * Ramp lines are not uniformly additive:
 *   - Charge_Type__c = 'Usage-Based' lines represent a cumulative commitment
 *     level per phase (each phase supersedes the previous one) — only the line
 *     with the highest Ramp_Phase__c counts, per product+attribute.
 *   - All other lines are additive ("Ramp_Identifier__c = 'Add'") EXCEPT when
 *     Ramp_Linked_Phase__c is set ('Price_Change'/'Change'), which means this
 *     line replaces — not adds to — the amount contributed by that linked phase.
 *   - Non-ramp lines (Ramp_Phase__c null) fall through the same logic as a
 *     single phase-0 bucket, so non-ramp quotes behave exactly like a plain sum.
 *
 * ─── Total_Contract_Value__c (month-weighted, per client correction) ──────
 * TCV is NOT Total_MRC__c * Contract_Term_Months__c — that treats the final
 * ramped-up rate as if it applied for the whole contract. Per the client's
 * model, each ramp phase contributes only the DELTA it introduces to the
 * running MRC, multiplied by the months remaining from that phase's start to
 * Contract_End_Date__c:
 *
 *   delta(phase N)     = cumulativeMRC(phase N) - cumulativeMRC(phase N-1)
 *   remainingMonths(N) = months between phase N's Ramp_Start_Date__c and
 *                        Quote.Contract_End_Date__c (phase 0 / non-ramp uses
 *                        Contract_Term_Months__c directly, i.e. the whole term)
 *   TCV                = SUM over phases of delta(phase) * remainingMonths(phase)
 *
 * cumulativeMRC(phase N) is computed by re-running the Total_MRC__c logic
 * above restricted to lines with Ramp_Phase__c <= N — i.e. "what would the
 * total have been if the ramp stopped at phase N." Summing consecutive
 * deltas back up always reproduces Total_MRC__c exactly (telescoping sum),
 * so this doesn't change the final steady-state number, only how TCV
 * distributes it over time. For a non-ramp quote this reduces to the
 * original formula: one phase (0), full term, Total_MRC__c * Contract_Term_Months__c.
 *
 * ASSUMPTION (validated against Quote 26000729-QT-1 and the client's 3-product/
 * 36-month worked example, not yet against a broader sample): Charge_Type__c =
 * 'Usage-Based' is the signal for "cumulative, take latest phase only" — every
 * other charge type is additive-with-override. Verify against more ramp quotes
 * before relying on this in production.
 */
public without sharing class QuoteMrcRollupService {

    private static final Decimal PHASE_ZERO = 0;

    // ─── Transaction-scoped rollup deferral (governor-limit relief) ─────────────
    // A bulk caller that performs several QuoteLineItem DMLs in one transaction
    // (e.g. the ramp builder in QuoteLineEditorController.splitRampLines[Bulk])
    // otherwise re-runs this rollup — and the Quote update + downstream Quote /
    // Opportunity / Account flow + CreditRollup cascade it triggers — on EVERY
    // intermediate DML, which blows the 100-SOQL limit ("Too many SOQL queries").
    // The caller wraps its DML block in beginDefer()/endDeferAndFlush(): while
    // deferred, recalculate() only accumulates the affected Quote Ids and returns,
    // so the whole cascade runs exactly ONCE at the end. The rollup recomputes
    // Total_MRC_2__c / TCV from scratch, so a single end-of-build run yields the
    // same final numbers as running it per DML.
    // NOTE (for architect review — Alosh): this uses static state deliberately as
    // a transaction-scoped deferral coordinator. It is NOT a static-Boolean trigger
    // bypass (the handler still runs on every DML); it only defers one expensive
    // aggregation. Flag on record per SF_ANTIPATTERNS "Static State in Apex".
    @TestVisible private static Boolean deferRollup = false;
    @TestVisible private static Set<Id> deferredQuoteIds = new Set<Id>();

    /** Begin deferring rollups for the current transaction. */
    public static void beginDefer() {
        deferRollup = true;
        deferredQuoteIds.clear();
    }

    /** Stop deferring and run a single rollup for every Quote touched while deferred. */
    public static void endDeferAndFlush() {
        deferRollup = false;
        if (!deferredQuoteIds.isEmpty()) {
            Set<Id> toRun = deferredQuoteIds.clone();
            deferredQuoteIds.clear();
            recalculate(toRun);
        }
    }

    /** Reset the deferral flag without flushing (use on the error path — the DML rolls back). */
    public static void clearDefer() {
        deferRollup = false;
        deferredQuoteIds.clear();
    }

    public static void recalculate(Set<Id> quoteIds) {
        if (quoteIds == null || quoteIds.isEmpty()) return;
        if (deferRollup) {
            deferredQuoteIds.addAll(quoteIds);
            return;
        }

        Map<Id, List<QuoteLineItem>> linesByQuote = new Map<Id, List<QuoteLineItem>>();
        for (QuoteLineItem qli : [
            SELECT QuoteId, Product2Id, Product_Attribute_Value__c, Charge_Type__c,
                   Ramp_Phase__c, Ramp_Linked_Phase__c, Ramp_Start_Date__c, MRC_Amount__c
            FROM QuoteLineItem
            WHERE QuoteId IN :quoteIds
        ]) {
            if (!linesByQuote.containsKey(qli.QuoteId)) {
                linesByQuote.put(qli.QuoteId, new List<QuoteLineItem>());
            }
            linesByQuote.get(qli.QuoteId).add(qli);
        }

        List<Quote> toUpdate = new List<Quote>();
        for (Quote q : [SELECT Id, Total_MRC_2__c, Total_Contract_Value_2__c, Contract_Term_Months__c, Contract_End_Date__c
                        FROM Quote WHERE Id IN :quoteIds]) {
            List<QuoteLineItem> lines = linesByQuote.containsKey(q.Id) ? linesByQuote.get(q.Id) : new List<QuoteLineItem>();

            Map<String, List<QuoteLineItem>> families = groupByFamily(lines);
            Decimal totalMrc = 0;
            for (List<QuoteLineItem> familyLines : families.values()) {
                totalMrc += familyTotal(familyLines);
            }
            totalMrc = totalMrc.setScale(2);

            Decimal tcv = calculateTcv(families, q.Contract_Term_Months__c, q.Contract_End_Date__c).setScale(2);

            if (q.Total_MRC_2__c != totalMrc || q.Total_Contract_Value_2__c != tcv) {
                toUpdate.add(new Quote(Id = q.Id, Total_MRC_2__c = totalMrc, Total_Contract_Value_2__c = tcv));
            }
        }
        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
    }

    private static Map<String, List<QuoteLineItem>> groupByFamily(List<QuoteLineItem> lines) {
        Map<String, List<QuoteLineItem>> families = new Map<String, List<QuoteLineItem>>();
        for (QuoteLineItem qli : lines) {
            String familyKey = qli.Product2Id + '|' + (qli.Product_Attribute_Value__c != null ? qli.Product_Attribute_Value__c : '');
            if (!families.containsKey(familyKey)) {
                families.put(familyKey, new List<QuoteLineItem>());
            }
            families.get(familyKey).add(qli);
        }
        return families;
    }

    /**
     * Computes one product+attribute family's contribution to Total_MRC__c.
     * Usage-Based: latest phase only. Everything else: sum of each phase's own
     * amount, with Ramp_Linked_Phase__c lines replacing (not adding to) the
     * amount attributed to the phase they reference.
     */
    private static Decimal familyTotal(List<QuoteLineItem> lines) {
        Boolean isCumulative = false;
        for (QuoteLineItem qli : lines) {
            if (qli.Charge_Type__c == 'Usage-Based') {
                isCumulative = true;
                break;
            }
        }

        if (isCumulative) {
            QuoteLineItem latest = null;
            for (QuoteLineItem qli : lines) {
                Decimal phase = qli.Ramp_Phase__c != null ? qli.Ramp_Phase__c : PHASE_ZERO;
                Decimal latestPhase = (latest != null && latest.Ramp_Phase__c != null) ? latest.Ramp_Phase__c : -1;
                if (latest == null || phase > latestPhase) {
                    latest = qli;
                }
            }
            return latest != null && latest.MRC_Amount__c != null ? latest.MRC_Amount__c : 0;
        }

        Map<Decimal, Decimal> amountByPhase = new Map<Decimal, Decimal>();
        List<QuoteLineItem> overrideLines = new List<QuoteLineItem>();

        for (QuoteLineItem qli : lines) {
            Decimal amount = qli.MRC_Amount__c != null ? qli.MRC_Amount__c : 0;
            if (qli.Ramp_Linked_Phase__c != null) {
                overrideLines.add(qli);
                continue;
            }
            Decimal ownPhase = qli.Ramp_Phase__c != null ? qli.Ramp_Phase__c : PHASE_ZERO;
            Decimal existing = amountByPhase.containsKey(ownPhase) ? amountByPhase.get(ownPhase) : 0;
            amountByPhase.put(ownPhase, existing + amount);
        }

        // Order matters here: the put below REPLACES the phase's amount, so when two
        // or more linked lines in the same family target the SAME phase (the shape the
        // "link all phases" feature produces — several repricing phases all pointing
        // back at the same earlier Add), the last one applied is the one that survives.
        // The query in recalculate() has no ORDER BY, so left unsorted that winner is
        // whatever SOQL happened to return last — arbitrary. Pin it to ascending phase
        // so the LATEST reprice is applied last and deterministically wins. This also
        // covers calculateTcv(), which routes its phase-prefix slices back through here.
        overrideLines = sortByPhaseAscending(overrideLines);

        for (QuoteLineItem qli : overrideLines) {
            Decimal amount = qli.MRC_Amount__c != null ? qli.MRC_Amount__c : 0;
            amountByPhase.put(qli.Ramp_Linked_Phase__c, amount);
        }

        Decimal total = 0;
        for (Decimal phaseAmount : amountByPhase.values()) {
            total += phaseAmount;
        }
        return total;
    }

    /**
     * TCV = SUM over ramp phases of (delta introduced at that phase) *
     * (months remaining from that phase's start to Contract_End_Date__c).
     * Phase 0 (non-ramp baseline lines) uses the full Contract_Term_Months__c,
     * so a quote with no ramp phases reduces to the original
     * Total_MRC__c * Contract_Term_Months__c formula.
     */
    private static Decimal calculateTcv(Map<String, List<QuoteLineItem>> families, Decimal contractTermMonths, Date contractEndDate) {
        Set<Decimal> phaseNumbers = new Set<Decimal>{ PHASE_ZERO };
        Map<Decimal, Date> startDateByPhase = new Map<Decimal, Date>();
        for (List<QuoteLineItem> familyLines : families.values()) {
            for (QuoteLineItem qli : familyLines) {
                Decimal phase = qli.Ramp_Phase__c != null ? qli.Ramp_Phase__c : PHASE_ZERO;
                phaseNumbers.add(phase);
                if (phase != PHASE_ZERO && qli.Ramp_Start_Date__c != null && !startDateByPhase.containsKey(phase)) {
                    startDateByPhase.put(phase, qli.Ramp_Start_Date__c);
                }
            }
        }

        List<Decimal> sortedPhases = sortAscending(phaseNumbers);

        // FB-864 alignment: remaining months are OFFSET-based — contract term minus
        // the whole months this phase starts after phase 1 — NOT months counted to
        // Contract_End_Date__c. Two reasons: (1) every other remaining-term rule in
        // the org counts down from the TERM (this method's own PHASE_ZERO / non-ramp
        // branch already does exactly that, and RampOrderService does it per phase
        // since FB-864); (2) FB-852 moves Contract_End_Date__c to D-1, which would
        // silently shave a month off every phase here (36/24/12 -> 35/23/11, ~3% of
        // TCV) with nothing erroring. Offset-based is immune to that.
        Date firstPhaseStart = null;
        for (Decimal p : sortedPhases) {
            if (p != PHASE_ZERO && startDateByPhase.containsKey(p)) {
                firstPhaseStart = startDateByPhase.get(p);
                break;
            }
        }
        Integer termMonths = contractTermMonths != null ? contractTermMonths.intValue() : 0;

        Decimal previousCumulative = 0;
        Decimal tcv = 0;
        for (Decimal phase : sortedPhases) {
            Decimal cumulative = 0;
            for (List<QuoteLineItem> familyLines : families.values()) {
                List<QuoteLineItem> prefixLines = new List<QuoteLineItem>();
                for (QuoteLineItem qli : familyLines) {
                    Decimal qliPhase = qli.Ramp_Phase__c != null ? qli.Ramp_Phase__c : PHASE_ZERO;
                    if (qliPhase <= phase) prefixLines.add(qli);
                }
                cumulative += familyTotal(prefixLines);
            }

            Decimal delta = cumulative - previousCumulative;
            previousCumulative = cumulative;

            Integer remainingMonths;
            if (phase == PHASE_ZERO || !startDateByPhase.containsKey(phase) || firstPhaseStart == null) {
                remainingMonths = termMonths;
            } else {
                Integer elapsed = monthsBetween(firstPhaseStart, startDateByPhase.get(phase));
                remainingMonths = Math.max(0, Math.min(termMonths, termMonths - elapsed));
            }

            tcv += delta * remainingMonths;
        }

        return tcv;
    }

    private static Integer monthsBetween(Date fromDate, Date toDate) {
        if (fromDate == null || toDate == null) return 0;
        Integer months = (toDate.year() - fromDate.year()) * 12 + (toDate.month() - fromDate.month());
        return months > 0 ? months : 0;
    }

    private static List<Decimal> sortAscending(Set<Decimal> values) {
        List<Decimal> result = new List<Decimal>(values);
        for (Integer i = 1; i < result.size(); i++) {
            Decimal key = result[i];
            Integer j = i - 1;
            while (j >= 0 && result[j] > key) {
                result[j + 1] = result[j];
                j--;
            }
            result[j + 1] = key;
        }
        return result;
    }

    /**
     * Orders QuoteLineItems by Ramp_Phase__c ascending. List.sort() on an sObject
     * list can't order by an arbitrary field, so this mirrors sortAscending() above
     * rather than introducing a Comparable wrapper for six lines of work. A null
     * Ramp_Phase__c counts as PHASE_ZERO, the same as everywhere else in this class.
     * Insertion sort is stable, so lines sharing a phase keep their original relative
     * order — nothing that was previously deterministic gets reshuffled.
     */
    private static List<QuoteLineItem> sortByPhaseAscending(List<QuoteLineItem> lines) {
        List<QuoteLineItem> result = lines.clone();
        for (Integer i = 1; i < result.size(); i++) {
            QuoteLineItem key = result[i];
            Decimal keyPhase = key.Ramp_Phase__c != null ? key.Ramp_Phase__c : PHASE_ZERO;
            Integer j = i - 1;
            while (j >= 0 && (result[j].Ramp_Phase__c != null ? result[j].Ramp_Phase__c : PHASE_ZERO) > keyPhase) {
                result[j + 1] = result[j];
                j--;
            }
            result[j + 1] = key;
        }
        return result;
    }
}