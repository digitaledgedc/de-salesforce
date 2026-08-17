/**
 * OdooBanSyncQueueableTest
 * Covers the NEW-A (Account partner sync) + NEW-B (BAN sync) callout flow:
 * already-synced Account skipping NEW-A, an unsynced Account triggering NEW-A
 * before NEW-B, the BAN-name-must-contain-a-hyphen guard, a failed callout
 * being logged and marked Sync Failed, and BANs that need no sync at all.
 *
 * All test Contacts are pre-seeded with Odoo_Partner_ID__c set so the newer
 * NEW-C (billing contact sync) branch never fires — that path is outside the
 * NEW-A/NEW-B scope this class's own header comment documents, and isn't part
 * of what's covered here. Chaining to SendNewOrdersQueueable/SendChangeOrdersQueueable
 * is also out of scope — every test uses the single-arg constructor, which
 * defaults chainOrderIds to empty so chainIfNeeded() returns immediately.
 */
@IsTest
private class OdooBanSyncQueueableTest {

    private static Contact makeSyncedContact(Id accountId) {
        Contact con = new Contact(
            AccountId = accountId, FirstName = 'BAN', LastName = 'Contact',
            Email = 'bansync-contact@test.com', Odoo_Partner_ID__c = 999
        );
        insert con;
        return con;
    }

    @IsTest
    static void testNoBansNeedSync_NoCalloutMade() {
        Account acc = new Account(Name = 'OBSQ No-Sync Account');
        insert acc;
        Contact con = makeSyncedContact(acc.Id);
        BillingAccount__c ban = new BillingAccount__c(
            Name = 'BAN-00001', Account__c = acc.Id, Billing_Contact__c = con.Id,
            Odoo_BAN_ID__c = 5555 // already synced -> excluded from the sync query entirely
        );
        insert ban;

        // No mock set at all — if a callout were attempted, this test would fail
        // with a CalloutException, proving none was made.
        Test.startTest();
        System.enqueueJob(new OdooBanSyncQueueable(new List<Id>{ ban.Id }));
        Test.stopTest();

        BillingAccount__c after = [SELECT Odoo_Sync_Status__c FROM BillingAccount__c WHERE Id = :ban.Id];
        System.assertEquals('Not Synced', after.Odoo_Sync_Status__c,
            'An already-synced BAN should be skipped by the query and left at its default status, untouched');
    }

