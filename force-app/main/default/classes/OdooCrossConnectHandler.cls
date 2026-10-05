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
 *   "partner_id":          <integer>,   // required — Odoo partner ID, matches Account.Odoo_Partner_ID__c
 *   "odoo_order_id":       <integer>,   // Odoo Sale Order ID — stored on Order.Odoo_Order_ID__c
 *   "site_code":           "<string>",  // e.g. "SIN1", "TYO1" — maps to Operation_Site__c
 *   "cross_connect_type":  "<string>",  // OPTIONAL free text — Odoo has no dedicated field for this;
 *                                        // omit entirely if not available, stored as-is in Description
 *   "remote_entity_name":  "<string>",  // OPTIONAL free text — same as above, no Odoo field backs this
 *   "remote_entity_type":  "<string>",  // OPTIONAL free text — same as above
 *   "port_speed":          "<string>",  // OPTIONAL, order-level summary — no Odoo field backs this either
 *   "mrc":                 <decimal>,   // Monthly recurring charge (order-level summary; optional if lines sent)
 *   "rdd":                 "YYYY-MM-DD",// Ready-for-deployment date → EffectiveDate/RDD__c — fallback only,
 *                                        // used when x_studio_service_request_date isn't sent
 *   "description":         "<string>",  // OPTIONAL free-text notes
 *   "lines": [                          // OPTIONAL — order line detail (added for OrderItem support)
 *     {
 *       "odoo_line_id":      <integer>,   // Odoo sale order line ID → OrderItem.Odoo_Sub_Line_ID__c
 *       "product_code":      "<string>",  // matches Product2.ProductCode — resolved via Standard Price Book
 *       "a_side_service_id": "<string>",  // → OrderItem.A_Side_Service_ID__c
 *       "z_side_service_id": "<string>",  // → OrderItem.Z_Side_Service_ID__c
 *       "port_speed":        "<string>",  // OPTIONAL — no Odoo field backs this; → OrderItem.Description
 *       "quantity":          <decimal>,   // → OrderItem.Quantity (default 1)
 *       "unit_price":        <decimal>,   // → OrderItem.UnitPrice (default 0; mrc_amount used as fallback)
 *       "mrc_amount":        <decimal>,   // fallback for unit_price when unit_price is absent —
 *                                          // OrderItem.MRC_Amount__c is a formula (UnitPrice * Quantity),
 *                                          // it is derived automatically, not written directly
 *       "line_remarks":      "<string>"   // OPTIONAL — → OrderItem.Description
 *     }
 *   ],
 *   "ns_ban_id":           <integer>,   // OPTIONAL — Odoo BAN ID, matches BillingAccount__c.Odoo_BAN_ID__c.
 *                                        // Also the source of Order.CurrencyIsoCode (from the BAN's own
 *                                        // CurrencyIsoCode) — not sent by Odoo directly.
 *   "x_studio_service_request_date": "YYYY-MM-DD", // OPTIONAL — Odoo's real field key for requested
 *                                        // delivery date; preferred over "rdd" when both are sent
 *   "x_studio_contract_end_date":    "YYYY-MM-DD"  // OPTIONAL — Odoo's real field key → Order.Contract_End_Date__c
 * }
 * None of the OPTIONAL fields above have a confirmed source field on the Odoo side — Odoo should
 * simply omit whichever of these it doesn't have. Every one of them is null-safe in Apex already;
 * omitting one narrows the Order/OrderItem Description text but never fails the request.
 *
 * Account lookup: direct via Account.Odoo_Partner_ID__c (Number field).
 * BAN lookup (optional): via BillingAccount__c.Odoo_BAN_ID__c, scoped to the matched Account —
 * if ns_ban_id is sent but no matching BAN is found, it's logged to DE_Integration_Error__c (IP-6)
 * as a warning and the Order is created in Draft without BillingAccount__c set (see below).
 *
 * Opportunity: created directly at StageName='5-Won' / ForecastCategoryName='Closed' — there is
 * no sales cycle to run since the cross-connect is already sold and provisioned in Odoo. Same
 * pattern RampOppService uses for ramp-phase Orders that bypass the normal Opportunity flow.
 * Requires resolving site_code to a Site__c (Target_Site__c and its Operation_Country__c are
 * both mandatory from 5-Won onward per VR_OPP_21_Site_Required_At_Quote, and the field's own
 * lookup filter requires the two to already agree) — if site_code is missing or matches no
 * Site__c, the Opportunity is skipped (logged to DE_Integration_Error__c) rather than letting
 * that validation failure take down Order/line creation with it; the Order is still created,
 * just without OpportunityId set. The new Order is linked to the Opportunity when one is created.
 *
 * Order created with Odoo_Order_ID__c set (marks it Odoo-originated) and Integration_Status__c=
 * 'Acknowledged'. If (and only if) a BAN was resolved, it's then immediately activated
 * (Status='Activated') — the physical service is already live in Odoo by the time this fires, so
 * there's nothing left to provision on the SF side. When no BAN resolves, the Order is left in
 * Draft instead of forcing activation: the org has a validation rule requiring BillingAccount__c
 * before an Order can be Activated, so forcing it would always throw.
 * Activation is done via a guarded update (OrderTriggerHandler.skipIntegrationRouting) specifically
 * to prevent the standard "Order activated" trigger from routing this through IP-1 and sending it
 * right back to Odoo as if it were a brand-new SF-originated order.
 *
 * Order lines: when "lines" is present and non-empty, Order.Pricebook2Id is set to the org's
 * Standard Price Book and one OrderItem is inserted per line, resolved via an active
 * PricebookEntry matching line.product_code on that price book. A line whose product_code has
 * no active PricebookEntry is skipped and logged to DE_Integration_Error__c (IP-6) — it does not
 * fail the whole request. OrderItem.Charge_Type__c is set from the product's own Charge_Type__c,
 * falling back to the .RC/.NR product code suffix when blank.
 *
 * MRC/NRC: Order.Total_MRC__c / Total_NRC__c are native Roll-Up Summary fields (sum of
 * OrderItem.MRC_Amount__c, filtered by Charge_Type__c) — no Apex math needed, they populate as
 * soon as the lines above are inserted with the correct Charge_Type__c. Once resolved, these are
 * copied straight onto Opportunity.MRC__c / NRC__c — every IP-6 order is a new order (never a
 * ramp phase), so this is a plain copy, not the delta/TCV math RampOppService does for ramp phases.
 *
 * On Account not found: DE_Integration_Error__c logged (IP-6). No Order or Opportunity created.
 * Response: 200 { "status": "ok", "order_id": "<SF Order Id>", "order_number": "<OrderNumber>",
 *                  "opportunity_id": "<SF Opportunity Id>",
 *                  "order_status": "Activated" | "Draft", "currency": "<CurrencyIsoCode>",
 *                  "lines": [ { "odoo_line_id": <integer>, "sf_orderitem_id": "<SF OrderItem Id>" }, ... ] }
 *                — "lines" is present (possibly empty, if every line was skipped) whenever the
 *                  request included a "lines" array; omitted entirely otherwise. "order_number" and
 *                  "currency" reflect the Order after insert (re-queried — OrderNumber is a
 *                  Salesforce-generated auto-number, never populated on the in-memory record).
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
        public List<CrossConnectLine> lines;
        public Long    ns_ban_id;
        public String  x_studio_service_request_date;
        public String  x_studio_contract_end_date;
        public String  order_number;
    }

    @TestVisible
    class CrossConnectLine {
        public Long    odoo_line_id;
        public String  product_code;
        public String  a_side_service_id;
        public String  z_side_service_id;
        public String  port_speed;
        public Decimal quantity;
        public Decimal unit_price;
        public Decimal mrc_amount;
        public String  line_remarks;
    }

    // Odoo's write-back keys for one created OrderItem: its own odoo_line_id echoed back
    // alongside the new SF Id, so Odoo can store the SF Id on its own sale.order.line.
    @TestVisible
    class LineResult {
        public Long odoo_line_id;
        public Id   sf_orderitem_id;
    }

    @TestVisible
    class ProcessResult {
        public Id               orderId;
        public String           orderNumber;
        public Id               opportunityId;
        public String           status;
        public String           currencyIsoCode;
        public List<LineResult> lines;
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

            ProcessResult result = processEvent(p);

            if (result != null) {
                Map<String, Object> body = new Map<String, Object>{
                    'status'         => 'ok',
                    'order_id'       => result.orderId,
                    'order_number'   => result.orderNumber,
                    'opportunity_id' => result.opportunityId,
                    'order_status'   => result.status,
                    'currency'       => result.currencyIsoCode
                };
                if (p.lines != null) {
                    List<Map<String, Object>> lineMaps = new List<Map<String, Object>>();
                    for (LineResult lr : result.lines) {
                        lineMaps.add(new Map<String, Object>{
                            'odoo_line_id'    => lr.odoo_line_id,
                            'sf_orderitem_id' => lr.sf_orderitem_id
                        });
                    }
                    body.put('lines', lineMaps);
                }
                res.statusCode = 200;
                res.responseBody = Blob.valueOf(JSON.serialize(body));
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
    static ProcessResult processEvent(CrossConnectPayload p) {
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

        // BAN lookup (optional): Odoo may send the BAN this cross-connect should bill against.
        // Scoped to the matched Account so a bad/unrelated Odoo BAN ID can't attach the wrong BAN.
        Id banId = null;
        String banCurrency = null;
        if (p.ns_ban_id != null) {
            List<BillingAccount__c> bans = [
                SELECT Id, CurrencyIsoCode
                FROM BillingAccount__c
                WHERE Odoo_BAN_ID__c = :Decimal.valueOf(p.ns_ban_id)
                  AND Account__c = :accountId
                WITH SECURITY_ENFORCED
                LIMIT 1
            ];
            if (!bans.isEmpty()) {
                banId       = bans[0].Id;
                banCurrency = bans[0].CurrencyIsoCode;
            } else {
                OdooCalloutService.logError(null, 'IP-6',
                    'Cross-connect event: ns_ban_id=' + p.ns_ban_id
                    + ' provided but no matching BillingAccount__c found for Account ' + accountId
                    + '. Odoo Order ID: ' + p.odoo_order_id);
            }
        }

        // EffectiveDate: prefer the real Odoo field (x_studio_service_request_date) once Odoo
        // starts sending it; fall back to the earlier best-effort "rdd" key, then today.
        // isNotBlank (not != null): Odoo sends "" rather than omitting the key for a date it
        // doesn't have, and Date.valueOf('') throws — blank must be treated the same as absent.
        String requestedDeliveryDate = String.isNotBlank(p.x_studio_service_request_date)
            ? p.x_studio_service_request_date : p.rdd;
        Date effectiveDate = String.isNotBlank(requestedDeliveryDate)
            ? Date.valueOf(requestedDeliveryDate) : Date.today();

        Date contractEndDate = String.isNotBlank(p.x_studio_contract_end_date)
            ? Date.valueOf(p.x_studio_contract_end_date) : null;

        // Opportunity: the cross-connect is already sold and provisioned in Odoo, so there's no
        // sales cycle to run here — created directly at 5-Won, the same pattern RampOppService
        // already uses for Orders that bypass the normal Opportunity flow entirely.
        // VR_OPP_21_Site_Required_At_Quote (active) requires Target_Site__c from 5-Won onward, and
        // its lookup filter requires Operation_Country__c to already match that Site's own country
        // — so both must be resolved and set together, or the insert would fail outright. If the
        // site can't be resolved, skip creating the Opportunity entirely rather than let that
        // validation exception take down Order/line creation with it.
        Opportunity opp = null;
        if (String.isNotBlank(p.site_code)) {
            List<Site__c> sites = [
                SELECT Id, Country_Name__c
                FROM Site__c
                WHERE Site_Code__c = :p.site_code
                WITH SECURITY_ENFORCED
                LIMIT 1
            ];
            if (!sites.isEmpty()) {
                opp = new Opportunity(
                    AccountId            = accountId,
                    Name                 = accounts[0].Name + ' - Cross Connect (' + p.site_code + ')',
                    StageName             = '5-Won',
                    ForecastCategoryName  = 'Closed',
                    CloseDate             = effectiveDate,
                    Amount                = p.mrc,
                    Contract_End_Date__c  = contractEndDate,
                    Target_Site__c        = sites[0].Id,
                    Operation_Country__c  = sites[0].Country_Name__c,
                    Opportunity_Number__c = p.order_number
                );
                if (banCurrency != null) {
                    opp.CurrencyIsoCode = banCurrency;
                }
                insert opp;
            } else {
                OdooCalloutService.logError(null, 'IP-6',
                    'Cross-connect event: no Site__c found for site_code=' + p.site_code
                    + ' — Opportunity not created. Odoo Order ID: ' + p.odoo_order_id);
            }
        } else {
            OdooCalloutService.logError(null, 'IP-6',
                'Cross-connect event: site_code missing — Opportunity not created (Target_Site__c '
                + 'is required from 5-Won onward). Odoo Order ID: ' + p.odoo_order_id);
        }

        // Description: cross-connect metadata for ops team. Every field here is optional and
        // has no confirmed Odoo source field (per Odoo team, 2026-08) — blank ones just leave
        // their line empty rather than blocking order creation.
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
            OpportunityId         = opp != null ? opp.Id : null,
            BillingAccount__c     = banId,
            Status                = 'Draft',
            EffectiveDate         = effectiveDate,
            Order_Type__c         = 'New Service',
            Operation_Site__c     = p.site_code,
            Odoo_Order_ID__c      = p.odoo_order_id != null ? String.valueOf(p.odoo_order_id) : null,
            Integration_Status__c = 'Acknowledged',
            Description           = orderDesc,
            RDD__c                = effectiveDate,
            Contract_End_Date__c  = contractEndDate,
            Order_number__c = p.order_number
        );
        // Currency: pulled from the BAN rather than left to default to the running (integration)
        // user's own currency — otherwise it silently mismatches the BAN and the PricebookEntry
        // currency-filter in insertOrderLines below would match against the wrong currency.
        if (banCurrency != null) {
            ord.CurrencyIsoCode = banCurrency;
        }
        insert ord;

        List<LineResult> lineResults = new List<LineResult>();
        if (p.lines != null && !p.lines.isEmpty()) {
            lineResults = insertOrderLines(ord.Id, p.lines);
        }

        // Activate: the cross-connect service is already live in Odoo, so there's no SF-side
        // provisioning left to do. skipIntegrationRouting prevents this from being treated like
        // a brand-new SF-originated order and re-sent to Odoo via IP-1 — see class doc comment.
        // Skipped when banId is null: the org enforces a validation rule requiring BillingAccount__c
        // before Status can become 'Activated', so forcing activation here would always throw for
        // an unresolved ns_ban_id. The Order is left in Draft and the earlier BAN-not-found warning
        // (already logged to DE_Integration_Error__c above) is what tells ops to fix it.
        String finalStatus = 'Draft';
        if (banId != null) {
            OrderTriggerHandler.skipIntegrationRouting = true;
            try {
                update new Order(Id = ord.Id, Status = 'Activated');
                finalStatus = 'Activated';
            } finally {
                OrderTriggerHandler.skipIntegrationRouting = false;
            }
        }

        // OrderNumber is a Salesforce-generated auto-number, and Total_MRC__c/Total_NRC__c are
        // native Roll-Up Summary fields (sum of OrderItem.MRC_Amount__c, filtered by
        // OrderItem.Charge_Type__c) — none of these are populated on the in-memory `ord` after
        // `insert`, so all three must be re-queried.
        Order savedOrder = [SELECT OrderNumber, CurrencyIsoCode, Total_MRC__c, Total_NRC__c FROM Order WHERE Id = :ord.Id];

        // Per client request (2026-09-16): every IP-6 order is a new order (never a ramp phase),
        // so the Order's own rollup totals are copied straight onto the Opportunity — no delta/TCV
        // math needed, unlike RampOppService's ramp-phase handling of these same two fields.
        if (opp != null) {
            update new Opportunity(
                Id     = opp.Id,
                MRC__c = savedOrder.Total_MRC__c,
                NRC__c = savedOrder.Total_NRC__c
            );
        }

        ProcessResult result = new ProcessResult();
        result.orderId       = ord.Id;
        result.orderNumber   = savedOrder.OrderNumber;
        result.opportunityId = opp != null ? opp.Id : null;
        result.status        = finalStatus;
        result.currencyIsoCode = savedOrder.CurrencyIsoCode;
        result.lines          = lineResults;
        return result;
    }

    // Resolves each line's product_code to an active PricebookEntry on the org's Standard
    // Price Book, sets the Order's Pricebook2Id, and inserts the matched lines as OrderItems.
    // Lines with no matching PricebookEntry are skipped and logged (do not fail the request).
    @TestVisible
    static List<LineResult> insertOrderLines(Id orderId, List<CrossConnectLine> lines) {
        List<LineResult> results = new List<LineResult>();

        Set<String> productCodes = new Set<String>();
        for (CrossConnectLine l : lines) {
            if (l.product_code != null) productCodes.add(l.product_code);
        }

        // Test.isRunningTest() branch is required: Apex test isolation hides the org's real
        // Standard Price Book from ordinary SOQL inside @IsTest methods — Test.getStandardPricebookId()
        // is the only way to reach it there. This is a standard Salesforce testing idiom, not
        // test-specific behavior leaking into production logic.
        Id stdPricebookId;
        if (Test.isRunningTest()) {
            stdPricebookId = Test.getStandardPricebookId();
        } else {
            List<Pricebook2> stdPricebooks = [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1];
            if (stdPricebooks.isEmpty()) {
                OdooCalloutService.logError(orderId, 'IP-6',
                    'Cross-connect lines skipped — no Standard Price Book found in org');
                return results;
            }
            stdPricebookId = stdPricebooks[0].Id;
        }

        // In multi-currency orgs, OrderItem.CurrencyIsoCode is a non-editable field that must
        // already match the parent Order — so the PricebookEntry we resolve to has to be the one
        // in the Order's own currency (the Standard Price Book can hold one entry per currency
        // per product). Queried dynamically so this stays portable to single-currency orgs, where
        // CurrencyIsoCode doesn't exist as a field at all.
        Boolean isMultiCurrency = UserInfo.isMultiCurrencyOrganization();
        String orderCurrency = null;
        if (isMultiCurrency) {
            List<SObject> orderRows = Database.query(
                'SELECT CurrencyIsoCode FROM Order WHERE Id = \'' + orderId + '\'');
            if (!orderRows.isEmpty()) {
                orderCurrency = (String) orderRows[0].get('CurrencyIsoCode');
            }
        }

        Map<String, Id> pbeIdByProductCode = new Map<String, Id>();
        // Charge_Type__c per product code: prefer the product's own Charge_Type__c; fall back to
        // the .RC/.NR product code suffix convention (same fallback used elsewhere in this org,
        // e.g. QuoteLineItemTriggerHandler) when the product doesn't have one set.
        Map<String, String> chargeTypeByProductCode = new Map<String, String>();
        if (!productCodes.isEmpty()) {
            String pbeQuery = 'SELECT Id, Product2.ProductCode, Product2.Charge_Type__c FROM PricebookEntry ' +
                'WHERE Product2.ProductCode IN :productCodes ' +
                'AND Pricebook2Id = :stdPricebookId AND IsActive = true';
            if (isMultiCurrency) {
                pbeQuery += ' AND CurrencyIsoCode = :orderCurrency';
            }
            pbeQuery += ' WITH SECURITY_ENFORCED';

            for (SObject row : Database.query(pbeQuery)) {
                SObject product = row.getSObject('Product2');
                String productCode = (String) product.get('ProductCode');
                pbeIdByProductCode.put(productCode, (Id) row.get('Id'));

                String chargeType = (String) product.get('Charge_Type__c');
                if (String.isBlank(chargeType)) {
                    chargeType = productCode.endsWithIgnoreCase('.NR') ? 'NRC' : 'MRC';
                }
                chargeTypeByProductCode.put(productCode, chargeType);
            }
        }

        update new Order(Id = orderId, Pricebook2Id = stdPricebookId);

        List<OrderItem> toInsert = new List<OrderItem>();
        List<Long> odooLineIdByIndex = new List<Long>();  // parallel to toInsert, for the write-back response
        for (CrossConnectLine l : lines) {
            Id pbeId = l.product_code != null ? pbeIdByProductCode.get(l.product_code) : null;

            if (pbeId == null) {
                OdooCalloutService.logError(orderId, 'IP-6',
                    'Cross-connect line skipped — no active PricebookEntry found for product_code='
                    + l.product_code + ' (odoo_line_id=' + l.odoo_line_id + ')');
                continue;
            }

            String lineDesc = (l.port_speed != null ? 'Port Speed: ' + l.port_speed : '')
                + (l.line_remarks != null ? (l.port_speed != null ? '\n' : '') + l.line_remarks : '');

            // MRC_Amount__c is a formula (UnitPrice * Quantity for non-NRC lines) — not writeable.
            // mrc_amount falls back into UnitPrice when unit_price isn't sent separately.
            Decimal effectiveUnitPrice = l.unit_price != null ? l.unit_price
                : (l.mrc_amount != null ? l.mrc_amount : 0);

            OrderItem oi = new OrderItem(
                OrderId               = orderId,
                PricebookEntryId      = pbeId,
                Quantity              = l.quantity != null ? l.quantity : 1,
                UnitPrice             = effectiveUnitPrice,
                Charge_Type__c        = chargeTypeByProductCode.get(l.product_code),
                A_Side_Service_ID__c  = l.a_side_service_id,
                Z_Side_Service_ID__c  = l.z_side_service_id,
                Odoo_Sub_Line_ID__c   = l.odoo_line_id != null ? String.valueOf(l.odoo_line_id) : null,
                Description           = lineDesc != '' ? lineDesc : null
            );
            toInsert.add(oi);
            odooLineIdByIndex.add(l.odoo_line_id);
        }

        if (!toInsert.isEmpty()) {
            insert toInsert;
            for (Integer i = 0; i < toInsert.size(); i++) {
                LineResult lr = new LineResult();
                lr.odoo_line_id    = odooLineIdByIndex[i];
                lr.sf_orderitem_id = toInsert[i].Id;
                results.add(lr);
            }
        }

        return results;
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    private static String jsonSafe(String s) {
        return s == null ? '' : s.replace('"', '\\"');
    }
}