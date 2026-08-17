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

        QuoteLineItem anchor = new QuoteLineItem(
            QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = prod.Id,
            Quantity = 2, UnitPrice = 3000000, Charge_Type__c = 'MRC',
            Line_Origin__c = 'Ramp', Ramp_Phase__c = 1, SortOrder = 10
        );
        insert new List<QuoteLineItem>{
            anchor,
            new QuoteLineItem(
                QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = prod.Id,
                Quantity = 4, UnitPrice = 3000000, Charge_Type__c = 'MRC',
                Line_Origin__c = 'Ramp', Ramp_Phase__c = 2, SortOrder = 11
            )
        };

        Test.startTest();
        ApexPages.StandardController sc = new ApexPages.StandardController(q);
        DE_QuoteTemplateController ctrl = new DE_QuoteTemplateController(sc);
        Test.stopTest();

        System.assertEquals(true, ctrl.isRampDeal, 'Should be a ramp deal');
        // Every ramp phase — including phase 1 — now gets its own schedule table;
        // the base table is the aggregated "Lines view" built from phase-1 anchors.
        System.assertEquals(2, ctrl.rampPhases.size(), 'Phases 1 and 2 each get a ramp schedule table');
        System.assertEquals('Ramp-1', ctrl.rampPhases[0].phaseNumber, 'Displayed schedule starts at Ramp-1');
        System.assertEquals('Ramp-2', ctrl.rampPhases[1].phaseNumber, 'Second table is Ramp-2');
        System.assertEquals(1, ctrl.rampPhases[0].mrcLines.size(), 'Phase 1 should have 1 MRC line');
        System.assertEquals(1, ctrl.rampPhases[1].mrcLines.size(), 'Phase 2 should have 1 MRC line');
        System.assert(ctrl.rampPhases[0].subtotalMRC > 0, 'Phase 1 MRC subtotal should be > 0');

        // Base table = the @TestSetup non-ramp MRC line (8,000,000, see
        // testController_standardQuote) plus the aggregated phase-1 anchor.
        System.assertEquals(2, ctrl.mrcLines.size(), 'Setup MRC line plus the aggregated ramp anchor');
        Set<Id> baseMrcIds = new Set<Id>();
        for (QuoteLineItem li : ctrl.mrcLines) baseMrcIds.add(li.Id);
        System.assert(baseMrcIds.contains(anchor.Id), 'Phase-1 anchor carries the aggregated base row');

        // No Ramp_Parent_Line__c link and Merge_IB_Task__c false, so the anchor
        // aggregates to itself: qty 2 @ 3,000,000, no discount.
        System.assertEquals(2, ctrl.displayQtyByLineId.get(anchor.Id).intValue(), 'Aggregated qty = phase-1 qty');
        System.assertEquals(3000000, ctrl.displayUnitByLineId.get(anchor.Id).intValue(), 'Unit price from last phase');
        System.assertEquals(6000000, ctrl.displaySubtotalByLineId.get(anchor.Id).intValue(), 'Aggregated subtotal = qty * unit');
        System.assertEquals(14000000, ctrl.grandTotalMRC, 'MRC grand total = 8,000,000 setup line + 6,000,000 aggregated anchor');
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
}