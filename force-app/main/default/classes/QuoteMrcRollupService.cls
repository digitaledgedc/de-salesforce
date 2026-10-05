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
 *   - Charge_Type__c = 'Usage-Based' lines, OR lines on a Product2 flagged
 *     Merge_IB_Task__c = true, represent a cumulative commitment level per
 *     phase (each phase's quantity IS the running total, not an add-on to
 *     the previous phase) — only the line with the highest Ramp_Phase__c
 *     counts, per product+attribute. (2026-09-03 fix: Merge_IB_Task__c
 *     products — e.g. "Dedicated Data Hall (Hyperscale space)" — were being
 *     treated as independent additive Adds and summed across phases, which
 *     both overstated Total_MRC_2__c and fed the wrong per-phase delta into
 *     TCV. OrderMrcRollupService already treats Merge_IB_Task__c this way at
 *     the Order/OrderItem level; this brings the Quote-level rollup in line
 *     with it, reusing the exact same "latest phase wins" logic already
 *     built for Usage-Based.)
 *   - All other lines are additive ("Ramp_Identifier__c = 'Add'") EXCEPT when
 *     Ramp_Linked_Phase__c is set ('Price_Change'/'Change'), which means this
 *     line replaces — not adds to — the amount contributed by that linked phase.
 *   - Non-ramp lines (Ramp_Phase__c null) fall through the same logic as a
 *     single phase-0 bucket, so non-ramp quotes behave exactly like a plain sum.
 *
 * ─── Total_Contract_Value__c (month-weighted, per client correction) ──────
 * TCV is NOT Total_MRC__c * Contract_Term_Months__c — that treats the final
 * ramped-up rate as if it applied for the whole contract. Each ramp phase
 * contributes the DELTA it introduces to the running MRC, multiplied by the
 * months REMAINING from that phase's start through to Contract_End_Date__c:
 *
 *   delta(phase N)       = cumulativeMRC(phase N) - cumulativeMRC(phase N-1)
 *   remainingMonths(N)   = day-aware months from phase N's Ramp_Start_Date__c
 *                          through Contract_End_Date__c (phase 0 / non-ramp
 *                          uses Contract_Term_Months__c directly, i.e. the
 *                          whole term) — see fractionalMonthsBetween
 *   TCV                  = SUM over phases of delta(phase) * remainingMonths(phase)
 *
 * This is mathematically equivalent to summing (standing/cumulative rate
 * during each phase's own window) * (that window's own duration) — a
 * telescoping identity that holds regardless of whether a phase's delta is
 * later superseded (Price_Change/Change) or stays permanently additive
 * (fresh Add): Σ delta(i)*remaining(i) = Σ_j duration(j)*cumulative(j).
 * There is deliberately no "window to the NEXT phase" step — an earlier
 * revision multiplied by the window to the next phase instead of
 * remaining(i), which understates every phase but the last.
 *
 * remainingMonths is DAY-AWARE (2026-09-03 client-confirmed model): it sums,
 * for every calendar month the [start, Contract_End_Date__c] span touches,
 * (days of that month covered) / (that month's own length) — applied
 * uniformly, including ordinary aligned spans (client-confirmed: even an
 * exact "same day, N months later" span like Sep 3 -> Dec 3 comes out to
 * ~3.03, not a clean 3.0, since not every touched month has 31 days). See
 * fractionalMonthsBetween for the exact algorithm and worked examples. This
 * changed the client's original 3-product/36-month worked example from
 * 46200 (the prior whole-months-only model) to ~46253.23 — expected under
 * this model, not a regression: every phase there starts on Jan 1, and
 * January/February/etc. aren't all 31 days, so day-summing them no longer
 * lands on a clean whole number the way naive "N months" reasoning did.
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
 * 'Usage-Based' OR Product2.Merge_IB_Task__c = true is the signal for
 * "cumulative, take latest phase only" — every other charge type is
 * additive-with-override. Verify against more ramp quotes before relying on
 * this in production.
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
        Set<Id> productIds = new Set<Id>();
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
            if (qli.Product2Id != null) productIds.add(qli.Product2Id);
        }

        // Merge_IB_Task__c mirrors OrderMrcRollupService's isAggregateByProduct —
        // same signal, same "latest phase wins" treatment, one level up (Quote
        // instead of Order).
        Map<Id, Boolean> isAggregateByProduct = new Map<Id, Boolean>();
        if (!productIds.isEmpty()) {
            for (Product2 p : [SELECT Id, Merge_IB_Task__c FROM Product2 WHERE Id IN :productIds]) {
                isAggregateByProduct.put(p.Id, p.Merge_IB_Task__c == true);
            }
        }

        List<Quote> toUpdate = new List<Quote>();
        for (Quote q : [SELECT Id, Total_MRC_2__c, Total_Contract_Value_2__c, Contract_Term_Months__c, Contract_End_Date__c
                        FROM Quote WHERE Id IN :quoteIds]) {
            List<QuoteLineItem> lines = linesByQuote.containsKey(q.Id) ? linesByQuote.get(q.Id) : new List<QuoteLineItem>();

            Map<String, List<QuoteLineItem>> families = groupByFamily(lines);
            Decimal totalMrc = 0;
            for (List<QuoteLineItem> familyLines : families.values()) {
                totalMrc += familyTotal(familyLines, isAggregateByProduct);
            }
            totalMrc = totalMrc.setScale(2);

            Decimal tcv = calculateTcv(families, q.Contract_Term_Months__c, q.Contract_End_Date__c, isAggregateByProduct).setScale(2);

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
     * Usage-Based OR Merge_IB_Task__c (aggregate) product: latest phase only.
     * Everything else: sum of each phase's own amount, with Ramp_Linked_Phase__c
     * lines replacing (not adding to) the amount attributed to the phase they
     * reference.
     */
    private static Decimal familyTotal(List<QuoteLineItem> lines, Map<Id, Boolean> isAggregateByProduct) {
        Boolean isCumulative = false;
        for (QuoteLineItem qli : lines) {
            Boolean isAggregate = isAggregateByProduct.containsKey(qli.Product2Id) ? isAggregateByProduct.get(qli.Product2Id) : false;
            if (qli.Charge_Type__c == 'Usage-Based' || isAggregate) {
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
     * (months REMAINING from that phase's Ramp_Start_Date__c through
     * Contract_End_Date__c). Phase 0 (non-ramp baseline lines) uses the full
     * Contract_Term_Months__c, so a quote with no ramp phases reduces to the
     * original Total_MRC__c * Contract_Term_Months__c formula.
     *
     * Every phase's delta is weighted by its remaining term to the contract
     * end, not by the window until the next phase — 2026-08-26 correction:
     * an earlier revision used "until the next phase" and reproduced only
     * 19800 of the client-confirmed 46200 for the worked example in
     * QuoteMrcRollupServiceTest.testTcvMatchesClientWorkedExample, because it
     * multiplied phase 1's 800 delta by 12 months instead of the full 36
     * remaining. remaining-to-end is mathematically equivalent to summing
     * (standing rate during each phase's own window) * (that window's own
     * duration) — see the class doc's telescoping-identity note — and this
     * holds for superseded (Price_Change) and permanently-additive (Add)
     * deltas alike, so there's no separate case for either.
     *
     * The last phase's remaining term ends at Contract_End_Date__c, which
     * (per FB-852) sits one day before a clean N-month mark — so its month
     * count can come out one month short of what a naive annual-cadence
     * assumption would suggest (e.g. 11 instead of 12). That's expected, not
     * a bug: it reflects the actual remaining term, not a rounded approximation.
     *
     * phaseMonths is day-aware, not whole-months-only (2026-08-26 client
     * request): a window's leftover — after the largest whole-month count
     * that still fits — is credited as a fraction of the calendar month(s)
     * it actually falls in, not dropped. A leftover that crosses a month
     * boundary (e.g. Aug 25 to Sep 10) splits into two fragments: the days
     * remaining in the first month over that month's own length, plus the
     * days into the second month over ITS length — see fractionalMonthsBetween.
     */
    private static Decimal calculateTcv(Map<String, List<QuoteLineItem>> families, Decimal contractTermMonths, Date contractEndDate, Map<Id, Boolean> isAggregateByProduct) {
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
        Integer termMonths = contractTermMonths != null ? contractTermMonths.intValue() : 0;

        Decimal previousCumulative = 0;
        Decimal tcv = 0;
        for (Integer i = 0; i < sortedPhases.size(); i++) {
            Decimal phase = sortedPhases[i];
            Decimal cumulative = 0;
            for (List<QuoteLineItem> familyLines : families.values()) {
                List<QuoteLineItem> prefixLines = new List<QuoteLineItem>();
                for (QuoteLineItem qli : familyLines) {
                    Decimal qliPhase = qli.Ramp_Phase__c != null ? qli.Ramp_Phase__c : PHASE_ZERO;
                    if (qliPhase <= phase) prefixLines.add(qli);
                }
                cumulative += familyTotal(prefixLines, isAggregateByProduct);
            }

            Decimal delta = cumulative - previousCumulative;
            previousCumulative = cumulative;

            Decimal phaseMonths;
            if (phase == PHASE_ZERO || !startDateByPhase.containsKey(phase)) {
                phaseMonths = termMonths;
            } else {
                Date thisPhaseStart = startDateByPhase.get(phase);
                phaseMonths = contractEndDate != null ? fractionalMonthsBetween(thisPhaseStart, contractEndDate) : Decimal.valueOf(termMonths);
            }

            tcv += delta * phaseMonths;
        }

        return tcv;
    }

    /**
     * Day-aware month count between two dates (2026-09-03 client-confirmed
     * model): sums, for every calendar month the CLOSED interval
     * [fromDate, toDate] touches, (days of that month covered by the
     * interval) / (that month's own length). Both endpoints are counted
     * (inclusive on both ends) — walk month by month from fromDate, and for
     * each month add (days of the interval that fall in it) / (that month's
     * length), until toDate's own month is reached.
     *
     * This applies uniformly, including ordinary aligned spans: e.g. Sep 3
     * to Dec 3 comes out to ~3.03, not a clean 3.0, since not every touched
     * month has 31 days. Confirmed against three hand-verified cases:
     *   - Jan 1 -> Jan 2 (same month)          = 2/31
     *   - Feb 1, 2027 -> Mar 1, 2027 (Feb=28d)  = 1 + 1/31 (all of Feb, +1 day of Mar)
     *   - Oct 15, 2026 -> Sep 30, 2028          = 23 + 17/31 (Oct 15-31 is 17 days)
     *
     * This replaced an earlier "whole months + one leftover fragment"
     * formula (forward-anchored, then backward-anchored) that tried to
     * express the gap as an integer month count plus a single trailing
     * fraction. That approach could never correctly handle a phase starting
     * on day 1 of a month too short to contain the target day (e.g. Feb 1
     * needing to reach a "day 30" equivalent) without an inconsistent,
     * non-invertible result. Day-summation has no such edge case: every
     * month, short or long, is just its own covered-days/length term.
     *
     * Changes the client's original 3-product/36-month worked example from
     * 46200 (old whole-months-only model) to ~46253.23 — see class doc.
     */
    private static Decimal fractionalMonthsBetween(Date fromDate, Date toDate) {
        if (fromDate == null || toDate == null || toDate < fromDate) return 0;

        Decimal total = 0;
        Integer year = fromDate.year();
        Integer month = fromDate.month();
        Integer startDay = fromDate.day();

        while (true) {
            Integer daysInThisMonth = Date.daysInMonth(year, month);
            Boolean isLastMonth = (year == toDate.year() && month == toDate.month());
            Integer endDay = isLastMonth ? toDate.day() : daysInThisMonth;

            Integer daysCounted = endDay - startDay + 1;
            total += Decimal.valueOf(daysCounted) / daysInThisMonth;

            if (isLastMonth) break;

            month += 1;
            if (month > 12) {
                month = 1;
                year += 1;
            }
            startDay = 1;
        }

        return total;
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