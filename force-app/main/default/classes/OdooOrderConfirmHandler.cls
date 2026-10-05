/**
 * OdooOrderConfirmHandler
 * IP-2: Inbound REST endpoint. Odoo POSTs this callback after creating a sale order
 * from an IP-1 payload. Returns the Odoo-internal subscription ID and per-line
 * subscription line IDs that Salesforce must store and echo back in future IP-1 Change Order
 * payloads (ns_subscription_line_id, ns_origin_sale_line_id).
 *
 * This endpoint is called once per IP-1 order, immediately after Odoo creates the
 * sale order and its subscription lines — before provisioning begins.
 *
 * Endpoint:  POST /services/apexrest/de/orderconfirm
 * Auth:      SF OAuth2 Client Credentials (same connected app as other inbound endpoints).
 *
 * What SF stores from this payload:
 *   Order.Odoo_Order_ID__c          → odoo_order_id     (may already be set by IP-1 response,
 *                                                         this confirms and overwrites)
 *   OrderItem.Odoo_Sub_Line_ID__c   → line.odoo_sub_line_id     (ns_subscription_line_id)
 *   OrderItem.Odoo_Origin_Line_ID__c → line.odoo_origin_line_id (ns_origin_sale_line_id)
 *   Asset.Odoo_Subscription_ID__c   → subscription_id   (for Assets already created by IP-5 new_service)
 *
 * Why this matters:
 *   IP-1 Change Orders must include ns_subscription_line_id and ns_origin_sale_line_id
 *   per line so Odoo can match the exact subscription line being amended. Odoo generates
 *   these IDs when creating the sale order — SF cannot know them until Odoo sends them here.
 *
 * Payload schema (Odoo → SF):
 * {
 *   "sf_order_id":     "<SF Order Id>",         // match key — SF record ID sent in IP-1
 *   "odoo_order_id":   <integer>,               // Odoo sale order ID (confirm/overwrite)
 *   "subscription_id": <integer>,               // Odoo subscription record ID
 *   "lines": [
 *     {
 *       "sf_orderitem_id":    "<SF OrderItem Id>", // SF record ID sent in IP-1
 *       "odoo_sub_line_id":   <integer>,           // ns_subscription_line_id for IP-1 Change Order
 *       "odoo_origin_line_id": <integer>           // ns_origin_sale_line_id for IP-1 Change Order
 *     }
 *   ]
 * }
 *
 * Response:  200 { "status": "ok", "updated_lines": N }
 *            400 { "error": "sf_order_id is required" }
 *            500 { "error": "..." }
 */
