/**
 * OdooInvoiceSyncHandler
 * IP-5: Inbound REST endpoint. Odoo POSTs invoice and payment data from the daily billing run.
 * SF stores the financial amounts and derives Payment_Status__c from them.
 *
 * Endpoint:  POST /services/apexrest/de/invoicesync
 * Cadence:   Daily 06:00 HKT (initiated by Odoo billing engine).
 * Auth:      SF OAuth2 Client Credentials (same connected app as other inbound endpoints).
 *
 * Payload schema:
 * {
 *   "invoices": [
 *     {
 *       "odoo_order_id":        <integer>,      // informational — not used for matching
 *       "odoo_line_id":         <integer>,      // PRIMARY match key → BillingEvent.Odoo_Line_ID__c
 *       "external_invoice_id":  "<string>",     // FALLBACK match key → BillingEvent.External_Invoice_Id__c
 *       "invoice_number":       "<string>",     // BillingEvent.Invoice_Number__c
 *       "invoice_date":         "YYYY-MM-DD",   // BillingEvent.Invoice_Date__c
 *       "invoice_amount":       <decimal>,      // BillingEvent.Invoice_Amount__c — total invoiced
 *       "amount_paid":          <decimal>,      // BillingEvent.Amount_Paid__c — total collected
 *       "balance":              <decimal>,      // BillingEvent.Balance__c — remaining owed
 *       "due_date":             "YYYY-MM-DD",   // BillingEvent.Due_Date__c — payment due date
 *       "payment_date":         "YYYY-MM-DD",   // BillingEvent.Payment_Date__c — last payment (nullable)
 *       "credit_note_ref":      "<string>",     // BillingEvent.Credit_Note_Reference__c (nullable)
 *       "credit_note_amount":   <decimal>       // BillingEvent.Credit_Note_Amount__c (nullable)
 *     }
 *   ]
 * }
 *
 * Payment_Status__c derivation (SF-side, not from Odoo):
 *   amount_paid >= invoice_amount               → "Paid"
 *   amount_paid > 0 AND amount_paid < invoice   → "Partially Paid"
 *   amount_paid = 0 AND today > due_date        → "Overdue"
 *   amount_paid = 0 AND today <= due_date       → "Invoiced - Unpaid"
 *
 * When fully paid: Status__c set to "Acknowledged".
 *
 * Match priority: Odoo_Line_ID__c → External_Invoice_Id__c.
 * Unmatched invoices are logged to DE_Integration_Error__c (IP-5). Processing continues.
 * Response:  200 { "status": "ok", "processed": N, "unmatched": M }
 */
