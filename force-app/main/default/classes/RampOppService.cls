/**
 * RampOppService
 *
 * Creates one child Opportunity per ramp phase — including phase 1 — and
 * re-points that phase's Order onto it. Called from
 * RampOrderService.splitRampOrder once OrderMrcRollupService has computed
 * each phase's incremental MRC, and BEFORE any of those Orders are
 * activated — Order_AfterSave_WonAutoClose fires on activation and resolves
 * the Opportunity via the Order's current OpportunityId, so every repoint
 * has to land first or that flow would close out the deal's Opportunity
 * instead of the new phase Opportunity.
 *
 * After this runs, the deal's own Opportunity holds no Order directly —
 * every phase, 1 through N, lives on its own child (Parent_Opportunity__c)
 * Opportunity. Every ramp child Opportunity is created directly at 5-Won: a
 * phase Order only gets split off after the deal itself has already been
 * quoted and accepted, so there is no open pipeline stage for a phase
 * Opportunity to sit in — it represents an already-committed slice of a
 * won deal.
 *
 * Because the deal Opportunity no longer has any Order pointing at it,
 * Order_AfterSave_WonAutoClose (which closes whatever Opportunity an
 * activated Order currently points to) can no longer reach it — so this
 * method closes the deal Opportunity itself, the same way that flow would
 * have, once every phase has its own child.
 *
 * ─── Per-phase MRC / NRC / TCV / Remaining Month (FB-1041 follow-up) ───────
 * Each phase Opportunity gets its own:
 *   - MRC__c            = that phase's incremental MRC (OrderMrcRollupService's
 *                          Total_Order_MRC__c)
 *   - NRC__c            = that phase's own Order.Total_NRC__c (2026-09-03 fix:
 *                          this was never wired up — every phase child
 *                          Opportunity's NRC__c came out blank even though
 *                          its own Order already carried the real total)
 *   - Remaining_Month__c = the day-aware month count from this phase's RDD__c
 *                          through Contract_End_Date__c (see fractionalMonthsBetween)
 *   - Contract_End_Date__c = copied straight from the phase's own Order
 *   - Total_Deal_MRC__c  = this phase's TCV, repurposed to hold TCV per the
 *                          client's direction to reuse that field rather than
 *                          add a new one (its label/description still describe
 *                          a parent-level rollup — stale for ramp deals now)
 *
 *   TCV(phase) = MRC__c(phase) * Remaining_Month__c(phase)
 *
 * Remaining_Month__c is the months REMAINING from that phase's start through
 * Contract_End_Date__c, not the window "until the next phase" (2026-08-26
 * correction, see QuoteMrcRollupService's class doc for the client-confirmed
 * proof): summing delta(phase)*remainingMonths(phase) over every phase is
 * mathematically equivalent to summing (standing MRC during each phase's own
 * window) * (that window's own duration) — true whether a phase's delta
 * later gets superseded or stays permanently additive, so there's no
 * separate case for either kind of ramp deal.
 *
 * This is NOT Order.Total_Contract_Value__c (Total_MRC__c * Contract_Term_
 * Months__c) — that formula field applies each phase's full incremental
 * MRC over the WHOLE contract term, which overstates every phase but the
 * last.
 *
 * ─── Parent Opportunity is zeroed out (2026-09-03) ─────────────────────────
 * Once every phase has its own child carrying the real MRC/TCV, the deal's
 * own Opportunity no longer represents any revenue on its own — its
 * MRC__c, NRC__c and Total_Deal_MRC__c (TCV) are forced to 0 here so it
 * can't double-count alongside its children (Amount is left alone — it
 * isn't one of the three fields this was scoped to).
 *
 * Remaining_Month__c is day-aware (2026-09-03 client-confirmed model — see
 * fractionalMonthsBetween): sums, for every calendar month the phase's
 * [RDD__c, Contract_End_Date__c] span touches, (days of that month covered)
 * / (that month's own length) — applied uniformly, including ordinary
 * aligned spans (an exact "same day, N months later" span is NOT
 * automatically a clean whole number, since not every touched month has the
 * same length).
 *
 * ─── CloseDate / GoLive_Target_Date__c / Forecast_Status__c (2026-09-22 fix) ───
 * Three more fields were wrong on every phase child, reported against the
 * live 260139 ramp:
 *   - CloseDate            = dealOpp.CloseDate — the deal's own close date,
 *                             same on every phase. Previously this line held
 *                             the phase's own RDD instead, so each phase
 *                             showed a different, incorrect Close Date.
 *   - GoLive_Target_Date__c = full.RDD__c — that phase's own ramp start date
 *                             (Requested Delivery Date). This is where RDD__c
 *                             belongs; it was never set here, so every phase
 *                             just carried the deal-level clone value instead
 *                             of its own.
 *   - Forecast_Status__c   = 'Won' — required, defaults to 'Pipeline' when
 *                             left unset (see its field description), so
 *                             every ramp child silently landed on Pipeline
 *                             despite being 5-Won/Closed.
 */
