/**
 * OdooInvoiceSyncHandlerTest
 * IP-5: Tests for inbound invoice sync — Odoo POSTs financial data, SF derives Payment_Status__c.
 * Covers: amount-based status derivation, match keys, unmatched error logging, empty payload,
 * mixed batch, credit notes, partial payments, overdue logic.
 */
@IsTest
private class OdooInvoiceSyncHandlerTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(
            Name                 = 'IP5 Test Customer',
            BillingCountry       = 'Singapore',
            Operation_Country__c = 'Singapore',
            RecordTypeId         = [
                SELECT Id FROM RecordType
                WHERE SObjectType = 'Account' AND DeveloperName = 'Customer' LIMIT 1
            ].Id
        );
        insert acc;

        Id deEntityRtId = Schema.SObjectType.Account
            .getRecordTypeInfosByDeveloperName().get('DE_Entity').getRecordTypeId();
        Account sgEntity = new Account(
            Name = 'DE SG Pte Ltd',
            RecordTypeId = deEntityRtId
        );
        insert sgEntity;

        Contact con = new Contact(
            AccountId = acc.Id, FirstName = 'IP5', LastName = 'BillingContact',
            Email = 'ip5-billing@test.com'
        );
        insert con;

        // 'Email (PDF attachment)' is no longer a valid InvoiceDeliveryMode__c value
        // in this org — current picklist is just Online / Paper.
        BillingAccount__c ban = new BillingAccount__c(
            Account__c = acc.Id, DE_Entity__c = sgEntity.Id,
            Billing_Contact__c = con.Id,
            InvoiceDeliveryMode__c = 'Online'
        );
        insert ban;

        Product2 prod = new Product2(Name = 'IP5 Test Product', ProductCode = 'TESTIP5', IsActive = true);
        insert prod;

        Id stdPbId = Test.getStandardPricebookId();
        insert new PricebookEntry(Pricebook2Id = stdPbId, Product2Id = prod.Id, UnitPrice = 1000, IsActive = true);

        Order ord = new Order(
            AccountId = acc.Id, BillingAccount__c = ban.Id,
            Status = 'Draft', EffectiveDate = Date.today().addMonths(-3),
            Operation_Site__c = 'JKT1', Pricebook2Id = stdPbId,
            Order_Type__c = 'New Service', Contract_Term_Months__c = 24
        );
        insert ord;

        // BE matched by Odoo_Line_ID__c — will test full payment
        BillingEvent__c be1 = new BillingEvent__c(
            Order__c = ord.Id, BAN__c = ban.Id,
            Odoo_Line_ID__c = '4401', External_Invoice_Id__c = 'EXT-001',
            Status__c = 'Sent to Odoo', MRC_Amount__c = 2000.00,
            Billed_Quantity__c = 1, Original_Quantity__c = 1
        );

        // BE matched only by External_Invoice_Id__c — will test partial payment
        BillingEvent__c be2 = new BillingEvent__c(
            Order__c = ord.Id, BAN__c = ban.Id,
            External_Invoice_Id__c = 'EXT-002',
            Status__c = 'Sent to Odoo', MRC_Amount__c = 1500.00,
            Billed_Quantity__c = 1, Original_Quantity__c = 1
        );

        // BE for overdue test
        BillingEvent__c be3 = new BillingEvent__c(
            Order__c = ord.Id, BAN__c = ban.Id,
            Odoo_Line_ID__c = '4403',
            Status__c = 'Sent to Odoo', MRC_Amount__c = 3000.00,
            Billed_Quantity__c = 1, Original_Quantity__c = 1
        );

        // BE for credit note test
        BillingEvent__c be4 = new BillingEvent__c(
            Order__c = ord.Id, BAN__c = ban.Id,
            Odoo_Line_ID__c = '4404',
            Status__c = 'Sent to Odoo', MRC_Amount__c = 500.00,
            Billed_Quantity__c = 1, Original_Quantity__c = 1
        );

        insert new List<BillingEvent__c>{ be1, be2, be3, be4 };
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    private static void callEndpoint(String jsonBody) {
        RestRequest req = new RestRequest();
        req.requestURI  = '/services/apexrest/de/invoicesync';
        req.httpMethod  = 'POST';
        req.requestBody = Blob.valueOf(jsonBody);
        RestContext.request  = req;
        RestContext.response = new RestResponse();
    }

    // ─── Full payment → Paid + Acknowledged ──────────────────────────────────

    @IsTest
    static void testFullPayment_PaidAndAcknowledged() {
        callEndpoint('{"invoices":[{'
            + '"odoo_line_id": 4401,'
            + '"invoice_number": "INV-2026-001",'
            + '"invoice_date": "2026-05-01",'
            + '"invoice_amount": 2000.00,'
            + '"amount_paid": 2000.00,'
            + '"balance": 0,'
            + '"due_date": "2026-06-01",'
            + '"payment_date": "2026-05-20"'
            + '}]}');

        Test.startTest();
        OdooInvoiceSyncHandler.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        String body = RestContext.response.responseBody.toString();
        System.assert(body.contains('"processed":1'));
        System.assert(body.contains('"unmatched":0'));

        BillingEvent__c be = [
            SELECT Invoice_Number__c, Invoice_Date__c, Invoice_Amount__c,
                   Amount_Paid__c, Balance__c, Due_Date__c, Payment_Date__c,
                   Payment_Status__c, Status__c, Acknowledged_Date__c
            FROM BillingEvent__c WHERE Odoo_Line_ID__c = '4401'
        ];
        System.assertEquals('INV-2026-001', be.Invoice_Number__c);
        System.assertEquals(Date.valueOf('2026-05-01'), be.Invoice_Date__c);
        System.assertEquals(2000.00, be.Invoice_Amount__c);
        System.assertEquals(2000.00, be.Amount_Paid__c);
        System.assertEquals(0, be.Balance__c);
        System.assertEquals(Date.valueOf('2026-06-01'), be.Due_Date__c);
        System.assertEquals(Date.valueOf('2026-05-20'), be.Payment_Date__c);
        System.assertEquals('Paid', be.Payment_Status__c);
        System.assertEquals('Acknowledged', be.Status__c);
        System.assertNotEquals(null, be.Acknowledged_Date__c);
    }

    // ─── Partial payment → Partially Paid ────────────────────────────────────

    @IsTest
    static void testPartialPayment_PartiallyPaid() {
        callEndpoint('{"invoices":[{'
            + '"external_invoice_id": "EXT-002",'
            + '"invoice_number": "INV-2026-002",'
            + '"invoice_amount": 1500.00,'
            + '"amount_paid": 750.00,'
            + '"balance": 750.00,'
            + '"due_date": "2026-07-01"'
            + '}]}');

        Test.startTest();
        OdooInvoiceSyncHandler.handlePost();
        Test.stopTest();

        BillingEvent__c be = [
            SELECT Amount_Paid__c, Balance__c, Payment_Status__c, Status__c
            FROM BillingEvent__c WHERE External_Invoice_Id__c = 'EXT-002'
        ];
        System.assertEquals(750.00, be.Amount_Paid__c);
        System.assertEquals(750.00, be.Balance__c);
        System.assertEquals('Partially Paid', be.Payment_Status__c);
        System.assertNotEquals('Acknowledged', be.Status__c);
    }

    // ─── Overdue: no payment, past due date ──────────────────────────────────

    @IsTest
    static void testOverdue_NoPaidPastDueDate() {
        callEndpoint('{"invoices":[{'
            + '"odoo_line_id": 4403,'
            + '"invoice_number": "INV-OVERDUE",'
            + '"invoice_amount": 3000.00,'
            + '"amount_paid": 0,'
            + '"balance": 3000.00,'
            + '"due_date": "2025-01-01"'
            + '}]}');

        Test.startTest();
        OdooInvoiceSyncHandler.handlePost();
        Test.stopTest();

        BillingEvent__c be = [
            SELECT Payment_Status__c, Balance__c
            FROM BillingEvent__c WHERE Odoo_Line_ID__c = '4403'
        ];
        System.assertEquals('Overdue', be.Payment_Status__c);
        System.assertEquals(3000.00, be.Balance__c);
    }

    // ─── Invoiced - Unpaid: no payment, not yet due ──────────────────────────

    @IsTest
    static void testInvoicedUnpaid_NotYetDue() {
        callEndpoint('{"invoices":[{'
            + '"odoo_line_id": 4404,'
            + '"invoice_number": "INV-NOTDUE",'
            + '"invoice_amount": 500.00,'
            + '"amount_paid": 0,'
            + '"balance": 500.00,'
            + '"due_date": "2027-12-31"'
            + '}]}');

        Test.startTest();
        OdooInvoiceSyncHandler.handlePost();
        Test.stopTest();

        BillingEvent__c be = [
            SELECT Payment_Status__c
            FROM BillingEvent__c WHERE Odoo_Line_ID__c = '4404'
        ];
        System.assertEquals('Invoiced - Unpaid', be.Payment_Status__c);
    }

    // ─── Credit note fields populated ────────────────────────────────────────

    @IsTest
    static void testCreditNote_AmountAndRefPopulated() {
        callEndpoint('{"invoices":[{'
            + '"odoo_line_id": 4403,'
            + '"invoice_amount": 3000.00,'
            + '"amount_paid": 3000.00,'
            + '"balance": 0,'
            + '"due_date": "2026-06-01",'
            + '"credit_note_ref": "CN-2026-001",'
            + '"credit_note_amount": 500.00'
            + '}]}');

        Test.startTest();
        OdooInvoiceSyncHandler.handlePost();
        Test.stopTest();

        BillingEvent__c be = [
            SELECT Credit_Note_Reference__c, Credit_Note_Amount__c, Payment_Status__c
            FROM BillingEvent__c WHERE Odoo_Line_ID__c = '4403'
        ];
        System.assertEquals('CN-2026-001', be.Credit_Note_Reference__c);
        System.assertEquals(500.00, be.Credit_Note_Amount__c);
        System.assertEquals('Paid', be.Payment_Status__c);
    }

    // ─── Fallback to External_Invoice_Id__c ──────────────────────────────────

    @IsTest
    static void testFallbackToExternalInvoiceId() {
        callEndpoint('{"invoices":[{'
            + '"odoo_line_id": 99999,'
            + '"external_invoice_id": "EXT-002",'
            + '"invoice_amount": 1500.00,'
            + '"amount_paid": 1500.00,'
            + '"balance": 0,'
            + '"due_date": "2026-06-01"'
            + '}]}');

        Test.startTest();
        OdooInvoiceSyncHandler.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        BillingEvent__c be = [
            SELECT Payment_Status__c FROM BillingEvent__c WHERE External_Invoice_Id__c = 'EXT-002'
        ];
        System.assertEquals('Paid', be.Payment_Status__c);
    }

    // ─── Unmatched → error logged ────────────────────────────────────────────

    @IsTest
    static void testUnmatchedInvoice_LogsError() {
        callEndpoint('{"invoices":[{'
            + '"odoo_line_id": 99999,'
            + '"external_invoice_id": "DOES-NOT-EXIST",'
            + '"invoice_amount": 1000.00,'
            + '"amount_paid": 1000.00,'
            + '"balance": 0,'
            + '"due_date": "2026-06-01"'
            + '}]}');

        Test.startTest();
        OdooInvoiceSyncHandler.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        String body = RestContext.response.responseBody.toString();
        System.assert(body.contains('"processed":0'));
        System.assert(body.contains('"unmatched":1'));

        List<DE_Integration_Error__c> errors = [
            SELECT Error_Message__c FROM DE_Integration_Error__c WHERE IP_Reference__c = 'IP-5'
        ];
        System.assertEquals(1, errors.size());
        System.assert(errors[0].Error_Message__c.contains('99999'));
    }

    // ─── Empty payload → 400 ─────────────────────────────────────────────────

    @IsTest
    static void testEmptyPayload_Returns400() {
        callEndpoint('{"invoices":[]}');

        Test.startTest();
        OdooInvoiceSyncHandler.handlePost();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode);
    }

    // ─── Mixed batch ─────────────────────────────────────────────────────────

    @IsTest
    static void testMixedBatch_ProcessedAndUnmatched() {
        callEndpoint('{"invoices":['
            + '{"odoo_line_id": 4401, "invoice_amount": 2000, "amount_paid": 2000, "balance": 0, "due_date": "2026-06-01"},'
            + '{"odoo_line_id": 88888, "invoice_amount": 500, "amount_paid": 500, "balance": 0, "due_date": "2026-06-01"}'
            + ']}');

        Test.startTest();
        OdooInvoiceSyncHandler.handlePost();
        Test.stopTest();

        String body = RestContext.response.responseBody.toString();
        System.assert(body.contains('"processed":1'));
        System.assert(body.contains('"unmatched":1'));
    }

    // ─── derivePaymentStatus unit tests ──────────────────────────────────────

    @IsTest
    static void testDerivePaymentStatus_AllScenarios() {
        System.assertEquals('Paid',
            OdooInvoiceSyncHandler.derivePaymentStatus(1000, 1000, Date.today().addDays(30)));
        System.assertEquals('Paid',
            OdooInvoiceSyncHandler.derivePaymentStatus(1000, 1500, Date.today()));
        System.assertEquals('Partially Paid',
            OdooInvoiceSyncHandler.derivePaymentStatus(1000, 500, Date.today().addDays(30)));
        System.assertEquals('Overdue',
            OdooInvoiceSyncHandler.derivePaymentStatus(1000, 0, Date.today().addDays(-30)));
        System.assertEquals('Invoiced - Unpaid',
            OdooInvoiceSyncHandler.derivePaymentStatus(1000, 0, Date.today().addDays(30)));
        System.assertEquals('Not Invoiced',
            OdooInvoiceSyncHandler.derivePaymentStatus(0, 0, null));
    }
}