@RestResource(urlMapping='/de/invoicesync')
global with sharing class OdooInvoiceSyncHandler {

    // ─── Payload DTOs ─────────────────────────────────────────────────────────

    @TestVisible
    class InvoiceSyncPayload {
        public List<InvoiceItem> invoices;
    }

    @TestVisible
    class InvoiceItem {
        public Long    odoo_order_id;
        public Long    odoo_line_id;
        public String  external_invoice_id;
        public String  invoice_number;
        public String  invoice_date;
        public Decimal invoice_amount;
        public Decimal amount_paid;
        public Decimal balance;
        public String  due_date;
        public String  payment_date;
        public String  credit_note_ref;
        public Decimal credit_note_amount;
    }

    // ─── Entry point ──────────────────────────────────────────────────────────

    @HttpPost
    global static void handlePost() {
        RestRequest  req = RestContext.request;
        RestResponse res = RestContext.response;

        try {
            InvoiceSyncPayload payload = (InvoiceSyncPayload) JSON.deserialize(
                req.requestBody.toString(), InvoiceSyncPayload.class);

            if (payload == null || payload.invoices == null || payload.invoices.isEmpty()) {
                res.statusCode = 400;
                res.responseBody = Blob.valueOf('{"error":"invoices array is required and must not be empty"}');
                return;
            }

            SyncResult result = processInvoices(payload.invoices);

            res.statusCode = 200;
            res.responseBody = Blob.valueOf(
                '{"status":"ok","processed":' + result.processed + ',"unmatched":' + result.unmatched + '}');

        } catch (Exception e) {
            res.statusCode = 500;
            res.responseBody = Blob.valueOf('{"error":"' + jsonSafe(e.getMessage()) + '"}');
        }
    }

    // ─── Processing ───────────────────────────────────────────────────────────

    @TestVisible
    static SyncResult processInvoices(List<InvoiceItem> items) {
        SyncResult result = new SyncResult();

        // Build lookup sets for batch query — match by odoo_line_id (preferred) or external_invoice_id
        Set<String> lineIds      = new Set<String>();
        Set<String> extInvIds    = new Set<String>();
        for (InvoiceItem item : items) {
            if (item.odoo_line_id != null) {
                lineIds.add(String.valueOf(item.odoo_line_id));
            }
            if (item.external_invoice_id != null && item.external_invoice_id != '') {
                extInvIds.add(item.external_invoice_id);
            }
        }

        // Single query — fetch all matching BillingEvents
        Map<String, BillingEvent__c> byLineId  = new Map<String, BillingEvent__c>();
        Map<String, BillingEvent__c> byExtInvId = new Map<String, BillingEvent__c>();

        for (BillingEvent__c be : [
            SELECT Id, Odoo_Line_ID__c, External_Invoice_Id__c,
                   Invoice_Number__c, Invoice_Date__c, Invoice_Amount__c,
                   Amount_Paid__c, Balance__c, Due_Date__c, Payment_Date__c,
                   Payment_Status__c, Credit_Note_Reference__c, Credit_Note_Amount__c,
                   Acknowledged_Date__c, Status__c
            FROM BillingEvent__c
            WHERE Odoo_Line_ID__c IN :lineIds
               OR External_Invoice_Id__c IN :extInvIds
        ]) {
            if (be.Odoo_Line_ID__c != null) {
                byLineId.put(be.Odoo_Line_ID__c, be);
            }
            if (be.External_Invoice_Id__c != null) {
                byExtInvId.put(be.External_Invoice_Id__c, be);
            }
        }

        List<BillingEvent__c> toUpdate = new List<BillingEvent__c>();

        for (InvoiceItem item : items) {
            BillingEvent__c be = null;
            String lineKey = item.odoo_line_id != null ? String.valueOf(item.odoo_line_id) : null;

            if (lineKey != null && byLineId.containsKey(lineKey)) {
                be = byLineId.get(lineKey);
            } else if (item.external_invoice_id != null && byExtInvId.containsKey(item.external_invoice_id)) {
                be = byExtInvId.get(item.external_invoice_id);
            }

            if (be == null) {
                OdooCalloutService.logError(null, 'IP-5',
                    'Unmatched invoice — odoo_line_id: ' + item.odoo_line_id
                    + ', external_invoice_id: ' + item.external_invoice_id);
                result.unmatched++;
                continue;
            }

            // Store financial amounts from Odoo
            if (item.invoice_number    != null) be.Invoice_Number__c        = item.invoice_number;
            if (item.invoice_date      != null) be.Invoice_Date__c          = Date.valueOf(item.invoice_date);
            if (item.invoice_amount    != null) be.Invoice_Amount__c        = item.invoice_amount;
            if (item.amount_paid       != null) be.Amount_Paid__c           = item.amount_paid;
            if (item.balance           != null) be.Balance__c               = item.balance;
            if (item.due_date          != null) be.Due_Date__c              = Date.valueOf(item.due_date);
            if (item.payment_date      != null) be.Payment_Date__c          = Date.valueOf(item.payment_date);
            if (item.credit_note_ref   != null) be.Credit_Note_Reference__c = item.credit_note_ref;
            if (item.credit_note_amount != null) be.Credit_Note_Amount__c   = item.credit_note_amount;

            // Derive Payment_Status__c from amounts — SF is the source of truth for status
            be.Payment_Status__c = derivePaymentStatus(
                be.Invoice_Amount__c, be.Amount_Paid__c, be.Due_Date__c);

            // Mark as Acknowledged when fully paid
            if ('Paid'.equals(be.Payment_Status__c)) {
                be.Status__c = 'Acknowledged';
                if (be.Acknowledged_Date__c == null) {
                    be.Acknowledged_Date__c = Date.today();
                }
            }

            toUpdate.add(be);
            result.processed++;
        }

        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
        return result;
    }

    // ─── Status derivation ────────────────────────────────────────────────────

    @TestVisible
    static String derivePaymentStatus(Decimal invoiceAmount, Decimal amountPaid, Date dueDate) {
        Decimal inv  = invoiceAmount != null ? invoiceAmount : 0;
        Decimal paid = amountPaid    != null ? amountPaid    : 0;

        if (inv > 0 && paid >= inv)                         return 'Paid';
        if (paid > 0 && paid < inv)                         return 'Partially Paid';
        if (dueDate != null && Date.today() > dueDate)      return 'Overdue';
        if (inv > 0)                                        return 'Invoiced - Unpaid';
        return 'Not Invoiced';
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    private static String jsonSafe(String s) {
        return s == null ? '' : s.replace('"', '\\"');
    }

    // ─── Result DTO ───────────────────────────────────────────────────────────

    @TestVisible
    class SyncResult {
        public Integer processed = 0;
        public Integer unmatched = 0;
    }
}