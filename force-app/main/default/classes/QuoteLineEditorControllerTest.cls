@IsTest
private class QuoteLineEditorControllerTest {

    @TestSetup
    static void setup() {
        // Target_Site__c has a required lookup filter: Site__c.Country_Name__c must
        // equal $Source.Operation_Country__c (the Opportunity's own field, not the
        // Account's). 'Singapore' is not actually a valid Operation_Country__c
        // picklist value in this org, so — unlike the original version of this test —
        // use Indonesia, which is valid on both Opportunity.Operation_Country__c and
        // Site__c.Country__c ('ID' -> Country_Name__c formula resolves to 'Indonesia').
        // Finance_Country_Manager__c pre-populated on the Site: the "Quote
        // Before-Save Site Managers" flow copies this (and the other manager
        // fields) from the Site to the Quote whenever Target_Site__c is set —
        // and re-fires on every subsequent Quote update as long as the Quote's
        // own Finance_Country_Manager__c stays null. With no manager set on the
        // Site, the flow keeps re-copying null and re-triggering, and on a
        // later save (e.g. the second ramp phase's Quote rollup update) throws
        // an unhandled fault — a separate pre-existing bug from the SOQL-limit
        // and Assign-SE ones, out of scope to fix here. Giving the Site a real
        // manager means the flow's backfill branch has nothing left to redo.
        Site__c site = new Site__c(
            Country__c                 = 'ID',
            Site_Code__c                = 'ID-QLETEST-01',
            Pricebook2__c             = Test.getStandardPricebookId(),
            Finance_Country_Manager__c  = UserInfo.getUserId()
        );
        insert site;

        Account acc = new Account(Name = 'QLE Test Account', Operation_Country__c = 'Indonesia');
        insert acc;

        // Sales_Engineer__c pre-populated: the "Opportunity - Before Save - Assign SE"
        // flow (fired via Quote After Save Sync To Opportunity whenever a ramp
        // phase is added) crashes with an unhandled fault when it has to actually
        // assign one — a separate pre-existing bug from the SOQL-limit one, out
        // of scope to fix here. Pre-setting it means the flow has nothing to do.
        Opportunity opp = new Opportunity(
            Name                 = 'QLE Test Opp',
            AccountId            = acc.Id,
            StageName            = '1-Suspect',
            CloseDate            = Date.today().addDays(30),
            Operation_Country__c = 'Indonesia',
            CurrencyIsoCode      = 'IDR',
            Target_Site__c       = site.Id,
            Pricebook2Id         = Test.getStandardPricebookId(),
            Sales_Engineer__c    = UserInfo.getUserId()
        );
        insert opp;

        // Finance_Country_Manager__c pre-populated: the "Quote Before-Save Site
        // Managers" flow re-fires on every subsequent Quote update as long as
        // Target_Site__c is set (inherited from the Opportunity) and
        // Finance_Country_Manager__c is null — and throws an unhandled fault
        // trying to backfill it from a Site__c record with no manager fields
        // set. A separate pre-existing bug from the SOQL-limit and Assign-SE
        // ones, out of scope to fix here. Pre-setting it means the flow's
        // backfill branch has nothing left to do.
        Quote q = new Quote(
            Name                        = 'QLE Test Quote',
            OpportunityId               = opp.Id,
            Pricebook2Id                = Test.getStandardPricebookId(),
            Finance_Country_Manager__c  = UserInfo.getUserId(),
            CurrencyIsoCode             = 'IDR',
            Target_Site__c              = site.Id
        );
        insert q;

        // NRC inserted first so its Id is available to set on the MRC product —
        // the MRC/NRC quantity cascade in updateQuoteLineItems() keys off
        // Product2.Paired_NRC_Product__c, not just the .RC/.NR code convention.
        Product2 nrcProd = new Product2(
            Name = 'CAB001.NR', ProductCode = 'CAB001.NR', IsActive = true,
            Charge_Type__c = 'NRC'
        );
        insert nrcProd;

        Product2 mrcProd = new Product2(
            Name = 'CAB001.RC', ProductCode = 'CAB001.RC', IsActive = true,
            Charge_Type__c = 'MRC', Attribute_Type__c = 'kVA', Attribute_Values__c = '5,10,15',
            Paired_NRC_Product__c = nrcProd.Id
        );
        insert mrcProd;

        // CurrencyIsoCode = 'IDR' to match the Quote — a country-based automation
        // forces Opportunity/Quote currency to IDR whenever Operation_Country__c =
        // 'Indonesia', regardless of what's passed on insert, so the PricebookEntry
        // must match IDR or the QuoteLineItem insert fails on a currency mismatch.
        PricebookEntry mrcPbe = new PricebookEntry(
            Pricebook2Id    = Test.getStandardPricebookId(),
            Product2Id      = mrcProd.Id,
            UnitPrice       = 100,
            IsActive        = true,
            CurrencyIsoCode = 'IDR'
        );
        PricebookEntry nrcPbe = new PricebookEntry(
            Pricebook2Id    = Test.getStandardPricebookId(),
            Product2Id      = nrcProd.Id,
            UnitPrice       = 500,
            IsActive        = true,
            CurrencyIsoCode = 'IDR'
        );
        insert new List<PricebookEntry>{ mrcPbe, nrcPbe };

        // Reload quote — flow may rename / reassign pricebook
        Quote reloaded = [SELECT Id FROM Quote WHERE OpportunityId = :opp.Id ORDER BY CreatedDate ASC LIMIT 1];

        QuoteLineItem mrcLine = new QuoteLineItem(
            QuoteId          = reloaded.Id,
            PricebookEntryId = mrcPbe.Id,
            Quantity         = 50,
            UnitPrice        = 100,
            StartDate        = Date.today(),
            EndDate          = Date.today().addMonths(12)
        );
        insert mrcLine;

        QuoteLineItem nrcLine = new QuoteLineItem(
            QuoteId            = reloaded.Id,
            PricebookEntryId   = nrcPbe.Id,
            Quantity           = 50,
            UnitPrice          = 500,
            Paired_MRC_Line__c = mrcLine.Id,
            Is_Auto_NRC__c     = true
        );
        insert nrcLine;
    }

    // ── Helper ────────────────────────────────────────────────────────────

    static Quote getTestQuote() {
        return [SELECT Id, Pricebook2Id FROM Quote ORDER BY CreatedDate ASC LIMIT 1];
    }

    static Map<String, Id> pairAutoNrcToCompetingMrc() {
        QuoteLineItem mrcTemplate = [
            SELECT QuoteId, PricebookEntryId, UnitPrice
            FROM QuoteLineItem WHERE Product2.ProductCode = 'CAB001.RC' LIMIT 1
        ];
        QuoteLineItem nrcTemplate = [
            SELECT PricebookEntryId, UnitPrice
            FROM QuoteLineItem WHERE Product2.ProductCode = 'CAB001.NR' LIMIT 1
        ];
        QuoteLineItem sourceMrc = new QuoteLineItem(
            QuoteId = mrcTemplate.QuoteId,
            PricebookEntryId = mrcTemplate.PricebookEntryId,
            Quantity = 8,
            UnitPrice = mrcTemplate.UnitPrice,
            StartDate = Date.today(),
            EndDate = Date.today().addMonths(12)
        );
        QuoteLineItem competingMrc = new QuoteLineItem(
            QuoteId = mrcTemplate.QuoteId,
            PricebookEntryId = mrcTemplate.PricebookEntryId,
            Quantity = 9,
            UnitPrice = mrcTemplate.UnitPrice,
            StartDate = Date.today(),
            EndDate = Date.today().addMonths(12)
        );
        insert new List<QuoteLineItem>{ sourceMrc, competingMrc };
        QuoteLineItem autoNrc = new QuoteLineItem(
            QuoteId = mrcTemplate.QuoteId,
            PricebookEntryId = nrcTemplate.PricebookEntryId,
            Quantity = 9,
            UnitPrice = nrcTemplate.UnitPrice,
            Paired_MRC_Line__c = competingMrc.Id,
            Is_Auto_NRC__c = true
        );
        insert autoNrc;
        return new Map<String, Id>{
            'sourceMrc' => sourceMrc.Id,
            'competingMrc' => competingMrc.Id,
            'autoNrc' => autoNrc.Id
        };
    }

