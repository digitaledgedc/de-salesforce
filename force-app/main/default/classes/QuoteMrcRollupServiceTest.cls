/**
 * QuoteMrcRollupServiceTest
 *
 * Coverage for FB-798: Total_MRC_2__c and Total_Contract_Value_2__c recalculation,
 * replacing the old Roll-Up Summary (Total_MRC_2__c) and formula
 * (Total_Contract_Value_2__c = Total_MRC_2__c * Contract_Term_Months__c).
 *
 *   1. Non-ramp quote: Total_MRC_2__c is a plain sum, same as the old rollup.
 *   2. Ramp quote: reproduces the Quote 26000729-QT-1 scenario (Cabinet with an
 *      Add + Add + Price_Change, Usage-Based with three cumulative Add phases)
 *      and asserts the client-confirmed expected total of 7,650,000.
 *   3. TCV: reproduces the client's 3-product/36-month worked example and
 *      asserts both the per-phase delta model and the final month-weighted TCV.
 */
@isTest
private class QuoteMrcRollupServiceTest {

    @TestSetup
    static void setupTestData() {
        // Inserting a Quote fires "Quote - After Save - Stage Advance", which pushes the
        // Opportunity to 3-Quote — and from that stage a validation rule demands an
        // Operation Site (Target_Site__c). Without it every test here dies in setup.
        Site__c site = new Site__c(Name = 'FB-798 Site', Site_Code__c = 'F798', Country__c = 'JP');
        insert site;

        Opportunity opp = new Opportunity(
            Name                           = 'Test Opp FB-798',
            StageName                      = '1-Suspect',
            CloseDate                      = Date.today().addDays(30),
            Feasibility_Status__c          = 'Feasible',
            MEDDPICC_Decision_Criteria__c  = 'Test criteria',
            Deal_Type__c                   = 'New Logo',
            // Target_Site__c's lookup filter is Site__c.Country_Name__c = this field, so
            // the two have to agree ('JP' on the Site renders as 'Japan') or the insert
            // is rejected by the filter.
            Operation_Country__c           = 'Japan',
            Target_Site__c                 = site.Id
        );
        // The Opportunity has to carry the pricebook too — quote automation derives the
        // Quote's Pricebook2Id from it, and an Opportunity with none leaves the Quote
        // without one, which rejects every QuoteLineItem.
        Id standardPbId = Test.getStandardPricebookId();
        opp.Pricebook2Id = standardPbId;
        insert opp;

        // Name is not a usable handle: the org's quote-numbering automation overwrites
        // it on insert (Name comes back as '260091-QT-1' and the like). Each quote
        // therefore carries its label in Customer_PO_Reference__c — which survives the
        // insert and, unlike Description, is filterable — and the tests look themselves
        // up by that.
        Quote nonRampQuote = new Quote(Name = 'Non-Ramp Quote', Customer_PO_Reference__c = 'Non-Ramp Quote', OpportunityId = opp.Id, Pricebook2Id = standardPbId);
        Quote rampQuote    = new Quote(Name = 'Ramp Quote',     Customer_PO_Reference__c = 'Ramp Quote',     OpportunityId = opp.Id, Pricebook2Id = standardPbId);
        // RDD__c must be set, not just Contract_End_Date__c directly: the
        // Quote - Before Save - Contract End Date flow recomputes
        // Contract_End_Date__c = ADDMONTHS(RDD__c, Contract_Term_Months__c) - 1
        // on every save and BLANKS it when RDD__c is empty — a direct
        // Contract_End_Date__c assignment with no RDD__c gets silently
        // wiped back to null before this record is even committed.
        Quote tcvQuote     = new Quote(
            Name = 'TCV Quote', Customer_PO_Reference__c = 'TCV Quote', OpportunityId = opp.Id, Pricebook2Id = standardPbId,
            Contract_Term_Months__c = 36, RDD__c = Date.newInstance(2024, 1, 2) // -> Contract_End_Date__c = 2027-01-01
        );
        // Quotes for the linked-phase ordering tests. Contract_Term_Months__c is set on
        // the collision quote so TCV is exercised too (calculateTcv routes phase-prefix
        // slices back through familyTotal, so it inherits the same ordering question).
        Quote samePhaseQuote = new Quote(
            Name = 'Same Phase Reprice Quote', Customer_PO_Reference__c = 'Same Phase Reprice Quote',
            OpportunityId = opp.Id, Pricebook2Id = standardPbId,
            Contract_Term_Months__c = 12
        );
        Quote singleRepriceQuote = new Quote(Name = 'Single Reprice Quote', Customer_PO_Reference__c = 'Single Reprice Quote', OpportunityId = opp.Id, Pricebook2Id = standardPbId);
        Quote fanOutQuote        = new Quote(Name = 'Fan Out Quote',        Customer_PO_Reference__c = 'Fan Out Quote',        OpportunityId = opp.Id, Pricebook2Id = standardPbId);
        // Window from the Ramp_Start_Date__c below (2027-04-01) to Contract_End_Date__c
        // (2027-04-16) is a same-month, 15-of-30-day partial month — exercises the
        // day-aware fractionalMonthsBetween single-fragment branch.
        Quote dayAwareTcvQuote = new Quote(
            Name = 'Day Aware TCV Quote', Customer_PO_Reference__c = 'Day Aware TCV Quote',
            OpportunityId = opp.Id, Pricebook2Id = standardPbId,
            Contract_Term_Months__c = 1, RDD__c = Date.newInstance(2027, 3, 17) // -> Contract_End_Date__c = 2027-04-16
        );
        // Window from 2027-08-25 to Contract_End_Date__c (2027-09-10) crosses the
        // Aug(31)/Sep(30) boundary — exercises fractionalMonthsBetween's two-fragment
        // branch (6 days left in August + 10 days into September).
        Quote crossMonthTcvQuote = new Quote(
            Name = 'Cross Month TCV Quote', Customer_PO_Reference__c = 'Cross Month TCV Quote',
            OpportunityId = opp.Id, Pricebook2Id = standardPbId,
            Contract_Term_Months__c = 1, RDD__c = Date.newInstance(2027, 8, 11) // -> Contract_End_Date__c = 2027-09-10
        );
        // Client-confirmed backward-anchor example: 2026-10-15 to Contract_End_Date__c
        // 2028-09-30 must equal 23 + 15/31 (15 remaining days of October, a 31-day
        // month) — exercises the corrected backward-from-toDate anchor directly.
        Quote backwardAnchorQuote = new Quote(
            Name = 'Backward Anchor TCV Quote', Customer_PO_Reference__c = 'Backward Anchor TCV Quote',
            OpportunityId = opp.Id, Pricebook2Id = standardPbId,
            Contract_Term_Months__c = 1, RDD__c = Date.newInstance(2028, 9, 1) // -> Contract_End_Date__c = 2028-09-30
        );
        // Real-world regression (Quote 260206-QT-1): three ramp phases on the SAME
        // Merge_IB_Task__c aggregate product, qty 100/150/200, all Ramp_Identifier__c
        // = 'Add' with no linking — must be treated as cumulative (latest phase wins),
        // not summed as independent adds.
        Quote aggregateQuote = new Quote(
            Name = 'Aggregate Product Quote', Customer_PO_Reference__c = 'Aggregate Product Quote',
            OpportunityId = opp.Id, Pricebook2Id = standardPbId,
            Contract_Term_Months__c = 48, RDD__c = Date.newInstance(2026, 10, 1) // -> Contract_End_Date__c = 2030-09-30
        );

        insert new List<Quote>{ nonRampQuote, rampQuote, tcvQuote, samePhaseQuote, singleRepriceQuote, fanOutQuote, dayAwareTcvQuote, crossMonthTcvQuote, backwardAnchorQuote, aggregateQuote };

        Product2 cabinet   = new Product2(Name = 'Test Cabinet',  IsActive = true);
        Product2 usage     = new Product2(Name = 'Test Usage',    IsActive = true);
        Product2 product1  = new Product2(Name = 'Test Product1', IsActive = true);
        Product2 product2  = new Product2(Name = 'Test Product2', IsActive = true);
        Product2 product3  = new Product2(Name = 'Test Product3', IsActive = true);
        Product2 aggregate = new Product2(Name = 'Test Aggregate Hall', IsActive = true, Merge_IB_Task__c = true);
        insert new List<Product2>{ cabinet, usage, product1, product2, product3, aggregate };

        // This is a multi-currency org and the Quote's currency is derived by automation
        // from the Opportunity, not by us — a QuoteLineItem is rejected outright if its
        // PricebookEntry's currency differs. Read back what the quotes actually landed on
        // and mint the entries to match rather than guessing at the corporate default.
        String quoteCurrency = [SELECT CurrencyIsoCode FROM Quote WHERE Id = :nonRampQuote.Id].CurrencyIsoCode;

        List<PricebookEntry> pbes = new List<PricebookEntry>();
        for (Product2 p : new List<Product2>{ cabinet, usage, product1, product2, product3, aggregate }) {
            pbes.add(new PricebookEntry(Pricebook2Id = standardPbId, Product2Id = p.Id, UnitPrice = 0,
                IsActive = true, CurrencyIsoCode = quoteCurrency));
        }
        insert pbes;
    }

