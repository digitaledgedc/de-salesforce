/**
 * OdooCrossConnectHandler
 * IP-6: Inbound REST endpoint. Odoo POSTs cross-connect provisioning events when a new
 * cross-connect service has been provisioned in the data centre.
 * Creates an Order on the matching Account to track the active cross-connect service
 * with its MRC, site, and technical details.
 *
 * Endpoint:  POST /services/apexrest/de/crossconnect
 * Auth:      SF OAuth2 Client Credentials (same connected app as other inbound endpoints).
 *
 * Payload schema (Odoo → SF):
 * {
 *   "partner_id":          <integer>,   // Odoo partner ID — matches Account.Odoo_Partner_ID__c
 *   "odoo_order_id":       <integer>,   // Odoo Sale Order ID — stored on Order.Odoo_Order_ID__c
 *   "site_code":           "<string>",  // e.g. "SIN1", "TYO1" — maps to Operation_Site__c
 *   "cross_connect_type":  "<string>",  // "SMF" | "MMF" | "Coax" | "Ethernet"
 *   "remote_entity_name":  "<string>",  // Name of connected entity (carrier, cloud, etc.)
 *   "remote_entity_type":  "<string>",  // "Carrier" | "Cloud" | "Customer" | "Exchange"
 *   "port_speed":          "<string>",  // e.g. "1G", "10G", "100G"
 *   "mrc":                 <decimal>,   // Monthly recurring charge
 *   "rdd":                 "YYYY-MM-DD",// Ready-for-deployment date → EffectiveDate
 *   "description":         "<string>"   // Free-text description (nullable)
 * }
 *
 * Account lookup: direct via Account.Odoo_Partner_ID__c (Number field).
 * Order created with Status='Draft', Odoo_Order_ID__c set, Integration_Status__c='Acknowledged'.
 * Setting Odoo_Order_ID__c marks this as an Odoo-originated order.
 *
 * On Account not found: DE_Integration_Error__c logged (IP-6). No Order created.
 * Response: 200 { "status": "ok", "order_id": "<SF Order Id>" }
 *           200 { "status": "ok", "warning": "Account not found..." }
 */
@RestResource(urlMapping='/de/crossconnect')
global with sharing class OdooCrossConnectHandler {

    // ─── Payload DTO ──────────────────────────────────────────────────────────

    @TestVisible
    class CrossConnectPayload {
        public Long    partner_id;
        public Long    odoo_order_id;
        public String  site_code;
        public String  cross_connect_type;
        public String  remote_entity_name;
        public String  remote_entity_type;
        public String  port_speed;
        public Decimal mrc;
        public String  rdd;
        public String  description;
    }

    // ─── Entry point ──────────────────────────────────────────────────────────

    @HttpPost
    global static void handlePost() {
        RestRequest  req = RestContext.request;
        RestResponse res = RestContext.response;

        try {
            CrossConnectPayload p = (CrossConnectPayload) JSON.deserialize(
                req.requestBody.toString(), CrossConnectPayload.class);

            if (p.partner_id == null) {
                res.statusCode = 400;
                res.responseBody = Blob.valueOf('{"error":"partner_id is required"}');
                return;
            }

            Id orderId = processEvent(p);

            if (orderId != null) {
                res.statusCode = 200;
                res.responseBody = Blob.valueOf('{"status":"ok","order_id":"' + orderId + '"}');
            } else {
                res.statusCode = 200;
                res.responseBody = Blob.valueOf(
                    '{"status":"ok","warning":"Account not found — event logged to DE_Integration_Error__c"}');
            }

        } catch (Exception e) {
            res.statusCode = 500;
            res.responseBody = Blob.valueOf('{"error":"' + jsonSafe(e.getMessage()) + '"}');
        }
    }

    // ─── Processing ───────────────────────────────────────────────────────────

    @TestVisible
    static Id processEvent(CrossConnectPayload p) {
        Decimal partnerKey = Decimal.valueOf(p.partner_id);

        // Look up Account directly by Odoo partner ID (Number field on Account)
        List<Account> accounts = [
            SELECT Id, Name
            FROM Account
            WHERE Odoo_Partner_ID__c = :partnerKey
            WITH SECURITY_ENFORCED
            LIMIT 1
        ];

        if (accounts.isEmpty()) {
            OdooCalloutService.logError(null, 'IP-6',
                'Cross-connect event received but no Account found for Odoo partner_id='
                + p.partner_id + '. Odoo Order ID: ' + p.odoo_order_id);
            return null;
        }

        Id accountId = accounts[0].Id;

        // EffectiveDate: RDD if provided, otherwise today
        Date effectiveDate = p.rdd != null ? Date.valueOf(p.rdd) : Date.today();

        // Description: cross-connect metadata for ops team
        String orderDesc = 'Odoo Order: ' + p.odoo_order_id
            + '\nType: ' + (p.cross_connect_type != null ? p.cross_connect_type : '')
            + '\nRemote Entity: ' + (p.remote_entity_name != null ? p.remote_entity_name : '')
            + ' (' + (p.remote_entity_type != null ? p.remote_entity_type : '') + ')'
            + '\nPort Speed: ' + (p.port_speed != null ? p.port_speed : '')
            + '\nSite: ' + (p.site_code != null ? p.site_code : '')
            + '\nMRC: ' + (p.mrc != null ? String.valueOf(p.mrc) : '')
            + (p.description != null ? '\nNotes: ' + p.description : '');

        Order ord = new Order(
            AccountId             = accountId,
            Status                = 'Draft',
            EffectiveDate         = effectiveDate,
            Order_Type__c         = 'New Service',
            Operation_Site__c     = p.site_code,
            Odoo_Order_ID__c      = p.odoo_order_id != null ? String.valueOf(p.odoo_order_id) : null,
            Integration_Status__c = 'Acknowledged',
            Description           = orderDesc,
            RDD__c                = effectiveDate
        );
        insert ord;
        return ord.Id;
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    private static String jsonSafe(String s) {
        return s == null ? '' : s.replace('"', '\\"');
    }
}