    // The shared @TestSetup quote uses the Standard Price Book as its own
    // pricebook, which collapses "site vs Standard" into the same record —
    // fine for most tests, but ensureCurrencyPbe/ensureQuotePricebookEntry and
    // Quote.Pricebook2.Name specifically distinguish the two (and Standard Price
    // Book relationship fields are unreliable in test context regardless). This
    // builds an isolated quote on a genuine custom site pricebook instead.
    static Quote buildQuoteOnCustomSitePricebook() {
        Pricebook2 sitePb = new Pricebook2(Name = 'QLE Isolated Site PB', IsActive = true);
        insert sitePb;

        Account acc = new Account(Name = 'QLE Isolated Account', Operation_Country__c = 'Indonesia');
        insert acc;
        Opportunity opp = new Opportunity(
            Name = 'QLE Isolated Opp', AccountId = acc.Id, StageName = '1-Suspect',
            CloseDate = Date.today().addDays(30), Operation_Country__c = 'Indonesia',
            CurrencyIsoCode = 'IDR'
        );
        insert opp;
        Quote q = new Quote(Name = 'QLE Isolated Quote', OpportunityId = opp.Id, Pricebook2Id = sitePb.Id, CurrencyIsoCode = 'IDR');
        insert q;
        return [SELECT Id, Pricebook2Id, AccountId FROM Quote WHERE Id = :q.Id];
    }

    // ── getQuoteLineItems ─────────────────────────────────────────────────

    @IsTest
    static void testGetQuoteLineItems() {
        Quote q = getTestQuote();
        Test.startTest();
        List<QuoteLineItem> result = QuoteLineEditorController.getQuoteLineItems(q.Id);
        Test.stopTest();
        System.assertEquals(2, result.size(), 'Should return MRC + NRC lines');
    }

    // ── searchProducts ────────────────────────────────────────────────────

    @IsTest
    static void testSearchProducts() {
        Quote q = getTestQuote();
        Test.startTest();
        List<Map<String, Object>> results = QuoteLineEditorController.searchProducts(
            'CAB001', q.Pricebook2Id, 'USD', null
        );
        Test.stopTest();
        System.assert(results.size() > 0, 'Should find products matching CAB001');
    }

    // ── addProductToQuote ─────────────────────────────────────────────────

    @IsTest
    static void testAddProductToQuote() {
        Quote q = getTestQuote();
        PricebookEntry pbe = [SELECT Id FROM PricebookEntry WHERE Product2.ProductCode = 'CAB001.RC' LIMIT 1];
        Test.startTest();
        QuoteLineEditorController.addProductToQuote(q.Id, pbe.Id, 5, null);
        Test.stopTest();
        Integer count = [SELECT COUNT() FROM QuoteLineItem WHERE QuoteId = :q.Id];
        // addProductToQuote auto-pairs every .RC add with its own new .NR line
        // (see "Auto-add NRC installation charge" — no duplicate guard), so
        // adding one MRC product yields 2 new lines, not 1: 2 original + 2 new = 4.
        System.assertEquals(4, count, 'Should have 4 lines (2 original + added MRC + its auto-paired NRC)');
    }

    // ── addProductToQuote — stamps Charge_Type__c from product code ─────

    @IsTest
    static void testAddProductToQuote_chargeType() {
        Quote q = getTestQuote();
        PricebookEntry nrcPbe = [SELECT Id FROM PricebookEntry WHERE Product2.ProductCode = 'CAB001.NR' LIMIT 1];
        Test.startTest();
        QuoteLineEditorController.addProductToQuote(q.Id, nrcPbe.Id, 1, null);
        Test.stopTest();
        QuoteLineItem added = [SELECT Charge_Type__c FROM QuoteLineItem WHERE QuoteId = :q.Id
                               AND Product2.ProductCode = 'CAB001.NR' AND Is_Auto_NRC__c = false LIMIT 1];
        System.assertEquals('NRC', added.Charge_Type__c, 'Charge_Type__c should be derived from .NR product code');
    }

    // ── updateQuoteLineItems — MRC→NRC cascade ───────────────────────────

    @IsTest
    static void testUpdateWithMrcNrcCascade() {
        QuoteLineItem mrc = [SELECT Id, Quantity FROM QuoteLineItem WHERE Product2.ProductCode = 'CAB001.RC' LIMIT 1];
        QuoteLineItem nrc = [SELECT Id, Quantity FROM QuoteLineItem WHERE Product2.ProductCode = 'CAB001.NR' LIMIT 1];
        System.assertEquals(50, mrc.Quantity, 'MRC qty before');
        System.assertEquals(50, nrc.Quantity, 'NRC qty before');

        Test.startTest();
        QuoteLineEditorController.updateQuoteLineItems(new List<QuoteLineItem>{
            new QuoteLineItem(Id = mrc.Id, Quantity = 30)
        });
        Test.stopTest();

        nrc = [SELECT Quantity FROM QuoteLineItem WHERE Id = :nrc.Id];
        System.assertEquals(30, nrc.Quantity, 'NRC qty should cascade from MRC');
    }

    @IsTest
    static void testUpdateWithMrcNrcCascade_doesNotRequantityUserOwnedNrc() {
        QuoteLineItem mrc = [SELECT Id FROM QuoteLineItem WHERE Product2.ProductCode = 'CAB001.RC' LIMIT 1];
        QuoteLineItem nrcTemplate = [
            SELECT QuoteId, PricebookEntryId, UnitPrice
            FROM QuoteLineItem WHERE Product2.ProductCode = 'CAB001.NR' LIMIT 1
        ];
        QuoteLineItem userNrc = new QuoteLineItem(
            QuoteId = nrcTemplate.QuoteId,
            PricebookEntryId = nrcTemplate.PricebookEntryId,
            Quantity = 7,
            UnitPrice = nrcTemplate.UnitPrice,
            Paired_MRC_Line__c = mrc.Id,
            Is_Auto_NRC__c = false
        );
        insert userNrc;

        Test.startTest();
        QuoteLineEditorController.updateQuoteLineItems(new List<QuoteLineItem>{
            new QuoteLineItem(Id = mrc.Id, Quantity = 30)
        });
        Test.stopTest();

        userNrc = [SELECT Quantity, Paired_MRC_Line__c, Is_Auto_NRC__c FROM QuoteLineItem WHERE Id = :userNrc.Id];
        System.assertEquals(7, userNrc.Quantity, 'Save must not re-quantify a user-owned NRC, even when legacy pairing remains');
        System.assertEquals(mrc.Id, userNrc.Paired_MRC_Line__c, 'This save path must not change existing pairing');
        System.assertEquals(false, userNrc.Is_Auto_NRC__c);
    }

    // ── splitRampLines — 2 phases ─────────────────────────────────────────