@RestResource(urlMapping='/de/orderconfirm')
global with sharing class OdooOrderConfirmHandler {

    // ─── Payload DTOs ─────────────────────────────────────────────────────────

    @TestVisible
    class OrderConfirmPayload {
        public String  sf_order_id;
        public Long    odoo_order_id;
        public Long    subscription_id;
        public List<LineConfirm> lines;
    }

    @TestVisible
    class LineConfirm {
        public String  sf_orderitem_id;
        public Long    odoo_sub_line_id;
        public Long    odoo_origin_line_id;
    }

    // ─── Entry point ──────────────────────────────────────────────────────────

    @HttpPost
    global static void handlePost() {
        RestRequest  req = RestContext.request;
        RestResponse res = RestContext.response;

        try {
            OrderConfirmPayload p = (OrderConfirmPayload) JSON.deserialize(
                req.requestBody.toString(), OrderConfirmPayload.class);

            if (p.sf_order_id == null || p.sf_order_id == '') {
                res.statusCode = 400;
                res.responseBody = Blob.valueOf('{"error":"sf_order_id is required"}');
                return;
            }

            Integer updated = processConfirmation(p);

            res.statusCode = 200;
            res.responseBody = Blob.valueOf('{"status":"ok","updated_lines":' + updated + '}');

        } catch (Exception e) {
            res.statusCode = 500;
            res.responseBody = Blob.valueOf('{"error":"' + jsonSafe(e.getMessage()) + '"}');
        }
    }

    // ─── Processing ───────────────────────────────────────────────────────────

    @TestVisible
    static Integer processConfirmation(OrderConfirmPayload p) {
        Integer updatedLines = 0;
        Id orderId = (Id) p.sf_order_id;

        // 1. Update Order: confirm Odoo_Order_ID__c and store subscription_id
        //    (order_id may already be set from IP-1 response; this is authoritative)
        Order o = new Order(Id = orderId);
        if (p.odoo_order_id != null) {
            o.Odoo_Order_ID__c = String.valueOf(p.odoo_order_id);
        }
        if (p.subscription_id != null) {
            o.Odoo_Subscription_ID__c = String.valueOf(p.subscription_id);
        }
        update o;

        // 2. Update OrderItems with subscription line IDs
        if (p.lines == null || p.lines.isEmpty()) {
            return 0;
        }

        // Collect OrderItem IDs for batch update
        Set<Id> orderItemIds = new Set<Id>();
        for (LineConfirm lc : p.lines) {
            if (lc.sf_orderitem_id != null && lc.sf_orderitem_id != '') {
                orderItemIds.add((Id) lc.sf_orderitem_id);
            }
        }

        if (orderItemIds.isEmpty()) return 0;

        // Verify OrderItems belong to the stated Order (security check)
        Set<Id> validIds = new Set<Id>();
        for (OrderItem existing : [
            SELECT Id FROM OrderItem
            WHERE Id IN :orderItemIds
              AND OrderId = :orderId
        ]) {
            validIds.add(existing.Id);
        }

        // Build update list
        List<OrderItem> toUpdate = new List<OrderItem>();
        // itemId -> subscription line id, so the Asset backfill below (step 3b)
        // can key off the same values without re-parsing p.lines.
        Map<Id, String> subLineIdByItem = new Map<Id, String>();
        for (LineConfirm lc : p.lines) {
            if (lc.sf_orderitem_id == null) continue;
            Id itemId = (Id) lc.sf_orderitem_id;
            if (!validIds.contains(itemId)) {
                OdooCalloutService.logError(orderId, 'IP-2',
                    'OrderItem ' + lc.sf_orderitem_id
                    + ' not found on Order ' + p.sf_order_id
                    + ' — skipped in IP-2 confirm');
                continue;
            }

            OrderItem oi = new OrderItem(Id = itemId);
            if (lc.odoo_sub_line_id    != null) oi.Odoo_Sub_Line_ID__c    = String.valueOf(lc.odoo_sub_line_id);
            if (lc.odoo_origin_line_id != null) oi.Odoo_Origin_Line_ID__c = String.valueOf(lc.odoo_origin_line_id);
            toUpdate.add(oi);
            updatedLines++;
            if (lc.odoo_sub_line_id != null) {
                subLineIdByItem.put(itemId, String.valueOf(lc.odoo_sub_line_id));
            }
        }

        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }

        // 3. Back-fill Assets created by IP-5 new_service with subscription_id
        //    (IP-5 may fire before or after IP-2 depending on Odoo timing)
        if (p.subscription_id != null) {
            List<Asset> assets = [
                SELECT Id, Odoo_Subscription_ID__c
                FROM Asset
                WHERE Source_Order__c = :orderId
                  AND Odoo_Subscription_ID__c = null
            ];
            if (!assets.isEmpty()) {
                for (Asset a : assets) {
                    a.Odoo_Subscription_ID__c = String.valueOf(p.subscription_id);
                }
                update assets;
            }
        }

        // 3b. Back-fill Asset.Odoo_Sub_Line_ID__c the same way — Assets created by
        // IP-5 new_service carry no line ID until IP-2 confirms it. Without this,
        // only OrderItem stays current; the Asset's line ID silently goes stale on
        // any future gap (Darren Wahyono, 2026-09-11).
        if (!subLineIdByItem.isEmpty()) {
            List<Asset> lineIdAssets = [
                SELECT Id, Source_OrderItem__c
                FROM Asset
                WHERE Source_OrderItem__c IN :subLineIdByItem.keySet()
                  AND Odoo_Sub_Line_ID__c = null
            ];
            if (!lineIdAssets.isEmpty()) {
                List<Asset> assetsToUpdate = new List<Asset>();
                for (Asset a : lineIdAssets) {
                    assetsToUpdate.add(new Asset(
                        Id = a.Id,
                        Odoo_Sub_Line_ID__c = subLineIdByItem.get(a.Source_OrderItem__c)
                    ));
                }
                update assetsToUpdate;
            }
        }

        return updatedLines;
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    private static String jsonSafe(String s) {
        return s == null ? '' : s.replace('"', '\\"');
    }
}