// without sharing: called from RampOrderService, itself a system-context
// invocable off the after-save Quote flow — ramp splitting must not depend
// on the running user's Opportunity access.
public without sharing class RampOppService {

    private static final String CLOSED_WON_STAGE = '5-Won';

    /**
     * @param parentOrder  The phase-1 Order; parentOrder.OpportunityId is
     *        the deal's Opportunity.
     * @param childOrders  The phase 2+ Orders created by splitRampOrder, in
     *        ascending phase order.
     *
     * Every Order here — parentOrder included — still points at the deal's
     * Opportunity on entry; this method re-points each one onto its own new
     * phase Opportunity.
     */
    public static void createRampChildren(Order parentOrder, List<Order> childOrders) {
        if (parentOrder == null || parentOrder.OpportunityId == null) {
            return;
        }

        List<Order> allPhaseOrders = new List<Order>{ parentOrder };
        if (childOrders != null) allPhaseOrders.addAll(childOrders);

        Id dealOppId = parentOrder.OpportunityId;

        // Duplicate-guard: only act on Orders still pointing at the deal's
        // Opportunity. One already re-pointed to its own phase Opportunity
        // was handled by a prior run of this method.
        List<Order> toProcess = new List<Order>();
        for (Order o : allPhaseOrders) {
            if (o.OpportunityId == dealOppId) {
                toProcess.add(o);
            }
        }
        if (toProcess.isEmpty()) return;

        List<Opportunity> deals = OpportunitySelector.getForRampClone(new Set<Id>{ dealOppId });
        if (deals.isEmpty()) return;
        Opportunity dealOpp = deals[0];

        // Total_Order_MRC__c / Ramp_Phase__c were written by
        // OrderMrcRollupService as a separate partial-field DML, so the
        // caller's in-memory Order records don't carry them — re-query.
        Map<Id, Order> refreshed = new Map<Id, Order>(
            [SELECT Id, Ramp_Phase__c, RDD__c, Total_Order_MRC__c, Total_NRC__c, Contract_End_Date__c
             FROM Order WHERE Id IN :toProcess]
        );

        List<Opportunity> phaseOpps = new List<Opportunity>();
        List<Order> ordersToLink = new List<Order>();
        Date dealContractEndDate = null;
        for (Order o : toProcess) {
            Order full = refreshed.get(o.Id);
            if (full == null) continue;
            if (dealContractEndDate == null) dealContractEndDate = full.Contract_End_Date__c;

            Integer phase = full.Ramp_Phase__c != null ? Integer.valueOf(full.Ramp_Phase__c) : 1;
            Decimal delta = full.Total_Order_MRC__c != null ? full.Total_Order_MRC__c : 0;
            Decimal remainingMonths = fractionalMonthsBetween(full.RDD__c, full.Contract_End_Date__c).setScale(2);
            Decimal tcv = (delta * remainingMonths).setScale(2);

            Opportunity phaseOpp = dealOpp.clone(false, false, false, false);
            phaseOpp.Name = dealOpp.Name + ' - Phase ' + phase;
            // Mirrors RampOrderService's Order_Number__c "<original>-RO<phase>"
            // convention (RO1 included). Set explicitly so
            // OppNumberGenerator.assignNumbers (which only fills a BLANK
            // Opportunity_Number__c) leaves it alone.
            phaseOpp.Opportunity_Number__c = dealOpp.Opportunity_Number__c + '-RO' + phase;
            phaseOpp.Parent_Opportunity__c = dealOpp.Id;
            phaseOpp.Order_Type__c = 'Ramp';
            phaseOpp.Is_Ramp_Deal__c = true;
            phaseOpp.StageName = CLOSED_WON_STAGE;
            phaseOpp.ForecastCategoryName = 'Closed';
            // Required, defaults to 'Pipeline' if left unset — see class doc.
            phaseOpp.Forecast_Status__c = 'Won';
            // The deal's own close date — same on every phase. See class doc.
            phaseOpp.CloseDate = dealOpp.CloseDate;
            // RDD__c is that phase's ramp start date (carried up from the
            // OrderItem.Ramp_Start_Date__c lines in RampOrderService); it is
            // the closest thing to "when this phase's revenue starts." See
            // class doc — this belongs on GoLive_Target_Date__c, not CloseDate.
            phaseOpp.GoLive_Target_Date__c = full.RDD__c;
            phaseOpp.Amount = delta;
            phaseOpp.MRC__c = delta;
            phaseOpp.NRC__c = full.Total_NRC__c != null ? full.Total_NRC__c : 0;
            phaseOpp.Remaining_Month__c = remainingMonths;
            phaseOpp.Contract_End_Date__c = full.Contract_End_Date__c;
            // Total_Deal_MRC__c repurposed to hold this phase's TCV — see
            // class doc.
            phaseOpp.Total_Deal_MRC__c = tcv;

            phaseOpps.add(phaseOpp);
            ordersToLink.add(full);
        }

        if (phaseOpps.isEmpty()) return;
        insert phaseOpps;

        List<Order> orderUpdates = new List<Order>();
        for (Integer i = 0; i < ordersToLink.size(); i++) {
            orderUpdates.add(new Order(Id = ordersToLink[i].Id, OpportunityId = phaseOpps[i].Id));
        }
        update orderUpdates;

        // Zero the deal Opportunity's own MRC/NRC/TCV — its children now
        // carry that value, so it can't double-count alongside them. Mark it
        // Is_Ramp_Deal__c = true (belt-and-suspenders — it should already be
        // true, since that's what triggers ramp splitting in the first
        // place, but ensure it here too) and copy Contract_End_Date__c down
        // from the phases so the deal record shows the same end date they do.
        // Mirrors Order_AfterSave_WonAutoClose for the StageName/CloseDate
        // part, which can no longer reach this Opportunity now that every
        // phase's Order points elsewhere.
        Opportunity dealOppUpdate = new Opportunity(
            Id = dealOpp.Id,
            MRC__c = 0,
            NRC__c = 0,
            Total_Deal_MRC__c = 0,
            Is_Ramp_Deal__c = true,
            Contract_End_Date__c = dealContractEndDate
        );
        if (dealOpp.StageName != CLOSED_WON_STAGE) {
            dealOppUpdate.StageName = CLOSED_WON_STAGE;
            dealOppUpdate.CloseDate = Date.today();
            dealOppUpdate.ForecastCategoryName = 'Closed';
        }
        update dealOppUpdate;
    }

    /**
     * Day-aware month count between two dates — identical algorithm to
     * QuoteMrcRollupService.fractionalMonthsBetween (kept as a separate
     * copy since Order/Opportunity and QuoteLineItem/Quote don't share a
     * common rollup utility class today; see that class for the full
     * derivation and worked examples). Walks month by month from fromDate
     * to toDate (both endpoints inclusive), summing (days of the interval
     * in that month) / (that month's own length).
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
}