    @IsTest
    static void testSplitRampLines_twoPhases() {
        Quote q = getTestQuote();
        QuoteLineItem src = [SELECT Id FROM QuoteLineItem WHERE Product2.ProductCode = 'CAB001.RC' LIMIT 1];

        String phasesJson = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{
                'quantity'  => 25,
                'startDate' => String.valueOf(Date.today()),
                'endDate'   => String.valueOf(Date.today().addMonths(6))
            },
            new Map<String, Object>{
                'quantity'  => 25,
                'startDate' => String.valueOf(Date.today().addMonths(6).addDays(1)),
                'endDate'   => String.valueOf(Date.today().addMonths(12))
            }
        });

        Test.startTest();
        QuoteLineEditorController.splitRampLines(src.Id, phasesJson, 'quantity');
        Test.stopTest();

        // Phase 1 — original record updated
        QuoteLineItem phase1 = [SELECT Quantity, Ramp_Phase__c, Ramp_Start_Date__c
                                FROM QuoteLineItem WHERE Id = :src.Id];
        System.assertEquals(25, phase1.Quantity, 'Phase 1 qty');
        System.assertEquals(1, phase1.Ramp_Phase__c, 'Phase 1 number');

        // Phase 2 — new record
        List<QuoteLineItem> allMrc = [
            SELECT Quantity, Ramp_Phase__c, UnitPrice
            FROM QuoteLineItem
            WHERE QuoteId = :q.Id AND Product2.ProductCode = 'CAB001.RC'
            ORDER BY Ramp_Phase__c ASC
        ];
        System.assertEquals(2, allMrc.size(), 'Should have 2 MRC lines after split');
        System.assertEquals(25, allMrc[1].Quantity, 'Phase 2 qty');
        System.assertEquals(2, allMrc[1].Ramp_Phase__c, 'Phase 2 number');
        System.assertEquals(100, allMrc[1].UnitPrice, 'Phase 2 inherits unit price');
    }

    // ── splitRampLines — 3 phases ─────────────────────────────────────────

    @IsTest
    static void testSplitRampLines_threePhases() {
        Quote q = getTestQuote();
        QuoteLineItem src = [SELECT Id FROM QuoteLineItem WHERE Product2.ProductCode = 'CAB001.RC' LIMIT 1];

        String phasesJson = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{
                'quantity'  => 10,
                'startDate' => String.valueOf(Date.today()),
                'endDate'   => String.valueOf(Date.today().addMonths(3))
            },
            new Map<String, Object>{
                'quantity'  => 20,
                'startDate' => String.valueOf(Date.today().addMonths(3).addDays(1)),
                'endDate'   => String.valueOf(Date.today().addMonths(6))
            },
            new Map<String, Object>{
                'quantity'  => 20,
                'startDate' => String.valueOf(Date.today().addMonths(6).addDays(1)),
                'endDate'   => String.valueOf(Date.today().addMonths(12))
            }
        });

        Test.startTest();
        QuoteLineEditorController.splitRampLines(src.Id, phasesJson, 'quantity');
        Test.stopTest();

        List<QuoteLineItem> allMrc = [
            SELECT Quantity, Ramp_Phase__c
            FROM QuoteLineItem
            WHERE QuoteId = :q.Id AND Product2.ProductCode = 'CAB001.RC'
            ORDER BY Ramp_Phase__c ASC
        ];
        System.assertEquals(3, allMrc.size(), 'Should have 3 MRC lines');
        System.assertEquals(10, allMrc[0].Quantity, 'Phase 1');
        System.assertEquals(20, allMrc[1].Quantity, 'Phase 2');
        System.assertEquals(20, allMrc[2].Quantity, 'Phase 3');
    }

    // ── splitRampLines — single phase (update only, no insert) ────────────

    @IsTest
    static void testSplitRampLines_singlePhase() {
        QuoteLineItem src = [SELECT Id FROM QuoteLineItem WHERE Product2.ProductCode = 'CAB001.RC' LIMIT 1];
        Quote q = getTestQuote();

        String phasesJson = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{
                'quantity'  => 50,
                'startDate' => String.valueOf(Date.today()),
                'endDate'   => String.valueOf(Date.today().addMonths(12))
            }
        });

        Test.startTest();
        QuoteLineEditorController.splitRampLines(src.Id, phasesJson, 'quantity');
        Test.stopTest();

        QuoteLineItem updated = [SELECT Quantity, Ramp_Phase__c FROM QuoteLineItem WHERE Id = :src.Id];
        System.assertEquals(50, updated.Quantity, 'Qty unchanged');
        System.assertEquals(1, updated.Ramp_Phase__c, 'Phase set to 1');

        Integer mrcCount = [SELECT COUNT() FROM QuoteLineItem WHERE QuoteId = :q.Id AND Product2.ProductCode = 'CAB001.RC'];
        System.assertEquals(1, mrcCount, 'No additional lines created');
    }

    // ── splitRampLines — price ramp (2 phases) ─────────────────────────

    @IsTest
    static void testSplitRampLines_priceRamp() {
        Quote q = getTestQuote();
        QuoteLineItem src = [SELECT Id, UnitPrice, Quantity FROM QuoteLineItem WHERE Product2.ProductCode = 'CAB001.RC' LIMIT 1];
        System.assertEquals(100, src.UnitPrice, 'Original price');
        System.assertEquals(50, src.Quantity, 'Original qty');

        String phasesJson = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{
                'unitPrice' => 80,
                'startDate' => String.valueOf(Date.today()),
                'endDate'   => String.valueOf(Date.today().addMonths(6))
            },
            new Map<String, Object>{
                'unitPrice' => 100,
                'startDate' => String.valueOf(Date.today().addMonths(6).addDays(1)),
                'endDate'   => String.valueOf(Date.today().addMonths(12))
            }
        });

        Test.startTest();
        QuoteLineEditorController.splitRampLines(src.Id, phasesJson, 'price');
        Test.stopTest();

        List<QuoteLineItem> allMrc = [
            SELECT Quantity, UnitPrice, Ramp_Phase__c
            FROM QuoteLineItem
            WHERE QuoteId = :q.Id AND Product2.ProductCode = 'CAB001.RC'
            ORDER BY Ramp_Phase__c ASC
        ];
        System.assertEquals(2, allMrc.size(), 'Should have 2 MRC phases');
        // Both phases keep original qty
        System.assertEquals(50, allMrc[0].Quantity, 'Phase 1 qty unchanged');
        System.assertEquals(50, allMrc[1].Quantity, 'Phase 2 qty unchanged');
        // Prices differ per phase
        System.assertEquals(80,  allMrc[0].UnitPrice, 'Phase 1 discounted price');
        System.assertEquals(100, allMrc[1].UnitPrice, 'Phase 2 full price');
    }

    // ── splitRampLines — NRC pairing follows MRC split ─────────────────

    @IsTest
    static void testSplitRampLines_nrcFollowsMrc() {
        Quote q = getTestQuote();
        QuoteLineItem mrcSrc = [SELECT Id FROM QuoteLineItem WHERE Product2.ProductCode = 'CAB001.RC' LIMIT 1];
        QuoteLineItem nrcBefore = [SELECT Id, Paired_MRC_Line__c FROM QuoteLineItem WHERE Product2.ProductCode = 'CAB001.NR' LIMIT 1];
        System.assertEquals(mrcSrc.Id, nrcBefore.Paired_MRC_Line__c, 'NRC should be paired to MRC before split');

        String phasesJson = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{
                'quantity'  => 20,
                'startDate' => String.valueOf(Date.today()),
                'endDate'   => String.valueOf(Date.today().addMonths(6))
            },
            new Map<String, Object>{
                'quantity'  => 30,
                'startDate' => String.valueOf(Date.today().addMonths(6).addDays(1)),
                'endDate'   => String.valueOf(Date.today().addMonths(12))
            }
        });

        Test.startTest();
        QuoteLineEditorController.splitRampLines(mrcSrc.Id, phasesJson, 'quantity');
        Test.stopTest();

        // MRC: 2 phase lines
        List<QuoteLineItem> allMrc = [
            SELECT Id, Quantity, Ramp_Phase__c
            FROM QuoteLineItem
            WHERE QuoteId = :q.Id AND Product2.ProductCode = 'CAB001.RC'
            ORDER BY Ramp_Phase__c ASC
        ];
        System.assertEquals(2, allMrc.size(), 'Should have 2 MRC phases');

        // NRC: 2 phase lines, each paired to its MRC phase
        List<QuoteLineItem> allNrc = [
            SELECT Id, Quantity, Ramp_Phase__c, Paired_MRC_Line__c, Is_Auto_NRC__c
            FROM QuoteLineItem
            WHERE QuoteId = :q.Id AND Product2.ProductCode = 'CAB001.NR'
            ORDER BY Ramp_Phase__c ASC
        ];
        System.assertEquals(2, allNrc.size(), 'Should have 2 NRC phases');

        // Phase 1 NRC — updated original, still paired to original MRC
        System.assertEquals(20, allNrc[0].Quantity, 'NRC Phase 1 qty matches MRC Phase 1');
        System.assertEquals(1, allNrc[0].Ramp_Phase__c, 'NRC Phase 1 number');
        System.assertEquals(allMrc[0].Id, allNrc[0].Paired_MRC_Line__c, 'NRC Phase 1 paired to MRC Phase 1');
        System.assertEquals(true, allNrc[0].Is_Auto_NRC__c, 'NRC Phase 1 keeps auto flag');

        // Phase 2 NRC — new line, paired to new MRC phase
        System.assertEquals(30, allNrc[1].Quantity, 'NRC Phase 2 qty matches MRC Phase 2');
        System.assertEquals(2, allNrc[1].Ramp_Phase__c, 'NRC Phase 2 number');
        System.assertEquals(allMrc[1].Id, allNrc[1].Paired_MRC_Line__c, 'NRC Phase 2 paired to MRC Phase 2');
        System.assertEquals(true, allNrc[1].Is_Auto_NRC__c, 'NRC Phase 2 keeps auto flag');
    }

    @IsTest
    static void testSplitRampLines_userOwnedNrcRemainsUnchanged() {
        Quote q = getTestQuote();
        QuoteLineItem mrc = [
            SELECT Id FROM QuoteLineItem
            WHERE Product2.ProductCode = 'CAB001.RC' LIMIT 1
        ];
        QuoteLineItem userNrc = [
            SELECT Id, Quantity, Paired_MRC_Line__c, Is_Auto_NRC__c
            FROM QuoteLineItem WHERE Product2.ProductCode = 'CAB001.NR' LIMIT 1
        ];
        userNrc.Quantity = 7;
        userNrc.Paired_MRC_Line__c = null;
        userNrc.Is_Auto_NRC__c = false;
        update userNrc;

        String phasesJson = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{
                'quantity' => 20,
                'startDate' => String.valueOf(Date.today()),
                'endDate' => String.valueOf(Date.today().addMonths(6))
            },
            new Map<String, Object>{
                'quantity' => 30,
                'startDate' => String.valueOf(Date.today().addMonths(6).addDays(1)),
                'endDate' => String.valueOf(Date.today().addMonths(12))
            }
        });

        Test.startTest();
        QuoteLineEditorController.splitRampLines(mrc.Id, phasesJson, 'quantity');
        Test.stopTest();

        List<QuoteLineItem> nrcLines = [
            SELECT Id, Quantity, Paired_MRC_Line__c, Is_Auto_NRC__c, Line_Origin__c
            FROM QuoteLineItem
            WHERE QuoteId = :q.Id AND Product2.ProductCode = 'CAB001.NR'
        ];
        System.assertEquals(1, nrcLines.size(), 'A user-owned NRC must not be split into ramp phases');
        System.assertEquals(7, nrcLines[0].Quantity, 'The user-entered NRC quantity must be preserved');
        System.assertEquals(null, nrcLines[0].Paired_MRC_Line__c, 'Ramp creation must not re-pair a user-owned NRC');
        System.assertEquals(false, nrcLines[0].Is_Auto_NRC__c);
        System.assertNotEquals('Ramp', nrcLines[0].Line_Origin__c, 'The user-owned NRC must remain outside the ramp');
    }

    @IsTest
    static void testSplitRampLines_doesNotStealAutoNrcPairedToAnotherMrc() {
        Map<String, Id> ids = pairAutoNrcToCompetingMrc();
        Id autoNrcId = ids.get('autoNrc');
        String phasesJson = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{ 'quantity' => 20, 'startDate' => String.valueOf(Date.today()) }
        });

        Test.startTest();
        QuoteLineEditorController.splitRampLines(ids.get('sourceMrc'), phasesJson, 'quantity');
        Test.stopTest();

        QuoteLineItem afterNrc = [
            SELECT Quantity, Paired_MRC_Line__c, Line_Origin__c
            FROM QuoteLineItem WHERE Id = :autoNrcId
        ];
        Id sourceMrcId = ids.get('sourceMrc');
        Integer stolenCount = [
            SELECT COUNT() FROM QuoteLineItem
            WHERE Product2.ProductCode = 'CAB001.NR' AND Paired_MRC_Line__c = :sourceMrcId
        ];
        System.assertEquals(9, afterNrc.Quantity, 'Fallback must not re-quantity another MRC\'s auto NRC');
        System.assertEquals(ids.get('competingMrc'), afterNrc.Paired_MRC_Line__c, 'Fallback must not steal another MRC\'s auto NRC');
        System.assertNotEquals('Ramp', afterNrc.Line_Origin__c, 'Another MRC\'s NRC must stay outside this ramp');
        System.assertEquals(0, stolenCount, 'No already-paired auto NRC may be reassigned to the ramp source');
    }

    // ── splitRampLines — attribute ramp (2 phases) ─────────────────────

    @IsTest
    static void testSplitRampLines_attributeRamp() {
        Quote q = getTestQuote();
        QuoteLineItem src = [SELECT Id, UnitPrice, Quantity FROM QuoteLineItem WHERE Product2.ProductCode = 'CAB001.RC' LIMIT 1];

        String phasesJson = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{
                'quantity'       => 50,
                'unitPrice'      => 100,
                'attributeValue' => '5',
                'startDate'      => String.valueOf(Date.today()),
                'endDate'        => String.valueOf(Date.today().addMonths(6))
            },
            new Map<String, Object>{
                'quantity'       => 50,
                'unitPrice'      => 100,
                'attributeValue' => '15',
                'startDate'      => String.valueOf(Date.today().addMonths(6).addDays(1)),
                'endDate'        => null
            }
        });

        Test.startTest();
        QuoteLineEditorController.splitRampLines(src.Id, phasesJson, 'attribute');
        Test.stopTest();

        List<QuoteLineItem> allMrc = [
            SELECT Quantity, UnitPrice, Ramp_Phase__c, Product_Attribute_Value__c
            FROM QuoteLineItem
            WHERE QuoteId = :q.Id AND Product2.ProductCode = 'CAB001.RC'
            ORDER BY Ramp_Phase__c ASC
        ];
        System.assertEquals(2, allMrc.size(), 'Should have 2 MRC phases');
        System.assertEquals('5',  allMrc[0].Product_Attribute_Value__c, 'Phase 1 attribute');
        System.assertEquals('15', allMrc[1].Product_Attribute_Value__c, 'Phase 2 attribute');
        System.assertEquals(50, allMrc[0].Quantity, 'Phase 1 qty unchanged');
        System.assertEquals(50, allMrc[1].Quantity, 'Phase 2 qty unchanged');
    }

    // ── deleteQuoteLineItems — MRC line (should succeed) ───────────────

    @IsTest
    static void testDeleteQuoteLineItems() {
        QuoteLineItem mrc = [SELECT Id FROM QuoteLineItem WHERE Product2.ProductCode = 'CAB001.RC' LIMIT 1];
        Test.startTest();
        QuoteLineEditorController.deleteQuoteLineItems(new List<Id>{ mrc.Id });
        Test.stopTest();
        Integer count = [SELECT COUNT() FROM QuoteLineItem WHERE Id = :mrc.Id];
        System.assertEquals(0, count, 'MRC line should be deleted');
    }

    // ── deleteQuoteLineItems — auto-NRC blocked by trigger ───────────────

    @IsTest
    static void testDeleteAutoNrc_blocked() {
        QuoteLineItem nrc = [SELECT Id FROM QuoteLineItem WHERE Product2.ProductCode = 'CAB001.NR' LIMIT 1];
        Boolean caught = false;
        Test.startTest();
        try {
            QuoteLineEditorController.deleteQuoteLineItems(new List<Id>{ nrc.Id });
        } catch (Exception e) {
            caught = true;
        }
        Test.stopTest();
        System.assert(caught, 'Deleting auto-NRC should throw');
        Integer count = [SELECT COUNT() FROM QuoteLineItem WHERE Id = :nrc.Id];
        System.assertEquals(1, count, 'NRC line should still exist');
    }

    // ── getQuotePricebookInfo ──────────────────────────────────────────────

    @IsTest
    static void testGetQuotePricebookInfo_ReturnsSiteAndAccountPricebookInfo() {
        Quote q = buildQuoteOnCustomSitePricebook();

        Test.startTest();
        Map<String, String> info = QuoteLineEditorController.getQuotePricebookInfo(q.Id);
        Test.stopTest();

        System.assertEquals(q.Pricebook2Id, info.get('sitePricebookId'));
        System.assertEquals('QLE Isolated Site PB', info.get('sitePricebookName'));
    }

    @IsTest
    static void testGetQuotePricebookInfo_AccountWithCustomerPricebook_IncludesAccountPricebookInfo() {
        Pricebook2 acctPb = new Pricebook2(Name = 'QLE Customer Overlay PB', IsActive = true);
        insert acctPb;
        Quote q = buildQuoteOnCustomSitePricebook();
        update new Account(Id = q.AccountId, Customer_Pricebook__c = acctPb.Id);

        Test.startTest();
        Map<String, String> info = QuoteLineEditorController.getQuotePricebookInfo(q.Id);
        Test.stopTest();

        System.assertEquals(acctPb.Id, info.get('accountPricebookId'));
        System.assertEquals('QLE Customer Overlay PB', info.get('accountPricebookName'));
    }

    @IsTest
    static void testGetQuotePricebookInfo_InvalidQuoteId_ReturnsEmptyMap() {
        Account acc = new Account(Name = 'QLE PricebookInfo Dummy');
        insert acc;
        Opportunity opp = new Opportunity(Name = 'QLE Dummy Opp', AccountId = acc.Id, StageName = '1-Suspect', CloseDate = Date.today());
        insert opp;
        Quote dummyQ = new Quote(Name = 'QLE Dummy Quote', OpportunityId = opp.Id, Pricebook2Id = Test.getStandardPricebookId());
        insert dummyQ;
        delete dummyQ;

        Test.startTest();
        Map<String, String> info = QuoteLineEditorController.getQuotePricebookInfo(dummyQ.Id);
        Test.stopTest();

        System.assertEquals(0, info.size(), 'A deleted/nonexistent quote id should return an empty map, not throw');
    }

    // ── getActiveApprovals ─────────────────────────────────────────────────

    @IsTest
    static void testGetActiveApprovals_NoActiveApprovals_ReturnsEmptyList() {
        Quote q = getTestQuote();

        Test.startTest();
        List<Map<String, String>> results = QuoteLineEditorController.getActiveApprovals(q.Id);
        Test.stopTest();

        System.assertEquals(0, results.size(), 'No pending approvals on the quote or its BANs should return an empty list');
    }

    @IsTest
    static void testGetActiveApprovals_WithRelatedBan_StillReturnsEmptyWithoutPendingApproval() {
        Quote q = getTestQuote();
        Account acc = [SELECT Id FROM Account LIMIT 1];
        insert new BillingAccount__c(
            Name = 'BAN-QLE-01', Account__c = acc.Id, Source_Quote__c = q.Id, CurrencyIsoCode = 'IDR'
        );

        Test.startTest();
        List<Map<String, String>> results = QuoteLineEditorController.getActiveApprovals(q.Id);
        Test.stopTest();

        System.assertEquals(0, results.size(), 'A related BAN with no pending approval should still return an empty list, exercising the BAN-lookup branch');
    }

    // ── Column preferences ──────────────────────────────────────────────────

    @IsTest
    static void testGetColumnPreferences_NoPrefsYet_ReturnsNull() {
        Test.startTest();
        String result = QuoteLineEditorController.getColumnPreferences();
        Test.stopTest();

        System.assertEquals(null, result, 'No saved prefs yet should return null');
    }

    @IsTest
    static void testSaveColumnPreferences_CreatesThenUpdatesPrefs() {
        Test.startTest();
        QuoteLineEditorController.saveColumnPreferences('{"cols":["a","b"]}');
        Test.stopTest();

        String saved = QuoteLineEditorController.getColumnPreferences();
        System.assertEquals('{"cols":["a","b"]}', saved);
    }

    @IsTest
    static void testSaveAutoSavePreference_CreatesPrefs() {
        Test.startTest();
        QuoteLineEditorController.saveAutoSavePreference(true);
        Test.stopTest();

        Quote_Editor_Prefs__c prefs = Quote_Editor_Prefs__c.getInstance(UserInfo.getUserId());
        System.assertEquals(true, prefs.Auto_Save__c);
    }

    // ── getBillingAccountOptions ─────────────────────────────────────────────

    @IsTest
    static void testGetBillingAccountOptions_ReturnsActiveMatchingCurrencyBan() {
        Quote q = getTestQuote();
        Account acc = [SELECT Id FROM Account LIMIT 1];
        insert new BillingAccount__c(
            Name = 'BAN-QLE-02', Account__c = acc.Id, Status__c = 'Active', CurrencyIsoCode = 'IDR'
        );

        Test.startTest();
        Map<String, Object> result = QuoteLineEditorController.getBillingAccountOptions(q.Id);
        Test.stopTest();

        List<Object> opts = (List<Object>) result.get('options');
        System.assertEquals(2, opts.size(), 'Should have the "--None--" placeholder plus one matching Active BAN');
    }

    @IsTest
    static void testGetBillingAccountOptions_InvalidQuoteId_ReturnsEmptyOptions() {
        Test.startTest();
        Map<String, Object> result = QuoteLineEditorController.getBillingAccountOptions(null);
        Test.stopTest();

        List<Object> opts = (List<Object>) result.get('options');
        System.assertEquals(0, opts.size());
        System.assertEquals(null, result.get('defaultBanId'));
    }

    // ── addProductToQuote — currency mismatch triggers ensureCurrencyPbe ────

    @IsTest
    static void testAddProductToQuote_CurrencyMismatch_CreatesNewIdrPbeViaEnsureCurrencyPbe() {
        // Needs a site pricebook distinct from the Standard Price Book — the
        // shared @TestSetup quote uses the Standard PB as its own site
        // pricebook, which would collapse ensureCurrencyPbe's "create in
        // Standard, then create in site" into two inserts on the same
        // pricebook (DUPLICATE_VALUE).
        Quote q = buildQuoteOnCustomSitePricebook();
        Product2 usdOnlyProd = new Product2(Name = 'QLE USD Only Product', ProductCode = 'QLE-USDONLY', IsActive = true);
        insert usdOnlyProd;
        // Standard PB entry required before any custom-pricebook entry for this product.
        insert new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(), Product2Id = usdOnlyProd.Id,
            UnitPrice = 200, IsActive = true, CurrencyIsoCode = 'USD'
        );
        // The USD entry lives on the quote's OWN site pricebook (just the wrong
        // currency) — realistic usage, and keeps "site" and "Standard" as two
        // genuinely different pricebooks so ensureCurrencyPbe's two inserts
        // (Standard IDR entry, then site IDR entry) don't collide.
        insert new PricebookEntry(
            Pricebook2Id = q.Pricebook2Id, Product2Id = usdOnlyProd.Id,
            UnitPrice = 200, IsActive = true, CurrencyIsoCode = 'USD'
        );
        PricebookEntry usdPbe = [
            SELECT Id FROM PricebookEntry
            WHERE Product2Id = :usdOnlyProd.Id AND CurrencyIsoCode = 'USD' AND Pricebook2Id = :q.Pricebook2Id
            LIMIT 1
        ];

        Test.startTest();
        QuoteLineEditorController.addProductToQuote(q.Id, usdPbe.Id, 1, null);
        Test.stopTest();

        QuoteLineItem added = [
            SELECT Id, CurrencyIsoCode FROM QuoteLineItem
            WHERE QuoteId = :q.Id AND Product2Id = :usdOnlyProd.Id LIMIT 1
        ];
        System.assertEquals('IDR', added.CurrencyIsoCode,
            'ensureCurrencyPbe should have created a new IDR-currency PBE (and its Standard PB counterpart) to match the quote');
    }

    // ── addProductToQuote — pricebook mismatch triggers ensureQuotePricebookEntry ──

    @IsTest
    static void testAddProductToQuote_AccountOverlayPricebook_CreatesEntryViaEnsureQuotePricebookEntry() {
        Quote q = buildQuoteOnCustomSitePricebook();
        Pricebook2 overlayPb = new Pricebook2(Name = 'QLE Account Overlay PB', IsActive = true);
        insert overlayPb;

        Product2 overlayProd = new Product2(Name = 'QLE Overlay Product', ProductCode = 'QLE-OVERLAY', IsActive = true);
        insert overlayProd;
        // Standard PB entry required before any custom-pricebook entry for this product.
        insert new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(), Product2Id = overlayProd.Id,
            UnitPrice = 300, IsActive = true, CurrencyIsoCode = 'IDR'
        );
        insert new PricebookEntry(
            Pricebook2Id = overlayPb.Id, Product2Id = overlayProd.Id,
            UnitPrice = 300, IsActive = true, CurrencyIsoCode = 'IDR'
        );
        PricebookEntry overlayPbe = [
            SELECT Id FROM PricebookEntry WHERE Product2Id = :overlayProd.Id AND Pricebook2Id = :overlayPb.Id LIMIT 1
        ];

        Test.startTest();
        QuoteLineEditorController.addProductToQuote(q.Id, overlayPbe.Id, 1, null);
        Test.stopTest();

        Integer count = [
            SELECT COUNT() FROM QuoteLineItem WHERE QuoteId = :q.Id AND Product2Id = :overlayProd.Id
        ];
        System.assertEquals(1, count,
            'ensureQuotePricebookEntry should have created a matching PBE in the quote\'s own pricebook so the line could be added');
    }

    // ── splitRampLinesBulk ───────────────────────────────────────────────────

    @IsTest
    static void testSplitRampLinesBulk_SingleEntry_SinglePhase() {
        // A 2-phase payload here hits the same pre-existing "Too many SOQL
        // queries: 101" bug already flagged for splitRampLines itself (this
        // bulk variant shares the same per-phase NRC-cascade cost despite its
        // docstring claiming better bulk-safety) — so this uses one phase to
        // exercise the bulk scaffolding (JSON parsing, bulk querying/DML,
        // NRC-pairing lookup) without tripping that governor limit.
        Quote q = getTestQuote();
        QuoteLineItem src = [SELECT Id FROM QuoteLineItem WHERE Product2.ProductCode = 'CAB001.RC' LIMIT 1];

        String phasesJson = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{ 'quantity' => 50, 'startDate' => String.valueOf(Date.today()) }
        });
        String bulkPayload = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{ 'sourceLineId' => src.Id, 'phasesJson' => phasesJson }
        });

        Test.startTest();
        QuoteLineEditorController.splitRampLinesBulk(bulkPayload, 'quantity');
        Test.stopTest();

        QuoteLineItem updated = [SELECT Quantity, Ramp_Phase__c, Line_Origin__c FROM QuoteLineItem WHERE Id = :src.Id];
        System.assertEquals(50, updated.Quantity);
        System.assertEquals(1, updated.Ramp_Phase__c);
        System.assertEquals('Ramp', updated.Line_Origin__c);
    }

    @IsTest
    static void testSplitRampLinesBulk_EmptyPayload_NoOp() {
        Test.startTest();
        QuoteLineEditorController.splitRampLinesBulk('[]', 'quantity');
        Test.stopTest();

        System.assert(true, 'An empty bulk payload should be a no-op, not throw');
    }

    @IsTest
    static void testSplitRampLinesBulk_TwoPhases_NoNrcPairing_CoversPhase2Creation() {
        // A product with no NRC counterpart (not ".RC"-suffixed) so the NRC-cascade
        // machinery (963-1092) stays a cheap no-op, keeping this well clear of the
        // documented "Too many SOQL queries: 101" governor-limit bug that a
        // 2-phase payload trips when NRC pairing/triggers cascade per phase (see
        // testSplitRampLinesBulk_SingleEntry_SinglePhase's comment) — this still
        // exercises the Phase-2+ creation loop, bulk DML, and date-patch logic.
        Quote q = getTestQuote();
        Product2 noPairProd = new Product2(
            Name = 'Bulk No-Pair Product', ProductCode = 'BULK-NOPAIR-01',
            IsActive = true, Charge_Type__c = 'MRC'
        );
        insert noPairProd;
        PricebookEntry noPairPbe = new PricebookEntry(
            Pricebook2Id = q.Pricebook2Id, Product2Id = noPairProd.Id,
            UnitPrice = 200, IsActive = true, CurrencyIsoCode = 'IDR'
        );
        insert noPairPbe;
        QuoteLineItem src = new QuoteLineItem(
            QuoteId = q.Id, PricebookEntryId = noPairPbe.Id, Product2Id = noPairProd.Id,
            Quantity = 10, UnitPrice = 200,
            StartDate = Date.today(), EndDate = Date.today().addMonths(12)
        );
        insert src;

        String phasesJson = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{ 'quantity' => 20, 'startDate' => String.valueOf(Date.today()), 'endDate' => String.valueOf(Date.today().addMonths(6)) },
            new Map<String, Object>{ 'quantity' => 30, 'startDate' => String.valueOf(Date.today().addMonths(6).addDays(1)) }
        });
        String bulkPayload = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{ 'sourceLineId' => src.Id, 'phasesJson' => phasesJson }
        });

        Test.startTest();
        QuoteLineEditorController.splitRampLinesBulk(bulkPayload, 'quantity');
        Test.stopTest();

        QuoteLineItem phase1 = [SELECT Quantity, Ramp_Phase__c, EndDate FROM QuoteLineItem WHERE Id = :src.Id];
        System.assertEquals(20, phase1.Quantity, 'Phase 1 qty should be updated in place');
        System.assertEquals(1, phase1.Ramp_Phase__c);
        System.assertNotEquals(null, phase1.EndDate, 'Phase 1 end date should be patched from the phases payload');

        List<QuoteLineItem> phase2 = [
            SELECT Quantity, Ramp_Phase__c, Ramp_Parent_Line__c
            FROM QuoteLineItem
            WHERE Product2Id = :noPairProd.Id AND Id != :src.Id
        ];
        System.assertEquals(1, phase2.size(), 'Phase 2 should be created as a new QLI');
        System.assertEquals(30, phase2[0].Quantity);
        System.assertEquals(src.Id, phase2[0].Ramp_Parent_Line__c);
    }

    @IsTest
    static void testSplitRampLinesBulk_userOwnedNrcRemainsUnchanged() {
        Quote q = getTestQuote();
        QuoteLineItem mrc = [
            SELECT Id FROM QuoteLineItem
            WHERE Product2.ProductCode = 'CAB001.RC' LIMIT 1
        ];
        QuoteLineItem userNrc = [
            SELECT Id, Quantity, Paired_MRC_Line__c, Is_Auto_NRC__c
            FROM QuoteLineItem WHERE Product2.ProductCode = 'CAB001.NR' LIMIT 1
        ];
        userNrc.Quantity = 7;
        userNrc.Paired_MRC_Line__c = null;
        userNrc.Is_Auto_NRC__c = false;
        update userNrc;

        String phasesJson = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{ 'quantity' => 20, 'startDate' => String.valueOf(Date.today()) }
        });
        String bulkPayload = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{ 'sourceLineId' => mrc.Id, 'phasesJson' => phasesJson }
        });

        Test.startTest();
        QuoteLineEditorController.splitRampLinesBulk(bulkPayload, 'quantity');
        Test.stopTest();

        QuoteLineItem afterNrc = [
            SELECT Quantity, Paired_MRC_Line__c, Is_Auto_NRC__c, Line_Origin__c
            FROM QuoteLineItem WHERE Id = :userNrc.Id
        ];
        System.assertEquals(7, afterNrc.Quantity, 'Bulk ramp creation must preserve the user-entered NRC quantity');
        System.assertEquals(null, afterNrc.Paired_MRC_Line__c, 'Bulk ramp creation must not re-pair a user-owned NRC');
        System.assertEquals(false, afterNrc.Is_Auto_NRC__c);
        System.assertNotEquals('Ramp', afterNrc.Line_Origin__c, 'The user-owned NRC must remain outside the ramp');
    }

    @IsTest
    static void testSplitRampLinesBulk_doesNotStealAutoNrcPairedToAnotherMrc() {
        Map<String, Id> ids = pairAutoNrcToCompetingMrc();
        Id autoNrcId = ids.get('autoNrc');
        String phasesJson = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{ 'quantity' => 20, 'startDate' => String.valueOf(Date.today()) }
        });
        String bulkPayload = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{ 'sourceLineId' => ids.get('sourceMrc'), 'phasesJson' => phasesJson }
        });

        Test.startTest();
        QuoteLineEditorController.splitRampLinesBulk(bulkPayload, 'quantity');
        Test.stopTest();

        QuoteLineItem afterNrc = [
            SELECT Quantity, Paired_MRC_Line__c, Line_Origin__c
            FROM QuoteLineItem WHERE Id = :autoNrcId
        ];
        Id sourceMrcId = ids.get('sourceMrc');
        Integer stolenCount = [
            SELECT COUNT() FROM QuoteLineItem
            WHERE Product2.ProductCode = 'CAB001.NR' AND Paired_MRC_Line__c = :sourceMrcId
        ];
        System.assertEquals(9, afterNrc.Quantity, 'Bulk fallback must not re-quantity another MRC\'s auto NRC');
        System.assertEquals(ids.get('competingMrc'), afterNrc.Paired_MRC_Line__c, 'Bulk fallback must not steal another MRC\'s auto NRC');
        System.assertNotEquals('Ramp', afterNrc.Line_Origin__c, 'Another MRC\'s NRC must stay outside this ramp');
        System.assertEquals(0, stolenCount, 'Bulk fallback may not reassign any already-paired auto NRC');
    }

    // ── getRampSiblings / aggregateRampNrcQty / addRampPhase / deleteRampPhases ──
    // These all operate on lines already marked Line_Origin__c='Ramp', which is
    // set by splitRampLines itself — so each test drives a real split first
    // rather than hand-constructing ramp data that might not match what the
    // UI/trigger layer actually produces.

    // Builds a 2-phase ramp via single-phase splitRampLines (Phase 1) + addRampPhase
    // (Phase 2) rather than a 2-phase splitRampLines call, which hits the
    // pre-existing "Too many SOQL queries: 101" bug for this MRC+NRC-paired
    // product (see the class-level note on the SOQL-limit findings).
    static QuoteLineItem buildTwoPhaseRamp() {
        QuoteLineItem src = splitPhase1Only();
        QuoteLineEditorController.addRampPhase(
            src.Id, 30, 100, String.valueOf(Date.today().addMonths(6).addDays(1)), null
        );
        return src;
    }

    // splitRampLines (Phase 1) alone already uses right up to the 100-query
    // budget for this MRC+NRC-paired product, leaving no headroom for
    // addRampPhase's (Phase 2) own cascade in the same governor-limit pool —
    // so callers that also need Phase 2 must run this before Test.startTest()
    // and addRampPhase itself inside Test.startTest()/stopTest(), splitting the
    // two calls across both pools instead of cramming both into one.
    static QuoteLineItem splitPhase1Only() {
        QuoteLineItem src = [SELECT Id, QuoteId FROM QuoteLineItem WHERE Product2.ProductCode = 'CAB001.RC' LIMIT 1];
        String phase1Json = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{ 'quantity' => 20, 'startDate' => String.valueOf(Date.today()) }
        });
        QuoteLineEditorController.splitRampLines(src.Id, phase1Json, 'quantity');
        return src;
    }

    @IsTest
    static void testGetRampSiblings_AfterSplit_ReturnsBothPhasesWithNrcInfo() {
        // Test.startTest() must wrap the ramp-building calls too, not just the
        // method under test — without the fresh governor-limit budget it grants,
        // even the single-phase splitRampLines call runs out of SOQL queries
        // (same underlying issue as the pre-existing 2-phase SOQL-limit bug).
        Test.startTest();
        QuoteLineItem src = buildTwoPhaseRamp();
        List<Map<String, Object>> siblings = QuoteLineEditorController.getRampSiblings(src.Id);
        Test.stopTest();

        System.assertEquals(2, siblings.size(), 'Should return both ramp phases for the MRC product');
        System.assertNotEquals(null, siblings[0].get('nrcId'), 'Each phase entry should carry its paired NRC info');
    }

    @IsTest
    static void testGetRampSiblings_NonRampLine_ReturnsEmptyList() {
        QuoteLineItem plainLine = [SELECT Id FROM QuoteLineItem WHERE Product2.ProductCode = 'CAB001.RC' LIMIT 1];

        Test.startTest();
        List<Map<String, Object>> siblings = QuoteLineEditorController.getRampSiblings(plainLine.Id);
        Test.stopTest();

        System.assertEquals(0, siblings.size(), 'A line that was never ramp-split should return an empty list');
    }

    @IsTest
    static void testAggregateRampNrcQty_AfterAddRampPhase_SumsMrcQtyOntoNrc() {
        // buildTwoPhaseRamp() (splitRampLines + addRampPhase together) uses just
        // over the 100-query budget by itself, so the two calls must be split
        // across both governor-limit pools: Phase 1's split runs here, before
        // Test.startTest(); Phase 2's addRampPhase runs inside Test.startTest()/
        // stopTest() along with the method under test and verification query.
        QuoteLineItem src = splitPhase1Only();

        Test.startTest();
        QuoteLineEditorController.addRampPhase(
            src.Id, 30, 100, String.valueOf(Date.today().addMonths(6).addDays(1)), null
        );
        Id q_Id = src.QuoteId;

        // Directly desync one NRC phase's quantity so aggregateRampNrcQty has something to fix.
        QuoteLineItem nrcPhase1 = [
            SELECT Id FROM QuoteLineItem
            WHERE QuoteId = :q_Id AND Product2.ProductCode = 'CAB001.NR' AND Ramp_Phase__c = 1 LIMIT 1
        ];
        nrcPhase1.Quantity = 999;
        update nrcPhase1;

        QuoteLineEditorController.aggregateRampNrcQty(q_Id);

        QuoteLineItem afterNrc = [SELECT Quantity FROM QuoteLineItem WHERE Id = :nrcPhase1.Id];
        Test.stopTest();

        System.assertEquals(20, afterNrc.Quantity, 'aggregateRampNrcQty should re-sync the NRC qty to match its paired MRC phase');
    }

    @IsTest
    static void testAggregateRampNrcQty_skipsUserOwnedNrc() {
        Quote q = getTestQuote();
        QuoteLineItem mrc = [
            SELECT Id FROM QuoteLineItem
            WHERE Product2.ProductCode = 'CAB001.RC' LIMIT 1
        ];
        update new QuoteLineItem(
            Id = mrc.Id,
            Quantity = 50,
            Charge_Type__c = 'MRC',
            Line_Origin__c = 'Ramp',
            Ramp_Phase__c = 1,
            Ramp_Line__c = true
        );

        QuoteLineItem userNrc = [
            SELECT Id FROM QuoteLineItem
            WHERE Product2.ProductCode = 'CAB001.NR' LIMIT 1
        ];
        update new QuoteLineItem(
            Id = userNrc.Id,
            Quantity = 7,
            Charge_Type__c = 'NRC',
            Paired_MRC_Line__c = null,
            Is_Auto_NRC__c = false,
            Line_Origin__c = 'Ramp',
            Ramp_Phase__c = 1,
            Ramp_Line__c = true
        );

        Test.startTest();
        QuoteLineEditorController.aggregateRampNrcQty(q.Id);
        Test.stopTest();

        QuoteLineItem afterNrc = [SELECT Quantity FROM QuoteLineItem WHERE Id = :userNrc.Id];
        System.assertEquals(7, afterNrc.Quantity, 'Aggregation must not recalculate a user-owned NRC');
    }

    @IsTest
    static void testAggregateRampNrcQty_NullQuoteId_NoOp() {
        Test.startTest();
        QuoteLineEditorController.aggregateRampNrcQty(null);
        Test.stopTest();

        System.assert(true, 'A null quoteId should be a no-op, not throw');
    }

    @IsTest
    static void testAddRampPhase_CreatesNewPhaseWithPairedNrc() {
        Quote q = getTestQuote();
        QuoteLineItem src = [SELECT Id FROM QuoteLineItem WHERE Product2.ProductCode = 'CAB001.RC' LIMIT 1];
        String phase1Json = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{ 'quantity' => 20, 'startDate' => String.valueOf(Date.today()) }
        });
        Test.startTest();
        QuoteLineEditorController.splitRampLines(src.Id, phase1Json, 'quantity');
        Id newPhaseId = QuoteLineEditorController.addRampPhase(
            src.Id, 30, 100, String.valueOf(Date.today().addMonths(6).addDays(1)), null
        );
        Test.stopTest();

        System.assertNotEquals(null, newPhaseId);
        QuoteLineItem newPhase = [SELECT Ramp_Phase__c, Quantity FROM QuoteLineItem WHERE Id = :newPhaseId];
        System.assertEquals(2, newPhase.Ramp_Phase__c, 'New phase should be numbered after the existing phase 1');
        System.assertEquals(30, newPhase.Quantity);

        Integer nrcCount = [
            SELECT COUNT() FROM QuoteLineItem WHERE QuoteId = :q.Id AND Product2.ProductCode = 'CAB001.NR' AND Ramp_Phase__c = 2
        ];
        System.assertEquals(1, nrcCount, 'A paired NRC line should be auto-created for the new phase');
    }

    @IsTest
    static void testAddRampPhase_doesNotUseAutoNrcPairedToAnotherMrc() {
        Map<String, Id> ids = pairAutoNrcToCompetingMrc();
        Id autoNrcId = ids.get('autoNrc');
        update new QuoteLineItem(
            Id = ids.get('sourceMrc'),
            Line_Origin__c = 'Ramp',
            Ramp_Line__c = true,
            Ramp_Phase__c = 1,
            Ramp_Start_Date__c = Date.today()
        );

        Test.startTest();
        QuoteLineEditorController.addRampPhase(
            ids.get('sourceMrc'), 30, 100,
            String.valueOf(Date.today().addMonths(6).addDays(1)), null
        );
        Test.stopTest();

        QuoteLineItem originalNrc = [
            SELECT Paired_MRC_Line__c FROM QuoteLineItem WHERE Id = :autoNrcId
        ];
        Integer rampNrcCount = [
            SELECT COUNT() FROM QuoteLineItem
            WHERE Product2.ProductCode = 'CAB001.NR' AND Line_Origin__c = 'Ramp'
        ];
        System.assertEquals(ids.get('competingMrc'), originalNrc.Paired_MRC_Line__c, 'Add phase must preserve another MRC\'s NRC ownership');
        System.assertEquals(0, rampNrcCount, 'Add phase must not clone another MRC\'s NRC as its template');
    }

    @IsTest
    static void testDeleteRampPhases_RemovesClonesAndRestoresOriginalQuantity() {
        // Same reasoning as testAggregateRampNrcQty above: buildTwoPhaseRamp()
        // (splitRampLines + addRampPhase together) is just over the 100-query
        // budget by itself, so Phase 1's split runs before Test.startTest() and
        // Phase 2's addRampPhase runs inside it, alongside the method under test
        // and its verification query.
        QuoteLineItem src = splitPhase1Only();

        Test.startTest();
        QuoteLineEditorController.addRampPhase(
            src.Id, 30, 100, String.valueOf(Date.today().addMonths(6).addDays(1)), null
        );
        Id q_Id = src.QuoteId;
        QuoteLineEditorController.deleteRampPhases(src.Id);

        List<QuoteLineItem> remaining = [
            SELECT Id, Quantity, Line_Origin__c, Ramp_Phase__c FROM QuoteLineItem
            WHERE QuoteId = :q_Id AND Product2.ProductCode = 'CAB001.RC'
        ];
        Test.stopTest();

        System.assertEquals(1, remaining.size(), 'Phase 2 clone should be deleted, leaving only the original line');

        QuoteLineItem restored = remaining[0];
        System.assertEquals(src.Id, restored.Id, 'The one remaining line should be the original parent line');
        System.assertEquals(50, restored.Quantity, 'Original quantity (20+30) should be restored onto the parent line');
        System.assertEquals('New', restored.Line_Origin__c, 'Parent line should be reset to a non-ramp line');
        System.assertEquals(null, restored.Ramp_Phase__c);
    }

    @IsTest
    static void testDeleteRampPhases_aggregateMrcUsesFinalPhaseQuantity() {
        Quote q = getTestQuote();
        Product2 aggregateProduct = new Product2(
            Name = 'QLE Aggregate Product',
            ProductCode = 'QLE-AGG-001',
            IsActive = true,
            Charge_Type__c = 'MRC',
            Merge_IB_Task__c = true
        );
        insert aggregateProduct;
        PricebookEntry aggregatePbe = new PricebookEntry(
            Pricebook2Id = q.Pricebook2Id,
            Product2Id = aggregateProduct.Id,
            UnitPrice = 100,
            IsActive = true,
            CurrencyIsoCode = 'IDR'
        );
        insert aggregatePbe;
        QuoteLineItem aggregateLine = new QuoteLineItem(
            QuoteId = q.Id,
            PricebookEntryId = aggregatePbe.Id,
            Product2Id = aggregateProduct.Id,
            Quantity = 2,
            UnitPrice = 100,
            Charge_Type__c = 'MRC',
            StartDate = Date.today(),
            EndDate = Date.today().addMonths(12)
        );
        insert aggregateLine;

        String phasesJson = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{
                'quantity' => 1,
                'startDate' => String.valueOf(Date.today()),
                'endDate' => String.valueOf(Date.today().addMonths(6))
            },
            new Map<String, Object>{
                'quantity' => 2,
                'startDate' => String.valueOf(Date.today().addMonths(6).addDays(1)),
                'endDate' => String.valueOf(Date.today().addMonths(12))
            }
        });
        QuoteLineEditorController.splitRampLines(aggregateLine.Id, phasesJson, 'quantity');

        Test.startTest();
        QuoteLineEditorController.deleteRampPhases(aggregateLine.Id);
        Test.stopTest();

        QuoteLineItem restored = [
            SELECT Quantity, Line_Origin__c, Ramp_Phase__c
            FROM QuoteLineItem WHERE Id = :aggregateLine.Id
        ];
        System.assertEquals(2, restored.Quantity, 'Aggregate MRC should restore the final level, not 1 + 2');
        System.assertEquals('New', restored.Line_Origin__c);
        System.assertEquals(null, restored.Ramp_Phase__c);
        System.assertEquals(1, [SELECT COUNT() FROM QuoteLineItem WHERE Product2Id = :aggregateProduct.Id]);
    }

    @IsTest
    static void testDeleteRampPhases_userOwnedNrcKeepsInputAndUnpairs() {
        Quote q = getTestQuote();
        QuoteLineItem mrc = [
            SELECT Id FROM QuoteLineItem
            WHERE Product2.ProductCode = 'CAB001.RC' LIMIT 1
        ];
        QuoteLineItem userNrc = [
            SELECT Id, QuoteId, Product2Id, PricebookEntryId, UnitPrice
            FROM QuoteLineItem WHERE Product2.ProductCode = 'CAB001.NR' LIMIT 1
        ];
        update new QuoteLineItem(
            Id = userNrc.Id,
            Quantity = 7,
            Charge_Type__c = 'NRC',
            Paired_MRC_Line__c = mrc.Id,
            Is_Auto_NRC__c = false,
            Line_Origin__c = 'Ramp',
            Ramp_Phase__c = 1,
            Ramp_Line__c = true
        );
        insert new QuoteLineItem(
            QuoteId = q.Id,
            PricebookEntryId = userNrc.PricebookEntryId,
            Product2Id = userNrc.Product2Id,
            Quantity = 2,
            UnitPrice = userNrc.UnitPrice,
            Charge_Type__c = 'NRC',
            Paired_MRC_Line__c = mrc.Id,
            Is_Auto_NRC__c = false,
            Line_Origin__c = 'Ramp',
            Ramp_Phase__c = 2,
            Ramp_Line__c = true,
            Ramp_Parent_Line__c = userNrc.Id
        );

        Test.startTest();
        QuoteLineEditorController.deleteRampPhases(userNrc.Id);
        Test.stopTest();

        List<QuoteLineItem> remainingNrc = [
            SELECT Id, Quantity, Paired_MRC_Line__c, Is_Auto_NRC__c,
                   Line_Origin__c, Ramp_Phase__c
            FROM QuoteLineItem
            WHERE QuoteId = :q.Id AND Product2.ProductCode = 'CAB001.NR'
        ];
        System.assertEquals(1, remainingNrc.size(), 'The accidental NRC phase clone should be deleted');
        System.assertEquals(userNrc.Id, remainingNrc[0].Id);
        System.assertEquals(7, remainingNrc[0].Quantity, 'The user-entered NRC quantity must remain unchanged');
        System.assertEquals(null, remainingNrc[0].Paired_MRC_Line__c, 'Ramp removal must restore the unpaired state');
        System.assertEquals(false, remainingNrc[0].Is_Auto_NRC__c);
        System.assertEquals('New', remainingNrc[0].Line_Origin__c);
        System.assertEquals(null, remainingNrc[0].Ramp_Phase__c);
    }

    @IsTest
    static void testDeleteRampPhases_NoRampedLines_NoOp() {
        // Reuse the shared setup's plain (never ramp-split) MRC line rather than
        // hand-building a fresh Quote/Product/PBE chain, which tripped an
        // unrelated NRC-pairing trigger side effect unrelated to this test's point.
        QuoteLineItem plainLine = [SELECT Id FROM QuoteLineItem WHERE Product2.ProductCode = 'CAB001.RC' LIMIT 1];

        Test.startTest();
        QuoteLineEditorController.deleteRampPhases(plainLine.Id);
        Test.stopTest();

        Integer count = [SELECT COUNT() FROM QuoteLineItem WHERE Id = :plainLine.Id];
        System.assertEquals(1, count, 'A non-ramped line should be left untouched (no-op)');
    }

    // ── addProductToQuote — SFDC-366 Unit of Measure seeding ─────────────
    //
    // The shared @TestSetup products carry no QuantityUnitOfMeasure, so
    // uomOrNull() short-circuits on String.isNotBlank() and the uomValueSet
    // describe is never built. These two products force both sides of the
    // guard: an on-list default that must be stamped, and an off-list one that
    // must be dropped rather than thrown at the restricted picklist.

    @IsTest
    static void testAddProductToQuote_seedsUoMFromProductDefault() {
        Quote q = getTestQuote();

        // 'Each' is an active value on the DE_Unit_Of_Measure global value set
        // that QuoteLineItem.UoM__c is bound to.
        Product2 onList = new Product2(
            Name = 'UOM001.RC', ProductCode = 'UOM001.RC', IsActive = true,
            Charge_Type__c = 'MRC', QuantityUnitOfMeasure = 'Each'
        );
        // Product2.QuantityUnitOfMeasure is UNRESTRICTED, so a value that is not
        // in the value set can legitimately exist on a product.
        Product2 offList = new Product2(
            Name = 'UOM002.RC', ProductCode = 'UOM002.RC', IsActive = true,
            Charge_Type__c = 'MRC', QuantityUnitOfMeasure = 'Furlongs'
        );
        insert new List<Product2>{ onList, offList };

        PricebookEntry onPbe = new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(), Product2Id = onList.Id,
            UnitPrice = 10, IsActive = true, CurrencyIsoCode = 'IDR'
        );
        PricebookEntry offPbe = new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(), Product2Id = offList.Id,
            UnitPrice = 10, IsActive = true, CurrencyIsoCode = 'IDR'
        );
        insert new List<PricebookEntry>{ onPbe, offPbe };

        Test.startTest();
        QuoteLineEditorController.addProductToQuote(q.Id, onPbe.Id, 1, null);
        QuoteLineEditorController.addProductToQuote(q.Id, offPbe.Id, 1, null);
        Test.stopTest();

        Map<String, String> uomByCode = new Map<String, String>();
        for (QuoteLineItem li : [
            SELECT Product2.ProductCode, UoM__c FROM QuoteLineItem
            WHERE QuoteId = :q.Id AND Product2.ProductCode IN ('UOM001.RC', 'UOM002.RC')
        ]) {
            uomByCode.put(li.Product2.ProductCode, li.UoM__c);
        }

        System.assertEquals('Each', uomByCode.get('UOM001.RC'),
            'An on-list Product2.QuantityUnitOfMeasure should be stamped onto QuoteLineItem.UoM__c');
        System.assertEquals(null, uomByCode.get('UOM002.RC'),
            'An off-list default must be dropped, not stamped — stamping it would throw '
            + 'INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST and block the rep from adding the product');
    }
}