    @isTest
    static void testNonRampQuotePlainSum() {
        Quote q = [SELECT Id FROM Quote WHERE Customer_PO_Reference__c = 'Non-Ramp Quote' LIMIT 1];
        PricebookEntry pbe = [SELECT Id, Product2Id FROM PricebookEntry WHERE Product2.Name = 'Test Cabinet' LIMIT 1];

        List<QuoteLineItem> lines = new List<QuoteLineItem>{
            new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = pbe.Product2Id,
                Quantity = 2, UnitPrice = 1000, Charge_Type__c = 'MRC'),
            new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = pbe.Product2Id,
                Quantity = 1, UnitPrice = 500, Charge_Type__c = 'MRC')
        };

        Test.startTest();
        insert lines;
        Test.stopTest();

        Quote result = [SELECT Total_MRC_2__c FROM Quote WHERE Id = :q.Id];
        // 2*1000 + 1*500 = 2500 — identical to what the old plain-sum rollup would give.
        System.assertEquals(2500, result.Total_MRC_2__c, 'Non-ramp Total_MRC_2__c should be an unchanged plain sum');
    }

    @isTest
    static void testRampQuoteMatchesClientConfirmedTotal() {
        Quote q = [SELECT Id FROM Quote WHERE Customer_PO_Reference__c = 'Ramp Quote' LIMIT 1];
        PricebookEntry cabinetPbe = [SELECT Id, Product2Id FROM PricebookEntry WHERE Product2.Name = 'Test Cabinet' LIMIT 1];
        PricebookEntry usagePbe   = [SELECT Id, Product2Id FROM PricebookEntry WHERE Product2.Name = 'Test Usage' LIMIT 1];

        List<QuoteLineItem> lines = new List<QuoteLineItem>{
            // Cabinet: Phase 1 Add (1 @ 1,000,000), Phase 2 Add (2 @ 1,950,000),
            // Phase 3 Price_Change linked to Phase 1 (1 @ 1,950,000) — replaces Phase 1's amount.
            new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = cabinetPbe.Id, Product2Id = cabinetPbe.Product2Id,
                Quantity = 1, UnitPrice = 1000000, Charge_Type__c = 'MRC', Line_Origin__c = 'Ramp',
                Ramp_Phase__c = 1, Ramp_Identifier__c = 'Add'),
            new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = cabinetPbe.Id, Product2Id = cabinetPbe.Product2Id,
                Quantity = 2, UnitPrice = 1950000, Charge_Type__c = 'MRC', Line_Origin__c = 'Ramp',
                Ramp_Phase__c = 2, Ramp_Identifier__c = 'Add'),
            new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = cabinetPbe.Id, Product2Id = cabinetPbe.Product2Id,
                Quantity = 1, UnitPrice = 1950000, Charge_Type__c = 'MRC', Line_Origin__c = 'Ramp',
                Ramp_Phase__c = 3, Ramp_Identifier__c = 'Price_Change', Ramp_Linked_Phase__c = 1),

            // Usage-Based: cumulative commitment per phase — only Phase 3 (100,000 @ 18) should count.
            new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = usagePbe.Id, Product2Id = usagePbe.Product2Id,
                Quantity = 50000, UnitPrice = 18, Charge_Type__c = 'Usage-Based', Line_Origin__c = 'Ramp',
                Ramp_Phase__c = 1, Ramp_Identifier__c = 'Add'),
            new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = usagePbe.Id, Product2Id = usagePbe.Product2Id,
                Quantity = 75000, UnitPrice = 18, Charge_Type__c = 'Usage-Based', Line_Origin__c = 'Ramp',
                Ramp_Phase__c = 2, Ramp_Identifier__c = 'Add'),
            new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = usagePbe.Id, Product2Id = usagePbe.Product2Id,
                Quantity = 100000, UnitPrice = 18, Charge_Type__c = 'Usage-Based', Line_Origin__c = 'Ramp',
                Ramp_Phase__c = 3, Ramp_Identifier__c = 'Add')
        };

        Test.startTest();
        insert lines;
        Test.stopTest();

        Quote result = [SELECT Total_MRC_2__c FROM Quote WHERE Id = :q.Id];
        // Cabinet: 3,900,000 (Phase 2 Add) + 1,950,000 (Phase 3 replaces Phase 1) = 5,850,000
        // Usage:   1,800,000 (Phase 3 only, cumulative)
        // Total:   7,650,000 — matches the client-confirmed expected value for Quote 26000729-QT-1.
        System.assertEquals(7650000, result.Total_MRC_2__c, 'Ramp Total_MRC_2__c should match the client-confirmed total');
    }

    /**
     * Client's worked example: 36-month contract, one ramp per year (Ramp 1 @
     * month 0, Ramp 2 @ month 12, Ramp 3 @ month 24), A=100, B=150, C=200, D=300.
     *
     *   Product 1 (qty 5): Ramp 1 Add @ A, Ramp 3 Price_Change (linked to Ramp 1) @ B
     *   Product 2 (qty 3): Ramp 2 Add @ C only
     *   Product 3 (qty 1): Ramp 1 Add @ D, unchanged through Ramp 2/3 (Change-linked)
     *
     * Expected per the client:
     *   Opportunity MRC — Ramp1: 5A+1D=800, Ramp2: 3C=600, Ramp3: 5(B-A)=250
     *   Total_MRC_2__c (steady state) = 5B + 3C + 1D = 750 + 600 + 300 = 1650
     *
     * TCV was originally confirmed at 36*800 + 24*600 + 12*250 = 46200 under a
     * whole-months-only model. The 2026-09-03 day-summation correction sums
     * each touched calendar month's covered-days/length rather than treating
     * "day 1 to day 1, N years later" as a clean integer — e.g. Ramp 1's
     * window (2024-01-01 -> 2027-01-01) touches Jan 2024 through Jan 2027,
     * and not every one of those 37 months has 31 days, so it comes out to
     * 1117/31 (~36.032), not a clean 36. New TCV = 1433850/31 ≈ 46253.23.
     * This is expected under the confirmed model, not a regression.
     */
    @isTest
    static void testTcvMatchesClientWorkedExample() {
        Quote q = [SELECT Id FROM Quote WHERE Customer_PO_Reference__c = 'TCV Quote' LIMIT 1];
        PricebookEntry pbe1 = [SELECT Id, Product2Id FROM PricebookEntry WHERE Product2.Name = 'Test Product1' LIMIT 1];
        PricebookEntry pbe2 = [SELECT Id, Product2Id FROM PricebookEntry WHERE Product2.Name = 'Test Product2' LIMIT 1];
        PricebookEntry pbe3 = [SELECT Id, Product2Id FROM PricebookEntry WHERE Product2.Name = 'Test Product3' LIMIT 1];

        Date ramp1Start = Date.newInstance(2024, 1, 1); // 36 months before Contract_End_Date__c
        Date ramp2Start = Date.newInstance(2025, 1, 1); // 24 months before
        Date ramp3Start = Date.newInstance(2026, 1, 1); // 12 months before

        List<QuoteLineItem> lines = new List<QuoteLineItem>{
            // Product 1: qty 5, A=100 at Ramp 1, price change to B=150 at Ramp 3.
            new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = pbe1.Id, Product2Id = pbe1.Product2Id,
                Quantity = 5, UnitPrice = 100, Charge_Type__c = 'MRC', Line_Origin__c = 'Ramp',
                Ramp_Phase__c = 1, Ramp_Identifier__c = 'Add', Ramp_Start_Date__c = ramp1Start),
            new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = pbe1.Id, Product2Id = pbe1.Product2Id,
                Quantity = 5, UnitPrice = 150, Charge_Type__c = 'MRC', Line_Origin__c = 'Ramp',
                Ramp_Phase__c = 3, Ramp_Identifier__c = 'Price_Change', Ramp_Linked_Phase__c = 1, Ramp_Start_Date__c = ramp3Start),

            // Product 2: qty 3, C=200, added fresh at Ramp 2 only.
            new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = pbe2.Id, Product2Id = pbe2.Product2Id,
                Quantity = 3, UnitPrice = 200, Charge_Type__c = 'MRC', Line_Origin__c = 'Ramp',
                Ramp_Phase__c = 2, Ramp_Identifier__c = 'Add', Ramp_Start_Date__c = ramp2Start),

            // Product 3: qty 1, D=300, unchanged — Ramp 2/3 are Change-linked back to Ramp 1.
            new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = pbe3.Id, Product2Id = pbe3.Product2Id,
                Quantity = 1, UnitPrice = 300, Charge_Type__c = 'MRC', Line_Origin__c = 'Ramp',
                Ramp_Phase__c = 1, Ramp_Identifier__c = 'Add', Ramp_Start_Date__c = ramp1Start),
            new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = pbe3.Id, Product2Id = pbe3.Product2Id,
                Quantity = 1, UnitPrice = 300, Charge_Type__c = 'MRC', Line_Origin__c = 'Ramp',
                Ramp_Phase__c = 2, Ramp_Identifier__c = 'Change', Ramp_Linked_Phase__c = 1, Ramp_Start_Date__c = ramp2Start),
            new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = pbe3.Id, Product2Id = pbe3.Product2Id,
                Quantity = 1, UnitPrice = 300, Charge_Type__c = 'MRC', Line_Origin__c = 'Ramp',
                Ramp_Phase__c = 3, Ramp_Identifier__c = 'Change', Ramp_Linked_Phase__c = 1, Ramp_Start_Date__c = ramp3Start)
        };

        Test.startTest();
        insert lines;
        Test.stopTest();

        Quote result = [SELECT Total_MRC_2__c, Total_Contract_Value_2__c FROM Quote WHERE Id = :q.Id];
        System.assertEquals(1650, result.Total_MRC_2__c, 'Steady-state Total_MRC_2__c should be 5B+3C+1D = 1650');
        System.assertEquals(46253.23, result.Total_Contract_Value_2__c, 'TCV should match the day-summation total of 1433850/31 (~46253.23)');
    }

    /**
     * Two repricing phases targeting the SAME earlier phase — the shape the "link all
     * phases" feature makes routine. Both Phase 2 and Phase 3 are linked to Phase 1,
     * so both write to the same bucket and only the last one applied survives; the
     * latest phase (3) must win. The Phase 3 line is inserted BEFORE the Phase 2 line
     * on purpose: recalculate()'s query has no ORDER BY, so an implementation that
     * applied overrides in SOQL order would leave Phase 2's 1200 standing and fail.
     */
    @isTest
    static void testLatestPhaseWinsWhenTwoRepricesTargetSamePhase() {
        Quote q = [SELECT Id FROM Quote WHERE Customer_PO_Reference__c = 'Same Phase Reprice Quote' LIMIT 1];
        PricebookEntry pbe = [SELECT Id, Product2Id FROM PricebookEntry WHERE Product2.Name = 'Test Cabinet' LIMIT 1];

        List<QuoteLineItem> lines = new List<QuoteLineItem>{
            new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = pbe.Product2Id,
                Quantity = 1, UnitPrice = 1000, Charge_Type__c = 'MRC', Line_Origin__c = 'Ramp',
                Ramp_Phase__c = 1, Ramp_Identifier__c = 'Add'),
            // Deliberately out of phase order — Phase 3 first, then Phase 2.
            new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = pbe.Product2Id,
                Quantity = 1, UnitPrice = 1500, Charge_Type__c = 'MRC', Line_Origin__c = 'Ramp',
                Ramp_Phase__c = 3, Ramp_Identifier__c = 'Price_Change', Ramp_Linked_Phase__c = 1),
            new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = pbe.Product2Id,
                Quantity = 1, UnitPrice = 1200, Charge_Type__c = 'MRC', Line_Origin__c = 'Ramp',
                Ramp_Phase__c = 2, Ramp_Identifier__c = 'Price_Change', Ramp_Linked_Phase__c = 1)
        };

        Test.startTest();
        insert lines;
        Test.stopTest();

        Quote result = [SELECT Total_MRC_2__c, Total_Contract_Value_2__c FROM Quote WHERE Id = :q.Id];
        // Phase 1 starts at 1000, Phase 2 reprices it to 1200, Phase 3 reprices it to
        // 1500 — the last reprice standing. Unsorted (SOQL order) this would be 1200.
        System.assertEquals(1500, result.Total_MRC_2__c, 'The latest linked phase should win when two reprices target one phase');
        // No Ramp_Start_Date__c on any line, so every phase gets the full 12-month term:
        // deltas 1000 + 200 + 300 = 1500, each * 12 = 18000. Same ordering, via calculateTcv.
        System.assertEquals(18000, result.Total_Contract_Value_2__c, 'TCV should use the same latest-phase-wins ordering as Total_MRC_2__c');
    }

    /**
     * Regression: a single reprice is untouched by the ordering fix — one linked line
     * has nothing to collide with, so it simply replaces its target phase's amount.
     */
    @isTest
    static void testSingleRepriceUnchanged() {
        Quote q = [SELECT Id FROM Quote WHERE Customer_PO_Reference__c = 'Single Reprice Quote' LIMIT 1];
        PricebookEntry pbe = [SELECT Id, Product2Id FROM PricebookEntry WHERE Product2.Name = 'Test Cabinet' LIMIT 1];

        List<QuoteLineItem> lines = new List<QuoteLineItem>{
            new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = pbe.Product2Id,
                Quantity = 2, UnitPrice = 100, Charge_Type__c = 'MRC', Line_Origin__c = 'Ramp',
                Ramp_Phase__c = 1, Ramp_Identifier__c = 'Add'),
            new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = pbe.Product2Id,
                Quantity = 2, UnitPrice = 150, Charge_Type__c = 'MRC', Line_Origin__c = 'Ramp',
                Ramp_Phase__c = 2, Ramp_Identifier__c = 'Price_Change', Ramp_Linked_Phase__c = 1)
        };

        Test.startTest();
        insert lines;
        Test.stopTest();

        Quote result = [SELECT Total_MRC_2__c FROM Quote WHERE Id = :q.Id];
        // Phase 2 (2 * 150 = 300) replaces Phase 1's 200 — one bucket, one override.
        System.assertEquals(300, result.Total_MRC_2__c, 'A single reprice should still simply replace its linked phase');
    }

    /**
     * Regression: the fan-out shape the "link all phases" feature produces — one
     * repricing phase with a separate line per earlier phase. Every override targets a
     * DIFFERENT phase, so there is no collision and the sort must leave the result
     * alone: all three Adds are repriced, none of them swallow each other.
     */
    @isTest
    static void testFanOutToDistinctPhasesUnchanged() {
        Quote q = [SELECT Id FROM Quote WHERE Customer_PO_Reference__c = 'Fan Out Quote' LIMIT 1];
        PricebookEntry pbe = [SELECT Id, Product2Id FROM PricebookEntry WHERE Product2.Name = 'Test Cabinet' LIMIT 1];

        List<QuoteLineItem> lines = new List<QuoteLineItem>();
        // Phases 1-3: 2 units @ 100 added at each phase.
        for (Integer phase = 1; phase <= 3; phase++) {
            lines.add(new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = pbe.Product2Id,
                Quantity = 2, UnitPrice = 100, Charge_Type__c = 'MRC', Line_Origin__c = 'Ramp',
                Ramp_Phase__c = phase, Ramp_Identifier__c = 'Add'));
        }
        // Phase 4: one repricing line per earlier phase, all 2 units @ 120.
        for (Integer linked = 1; linked <= 3; linked++) {
            lines.add(new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = pbe.Product2Id,
                Quantity = 2, UnitPrice = 120, Charge_Type__c = 'MRC', Line_Origin__c = 'Ramp',
                Ramp_Phase__c = 4, Ramp_Identifier__c = 'Price_Change', Ramp_Linked_Phase__c = linked));
        }

        Test.startTest();
        insert lines;
        Test.stopTest();

        Quote result = [SELECT Total_MRC_2__c FROM Quote WHERE Id = :q.Id];
        // Each of phases 1/2/3 ends up at 2 * 120 = 240 — 6 units at 120 = 720 total.
        System.assertEquals(720, result.Total_MRC_2__c, 'Fan-out to distinct phases should reprice all three, not collapse to one');
    }

    /**
     * 2026-08-26 client request (day-summation formula corrected 2026-09-03):
     * TCV must not drop a partial month's leftover days. Window is
     * 2027-04-01 to Contract_End_Date__c 2027-04-16, entirely within one
     * calendar month (April, 30 days). Both endpoints are counted, so
     * covered days = 16 - 1 + 1 = 16 -> 16/30 of a month. TCV = 200 * 16/30
     * = 3200/30 ≈ 106.67 — a value a whole-months-only calc would have
     * flattened to 0.
     */
    @isTest
    static void testTcvCreditsPartialMonthWithinOneCalendarMonth() {
        Quote q = [SELECT Id FROM Quote WHERE Customer_PO_Reference__c = 'Day Aware TCV Quote' LIMIT 1];
        PricebookEntry pbe = [SELECT Id, Product2Id FROM PricebookEntry WHERE Product2.Name = 'Test Cabinet' LIMIT 1];

        QuoteLineItem line = new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = pbe.Product2Id,
            Quantity = 1, UnitPrice = 200, Charge_Type__c = 'MRC', Line_Origin__c = 'Ramp',
            Ramp_Phase__c = 1, Ramp_Identifier__c = 'Add', Ramp_Start_Date__c = Date.newInstance(2027, 4, 1));

        Test.startTest();
        insert line;
        Test.stopTest();

        Quote result = [SELECT Total_MRC_2__c, Total_Contract_Value_2__c FROM Quote WHERE Id = :q.Id];
        System.assertEquals(200, result.Total_MRC_2__c, 'Steady-state MRC is unaffected — only TCV is day-aware');
        System.assertEquals(106.67, result.Total_Contract_Value_2__c, 'TCV should credit the partial 16/30 month (both endpoints counted), not flatten it to 0 whole months');
    }

    /**
     * 2026-08-26 client request (day-summation formula corrected 2026-09-03):
     * a leftover that crosses a month boundary splits into two fragments,
     * each weighted by ITS OWN month's length. Window is 2027-08-25 to
     * Contract_End_Date__c 2027-09-10, both endpoints counted: 7 days of
     * August (25,26,...,31 = 7, out of 31) + 10 days of September (1..10,
     * out of 30). delta 930 = 93*10 (93 = LCM-friendly multiple of both
     * fragments' combined denominator) makes it cancel cleanly:
     * 930*(7/31 + 10/30) = 930*52/93 = 520.
     */
    @isTest
    static void testTcvSplitsLeftoverAcrossTwoDifferentLengthMonths() {
        Quote q = [SELECT Id FROM Quote WHERE Customer_PO_Reference__c = 'Cross Month TCV Quote' LIMIT 1];
        PricebookEntry pbe = [SELECT Id, Product2Id FROM PricebookEntry WHERE Product2.Name = 'Test Cabinet' LIMIT 1];

        QuoteLineItem line = new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = pbe.Product2Id,
            Quantity = 1, UnitPrice = 930, Charge_Type__c = 'MRC', Line_Origin__c = 'Ramp',
            Ramp_Phase__c = 1, Ramp_Identifier__c = 'Add', Ramp_Start_Date__c = Date.newInstance(2027, 8, 25));

        Test.startTest();
        insert line;
        Test.stopTest();

        Quote result = [SELECT Total_MRC_2__c, Total_Contract_Value_2__c FROM Quote WHERE Id = :q.Id];
        System.assertEquals(930, result.Total_MRC_2__c, 'Steady-state MRC is unaffected — only TCV is day-aware');
        System.assertEquals(520, result.Total_Contract_Value_2__c, 'TCV should split the leftover across August and September by each month\'s own length, both endpoints counted');
    }

    /**
     * 2026-09-03 correction: client-confirmed day-summation example.
     * 2026-10-15 to Contract_End_Date__c 2028-09-30: October contributes
     * Oct 15-31 inclusive = 17 days out of 31 (both endpoints counted), then
     * 22 full months (Nov 2026 - Aug 2028), then September 2028 is a FULL
     * month (Sep 30 is the last day of September, so day-count = 30/30 = 1).
     * Total = 17/31 + 22 + 1 = 23 + 17/31 = 730/31. delta 31 makes it cancel
     * cleanly: 31 * 730/31 = 730.
     */
    @isTest
    static void testTcvAnchorsLeftoverAgainstStartMonthNotEndMonth() {
        Quote q = [SELECT Id FROM Quote WHERE Customer_PO_Reference__c = 'Backward Anchor TCV Quote' LIMIT 1];
        PricebookEntry pbe = [SELECT Id, Product2Id FROM PricebookEntry WHERE Product2.Name = 'Test Cabinet' LIMIT 1];

        QuoteLineItem line = new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = pbe.Product2Id,
            Quantity = 1, UnitPrice = 31, Charge_Type__c = 'MRC', Line_Origin__c = 'Ramp',
            Ramp_Phase__c = 1, Ramp_Identifier__c = 'Add', Ramp_Start_Date__c = Date.newInstance(2026, 10, 15));

        Test.startTest();
        insert line;
        Test.stopTest();

        Quote result = [SELECT Total_Contract_Value_2__c FROM Quote WHERE Id = :q.Id];
        System.assertEquals(730, result.Total_Contract_Value_2__c, 'TCV should day-sum every touched month, both endpoints counted');
    }

    /**
     * Real-world regression (Quote 260206-QT-1): a Merge_IB_Task__c aggregate
     * product ramping 100 -> 150 -> 200 units across three 'Add' phases, none
     * linked to each other, must be treated as cumulative (latest phase's own
     * amount is the steady state; each phase's delta is the difference from
     * the phase before it) — the same rule OrderMrcRollupService already
     * applies via isAggregateByProduct, now mirrored here via
     * Product2.Merge_IB_Task__c.
     *
     *   Phase 1: 100 * 100 = 10,000 (fresh)      -> delta 10,000
     *   Phase 2: 150 * 100 = 15,000               -> delta  5,000
     *   Phase 3: 200 * 100 = 20,000 (steady state) -> delta  5,000
     *
     * Under the 2026-09-03 day-summation model this comes out to exactly
     * 48 / 46 / 44 months respectively — Contract_End_Date__c (2030-09-30)
     * is the LAST day of September, so both the first month (Oct 2026, fully
     * covered from day 1) and the last month (Sep 2030, fully covered
     * through its last day) land as clean whole months, with every month in
     * between also whole. TCV = 10000*48 + 5000*46 + 5000*44 = 930000 —
     * this matches the client's own original illustrative formula exactly.
     */
    @isTest
    static void testAggregateProductUsesConsecutivePhaseDelta() {
        Quote q = [SELECT Id FROM Quote WHERE Customer_PO_Reference__c = 'Aggregate Product Quote' LIMIT 1];
        PricebookEntry pbe = [SELECT Id, Product2Id FROM PricebookEntry WHERE Product2.Name = 'Test Aggregate Hall' LIMIT 1];

        List<QuoteLineItem> lines = new List<QuoteLineItem>{
            new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = pbe.Product2Id,
                Quantity = 100, UnitPrice = 100, Charge_Type__c = 'MRC', Line_Origin__c = 'Ramp',
                Ramp_Phase__c = 1, Ramp_Identifier__c = 'Add', Ramp_Start_Date__c = Date.newInstance(2026, 10, 1)),
            new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = pbe.Product2Id,
                Quantity = 150, UnitPrice = 100, Charge_Type__c = 'MRC', Line_Origin__c = 'Ramp',
                Ramp_Phase__c = 2, Ramp_Identifier__c = 'Add', Ramp_Start_Date__c = Date.newInstance(2026, 12, 1)),
            new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = pbe.Product2Id,
                Quantity = 200, UnitPrice = 100, Charge_Type__c = 'MRC', Line_Origin__c = 'Ramp',
                Ramp_Phase__c = 3, Ramp_Identifier__c = 'Add', Ramp_Start_Date__c = Date.newInstance(2027, 2, 1))
        };

        Test.startTest();
        insert lines;
        Test.stopTest();

        Quote result = [SELECT Total_MRC_2__c, Total_Contract_Value_2__c FROM Quote WHERE Id = :q.Id];
        System.assertEquals(20000, result.Total_MRC_2__c, 'Steady-state MRC for an aggregate product is the LAST phase\'s own amount, not the sum of all three');

        // Deltas 10,000 / 5,000 / 5,000, each weighted by its own day-aware
        // remaining term to Contract_End_Date__c (2030-09-30) — 48 / 46 / 44
        // exactly (see class doc), so TCV = 10000*48 + 5000*46 + 5000*44 = 930000.
        System.assertEquals(930000, result.Total_Contract_Value_2__c, 'TCV should use consecutive-phase deltas (10000/5000/5000) weighted by 48/46/44 months, not independent-add deltas (10000/15000/20000)');
    }
}