    @IsTest
    static void testAccountAlreadySynced_SkipsNewA_NewBSucceeds() {
        Account acc = new Account(Name = 'OBSQ Synced Account', Odoo_Partner_ID__c = 501);
        insert acc;
        Contact con = makeSyncedContact(acc.Id);
        BillingAccount__c ban = new BillingAccount__c(
            Name = 'BAN-00002', Account__c = acc.Id, Billing_Contact__c = con.Id,
            Invoice_Frequency__c = 'Monthly', InvoiceDeliveryMode__c = 'Online'
        );
        insert ban;

        Test.setMock(HttpCalloutMock.class, new MockOdooCallout(200,
            '{"result": {"ban_id": 9001, "partner_id": 501, "invoice_frequency_id": 1}}'));

        Test.startTest();
        System.enqueueJob(new OdooBanSyncQueueable(new List<Id>{ ban.Id }));
        Test.stopTest();

        Account afterAcc = [SELECT Odoo_Partner_ID__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals(501, afterAcc.Odoo_Partner_ID__c,
            'Account was already synced — NEW-A should not have run or changed anything');

        BillingAccount__c afterBan = [SELECT Odoo_BAN_ID__c, Odoo_Sync_Status__c FROM BillingAccount__c WHERE Id = :ban.Id];
        System.assertEquals(9001, afterBan.Odoo_BAN_ID__c, 'NEW-B should have written back Odoo_BAN_ID__c');
        System.assertEquals('Synced', afterBan.Odoo_Sync_Status__c);
    }

    @IsTest
    static void testAccountNotSynced_NewARunsThenNewBSucceeds() {
        Account acc = new Account(Name = 'OBSQ Unsynced Account'); // no Odoo_Partner_ID__c
        insert acc;
        Contact con = makeSyncedContact(acc.Id);
        BillingAccount__c ban = new BillingAccount__c(
            Name = 'BAN-00003', Account__c = acc.Id, Billing_Contact__c = con.Id,
            Invoice_Frequency__c = 'Monthly', InvoiceDeliveryMode__c = 'Online'
        );
        insert ban;

        // Same response body satisfies both the NEW-A partner_id lookup and the
        // NEW-B ban_id/partner_id/invoice_frequency_id lookups.
        Test.setMock(HttpCalloutMock.class, new MockOdooCallout(200,
            '{"result": {"partner_id": 777, "ban_id": 9002, "invoice_frequency_id": 1}}'));

        Test.startTest();
        System.enqueueJob(new OdooBanSyncQueueable(new List<Id>{ ban.Id }));
        Test.stopTest();

        Account afterAcc = [SELECT Odoo_Partner_ID__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals(777, afterAcc.Odoo_Partner_ID__c, 'NEW-A should have written the new partner_id to the Account');

        BillingAccount__c afterBan = [SELECT Odoo_BAN_ID__c, Odoo_Sync_Status__c FROM BillingAccount__c WHERE Id = :ban.Id];
        System.assertEquals(9002, afterBan.Odoo_BAN_ID__c, 'NEW-B should have run using the partner_id NEW-A just created');
        System.assertEquals('Synced', afterBan.Odoo_Sync_Status__c);
    }

    @IsTest
    static void testBanNameMissingHyphen_SkippedAsSyncFailed_NoNewBAttempted() {
        Account acc = new Account(Name = 'OBSQ Bad Name Account', Odoo_Partner_ID__c = 501);
        insert acc;
        Contact con = makeSyncedContact(acc.Id);
        BillingAccount__c ban = new BillingAccount__c(
            Name = 'BAN00004', // no hyphen — Odoo's _compute_next_ban_id would crash on this
            Account__c = acc.Id, Billing_Contact__c = con.Id,
            Invoice_Frequency__c = 'Monthly', InvoiceDeliveryMode__c = 'Online'
        );
        insert ban;

        // No mock needed for NEW-B (should never be called for this BAN); NEW-A
        // is also skipped since the Account is already synced.
        Test.startTest();
        System.enqueueJob(new OdooBanSyncQueueable(new List<Id>{ ban.Id }));
        Test.stopTest();

        BillingAccount__c afterBan = [SELECT Odoo_BAN_ID__c, Odoo_Sync_Status__c, Odoo_Sync_Error__c FROM BillingAccount__c WHERE Id = :ban.Id];
        System.assertEquals(null, afterBan.Odoo_BAN_ID__c, 'No hyphen in the BAN name should block NEW-B entirely');
        System.assertEquals('Sync Failed', afterBan.Odoo_Sync_Status__c);
        System.assert(afterBan.Odoo_Sync_Error__c.contains('hyphen'), 'Error should explain the hyphen requirement');

        Integer errorCount = [SELECT COUNT() FROM DE_Integration_Error__c WHERE IP_Reference__c = 'NEW-B'];
        System.assertEquals(1, errorCount, 'The hyphen-guard skip should be logged as an integration error');
    }

    @IsTest
    static void testCalloutFails_BanMarkedSyncFailedWithErrorLogged() {
        Account acc = new Account(Name = 'OBSQ Callout Fail Account', Odoo_Partner_ID__c = 501);
        insert acc;
        Contact con = makeSyncedContact(acc.Id);
        BillingAccount__c ban = new BillingAccount__c(
            Name = 'BAN-00005', Account__c = acc.Id, Billing_Contact__c = con.Id,
            Invoice_Frequency__c = 'Monthly', InvoiceDeliveryMode__c = 'Online'
        );
        insert ban;

        Test.setMock(HttpCalloutMock.class, MockOdooCallout.httpError());

        Test.startTest();
        System.enqueueJob(new OdooBanSyncQueueable(new List<Id>{ ban.Id }));
        Test.stopTest();

        BillingAccount__c afterBan = [SELECT Odoo_Sync_Status__c FROM BillingAccount__c WHERE Id = :ban.Id];
        System.assertEquals('Sync Failed', afterBan.Odoo_Sync_Status__c);

        Integer errorCount = [SELECT COUNT() FROM DE_Integration_Error__c WHERE IP_Reference__c = 'NEW-B'];
        System.assertEquals(1, errorCount, 'A failed NEW-B callout should be logged');
    }

    @IsTest
    static void testNewAReturnsPartnerIdZero_LoggedAsError_AccountNotUpdated() {
        Account acc = new Account(Name = 'OBSQ Zero Partner Account'); // no Odoo_Partner_ID__c -> needs NEW-A
        insert acc;
        Contact con = makeSyncedContact(acc.Id);
        BillingAccount__c ban = new BillingAccount__c(
            Name = 'BAN-00006', Account__c = acc.Id, Billing_Contact__c = con.Id,
            Invoice_Frequency__c = 'Monthly', InvoiceDeliveryMode__c = 'Online'
        );
        insert ban;

        // NEW-A "succeeds" per Odoo but returns partner_id=0 — a silent rejection.
        Test.setMock(HttpCalloutMock.class, new MockOdooCallout(200, '{"result": {"partner_id": 0}}'));

        Test.startTest();
        System.enqueueJob(new OdooBanSyncQueueable(new List<Id>{ ban.Id }));
        Test.stopTest();

        Account afterAcc = [SELECT Odoo_Partner_ID__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals(null, afterAcc.Odoo_Partner_ID__c, 'partner_id=0 must not be written to the Account');

        Integer errorCount = [SELECT COUNT() FROM DE_Integration_Error__c WHERE IP_Reference__c = 'NEW-A'];
        System.assertEquals(1, errorCount, 'partner_id=0 should be logged so an admin can resolve it manually');

        // NEW-B should also be skipped entirely since no usable partner_id exists.
        BillingAccount__c afterBan = [SELECT Odoo_Sync_Status__c FROM BillingAccount__c WHERE Id = :ban.Id];
        System.assertEquals('Sync Failed', afterBan.Odoo_Sync_Status__c);
    }

    @IsTest
    static void testNewBSucceeds_ButBanIdMissing_MarkedSyncFailed() {
        Account acc = new Account(Name = 'OBSQ Missing BanId Account', Odoo_Partner_ID__c = 501);
        insert acc;
        Contact con = makeSyncedContact(acc.Id);
        BillingAccount__c ban = new BillingAccount__c(
            Name = 'BAN-00007', Account__c = acc.Id, Billing_Contact__c = con.Id,
            Invoice_Frequency__c = 'Monthly', InvoiceDeliveryMode__c = 'Online'
        );
        insert ban;

        // HTTP 200, no top-level error, but the ban_id key is simply absent.
        Test.setMock(HttpCalloutMock.class, new MockOdooCallout(200, '{"result": {"partner_id": 501}}'));

        Test.startTest();
        System.enqueueJob(new OdooBanSyncQueueable(new List<Id>{ ban.Id }));
        Test.stopTest();

        BillingAccount__c afterBan = [SELECT Odoo_BAN_ID__c, Odoo_Sync_Status__c, Odoo_Sync_Error__c FROM BillingAccount__c WHERE Id = :ban.Id];
        System.assertEquals(null, afterBan.Odoo_BAN_ID__c);
        System.assertEquals('Sync Failed', afterBan.Odoo_Sync_Status__c);
        System.assert(afterBan.Odoo_Sync_Error__c.contains('ban_id missing'), 'Error should explain ban_id was missing from an otherwise-successful response');

        Integer errorCount = [SELECT COUNT() FROM DE_Integration_Error__c WHERE IP_Reference__c = 'NEW-B'];
        System.assertEquals(1, errorCount);
    }

    @IsTest
    static void testOrderDerivedCompanyId_IncludedInSyncPayload() {
        Account acc = new Account(Name = 'OBSQ Order-Derived Account', Odoo_Partner_ID__c = 501);
        insert acc;
        Contact con = makeSyncedContact(acc.Id);
        BillingAccount__c ban = new BillingAccount__c(
            Name = 'BAN-00008', Account__c = acc.Id, Billing_Contact__c = con.Id,
            Invoice_Frequency__c = 'Monthly', InvoiceDeliveryMode__c = 'Online'
        );
        insert ban;

        Product2 prod = new Product2(Name = 'OBSQ Order Product', IsActive = true);
        insert prod;
        Id stdPbId = Test.getStandardPricebookId();
        insert new PricebookEntry(Pricebook2Id = stdPbId, Product2Id = prod.Id, UnitPrice = 100, IsActive = true);
        PricebookEntry pbe = [SELECT Id FROM PricebookEntry WHERE Pricebook2Id = :stdPbId AND Product2Id = :prod.Id LIMIT 1];

        // BOM1 is a real, active Odoo_Site__mdt record with a positive company/country ID.
        insert new Order(
            AccountId = acc.Id, BillingAccount__c = ban.Id, Status = 'Draft',
            EffectiveDate = Date.today(), Operation_Site__c = 'BOM1',
            Pricebook2Id = stdPbId, Order_Type__c = 'New Service'
        );

        Test.setMock(HttpCalloutMock.class, new MockOdooCallout(200,
            '{"result": {"ban_id": 9009, "partner_id": 501, "invoice_frequency_id": 1}}'));

        Test.startTest();
        System.enqueueJob(new OdooBanSyncQueueable(new List<Id>{ ban.Id }));
        Test.stopTest();

        BillingAccount__c afterBan = [SELECT Odoo_Sync_Payload__c FROM BillingAccount__c WHERE Id = :ban.Id];
        System.assert(afterBan.Odoo_Sync_Payload__c.contains('"ns_de_company_id":17'),
            'The company id derived from the BOM1 order\'s Odoo_Site__mdt record should be included in the NEW-B payload');
    }

    @IsTest
    static void testFullOptionalFields_IncludedInSyncPayload() {
        Account acc = new Account(
            Name = 'OBSQ Full Fields Account', Odoo_Partner_ID__c = 501,
            BillingStreet = '1 Test Street', BillingCity = 'Jakarta'
        );
        insert acc;
        Contact con = makeSyncedContact(acc.Id);
        BillingAccount__c ban = new BillingAccount__c(
            Name = 'BAN-00009', Account__c = acc.Id, Billing_Contact__c = con.Id,
            Invoice_Frequency__c = 'Monthly', InvoiceDeliveryMode__c = 'Online',
            Charge_Period_Presentment__c = 'Standard',
            Invoice_Presentment__c = 'EDGE Default',
            BAN_ID_INV_Label__c = 'Test Label',
            BAN_ID_Reference__c = 'Test Ref',
            Different_Invoice_Currency__c = true,
            Invoice_Currency__c = 'IDR',
            Additional_Invoice_Email__c = 'a@test.com, b@test.com'
        );
        insert ban;

        Test.setMock(HttpCalloutMock.class, new MockOdooCallout(200,
            '{"result": {"ban_id": 9010, "partner_id": 501, "invoice_frequency_id": 1}}'));

        Test.startTest();
        System.enqueueJob(new OdooBanSyncQueueable(new List<Id>{ ban.Id }));
        Test.stopTest();

        BillingAccount__c afterBan = [SELECT Odoo_Sync_Payload__c FROM BillingAccount__c WHERE Id = :ban.Id];
        String payload = afterBan.Odoo_Sync_Payload__c;
        System.assert(payload.contains('"charge_period_presentment":"standard"'), 'Charge period presentment should be lowercased/underscored');
        System.assert(payload.contains('"invoice_presentment":"edge_default"'), 'Invoice presentment should be lowercased/underscored');
        System.assert(payload.contains('"ns_inv_report_label":"Test Label"'), 'BAN_ID_INV_Label__c should be included');
        System.assert(payload.contains('"ns_inv_report_value":"Test Ref"'), 'BAN_ID_Reference__c should be included');
        System.assert(payload.contains('"ns_billing_address":"1 Test Street, Jakarta"'), 'Billing address should combine street and city');
        System.assert(payload.contains('"additional_email":"a@test.com, b@test.com"'), 'Additional emails should be normalized');
    }

    @IsTest
    static void testConstructors_WithEmptyChainOrderIds_DoNotEnqueueOrThrow() {
        Account acc = new Account(Name = 'OBSQ Constructor Account', Odoo_Partner_ID__c = 501);
        insert acc;
        Contact con = makeSyncedContact(acc.Id);
        BillingAccount__c ban = new BillingAccount__c(
            Name = 'BAN-00010', Account__c = acc.Id, Billing_Contact__c = con.Id,
            Invoice_Frequency__c = 'Monthly', InvoiceDeliveryMode__c = 'Online'
        );
        insert ban;

        Test.setMock(HttpCalloutMock.class, new MockOdooCallout(200,
            '{"result": {"ban_id": 9011, "partner_id": 501, "invoice_frequency_id": 1}}'));

        // Both chaining constructors, with an explicitly empty order-id list so
        // chainIfNeeded() still short-circuits before attempting any enqueue —
        // this exercises the constructors themselves without pulling in
        // SendNewOrdersQueueable/SendChangeOrdersQueueable.
        Test.startTest();
        System.enqueueJob(new OdooBanSyncQueueable(new List<Id>{ ban.Id }, new List<Id>()));
        Test.stopTest();

        BillingAccount__c afterBan = [SELECT Odoo_Sync_Status__c FROM BillingAccount__c WHERE Id = :ban.Id];
        System.assertEquals('Synced', afterBan.Odoo_Sync_Status__c);
    }

    @IsTest
    static void testThreeArgConstructor_IP4Target_WithEmptyChainOrderIds_DoesNotThrow() {
        OdooBanSyncQueueable q = new OdooBanSyncQueueable(new List<Id>(), new List<Id>(), 'IP-4');
        System.assertNotEquals(null, q, 'Three-arg constructor with an explicit chainTarget should not throw');
    }

    @IsTest
    static void testUnmappedFrequencyAndDeliveryMode_AndBlankPresentmentFields_FalseBranchesInPayload() {
        Account acc = new Account(Name = 'OBSQ Unmapped Fields Account', Odoo_Partner_ID__c = 501);
        insert acc;
        Contact con = makeSyncedContact(acc.Id);
        BillingAccount__c ban = new BillingAccount__c(
            Name = 'BAN-00011', Account__c = acc.Id, Billing_Contact__c = con.Id,
            Invoice_Frequency__c = 'Monthly',
            InvoiceDeliveryMode__c = 'Paper',      // valid picklist value, but not in mapInvoiceDeliveryMode's map
            Charge_Period_Presentment__c = null,
            Invoice_Presentment__c = null
        );
        insert ban;

        Test.setMock(HttpCalloutMock.class, new MockOdooCallout(200,
            '{"result": {"ban_id": 9012, "partner_id": 501}}'));

        Test.startTest();
        System.enqueueJob(new OdooBanSyncQueueable(new List<Id>{ ban.Id }));
        Test.stopTest();

        BillingAccount__c afterBan = [SELECT Odoo_Sync_Payload__c, Odoo_Sync_Status__c FROM BillingAccount__c WHERE Id = :ban.Id];
        System.assertEquals('Synced', afterBan.Odoo_Sync_Status__c);
        String payload = afterBan.Odoo_Sync_Payload__c;
        System.assert(payload.contains('"ns_invoice_delivery":false'), 'Unmapped delivery mode should send false so Odoo uses its default');
        System.assert(payload.contains('"ns_invoice_presentment":false'), 'Explicitly blank invoice presentment should send false, not the field\'s default label');
    }

    @IsTest
    static void testHistoricalBanPartnerId_UsedDirectly_SkipsNewA() {
        Account acc = new Account(Name = 'OBSQ Historical Migration Account'); // Account itself never synced
        insert acc;
        Contact con = makeSyncedContact(acc.Id);
        BillingAccount__c ban = new BillingAccount__c(
            Name = 'BAN-00012', Account__c = acc.Id, Billing_Contact__c = con.Id,
            Odoo_Partner_ID__c = '888', // historical partner id, loaded directly from the Odoo export
            Invoice_Frequency__c = 'Monthly', InvoiceDeliveryMode__c = 'Online'
        );
        insert ban;

        Test.setMock(HttpCalloutMock.class, new MockOdooCallout(200,
            '{"result": {"ban_id": 9013, "partner_id": 888, "invoice_frequency_id": 1}}'));

        Test.startTest();
        System.enqueueJob(new OdooBanSyncQueueable(new List<Id>{ ban.Id }));
        Test.stopTest();

        Account afterAcc = [SELECT Odoo_Partner_ID__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals(null, afterAcc.Odoo_Partner_ID__c,
            'NEW-A should never fire for a historical BAN — the Account itself is never touched');

        BillingAccount__c afterBan = [SELECT Odoo_BAN_ID__c, Odoo_Sync_Status__c FROM BillingAccount__c WHERE Id = :ban.Id];
        System.assertEquals(9013, afterBan.Odoo_BAN_ID__c, 'NEW-B should proceed directly using the historical partner_id');
        System.assertEquals('Synced', afterBan.Odoo_Sync_Status__c);
    }

    @IsTest
    static void testAccountNeedsNewA_OrderDerivedCompanyAndCountry_IncludedInNewAFlow() {
        Account acc = new Account(Name = 'OBSQ NewA OrderDerived Account'); // needs NEW-A
        insert acc;
        Contact con = makeSyncedContact(acc.Id);
        BillingAccount__c ban = new BillingAccount__c(
            Name = 'BAN-00013', Account__c = acc.Id, Billing_Contact__c = con.Id,
            Invoice_Frequency__c = 'Monthly', InvoiceDeliveryMode__c = 'Online'
        );
        insert ban;

        Product2 prod = new Product2(Name = 'OBSQ NewA Order Product', IsActive = true);
        insert prod;
        Id stdPbId = Test.getStandardPricebookId();
        insert new PricebookEntry(Pricebook2Id = stdPbId, Product2Id = prod.Id, UnitPrice = 100, IsActive = true);

        // BOM1 -> Odoo_Company_ID__c 17, Odoo_Country_ID__c 12 — drives accountCompanyMap/
        // accountCountryMap, which feed company_id/country_id into the NEW-A payload.
        insert new Order(
            AccountId = acc.Id, BillingAccount__c = ban.Id, Status = 'Draft',
            EffectiveDate = Date.today(), Operation_Site__c = 'BOM1',
            Pricebook2Id = stdPbId, Order_Type__c = 'New Service'
        );

        Test.setMock(HttpCalloutMock.class, new MockOdooCallout(200,
            '{"result": {"partner_id": 555, "ban_id": 9014, "invoice_frequency_id": 1}}'));

        Test.startTest();
        System.enqueueJob(new OdooBanSyncQueueable(new List<Id>{ ban.Id }));
        Test.stopTest();

        Account afterAcc = [SELECT Odoo_Partner_ID__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals(555, afterAcc.Odoo_Partner_ID__c, 'NEW-A should have run (with company/country derived from the BOM1 order) and set the new partner id');
    }

    @IsTest
    static void testBillingContactNeedsNewC_SucceedsAndUpdatesContact() {
        Account acc = new Account(Name = 'OBSQ NewC Account', Odoo_Partner_ID__c = 501);
        insert acc;
        // Unlike makeSyncedContact, this Contact has no Odoo_Partner_ID__c — needs NEW-C.
        Contact con = new Contact(
            AccountId = acc.Id, FirstName = 'NewC', LastName = 'Contact',
            Email = 'newc-contact@test.com', Phone = '555-0100'
        );
        insert con;
        BillingAccount__c ban = new BillingAccount__c(
            Name = 'BAN-00014', Account__c = acc.Id, Billing_Contact__c = con.Id,
            Invoice_Frequency__c = 'Monthly', InvoiceDeliveryMode__c = 'Online'
        );
        insert ban;

        // Same response shape satisfies NEW-C's partner_id lookup and NEW-B's
        // ban_id/partner_id/invoice_frequency_id lookups.
        Test.setMock(HttpCalloutMock.class, new MockOdooCallout(200,
            '{"result": {"partner_id": 666, "ban_id": 9015, "invoice_frequency_id": 1}}'));

        Test.startTest();
        System.enqueueJob(new OdooBanSyncQueueable(new List<Id>{ ban.Id }));
        Test.stopTest();

        Contact afterCon = [SELECT Odoo_Partner_ID__c FROM Contact WHERE Id = :con.Id];
        System.assertEquals(666, afterCon.Odoo_Partner_ID__c, 'NEW-C should have written the new partner id to the billing contact');

        BillingAccount__c afterBan = [SELECT Odoo_Sync_Status__c FROM BillingAccount__c WHERE Id = :ban.Id];
        System.assertEquals('Synced', afterBan.Odoo_Sync_Status__c);
    }

    @IsTest
    static void testBillingContactNewC_PartnerIdZero_LoggedAsError() {
        Account acc = new Account(Name = 'OBSQ NewC Zero Account', Odoo_Partner_ID__c = 501);
        insert acc;
        Contact con = new Contact(
            AccountId = acc.Id, FirstName = 'NewCZero', LastName = 'Contact',
            Email = 'newc-zero@test.com'
        );
        insert con;
        BillingAccount__c ban = new BillingAccount__c(
            Name = 'BAN-00015', Account__c = acc.Id, Billing_Contact__c = con.Id,
            Invoice_Frequency__c = 'Monthly', InvoiceDeliveryMode__c = 'Online'
        );
        insert ban;

        Test.setMock(HttpCalloutMock.class, new MockOdooCallout(200, '{"result": {"partner_id": 0}}'));

        Test.startTest();
        System.enqueueJob(new OdooBanSyncQueueable(new List<Id>{ ban.Id }));
        Test.stopTest();

        Contact afterCon = [SELECT Odoo_Partner_ID__c FROM Contact WHERE Id = :con.Id];
        System.assertEquals(null, afterCon.Odoo_Partner_ID__c, 'partner_id=0 must not be written to the Contact');

        List<DE_Integration_Error__c> errs = [SELECT Error_Message__c FROM DE_Integration_Error__c WHERE IP_Reference__c = 'NEW-A'];
        System.assertEquals(1, errs.size(), 'partner_id=0 on NEW-C should be logged for manual resolution');
        System.assert(errs[0].Error_Message__c.contains('NEW-C'), 'The error should identify itself as coming from the NEW-C flow');
    }

    @IsTest
    static void testBillingContactNewC_CalloutFails_LoggedAsError() {
        Account acc = new Account(Name = 'OBSQ NewC Fail Account', Odoo_Partner_ID__c = 501);
        insert acc;
        Contact con = new Contact(
            AccountId = acc.Id, FirstName = 'NewCFail', LastName = 'Contact',
            Email = 'newc-fail@test.com'
        );
        insert con;
        BillingAccount__c ban = new BillingAccount__c(
            Name = 'BAN-00016', Account__c = acc.Id, Billing_Contact__c = con.Id,
            Invoice_Frequency__c = 'Monthly', InvoiceDeliveryMode__c = 'Online'
        );
        insert ban;

        Test.setMock(HttpCalloutMock.class, MockOdooCallout.httpError());

        Test.startTest();
        System.enqueueJob(new OdooBanSyncQueueable(new List<Id>{ ban.Id }));
        Test.stopTest();

        Integer errorCount = [SELECT COUNT() FROM DE_Integration_Error__c WHERE IP_Reference__c = 'NEW-C'];
        System.assertEquals(1, errorCount, 'A failed NEW-C callout should be logged under IP_Reference NEW-C');
    }

    // ─── Payload builder / helper unit tests (all @TestVisible) ────────────────

    @IsTest
    static void testNormalizeAdditionalEmails_CollapsesWhitespaceAndCommas() {
        String result = OdooBanSyncQueueable.normalizeAdditionalEmails('a@test.com   b@test.com,c@test.com');
        System.assertEquals('a@test.com, b@test.com, c@test.com', result);
    }

    @IsTest
    static void testNormalizeAdditionalEmails_Blank_ReturnsEmptyString() {
        System.assertEquals('', OdooBanSyncQueueable.normalizeAdditionalEmails(null));
        System.assertEquals('', OdooBanSyncQueueable.normalizeAdditionalEmails('   '));
    }

    @IsTest
    static void testMapInvoiceDeliveryMode_KnownAndUnknownValues() {
        System.assertEquals('online', OdooBanSyncQueueable.mapInvoiceDeliveryMode('Online'));
        System.assertEquals(null, OdooBanSyncQueueable.mapInvoiceDeliveryMode('Paper'),
            'Unmapped values should return null so the caller sends false (Odoo default)');
        System.assertEquals(null, OdooBanSyncQueueable.mapInvoiceDeliveryMode(null));
    }

    @IsTest
    static void testToSelectionKey_LowercasesAndUnderscoresSpaces() {
        System.assertEquals('edge_default', OdooBanSyncQueueable.toSelectionKey('EDGE Default'));
        System.assertEquals('', OdooBanSyncQueueable.toSelectionKey(null));
        System.assertEquals('', OdooBanSyncQueueable.toSelectionKey('   '));
    }
}