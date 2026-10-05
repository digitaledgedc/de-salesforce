@IsTest
private class DE_QuoteTemplateControllerTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(
            Name = 'Test Customer Pte Ltd',
            Operation_Country__c = 'Singapore',
            Preferred_Language__c = 'English',
            Local_Language__c = true,
            Local_Entity_Name__c = 'テスト顧客株式会社',
            Local_Registered_Office_Address__c = '東京都テスト区1-2-3'
        );
        insert acc;

        Opportunity opp = new Opportunity(
            Name      = 'Test Opp',
            AccountId = acc.Id,
            StageName = '3-Qualified',
            CloseDate = Date.today().addMonths(3)
        );
        insert opp;

        Id pbId = Test.getStandardPricebookId();

        Site__c site = new Site__c(
            Country__c    = 'ID',
            Site_Code__c  = 'JKT1',
            Status__c     = 'Operational'
        );
        insert site;

        Quote q = new Quote(
            Name             = 'Q-2026-001',
            OpportunityId    = opp.Id,
            Pricebook2Id     = pbId,
            Status           = 'Draft',
            Quote_Type__c    = 'New',
            Quote_Number__c  = 'Q-2026-001',
            Target_Site__c   = site.Id,
            Contract_Term_Months__c = 24,
            ExpirationDate   = Date.today().addDays(30),
            BillingName      = 'Test Customer Pte Ltd',
            BillingStreet    = '123 Test Street',
            BillingCity      = 'Jakarta',
            BillingCountry   = 'Indonesia',
            SBI_Flag__c      = false
        );
        insert q;

        Product2 prod = new Product2(
            Name            = 'Full Cab',
            IsActive        = true,
            QuantityUnitOfMeasure = 'Cab'
        );
        insert prod;

        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = pbId,
            Product2Id   = prod.Id,
            UnitPrice    = 5000000,
            IsActive     = true
        );
        insert pbe;

        insert new List<QuoteLineItem>{
            new QuoteLineItem(
                QuoteId          = q.Id,
                PricebookEntryId = pbe.Id,
                Product2Id       = prod.Id,
                Quantity         = 1,
                UnitPrice        = 5000000,
                Charge_Type__c   = 'NRC',
                SortOrder        = 1
            ),
            new QuoteLineItem(
                QuoteId          = q.Id,
                PricebookEntryId = pbe.Id,
                Product2Id       = prod.Id,
                Quantity         = 1,
                UnitPrice        = 8000000,
                Charge_Type__c   = 'MRC',
                SortOrder        = 1
            )
        };
    }

    @IsTest
    static void testController_standardQuote() {
        Quote q = [SELECT Id FROM Quote LIMIT 1];
        Test.startTest();
        ApexPages.StandardController sc = new ApexPages.StandardController(q);
        DE_QuoteTemplateController ctrl = new DE_QuoteTemplateController(sc);
        Test.stopTest();

        System.assertEquals('Quotation', ctrl.quoteTitle, 'Default non-binding New quote title');
        System.assertEquals(false, ctrl.showSpecialNote, 'SBI_Flag is false — no special note');
        System.assertEquals(1, ctrl.nrcLines.size(),  'Should have 1 NRC line');
        System.assertEquals(1, ctrl.mrcLines.size(),  'Should have 1 MRC line');
        System.assertEquals(5000000, ctrl.grandTotalNRC, 'NRC total should be 5,000,000');
        System.assertEquals(8000000, ctrl.grandTotalMRC, 'MRC total should be 8,000,000');
        System.assertEquals(false, ctrl.showEndCustomer, 'No Channel_Partner__c set — End Customer row hidden');
    }

    @IsTest
    static void testController_endCustomer() {
        Quote q = [SELECT Id, OpportunityId, Opportunity.AccountId FROM Quote LIMIT 1];

        Id endCustomerRtId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName()
            .get('End_Customer').getRecordTypeId();
        Account endCustomerAcc = new Account(
            Name = 'End Customer Co',
            RecordTypeId = endCustomerRtId,
            ParentId = q.Opportunity.AccountId
        );
        insert endCustomerAcc;

        Opportunity opp = new Opportunity(Id = q.OpportunityId, Channel_Partner__c = endCustomerAcc.Id);
        update opp;

        Test.startTest();
        ApexPages.StandardController sc = new ApexPages.StandardController(q);
        DE_QuoteTemplateController ctrl = new DE_QuoteTemplateController(sc);
        Test.stopTest();

        System.assertEquals(true, ctrl.showEndCustomer, 'Channel_Partner__c populated — End Customer row shown');
        System.assertEquals('End Customer Co', ctrl.endCustomer, 'endCustomer should mirror End_Customer__c formula');
    }

    @IsTest
    static void testController_amendmentTitle() {
        Quote q = [SELECT Id FROM Quote LIMIT 1];
        q.Quote_Type__c = 'Amendment';
        update q;

        Test.startTest();
        ApexPages.StandardController sc = new ApexPages.StandardController(q);
        DE_QuoteTemplateController ctrl = new DE_QuoteTemplateController(sc);
        Test.stopTest();

        System.assertEquals('Change Quotation', ctrl.quoteTitle, 'Non-binding Amendment title');
    }

    @IsTest
    static void testController_sbiFlag() {
        Quote q = [SELECT Id FROM Quote LIMIT 1];
        ApexPages.currentPage().getParameters().put('lang', 'invalid');

        Test.startTest();
        ApexPages.StandardController sc = new ApexPages.StandardController(q);
        DE_QuoteTemplateController ctrl = new DE_QuoteTemplateController(sc);
        Test.stopTest();

        System.assertEquals('en_US', ctrl.documentLanguage, 'Invalid language falls back to English');
    }

    @IsTest
    static void testController_rampDeal() {
        Quote q = [SELECT Id FROM Quote LIMIT 1];

        // Add ramp-flagged line items — controller detects ramp from Ramp_Line__c on QLIs
        Id pbId = Test.getStandardPricebookId();
        Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
        PricebookEntry pbe = [SELECT Id FROM PricebookEntry WHERE Pricebook2Id = :pbId LIMIT 1];

        // A real ramp group: the phase-1 line is the anchor (no Ramp_Parent_Line__c)
        // and later phases point back at it. Phase 2 carries an escalated unit price
        // so the first-vs-last phase price choice is actually observable below.
        QuoteLineItem anchor = new QuoteLineItem(
            QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = prod.Id,
            Quantity = 2, UnitPrice = 3000000, Charge_Type__c = 'MRC',
            Line_Origin__c = 'Ramp', Ramp_Phase__c = 1, SortOrder = 10
        );
        insert anchor;

        insert new QuoteLineItem(
            QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = prod.Id,
            Quantity = 4, UnitPrice = 3300000, Charge_Type__c = 'MRC',
            Line_Origin__c = 'Ramp', Ramp_Phase__c = 2, SortOrder = 11,
            Ramp_Parent_Line__c = anchor.Id
        );

        Test.startTest();
        ApexPages.StandardController sc = new ApexPages.StandardController(q);
        DE_QuoteTemplateController ctrl = new DE_QuoteTemplateController(sc);
        Test.stopTest();

        System.assertEquals(true, ctrl.isRampDeal, 'Should be a ramp deal');
        // Every ramp phase — including phase 1 — now gets its own schedule table;
        // the base table is the aggregated "Lines view" built from the group anchors.
        System.assertEquals(2, ctrl.rampPhases.size(), 'Phases 1 and 2 each get a ramp schedule table');
        System.assertEquals('Ramp-1', ctrl.rampPhases[0].phaseNumber, 'Displayed schedule starts at Ramp-1');
        System.assertEquals('Ramp-2', ctrl.rampPhases[1].phaseNumber, 'Second table is Ramp-2');
        System.assertEquals(1, ctrl.rampPhases[0].mrcLines.size(), 'Phase 1 should have 1 MRC line');
        System.assertEquals(1, ctrl.rampPhases[1].mrcLines.size(), 'Phase 2 should have 1 MRC line');
        System.assert(ctrl.rampPhases[0].subtotalMRC > 0, 'Phase 1 MRC subtotal should be > 0');

        // Base table = the @TestSetup non-ramp MRC line (8,000,000, see
        // testController_standardQuote) plus one aggregated row for the ramp group.
        System.assertEquals(2, ctrl.mrcLines.size(), 'Setup MRC line plus the aggregated ramp anchor');
        Set<Id> baseMrcIds = new Set<Id>();
        for (QuoteLineItem li : ctrl.mrcLines) baseMrcIds.add(li.Id);
        System.assert(baseMrcIds.contains(anchor.Id), 'The group anchor carries the aggregated base row');

        // Neither phase sets Ramp_Linked_Phase__c, so both are "new" quantity and the
        // aggregated qty is their sum. Merge_IB_Task__c is false, so this is not an
        // aggregate product and the running-capacity rule does not apply.
        System.assertEquals(6, ctrl.displayQtyByLineId.get(anchor.Id).intValue(), 'Aggregated qty = phase 1 + phase 2');
        // SFDC-275: the first table prints the FIRST phase price (3,000,000), not the
        // escalated phase-2 price (3,300,000) — escalations belong in the ramp tables.
        System.assertEquals(3000000, ctrl.displayUnitByLineId.get(anchor.Id).intValue(), 'Unit price from the first phase');
        System.assertEquals(18000000, ctrl.displaySubtotalByLineId.get(anchor.Id).intValue(), 'Aggregated subtotal = qty * first-phase unit');
        System.assertEquals(26000000, ctrl.grandTotalMRC, 'MRC grand total = 8,000,000 setup line + 18,000,000 aggregated group');
    }

    @IsTest
    static void testController_rampGroupAnchoredAfterPhase1() {
        // SFDC-349 regression guard. A space that only comes online partway through
        // the ramp anchors at phase 2, not phase 1. The old rule collected anchors on
        // "Ramp_Phase__c <= 1", so that whole group vanished from the aggregated first
        // table (48,000 of 60,000 kVA missing on NAVKRUSD-OR-021346). Anchors are now
        // keyed on Ramp_Parent_Line__c == null, so the group renders.
        Quote q = [SELECT Id FROM Quote LIMIT 1];

        Id pbId = Test.getStandardPricebookId();
        Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
        PricebookEntry pbe = [SELECT Id FROM PricebookEntry WHERE Pricebook2Id = :pbId LIMIT 1];

        QuoteLineItem phase1Anchor = new QuoteLineItem(
            QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = prod.Id,
            Quantity = 2, UnitPrice = 3000000, Charge_Type__c = 'MRC',
            Line_Origin__c = 'Ramp', Ramp_Phase__c = 1, SortOrder = 10
        );
        // Anchors at phase 2 — no parent line, so it is a group in its own right.
        QuoteLineItem lateAnchor = new QuoteLineItem(
            QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = prod.Id,
            Quantity = 5, UnitPrice = 2000000, Charge_Type__c = 'MRC',
            Line_Origin__c = 'Ramp', Ramp_Phase__c = 2, SortOrder = 20
        );
        insert new List<QuoteLineItem>{ phase1Anchor, lateAnchor };

        insert new QuoteLineItem(
            QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = prod.Id,
            Quantity = 4, UnitPrice = 3000000, Charge_Type__c = 'MRC',
            Line_Origin__c = 'Ramp', Ramp_Phase__c = 2, SortOrder = 11,
            Ramp_Parent_Line__c = phase1Anchor.Id
        );

        Test.startTest();
        ApexPages.StandardController sc = new ApexPages.StandardController(q);
        DE_QuoteTemplateController ctrl = new DE_QuoteTemplateController(sc);
        Test.stopTest();

        // Setup MRC line + phase-1 group + the group that anchors at phase 2.
        System.assertEquals(3, ctrl.mrcLines.size(), 'The phase-2 anchored group must not be dropped');
        Set<Id> baseMrcIds = new Set<Id>();
        for (QuoteLineItem li : ctrl.mrcLines) baseMrcIds.add(li.Id);
        System.assert(baseMrcIds.contains(phase1Anchor.Id), 'Phase-1 group renders');
        System.assert(baseMrcIds.contains(lateAnchor.Id), 'Group anchored at phase 2 renders — this is the SFDC-349 fix');

        System.assertEquals(6, ctrl.displayQtyByLineId.get(phase1Anchor.Id).intValue(), 'Phase-1 group aggregates both its phases');
        System.assertEquals(5, ctrl.displayQtyByLineId.get(lateAnchor.Id).intValue(), 'Late group carries its own qty');
        System.assertEquals(10000000, ctrl.displaySubtotalByLineId.get(lateAnchor.Id).intValue(), 'Late group subtotal = 5 * 2,000,000');
        System.assertEquals(36000000, ctrl.grandTotalMRC, 'MRC grand total = 8,000,000 + 18,000,000 + 10,000,000');
    }

    @IsTest
    static void testController_changeOrderNonBinding() {
        Quote q = [SELECT Id FROM Quote LIMIT 1];
        q.Quote_Type__c = 'Change Order';
        update q;

        Test.startTest();
        ApexPages.StandardController sc = new ApexPages.StandardController(q);
        DE_QuoteTemplateController ctrl = new DE_QuoteTemplateController(sc);
        Test.stopTest();

        System.assertEquals(true, ctrl.isChangeOrder, 'Should be a change order');
        System.assertEquals('Change Quotation', ctrl.quoteTitle, 'Change Order title');
        System.assertNotEquals(null, ctrl.deEntityName, 'DE entity name should be populated');
    }

    @IsTest
    static void testController_japaneseLabels() {
        Quote q = [SELECT Id FROM Quote LIMIT 1];
        ApexPages.currentPage().getParameters().put('lang', 'ja');

        Test.startTest();
        DE_QuoteTemplateController ctrl = new DE_QuoteTemplateController(
            new ApexPages.StandardController(q)
        );
        Test.stopTest();

        System.assertEquals('ja', ctrl.documentLanguage);
        System.assertEquals('見積', ctrl.quoteTitle);
        System.assertEquals('注文書番号', ctrl.pdfLabels.get('Header_Order_Number'));
        System.assertEquals(
            'テスト顧客株式会社',
            ctrl.billingName,
            'Legacy local name must remain the fallback while Translated_Name__c is blank'
        );
        System.assertEquals(
            '東京都テスト区1-2-3',
            ctrl.billingAddress,
            'Local address must not depend on Preferred_Language__c matching the request'
        );
    }

    @IsTest
    static void testController_nullId() {
        Test.startTest();
        ApexPages.StandardController sc = new ApexPages.StandardController(new Quote());
        DE_QuoteTemplateController ctrl = new DE_QuoteTemplateController(sc);
        Test.stopTest();

        System.assertEquals('Quotation', ctrl.quoteTitle, 'Default title should be Quotation');
        System.assertEquals(0, ctrl.nrcLines.size(),  'No lines for null ID');
        System.assertEquals(0, ctrl.mrcLines.size(),  'No lines for null ID');
        System.assertEquals(0, ctrl.grandTotalNRC, 'Grand total NRC should be 0');
        System.assertEquals(0, ctrl.grandTotalMRC, 'Grand total MRC should be 0');
        System.assertEquals(false, ctrl.isRampDeal, 'Default should not be ramp');
        System.assertEquals(false, ctrl.isChangeOrder, 'Default should not be change order');
    }

    // ─── Coverage gap-fill tests ───────────────────────────────────────────
    // Added to close specific uncovered branches identified from the last
    // code coverage run (see DE-XXXX). Each test below targets one or a
    // small cluster of related uncovered lines in DE_QuoteTemplateController.

    @IsTest
    static void testController_quoteRecordDeleted() {
        // Covers the quotes.isEmpty() -> initDefaults() fallback: a Quote Id
        // that no longer resolves to a record (e.g. deleted between the VF
        // page load and render).
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        Quote tempQ = new Quote(
            Name = 'Q-TEMP-DEL', OpportunityId = opp.Id,
            Pricebook2Id = Test.getStandardPricebookId(),
            Status = 'Draft', Quote_Type__c = 'New', Quote_Number__c = 'Q-TEMP-DEL'
        );
        insert tempQ;
        Id deletedId = tempQ.Id;
        delete tempQ;

        Test.startTest();
        ApexPages.StandardController sc = new ApexPages.StandardController(new Quote(Id = deletedId));
        DE_QuoteTemplateController ctrl = new DE_QuoteTemplateController(sc);
        Test.stopTest();

        System.assertEquals('Quotation', ctrl.quoteTitle, 'Falls back to defaults when the Quote no longer exists');
        System.assertEquals(0, ctrl.nrcLines.size(), 'No lines for a quote record that no longer exists');
    }

    @IsTest
    static void testController_bindingChangeOrderWithOriginalOrder() {
        // Covers: Binding terms heading branch, amendedOrderNumber true
        // branch (isChangeOrder && Original_Order__r != null), and the CJK
        // soft-break insertion in termsContent.
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        Account orderAcc = new Account(Name = 'Order Acc');
        insert orderAcc;
        Order ord = new Order(
            AccountId = orderAcc.Id, EffectiveDate = Date.today(), Status = 'Draft',
            Order_Number__c = 'ORD-2026-001'
        );
        insert ord;

        Quote q2 = new Quote(
            Name = 'Q-CO-001', OpportunityId = opp.Id, Pricebook2Id = Test.getStandardPricebookId(),
            Status = 'Approved', Quote_Type__c = 'Change Order', Quote_Number__c = 'Q-CO-001',
            Is_Binding__c = true, Original_Order__c = ord.Id, CurrencyIsoCode = 'USD',
            ExpirationDate = Date.today().addDays(30),
            Service_Order_Terms__c = '本契約の条件、及び付随する事項について。'
        );
        insert q2;

        Test.startTest();
        DE_QuoteTemplateController ctrl = new DE_QuoteTemplateController(new ApexPages.StandardController(q2));
        Test.stopTest();

        System.assertEquals(true, ctrl.isChangeOrder, 'Change Order type');
        System.assertEquals('ORD-2026-001', ctrl.amendedOrderNumber, 'Amended order number pulled from Original_Order__r');
        System.assertEquals(ctrl.pdfLabels.get('Heading_Terms_Binding'), ctrl.termsHeading, 'Binding heading used when Is_Binding__c is true');
        System.assert(ctrl.termsContent.contains('、 '), 'CJK soft break inserted after full-width comma: ' + ctrl.termsContent);
    }

    @IsTest
    static void testController_accountNameFallbackNoLocal() {
        // Covers accountDisplayName falling back to Account.Name (no
        // translation, no legacy local name) and billingName falling back to
        // that accountDisplayName (BillingName left blank on the Quote).
        Account acc = new Account(Name = 'Plain English Co', Preferred_Language__c = 'English', Local_Language__c = false);
        insert acc;
        Opportunity opp = new Opportunity(Name = 'Plain Opp', AccountId = acc.Id, StageName = '3-Qualified', CloseDate = Date.today().addMonths(2));
        insert opp;
        Quote q = new Quote(
            Name = 'Q-PLAIN-001', OpportunityId = opp.Id, Pricebook2Id = Test.getStandardPricebookId(),
            Status = 'Draft', Quote_Type__c = 'New', Quote_Number__c = 'Q-PLAIN-001'
        );
        insert q;

        Test.startTest();
        DE_QuoteTemplateController ctrl = new DE_QuoteTemplateController(new ApexPages.StandardController(q));
        Test.stopTest();

        System.assertEquals('Plain English Co', ctrl.billingName, 'Falls back to Account.Name when no translation/local name and BillingName blank');
    }

    @IsTest
    static void testController_accountTranslatedName() {
        // Covers useTranslatedAccount true branch (Account preferred
        // language matches document language and Translated_Name__c is set).
        Account acc = new Account(
            Name = 'Translated Co', Preferred_Language__c = 'Japanese',
            Translated_Name__c = '翻訳された会社名', Local_Language__c = false
        );
        insert acc;
        Opportunity opp = new Opportunity(Name = 'Translated Opp', AccountId = acc.Id, StageName = '3-Qualified', CloseDate = Date.today().addMonths(2));
        insert opp;
        Quote q = new Quote(
            Name = 'Q-TRANS-001', OpportunityId = opp.Id, Pricebook2Id = Test.getStandardPricebookId(),
            Status = 'Draft', Quote_Type__c = 'New', Quote_Number__c = 'Q-TRANS-001'
        );
        insert q;
        ApexPages.currentPage().getParameters().put('lang', 'ja');

        Test.startTest();
        DE_QuoteTemplateController ctrl = new DE_QuoteTemplateController(new ApexPages.StandardController(q));
        Test.stopTest();

        System.assertEquals('翻訳された会社名', ctrl.billingName, 'Translated_Name__c used when Account preferred language matches document language');
    }

    @IsTest
    static void testController_chinaEntityTax() {
        // Covers isChinaEntity true, DE_Entity__r non-null fallback name
        // branch, and the 6% VAT tax-inclusive calculation in addBaseLine.
        Quote q = [SELECT Id FROM Quote LIMIT 1];
        Id deEntityRtId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('DE_Entity').getRecordTypeId();
        Account chinaEntity = new Account(
            Name = 'DE China Entity', RecordTypeId = deEntityRtId, Operation_Country__c = 'China'
        );
        insert chinaEntity;
        q.DE_Entity__c = chinaEntity.Id;
        q.CurrencyIsoCode = 'USD';
        update q;

        Test.startTest();
        DE_QuoteTemplateController ctrl = new DE_QuoteTemplateController(new ApexPages.StandardController(q));
        Test.stopTest();

        System.assertEquals(true, ctrl.isChinaEntity, 'DE_Entity Operation_Country__c = China flags China entity');
        System.assertEquals('DE China Entity', ctrl.deEntityName, 'No translation set up — falls back to Account.Name');
        System.assert(ctrl.chinaTaxTotal > 0, '6% VAT should be computed on non-zero line totals');
        for (QuoteLineItem li : ctrl.nrcLines) {
            System.assert(ctrl.taxByLineId.get(li.Id) > 0, 'Tax computed for NRC line');
            System.assert(ctrl.exclByLineId.get(li.Id) > 0, 'Tax-exclusive amount computed for NRC line');
        }
    }

    @IsTest
    static void testController_entityAndContactTranslation() {
        // Covers useTranslatedContact and useTranslatedEntity true branches
        // (both require the referenced record to be non-null before the
        // preference/translated-name checks even run).
        Quote q = [SELECT Id, OpportunityId, Opportunity.AccountId FROM Quote LIMIT 1];

        Contact translatedContact = new Contact(
            LastName = 'TransContact', AccountId = q.Opportunity.AccountId,
            Language_Preference__c = 'Japanese', Translated_Name__c = '翻訳された担当者'
        );
        insert translatedContact;

        Id deEntityRtId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('DE_Entity').getRecordTypeId();
        Account translatedEntity = new Account(
            Name = 'DE Japan Entity', RecordTypeId = deEntityRtId,
            Operation_Country__c = 'Japan', Preferred_Language__c = 'Japanese',
            Translated_Name__c = 'デジタルエッジ日本法人'
        );
        insert translatedEntity;

        q.ContactId = translatedContact.Id;
        q.DE_Entity__c = translatedEntity.Id;
        q.CurrencyIsoCode = 'USD';
        update q;
        ApexPages.currentPage().getParameters().put('lang', 'ja');

        Test.startTest();
        DE_QuoteTemplateController ctrl = new DE_QuoteTemplateController(new ApexPages.StandardController(q));
        Test.stopTest();

        System.assertEquals('翻訳された担当者', ctrl.contactName, 'Translated contact name used when language preference matches document language');
        System.assertEquals('デジタルエッジ日本法人', ctrl.deEntityName, 'Translated entity name used when preferred language matches');
    }

    @IsTest
    static void testController_quoteAccountTranslated() {
        // Covers useTranslatedQuoteAccount true branch.
        Quote q = [SELECT Id FROM Quote LIMIT 1];
        Account translatedQA = new Account(
            Name = 'QA Translated Co', Preferred_Language__c = 'Japanese',
            Translated_Name__c = '翻訳された請求先'
        );
        insert translatedQA;
        q.QuoteAccountId = translatedQA.Id;
        update q;
        ApexPages.currentPage().getParameters().put('lang', 'ja');

        Test.startTest();
        DE_QuoteTemplateController ctrl = new DE_QuoteTemplateController(new ApexPages.StandardController(q));
        Test.stopTest();

        System.assertEquals('翻訳された請求先', ctrl.quoteAccountName, 'Translated quote account name used');
    }

    @IsTest
    static void testController_quoteAccountNameFallback() {
        // Covers quoteAccountName falling back to plain Account.Name (no
        // translation, no legacy local name).
        Quote q = [SELECT Id FROM Quote LIMIT 1];
        Account plainQA = new Account(
            Name = 'QA Plain Co', Preferred_Language__c = 'English', Local_Language__c = false
        );
        insert plainQA;
        q.QuoteAccountId = plainQA.Id;
        update q;

        Test.startTest();
        DE_QuoteTemplateController ctrl = new DE_QuoteTemplateController(new ApexPages.StandardController(q));
        Test.stopTest();

        System.assertEquals('QA Plain Co', ctrl.quoteAccountName, 'Falls back to Account.Name with no translation/local name');
    }

    @IsTest
    static void testController_nullContractTerm() {
        // Covers initialTermStr blank branch when Contract_Term_Months__c is null.
        Quote q = [SELECT Id FROM Quote LIMIT 1];
        q.Contract_Term_Months__c = null;
        update q;

        Test.startTest();
        DE_QuoteTemplateController ctrl = new DE_QuoteTemplateController(new ApexPages.StandardController(q));
        Test.stopTest();

        System.assertEquals('', ctrl.initialTermStr, 'Null contract term renders as blank string');
    }

    @IsTest
    static void testController_targetSiteWithCompoundAddress() {
        // Covers the Target_Site__c lookup + compound Address__c JSON parse
        // + assembled addrParts join branch.
        Quote q = [SELECT Id, Pricebook2Id FROM Quote LIMIT 1];
        Site__c site = new Site__c(
            Name = 'JKT Test DC', Site_Code__c = 'JKT9', Country__c = 'ID',
            Address__Street__s = '1 Test Way', Address__City__s = 'Jakarta',
            Address__StateCode__s = 'CA', Address__CountryCode__s = 'US',
            Address__PostalCode__s = '90001',
            // Same pricebook the Quote already uses — the Quote_BeforeSave_AutoSetup
            // flow re-assigns Pricebook2Id from Target_Site__r.Pricebook2__c whenever
            // Target_Site__c is set, and the platform blocks changing a Quote's
            // pricebook once QuoteLineItems exist against it.
            Pricebook2__c = q.Pricebook2Id
        );
        insert site;
        q.Target_Site__c = site.Id;
        update q;

        Test.startTest();
        DE_QuoteTemplateController ctrl = new DE_QuoteTemplateController(new ApexPages.StandardController(q));
        Test.stopTest();

        System.assertEquals('JKT Test DC', ctrl.siteName, 'Site name populated from Target_Site__c lookup');
        System.assert(ctrl.siteAddress.contains('1 Test Way'), 'Assembled compound address included: ' + ctrl.siteAddress);
        System.assertEquals(true, ctrl.showDataCenter, 'Data center block should show');
    }

    @IsTest
    static void testController_targetSiteLocalAddressOverride() {
        // Covers the non-English Local_Address__c override branch.
        Quote q = [SELECT Id, Pricebook2Id FROM Quote LIMIT 1];
        Site__c site = new Site__c(
            Name = 'Tokyo Test DC', Site_Code__c = 'TYO9', Country__c = 'JP',
            Address__Street__s = '1 Test Way', Address__City__s = 'Tokyo',
            Address__StateCode__s = 'CA', Address__CountryCode__s = 'US',
            Address__PostalCode__s = '90001',
            Local_Address__c = '東京都テストセンター',
            // Same pricebook the Quote already uses — see comment in
            // testController_targetSiteWithCompoundAddress above.
            Pricebook2__c = q.Pricebook2Id
        );
        insert site;
        q.Target_Site__c = site.Id;
        update q;
        ApexPages.currentPage().getParameters().put('lang', 'ja');

        Test.startTest();
        DE_QuoteTemplateController ctrl = new DE_QuoteTemplateController(new ApexPages.StandardController(q));
        Test.stopTest();

        System.assertEquals('東京都テストセンター', ctrl.siteAddress, 'Local address overrides compound address for non-English documents');
    }

    @IsTest
    static void testController_rampNrcLineAndWrapperGetters() {
        // Covers: ramp phase 2+ NRC branch (pw.nrcLines.add), and the
        // RampLineWrapper delegate getters — otherwise only ever invoked via
        // Visualforce EL, never from Apex, so unreachable without direct calls.
        Quote q = [SELECT Id FROM Quote LIMIT 1];
        Id pbId = Test.getStandardPricebookId();
        Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
        PricebookEntry pbe = [SELECT Id FROM PricebookEntry WHERE Pricebook2Id = :pbId LIMIT 1];

        insert new List<QuoteLineItem>{
            // Phase 1 -> folded into the base table
            new QuoteLineItem(
                QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = prod.Id,
                Quantity = 1, UnitPrice = 1000000, Charge_Type__c = 'MRC',
                Line_Origin__c = 'Ramp', Ramp_Phase__c = 1, SortOrder = 20
            ),
            // Phase 2, NRC charge type -> exercises the isNRC true ramp branch
            new QuoteLineItem(
                QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = prod.Id,
                Quantity = 3, UnitPrice = 500000, Charge_Type__c = 'NRC',
                Line_Origin__c = 'Ramp', Ramp_Phase__c = 2,
                Ramp_Start_Date__c = Date.today().addMonths(1), SortOrder = 21
            )
        };

        Test.startTest();
        DE_QuoteTemplateController ctrl = new DE_QuoteTemplateController(new ApexPages.StandardController(q));
        Test.stopTest();

        // Phase 1 now also gets its own table, so the NRC phase-2 table is index 1.
        System.assertEquals(2, ctrl.rampPhases.size(), 'Phases 1 and 2 each get a ramp schedule table');
        DE_QuoteTemplateController.RampPhaseWrapper phase = ctrl.rampPhases[1];
        System.assertEquals(1, phase.nrcLines.size(), 'NRC-charge ramp line added to the NRC ramp bucket');
        System.assertEquals(0, phase.mrcLines.size(), 'No MRC ramp lines in this phase');
        System.assert(phase.subtotalNRC > 0, 'NRC subtotal should be > 0');

        DE_QuoteTemplateController.RampLineWrapper rlw = phase.nrcLines[0];
        // Exercise the delegate getters directly — only ever invoked via VF EL otherwise.
        System.assertEquals(prod.Id, rlw.Product2.Id, 'Product2 delegate getter');
        System.assertEquals(3, rlw.Quantity.intValue(), 'Quantity delegate getter');
        System.assertEquals(500000, rlw.UnitPrice.intValue(), 'UnitPrice delegate getter');
        System.assertEquals(3, rlw.rampAdditionalQty.intValue(), 'EndQuantity defaults to Quantity when unset, StartQuantity defaults to 0');
        System.assertNotEquals(null, rlw.TotalPrice, 'TotalPrice delegate getter');
        System.assertEquals(null, rlw.Discount, 'Discount delegate getter (no discount set)');
        System.assertEquals(null, rlw.Description, 'Description delegate getter mirrors Line_Remarks__c');
        System.assertEquals(null, rlw.Notes, 'Notes delegate getter mirrors Line_Remarks__c');
        System.assertEquals('', rlw.Product_Attribute_Value, 'Attribute display defaults to empty string when unset');
    }

    @IsTest
    static void testController_discountColumn() {
        // Covers hasAnyDiscount true branch and getDiscountCol() true branch.
        Quote q = [SELECT Id FROM Quote LIMIT 1];
        Id pbId = Test.getStandardPricebookId();
        Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
        PricebookEntry pbe = [SELECT Id FROM PricebookEntry WHERE Pricebook2Id = :pbId LIMIT 1];
        insert new QuoteLineItem(
            QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = prod.Id,
            Quantity = 1, UnitPrice = 100000, Discount = 10, Charge_Type__c = 'MRC', SortOrder = 30
        );

        Test.startTest();
        DE_QuoteTemplateController ctrl = new DE_QuoteTemplateController(new ApexPages.StandardController(q));
        Test.stopTest();

        System.assertEquals(true, ctrl.hasAnyDiscount, 'A line with a Discount flags hasAnyDiscount');
        System.assertEquals(1, ctrl.getDiscountCol().size(), 'Discount column shown when any line has a discount');
    }

    @IsTest
    static void testController_conditionalColumnGetters() {
        // Covers getServiceIdCol/getNrcSectionFlag/getMrcSectionFlag/
        // getDiscountCol — VF-EL-only getters never otherwise invoked from Apex.
        Quote qCO = [SELECT Id FROM Quote LIMIT 1];
        qCO.Quote_Type__c = 'Change Order';
        update qCO;

        Test.startTest();
        DE_QuoteTemplateController ctrlChangeOrder = new DE_QuoteTemplateController(new ApexPages.StandardController(qCO));
        DE_QuoteTemplateController ctrlDefaults = new DE_QuoteTemplateController(
            new ApexPages.StandardController(new Quote())
        );
        Test.stopTest();

        System.assertEquals(1, ctrlChangeOrder.getServiceIdCol().size(), 'Change Order shows the Service ID column');
        System.assertEquals(1, ctrlChangeOrder.getNrcSectionFlag().size(), 'NRC lines present -> section flag populated');
        System.assertEquals(1, ctrlChangeOrder.getMrcSectionFlag().size(), 'MRC lines present -> section flag populated');
        System.assertEquals(0, ctrlChangeOrder.getDiscountCol().size(), 'No line carries a discount -> empty column');

        System.assertEquals(0, ctrlDefaults.getServiceIdCol().size(), 'Not a Change Order -> empty column');
        System.assertEquals(0, ctrlDefaults.getNrcSectionFlag().size(), 'No lines -> empty column');
        System.assertEquals(0, ctrlDefaults.getMrcSectionFlag().size(), 'No lines -> empty column');
    }

    @IsTest
    static void testController_assetDisplayNameAndAttributeCombine() {
        // Covers all three stripProductSuffix branches (colon suffix,
        // endsWith fallback, no suffix) and the combineAttributeDisplay
        // branch where both Product_Attribute_Value__c and
        // Custom_Attribute_Value__c are present.
        Quote q = [SELECT Id FROM Quote LIMIT 1];
        Id pbId = Test.getStandardPricebookId();
        Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
        PricebookEntry pbe = [SELECT Id FROM PricebookEntry WHERE Pricebook2Id = :pbId LIMIT 1];

        Account assetAcc = new Account(Name = 'Asset Test Acc');
        insert assetAcc;
        Asset colonSuffixAsset = new Asset(Name = 'SVC-001: Full Cab', AccountId = assetAcc.Id);
        Asset dashSuffixAsset  = new Asset(Name = 'SVC-002-Full Cab', AccountId = assetAcc.Id);
        Asset noSuffixAsset    = new Asset(Name = 'SVC-003', AccountId = assetAcc.Id);
        insert new List<Asset>{ colonSuffixAsset, dashSuffixAsset, noSuffixAsset };

        List<QuoteLineItem> lines = new List<QuoteLineItem>{
            new QuoteLineItem(
                QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = prod.Id,
                Quantity = 1, UnitPrice = 1000, Charge_Type__c = 'MRC', SortOrder = 40,
                Asset__c = colonSuffixAsset.Id,
                Product_Attribute_Value__c = '10Gbps', Custom_Attribute_Value__c = 5
            ),
            new QuoteLineItem(
                QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = prod.Id,
                Quantity = 1, UnitPrice = 1000, Charge_Type__c = 'MRC', SortOrder = 41,
                Asset__c = dashSuffixAsset.Id
            ),
            new QuoteLineItem(
                QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = prod.Id,
                Quantity = 1, UnitPrice = 1000, Charge_Type__c = 'MRC', SortOrder = 42,
                Asset__c = noSuffixAsset.Id
            )
        };
        insert lines;

        Test.startTest();
        DE_QuoteTemplateController ctrl = new DE_QuoteTemplateController(new ApexPages.StandardController(q));
        Test.stopTest();

        System.assertEquals('SVC-001', ctrl.assetDisplayNameByLineId.get(lines[0].Id), 'Trailing ": Product Name" suffix stripped');
        System.assertEquals('SVC-002', ctrl.assetDisplayNameByLineId.get(lines[1].Id), 'Trailing product-name suffix stripped via endsWith fallback');
        System.assertEquals('SVC-003', ctrl.assetDisplayNameByLineId.get(lines[2].Id), 'Name with no product suffix left unchanged');

        String combined = ctrl.attributeDisplayByLineId.get(lines[0].Id);
        System.assert(combined.startsWith('10Gbps / 5'), 'Attribute + custom value combined with " / ": ' + combined);
    }

    @IsTest
    static void testController_zeroCustomAttributePrintsBlank() {
        // SFDEV-5: a Custom_Attribute_Value__c of 0 is "not entered" and must
        // not print as 0.00 on the quote.
        Quote q = [SELECT Id FROM Quote LIMIT 1];
        Id pbId = Test.getStandardPricebookId();
        Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
        PricebookEntry pbe = [SELECT Id FROM PricebookEntry WHERE Pricebook2Id = :pbId LIMIT 1];

        List<QuoteLineItem> lines = new List<QuoteLineItem>{
            new QuoteLineItem(
                QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = prod.Id,
                Quantity = 1, UnitPrice = 1000, Charge_Type__c = 'MRC', SortOrder = 50,
                Custom_Attribute_Value__c = 0
            ),
            new QuoteLineItem(
                QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = prod.Id,
                Quantity = 1, UnitPrice = 1000, Charge_Type__c = 'MRC', SortOrder = 51,
                Product_Attribute_Value__c = '10Gbps', Custom_Attribute_Value__c = 0
            )
        };
        insert lines;

        Test.startTest();
        DE_QuoteTemplateController ctrl = new DE_QuoteTemplateController(new ApexPages.StandardController(q));
        Test.stopTest();

        System.assertEquals('', ctrl.attributeDisplayByLineId.get(lines[0].Id), 'Zero custom value alone prints blank');
        System.assertEquals('10Gbps', ctrl.attributeDisplayByLineId.get(lines[1].Id), 'Zero custom value not appended to the attribute');
    }

    @IsTest
    static void testController_translatedProductName() {
        // Covers the Product2DataTranslation lookup + translatedProductNames
        // containsKey true branch in productNameByLineId assembly.
        Quote q = [SELECT Id FROM Quote LIMIT 1];
        Product2 prod = [SELECT Id, Name FROM Product2 LIMIT 1];

        Product2DataTranslation translation = new Product2DataTranslation(
            ParentId = prod.Id, Name = '日本語製品名', Language = 'ja'
        );
        insert translation;
        ApexPages.currentPage().getParameters().put('lang', 'ja');

        Test.startTest();
        DE_QuoteTemplateController ctrl = new DE_QuoteTemplateController(new ApexPages.StandardController(q));
        Test.stopTest();

        Boolean foundTranslated = false;
        for (String name : ctrl.productNameByLineId.values()) {
            if (name == '日本語製品名') foundTranslated = true;
        }
        System.assert(foundTranslated, 'Translated product name used for ja document language');
    }

    // ─── SFDC-404: CJK / long-token line breaking in the PDF ─────────────────
    // The PDF renderer breaks a line only at whitespace, so an unbroken CJK
    // phrase overflows its fixed-width column and is cut at the page margin.
    // pdfWrapText escapes the value and injects <wbr/> at each legal break.

    // The exact string from the ticket, kept verbatim so a regression is
    // recognisable against the reported document.
    private static final String SFDC404_REMARKS =
        'アイネス W3F-16　BPOオフィスエリア設備利用料(パーティション、分電盤、防災法令対応他)';

    @IsTest
    static void testPdfWrapText_cjkGainsBreaksWithoutLosingText() {
        String wrapped = DE_QuoteTemplateController.pdfWrapText(SFDC404_REMARKS);

        System.assert(wrapped.contains('<wbr/>'),
            'CJK text must gain break opportunities: ' + wrapped);
        // The whole point of the fix: nothing may be dropped. Strip the markup
        // back out and the original must be intact, character for character.
        System.assertEquals(SFDC404_REMARKS, wrapped.replace('<wbr/>', ''),
            'Removing the injected <wbr/> must restore the original exactly');
    }

    @IsTest
    static void testPdfWrapText_kinsokuNeverBreaksBeforeClosingPunctuation() {
        String wrapped = DE_QuoteTemplateController.pdfWrapText(SFDC404_REMARKS);

        // A line must not begin with closing punctuation, so no break may be
        // inserted directly in front of one.
        for (String closer : new List<String>{ '、', '。', ')', '）', '」' }) {
            System.assert(!wrapped.contains('<wbr/>' + closer),
                'No break opportunity may precede "' + closer + '": ' + wrapped);
        }
    }

    @IsTest
    static void testPdfWrapText_escapesHtmlBeforeInjecting() {
        // The page renders this with escape="false", so the escaping done here
        // is the only thing standing between customer text and the markup.
        String wrapped = DE_QuoteTemplateController.pdfWrapText('設備 & 保守 <重要> "至急"');

        System.assert(wrapped.contains('&amp;'),  'Ampersand escaped: '   + wrapped);
        System.assert(wrapped.contains('&lt;'),   'Less-than escaped: '   + wrapped);
        System.assert(wrapped.contains('&gt;'),   'Greater-than escaped: '+ wrapped);
        System.assert(wrapped.contains('&quot;'), 'Double quote escaped: '+ wrapped);
        // The raw characters must not survive anywhere outside an entity.
        System.assert(!wrapped.contains('<重要>'), 'Raw angle brackets must not reach the page: ' + wrapped);
    }

    @IsTest
    static void testPdfWrapText_longAsciiRunIsBroken() {
        // Not a CJK-only bug: any token longer than a column clips the same way.
        String token = 'SupplementaryPowerInstallationChargeForCabinetA12IncludingUPSRedundancy';
        String wrapped = DE_QuoteTemplateController.pdfWrapText(token);

        System.assert(wrapped.contains('<wbr/>'),
            'A long unbroken ASCII token must gain break opportunities: ' + wrapped);
        System.assertEquals(token, wrapped.replace('<wbr/>', ''),
            'Removing the injected <wbr/> must restore the original exactly');
    }

    @IsTest
    static void testPdfWrapText_ordinaryEnglishLeftAlone() {
        // Prose already breaks at its spaces; injecting anything would risk
        // splitting words that render correctly today.
        String prose = 'Additional power install for Rack A-12, includes UPS redundancy.';
        System.assertEquals(prose, DE_QuoteTemplateController.pdfWrapText(prose),
            'Ordinary spaced English must pass through untouched');
    }

    @IsTest
    static void testPdfWrapText_blankInputReturnsEmptyString() {
        // Visualforce map[key] EL treats a null value as a missing key
        // ("Map key ... not found in map"), so null must never be returned.
        System.assertEquals('', DE_QuoteTemplateController.pdfWrapText(null),  'Null becomes empty string');
        System.assertEquals('', DE_QuoteTemplateController.pdfWrapText(''),    'Empty stays empty');
        System.assertEquals('', DE_QuoteTemplateController.pdfWrapText('   '), 'Blank becomes empty string');
    }

    @IsTest
    static void testController_htmlColumnMapsWrapCjk() {
        // End-to-end: the maps the page actually reads must carry the breaks,
        // while the plain maps stay clean for any non-HTML consumer.
        Quote q = [SELECT Id FROM Quote LIMIT 1];
        Id pbId = Test.getStandardPricebookId();
        Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
        PricebookEntry pbe = [SELECT Id FROM PricebookEntry WHERE Pricebook2Id = :pbId LIMIT 1];

        QuoteLineItem line = new QuoteLineItem(
            QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = prod.Id,
            Quantity = 1, UnitPrice = 1000, Charge_Type__c = 'MRC', SortOrder = 60,
            Line_Remarks__c = SFDC404_REMARKS,
            Product_Attribute_Value__c = '二百ボルト三十アンペア二重化対応'
        );
        insert line;

        Test.startTest();
        DE_QuoteTemplateController ctrl = new DE_QuoteTemplateController(new ApexPages.StandardController(q));
        Test.stopTest();

        String remarksHtml = ctrl.remarksHtmlByLineId.get(line.Id);
        System.assert(remarksHtml.contains('<wbr/>'), 'Remarks column carries break opportunities: ' + remarksHtml);
        System.assertEquals(SFDC404_REMARKS, remarksHtml.replace('<wbr/>', ''), 'Remarks text preserved in full');

        String attrHtml = ctrl.attributeHtmlByLineId.get(line.Id);
        System.assert(attrHtml.contains('<wbr/>'), 'Attribute column carries break opportunities: ' + attrHtml);

        // The plain map is what non-HTML callers use — it must stay markup-free.
        System.assertEquals(SFDC404_REMARKS, line.Line_Remarks__c, 'Stored value untouched');
        System.assert(!ctrl.attributeDisplayByLineId.get(line.Id).contains('<wbr/>'),
            'The plain attribute map must not carry markup');

        // Every free-text column in the grid needs an entry, never a null.
        System.assertNotEquals(null, ctrl.productNameHtmlByLineId.get(line.Id), 'Product Name HTML present');
        System.assertNotEquals(null, ctrl.assetNameHtmlByLineId.get(line.Id),   'Service ID HTML present');
        System.assertNotEquals(null, ctrl.unitHtmlByLineId.get(line.Id),        'Unit HTML present');
    }

    @IsTest
    static void testController_rampWrapperHtmlGetters() {
        // The ramp grid renders through RampLineWrapper, not the line maps, so
        // its HTML getters need their own coverage — they are otherwise only
        // ever reached from Visualforce EL.
        Quote q = [SELECT Id FROM Quote LIMIT 1];
        Id pbId = Test.getStandardPricebookId();
        Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
        PricebookEntry pbe = [SELECT Id FROM PricebookEntry WHERE Pricebook2Id = :pbId LIMIT 1];

        insert new QuoteLineItem(
            QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = prod.Id,
            Quantity = 2, UnitPrice = 750000, Charge_Type__c = 'MRC',
            Line_Origin__c = 'Ramp', Ramp_Phase__c = 2,
            Ramp_Start_Date__c = Date.today().addMonths(1), SortOrder = 61,
            Line_Remarks__c = SFDC404_REMARKS,
            Product_Attribute_Value__c = '二百ボルト三十アンペア二重化対応'
        );

        Test.startTest();
        DE_QuoteTemplateController ctrl = new DE_QuoteTemplateController(new ApexPages.StandardController(q));
        Test.stopTest();

        DE_QuoteTemplateController.RampLineWrapper rlw = null;
        for (DE_QuoteTemplateController.RampPhaseWrapper pw : ctrl.rampPhases) {
            if (!pw.mrcLines.isEmpty()) { rlw = pw.mrcLines[0]; break; }
        }
        System.assertNotEquals(null, rlw, 'A ramp MRC wrapper was built');

        System.assert(rlw.NotesHtml.contains('<wbr/>'),
            'Ramp Remarks carries break opportunities: ' + rlw.NotesHtml);
        System.assertEquals(SFDC404_REMARKS, rlw.NotesHtml.replace('<wbr/>', ''),
            'Ramp Remarks text preserved in full');
        System.assert(rlw.ProductAttributeHtml.contains('<wbr/>'),
            'Ramp Attribute carries break opportunities: ' + rlw.ProductAttributeHtml);
        System.assertNotEquals(null, rlw.displayProductNameHtml, 'Ramp Product Name HTML present');
        System.assertNotEquals(null, rlw.UnitHtml,               'Ramp Unit HTML present');
    }

    // ─── SFDC-143: Additional Qty per phase ──────────────────────────────
    // The old rule was EndQuantity - StartQuantity. StartQuantity is never
    // populated, so it degenerated to the phase TOTAL. These two lock in the
    // replacement: subtract the previous phase only on an aggregate product,
    // where Quantity is a running total.

    private static PricebookEntry newPbe(Boolean isAggregate, String name) {
        Product2 p = new Product2(Name = name, ProductCode = name,
                                  IsActive = true, Merge_IB_Task__c = isAggregate,
                                  QuantityUnitOfMeasure = 'Unit');
        insert p;
        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(), Product2Id = p.Id,
            UnitPrice = 100, IsActive = true);
        insert pbe;
        return pbe;
    }

    @IsTest
    static void testController_additionalQtyAggregateIsThePhaseDelta() {
        Quote q = [SELECT Id FROM Quote LIMIT 1];
        PricebookEntry pbe = newPbe(true, 'SFDC143 Aggregate');

        // Running total 1 -> 3 -> 3. Phase 3 only reprices, so it adds nothing.
        QuoteLineItem anchor = new QuoteLineItem(
            QuoteId = q.Id, PricebookEntryId = pbe.Id, Quantity = 1, UnitPrice = 100,
            Charge_Type__c = 'MRC', Line_Origin__c = 'Ramp', Ramp_Phase__c = 1, SortOrder = 10);
        insert anchor;
        insert new List<QuoteLineItem>{
            new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = pbe.Id, Quantity = 3,
                UnitPrice = 100, Charge_Type__c = 'MRC', Line_Origin__c = 'Ramp',
                Ramp_Phase__c = 2, SortOrder = 11, Ramp_Parent_Line__c = anchor.Id),
            new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = pbe.Id, Quantity = 3,
                UnitPrice = 110, Charge_Type__c = 'MRC', Line_Origin__c = 'Ramp',
                Ramp_Phase__c = 3, SortOrder = 12, Ramp_Parent_Line__c = anchor.Id)
        };

        Test.startTest();
        DE_QuoteTemplateController ctrl =
            new DE_QuoteTemplateController(new ApexPages.StandardController(q));
        Test.stopTest();

        Map<String, Decimal> additionalByPhase = new Map<String, Decimal>();
        for (DE_QuoteTemplateController.RampPhaseWrapper pw : ctrl.rampPhases) {
            for (DE_QuoteTemplateController.RampLineWrapper rl : pw.mrcLines) {
                if (rl.Product2.Name == 'SFDC143 Aggregate') {
                    additionalByPhase.put(pw.phaseNumber, rl.rampAdditionalQty);
                }
            }
        }
        // Phase 1 has no predecessor, so the whole running total reads as additional —
        // that is what makes the column sum to the aggregate total (1 + 2 + 0 = 3).
        System.assertEquals(1, additionalByPhase.get('Ramp-1'), 'Phase 1 additional = its own running total');
        System.assertEquals(2, additionalByPhase.get('Ramp-2'), 'Phase 2 additional = 3 - 1, NOT the total 3');
        System.assertEquals(0, additionalByPhase.get('Ramp-3'), 'Phase 3 only reprices, so it adds nothing');
    }

    @IsTest
    static void testController_additionalQtyNonAggregateIsTheLineQuantity() {
        Quote q = [SELECT Id FROM Quote LIMIT 1];
        PricebookEntry pbe = newPbe(false, 'SFDC143 Plain');

        // Quantity is ALREADY the per-phase increment here, so it must not be
        // subtracted. Phase 3 reprices phase 1 and therefore adds nothing.
        QuoteLineItem anchor = new QuoteLineItem(
            QuoteId = q.Id, PricebookEntryId = pbe.Id, Quantity = 2, UnitPrice = 100,
            Charge_Type__c = 'MRC', Line_Origin__c = 'Ramp', Ramp_Phase__c = 1, SortOrder = 10);
        insert anchor;
        insert new List<QuoteLineItem>{
            new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = pbe.Id, Quantity = 3,
                UnitPrice = 100, Charge_Type__c = 'MRC', Line_Origin__c = 'Ramp',
                Ramp_Phase__c = 2, SortOrder = 11, Ramp_Parent_Line__c = anchor.Id),
            new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = pbe.Id, Quantity = 2,
                UnitPrice = 120, Charge_Type__c = 'MRC', Line_Origin__c = 'Ramp',
                Ramp_Phase__c = 3, SortOrder = 12, Ramp_Parent_Line__c = anchor.Id,
                Ramp_Linked_Phase__c = 1)
        };

        Test.startTest();
        DE_QuoteTemplateController ctrl =
            new DE_QuoteTemplateController(new ApexPages.StandardController(q));
        Test.stopTest();

        Map<String, Decimal> additionalByPhase = new Map<String, Decimal>();
        for (DE_QuoteTemplateController.RampPhaseWrapper pw : ctrl.rampPhases) {
            for (DE_QuoteTemplateController.RampLineWrapper rl : pw.mrcLines) {
                if (rl.Product2.Name == 'SFDC143 Plain') {
                    additionalByPhase.put(pw.phaseNumber, rl.rampAdditionalQty);
                }
            }
        }
        System.assertEquals(2, additionalByPhase.get('Ramp-1'), 'Non-aggregate phase 1 additional = its quantity');
        System.assertEquals(3, additionalByPhase.get('Ramp-2'), 'Non-aggregate phase 2 additional = its quantity, not 3 - 2');
        System.assertEquals(0, additionalByPhase.get('Ramp-3'), 'A repricing phase adds no quantity');
    }

    // SFDC-585: the Indonet logo needs an EPIX (IXP) line AND an Indonesian entity.
    private static Boolean epixLogoFor(String entityCountry) {
        Quote q = [SELECT Id FROM Quote LIMIT 1];
        Product2 prod = [SELECT Id FROM Product2 WHERE Name = 'Full Cab' LIMIT 1];
        prod.ProductCode = 'IXP001.RC';
        update prod;

        Id deEntityRtId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('DE_Entity').getRecordTypeId();
        Account entity = new Account(
            Name = 'DE ' + entityCountry + ' Entity', RecordTypeId = deEntityRtId, Operation_Country__c = entityCountry
        );
        insert entity;
        q.DE_Entity__c = entity.Id;
        update q;

        Test.startTest();
        DE_QuoteTemplateController ctrl = new DE_QuoteTemplateController(new ApexPages.StandardController(q));
        Test.stopTest();
        return ctrl.hasEpixProduct;
    }

    @IsTest
    static void testEpixLogo_indonesianEntity() {
        System.assertEquals(true, epixLogoFor('Indonesia'), 'IXP line on an Indonesian entity shows the Indonet logo');
    }

    @IsTest
    static void testEpixLogo_philippineEntity() {
        System.assertEquals(false, epixLogoFor('Philippines'), 'IXP line on a Philippine entity must not show the Indonet logo');
    }
}