/**
 * OdooAssetStatusHandler
 * IP-2: Inbound REST endpoint. Odoo POSTs one or more subscription lines per request.
 *
 * Endpoint: POST /services/apexrest/de/assetstatus
 *
 * Key design principle (confirmed 2026-04-30 transcript with Odoo team):
 *   Odoo groups identical items (same product, customer, price) into ONE subscription line.
 *   A single subscription line can represent N physical units (e.g., 20 cabinets).
 *   The N individual task/IB IDs are sent as an array in odoo_project_task_ids.
 *   SF receives ONE line entry and fans out to N separate Assets — one per task ID.
 *   All N Assets share: subscription_id, sub_line_id, origin_line_id, product, MRC, dates.
 *   Each Asset gets a unique task_id stored in Odoo_IB_ID__c.
 *
 * NEW BEHAVIOR (2026-07-06):
 *   Product2.Merge_IB_Task__c controls asset creation behavior:
 *   - TRUE:  Create ONE Asset with Quantity = Odoo quantity (multiple units on one Asset)
 *   - FALSE: Create N Assets with Quantity = 1 (fan-out, one per task ID)
 *
 * The 4 IDs required for IP-4 change orders, stored on every Asset:
 *   Odoo_IB_ID__c             — task_id          (unique per asset)
 *   Odoo_Subscription_ID__c   — subscription_id  (shared across grouped line)
 *   Odoo_Sub_Line_ID__c       — sub_line_id       (shared across grouped line)
 *   Odoo_Origin_Line_ID__c    — origin_line_id    (shared across grouped line)
 *
 * Payload structure (Odoo native field names):
 * {
 *   "event_type":  "new_service" | "amendment" | "churn" | "renewal" | "suspension" | "resumption",
 *   "lines": [
 *     {
 *       "id":              <integer>,        // sale.subscription.line ID
 *       "subscription_id": <integer>,        // sale.subscription ID (sent per-line by Odoo)
 *       "sf_order_id":     "<SF Order Id>",  // required for new_service (per-line in Odoo's format)
 *       "sf_orderitem_id": "<SF Id>",        // required for new_service
 *       "origin_line_id":  <integer>,        // ns_origin_sale_line_id
 *       "project_task_ids": [<int>, ...],    // all task IDs — fan-out for new_service; IB ID for lifecycle events
 *       "sub_task_ids":     [<int>, ...],    // sub-task IDs (parallel array)
 *       "mrr":             <decimal>,         // MRC
 *       "quantity":        <decimal>,
 *       "start_date":      "YYYY-MM-DD",
 *       "termination_date": "YYYY-MM-DD"    // churn only
 *     }
 *   ]
 * }
 * Note: top-level "odoo_sub_id" and "sf_order_id" are also accepted for backward compatibility.
 *
 * new_service: 
 *   - If Merge_IB_Task__c = TRUE: Creates ONE Asset with Quantity = Odoo quantity
 *   - If Merge_IB_Task__c = FALSE: Fans out to one Asset per task ID with Quantity = 1
 *   - Stores all 4 IP-4 IDs on each Asset
 *   - Also writes task IDs back to OrderItem for legacy IP-4 reference
 *
 * amendment / renewal: updates Asset MRC, Quantity, Odoo_Subscription_ID__c.
 * churn: terminates Asset (Obsolete + Terminated + Termination_Date__c).
 * suspension / resumption: updates Asset_Lifecycle_Status__c only.
 *
 * All events are bulkified — one SOQL query + one DML per event type regardless of line count.
 */
@RestResource(urlMapping='/de/assetstatus')
global with sharing class OdooAssetStatusHandler {

    // ─── DTOs ─────────────────────────────────────────────────────────────────

    @TestVisible
    class AssetEventPayload {
        public String          event_type;
        public Long            odoo_sub_id;
        public String          sf_order_id;
        public List<LineItem>  lines;
    }

    @TestVisible
    class LineItem {
        // Odoo native field names (matched exactly to what Odoo sends)
        public Long         id;  // sale.subscription.line ID
        public String         name;  
        public Long         subscription_id; // sale.subscription ID — sent per-line by Odoo
        public String       sf_order_id;    // SF Order ID — sent per-line by Odoo for new_service
        public String       sf_orderitem_id;
        public Long         odoo_ib_id;     // legacy: single task ID (kept for backward compat)
        public Long         origin_line_id; // ns_origin_sale_line_id — for IP-4 change orders
        public List<Long>   project_task_ids;  // all task IDs: fan-out for new_service; IB ID for lifecycle events
        public List<Long>   sub_task_ids;      // parallel sub-task IDs
        public Decimal      mrr;
        public Decimal      price_unit;        // unit price (Odoo may send both mrr and price_unit)
        public Decimal      quantity;
        Public String       x_studio_breaker_id ;
        Public String       x_studio_space_id  ;
        Public String       ns_a_side_service_id  ;
        Public String       ns_z_side_service_id  ;
        Public String 		stage_id ;
        Public Date 		x_studio_service_commencement_date  ;
        Public String 		ns_customer_service_reference  ;
        public String       start_date;
        public String       termination_date;  // churn only (also aliased as stop_date)
        public String       stop_date;         // alias for termination_date used by some Odoo flows
        public String      ns_product_attribute_value;  // Odoo product attribute value ID
        public String       ns_custom_attribute_value;   // custom attribute text
        public String       remarks;                     // line-level remarks from Odoo
        public String       billing_charge_type;         // advance / arrear
        // ── Odoo IBS fields — accepted so payload doesn't break; stored where Asset fields exist ──
        public Long         product_id;                  // product.product ID (fallback product lookup)
        public String       product_name;                // Product display name
        public String       product_attribute;           // Product attribute text (e.g. "Draw Cap in kW: 5")
        public String       charge_through_date;         // Billing period end → Contract_End__c
        public Decimal      billing_multiplier;          // Billing multiplier
        public Decimal      discount;                    // Discount %
        public Decimal      tax_rate;                    // Tax rate %
        public Decimal      total;                       // Line total
        public Decimal      subtotal;                    // Line subtotal
        public Decimal      contracted_usd_amount;       // Contracted USD
        public Long         ban_id;                      // Odoo BAN ID
        public Long         target_ban_id;               // Odoo Target BAN ID
        public String       legacy_bill_no;              // Legacy billing number
        public Long         sale_order_line_id;          // Sale order line ID (alias for origin_line_id)
    }

    // ─── Entry point ──────────────────────────────────────────────────────────

    @HttpPost
    global static void handlePost() {
        RestRequest  req = RestContext.request;
        RestResponse res = RestContext.response;
        try {
            AssetEventPayload p = (AssetEventPayload) JSON.deserialize(
                req.requestBody.toString(), AssetEventPayload.class);

            if (p.event_type == null) { res.statusCode = 400; res.responseBody = Blob.valueOf('{"error":"event_type is required"}'); return;
            }
            if (p.lines == null || p.lines.isEmpty()) {
                res.statusCode = 400;
                res.responseBody = Blob.valueOf('{"error":"lines array is required and must not be empty"}');
                return;
            }

            List<Id> assetIds;
            if      (p.event_type == 'new_service') assetIds = handleNewService(p);
            else if (p.event_type == 'amendment')   assetIds = handleAmendment(p);
            else if (p.event_type == 'churn')        assetIds = handleChurn(p);
            else if (p.event_type == 'renewal')      assetIds = handleRenewal(p);
            else if (p.event_type == 'suspension')   assetIds = handleSuspension(p);
            else if (p.event_type == 'resumption')   assetIds = handleResumption(p);
            else {
                res.statusCode = 400;
                res.responseBody = Blob.valueOf('{"error":"unknown event_type: ' + jsonSafe(p.event_type) + '"}');
                return;
            }

            res.statusCode = 200;
            res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
                'status'    => 'ok',
                'processed' => assetIds.size(),
                'asset_ids' => assetIds
            }));

        } catch (OdooHandlerException e) {
            res.statusCode = 422;
            res.responseBody = Blob.valueOf('{"error":"' + jsonSafe(e.getMessage()) + '"}'); } catch (Exception e) { res.statusCode = 500; res.responseBody = Blob.valueOf('{"error":"' + jsonSafe(e.getMessage()) + '"}');
        }
    }

    // ─── NEW SERVICE ──────────────────────────────────────────────────────────
    // Odoo sends the subscription + sub lines after provisioning is created.
    // SF creates one Asset per individual task ID, writes sub line IDs back to OrderItems.
    //
    // NEW BEHAVIOR (2026-07-06):
    //   Product2.Merge_IB_Task__c controls behavior:
    //   - TRUE:  One Asset with Quantity = Odoo quantity
    //   - FALSE: One Asset per task ID with Quantity = 1 (fan-out)
    //
    // Fan-out behaviour (confirmed 2026-04-30 transcript):
    //   Odoo groups multiple provisioned units (e.g. 20 cabinets) into one subscription line
    //   and sends ALL task IDs in odoo_project_task_ids. SF must create one Asset per task ID.
    //   Each fanned-out Asset is quantity=1 and shares the line's MRC, product, and dates.
    //   Legacy fallback: if odoo_project_task_ids is absent, use odoo_ib_id (one Asset per line).

    @TestVisible
    static List<Id> handleNewService(AssetEventPayload p) {
        // sf_order_id accepted at the payload root (backward compat) or inside each line (Odoo native)
        String orderIdStr = p.sf_order_id != null
            ? p.sf_order_id
            : (!p.lines.isEmpty() && p.lines[0].sf_order_id != null ? p.lines[0].sf_order_id : null);
        if (orderIdStr == null) throw new OdooHandlerException('sf_order_id required for new_service');
        Id orderId = (Id) orderIdStr;

        // Collect sf_orderitem_ids — optional: OI enriches Asset but is not required
        Set<Id> oiIds = new Set<Id>();
        for (LineItem line : p.lines) {
            if (line.sf_orderitem_id != null && line.sf_orderitem_id != '') {
                try { oiIds.add((Id) line.sf_orderitem_id); } catch (Exception e) { /* invalid Id format */ }
            }
        }

        // Query OrderItems if any IDs were provided
        Map<Id, OrderItem> oiMap = new Map<Id, OrderItem>();
        if (!oiIds.isEmpty()) {
            oiMap = new Map<Id, OrderItem>([
                SELECT Id, Product2Id, Product2.Name, Product2.Merge_IB_Task__c, Description, Quantity,
                       UnitPrice, ServiceDate, Inventory__c, Space__c,
                       Order.AccountId, Order.RDD__c,
                       Order.OpportunityId, Order.Contact__c
                FROM OrderItem
                WHERE Id IN :oiIds
                  AND OrderId = :orderId
            ]);
        }

        // Order-level data — fallback for lines where OI not found or not provided
        Order parentOrder = [SELECT AccountId, RDD__c, OpportunityId, Contact__c, Original_Order__c
                             FROM Order WHERE Id = :orderId LIMIT 1];
        // If this is a Change Order, assets belong to the Original Order (not the CO)
        Id sourceOrderId = parentOrder.Original_Order__c != null ? parentOrder.Original_Order__c : orderId;

        // NRC lookup only for matched OIs
        Map<Id, Decimal> nrcByMrcId = new Map<Id, Decimal>();
        if (!oiMap.isEmpty()) {
            for (OrderItem nrcOi : [
                SELECT Paired_MRC_OrderItem__c, UnitPrice, Quantity
                FROM OrderItem
                WHERE OrderId = :orderId
                  AND Charge_Type__c = 'NRC'
                  AND Paired_MRC_OrderItem__c IN :oiMap.keySet()
            ]) {
                nrcByMrcId.put(
                    nrcOi.Paired_MRC_OrderItem__c,
                    (nrcOi.UnitPrice != null ? nrcOi.UnitPrice : 0)
                        * (nrcOi.Quantity != null ? nrcOi.Quantity : 1)
                );
            }
        }

        // Product lookup by Odoo ID — fallback when OI not available
        Set<Decimal> odooProductIds = new Set<Decimal>();
        for (LineItem line : p.lines) {
            if (line.product_id != null) odooProductIds.add(Decimal.valueOf(line.product_id));
        }
        Map<Decimal, Product2> productByOdooId = new Map<Decimal, Product2>();
        if (!odooProductIds.isEmpty()) {for (Product2 prod : [SELECT Id, Name, Odoo_Product_ID__c, Merge_IB_Task__c FROM Product2 WHERE Odoo_Product_ID__c IN :odooProductIds]) { productByOdooId.put(prod.Odoo_Product_ID__c, prod); }
        }

        // subscription ID: accepted at root (backward compat) or per-line (Odoo native)
        String subIdStr = (!p.lines.isEmpty() && p.lines[0].subscription_id != null
                ? String.valueOf(p.lines[0].subscription_id) : null);

        List<Asset>     toInsert       = new List<Asset>();
        List<OrderItem> oiSubLineWrite = new List<OrderItem>();

        for (LineItem line : p.lines) {
            // Resolve OrderItem — optional enrichment
            OrderItem oi = null;
            Boolean mergeIbTask = false; // Default to fan-out behavior
            
            if (line.sf_orderitem_id != null && line.sf_orderitem_id != '') {
                try { 
                    oi = oiMap.get((Id) line.sf_orderitem_id); 
                    if (oi != null && oi.Product2 != null) {
                        mergeIbTask = oi.Product2.Merge_IB_Task__c == true;
                    } } catch (Exception e) { /* bad Id */ }
                if (oi == null) {
                    OdooCalloutService.logError(orderId, 'IP-2',
                        'new_service: OrderItem ' + line.sf_orderitem_id
                        + ' not found on Order ' + orderIdStr
                        + ' — creating Asset from Order + line data');
                }
            }

            // If OI not found or no Product2 on OI, check productByOdooId for Merge_IB_Task__c
            if (oi == null && line.product_id != null) { Product2 prod = productByOdooId.get(Decimal.valueOf(line.product_id)); if (prod != null) { mergeIbTask = prod.Merge_IB_Task__c == true;  }
            }

            Date    scd = line.start_date != null ? Date.valueOf(line.start_date) : (oi != null ? oi.ServiceDate : null);
            Decimal nrc = (oi != null && nrcByMrcId.containsKey(oi.Id)) ? nrcByMrcId.get(oi.Id) : 0;
            String lineSubId = line.subscription_id != null ? String.valueOf(line.subscription_id) : subIdStr;
            Decimal mrcVal = line.mrr != null ? line.mrr : line.price_unit;

            List<Long> taskIds = new List<Long>();
            if (line.project_task_ids != null && !line.project_task_ids.isEmpty()) {
                taskIds = line.project_task_ids;
            } else if (line.odoo_ib_id != null) {
                taskIds.add(line.odoo_ib_id);
            }

            String subLineIdStr    = line.id != null ? String.valueOf(line.id) : null;
            // origin_line_id: prefer explicit field, fall back to sale_order_line_id
            Long effectiveOriginId = line.origin_line_id != null ? line.origin_line_id : line.sale_order_line_id;
            String originLineIdStr = effectiveOriginId != null ? String.valueOf(effectiveOriginId) : null;
            Decimal mrc            = mrcVal;

            // Resolve Asset fields — prefer OI data, fall back to Order + line payload
            Id      accountId     = oi != null ? oi.Order.AccountId     : parentOrder.AccountId;
            Id      opportunityId = oi != null ? oi.Order.OpportunityId : parentOrder.OpportunityId;
            Id      contactId     = oi != null ? oi.Order.Contact__c    : parentOrder.Contact__c;
            Date    rdd           = oi != null ? oi.Order.RDD__c        : parentOrder.RDD__c;
            Id      product2Id    = null;
            String  assetName     = ( line.name != null ? line.name : 'Asset');
            Id      inventoryId   = line.x_studio_breaker_id  != null ? line.x_studio_breaker_id  : null ;
            Id      spaceId       = line.x_studio_space_id != null ? line.x_studio_space_id : null ;
            
            // Determine effective quantity for this product
            Decimal effectiveQuantity = 1; // Default
            if (mergeIbTask) {
                // When Merge_IB_Task__c = TRUE, use Odoo quantity on a single Asset
                effectiveQuantity = line.quantity != null ? line.quantity : 1;
            }
            
            if (oi != null) {
                product2Id  = oi.Product2Id;
                inventoryId = oi.Inventory__c;
                spaceId     = oi.Space__c;
            } else {
                // Fallback: look up Product2 by Odoo product_id
                if (line.product_id != null) { Product2 prod = productByOdooId.get(Decimal.valueOf(line.product_id)); if (prod != null) { product2Id = prod.Id;
                    }
                }
            }

            // ─── Asset Creation Logic ──────────────────────────────────────
            // Case 1: Merge_IB_Task__c = TRUE → Create ONE Asset with quantity = Odoo quantity
            // Case 2: Merge_IB_Task__c = FALSE → Create N Assets with quantity = 1 (fan-out)
            
            if (mergeIbTask) {
                // ─── MERGE MODE: Single Asset with full quantity ──────────
                String combinedTaskIds = String.join(convertLongsToStrings(taskIds), ',');
                
                Asset a = new Asset(
                    Name                      = assetName,
                    AccountId                 = accountId,
                    Product2Id                = product2Id,
                    Quantity                  = effectiveQuantity,  // ← Use Odoo quantity
                    Price                     = mrc,
                    MRC__c                    = mrc,
                    NRC__c                    = nrc,
                    Source_Order__c           = sourceOrderId,
                    Source_OrderItem__c       = oi != null ? oi.Id : null,
                    Opportunity__c            = opportunityId,
                    Contact__c                = contactId,
                    SCD__c                    = scd,
                    Asset_RDD__c              = rdd,
                    Inventory__c              = inventoryId,
                    Space__c                  = spaceId,
                    Odoo_IB_ID__c             = combinedTaskIds,  // ← Store ALL task IDs combined
                    Odoo_Subscription_ID__c   = lineSubId,
                    Odoo_Sub_Line_ID__c       = subLineIdStr,
                    Odoo_Origin_Line_ID__c    = originLineIdStr,
                    Customer_Service_Reference__c = line.ns_customer_service_reference,
                    Status                    = line.stage_id  != null ? line.stage_id : 'In Service',
                    Asset_Lifecycle_Status__c = 'In Service',
                    InstallDate               = Date.today(),
                    A_Side_Asset__c           = line.ns_a_side_service_id,
                    Z_Side_Asset__c           = line.ns_z_side_service_id,
                    Product_Attribute__c      = ( line.ns_product_attribute_value.toLowerCase() != 'false' ? line.ns_product_attribute_value : null)
                    //Odoo_Project_Task_IDs__c  = combinedTaskIds  // ← Store all task IDs for reference
                );
                // IBS fields — stored for future CO/QLI reference
                if (line.charge_through_date != null) a.Charge_Through_Date__c = Date.valueOf(line.charge_through_date);
                if (line.remarks != null)             a.Description = line.remarks;
                if (line.billing_charge_type != null)  a.Billing_Charge_Type__c = line.billing_charge_type;
                if (line.product_attribute != null)     a.Product_Attribute__c = line.product_attribute;
                if (line.billing_multiplier != null)    a.Billing_Multiplier__c = line.billing_multiplier;
                if (line.discount != null)              a.Discount_Percent__c = line.discount;
                if (line.tax_rate != null)              a.Tax_Rate__c = line.tax_rate;
                if (line.contracted_usd_amount != null) a.Contracted_USD_Amount__c = line.contracted_usd_amount;
                if (line.ban_id != null)                a.Odoo_BAN_ID__c = String.valueOf(line.ban_id);
                if (line.target_ban_id != null)         a.Odoo_Target_BAN_ID__c = String.valueOf(line.target_ban_id);
                if (line.legacy_bill_no != null)        a.Legacy_Bill_No__c = line.legacy_bill_no;
                toInsert.add(a);
                
            } else {
                // ─── FAN-OUT MODE: One Asset per task ID, each with Quantity = 1 ──
                for (Long taskId : taskIds) {
                    Asset a = new Asset(
                        Name                      = assetName,
                        AccountId                 = accountId,
                        Product2Id                = product2Id,
                        Quantity                  = 1,  // ← Each asset gets quantity = 1
                        Price                     = mrc,
                        MRC__c                    = mrc,
                        NRC__c                    = nrc,
                        Source_Order__c           = sourceOrderId,
                        Source_OrderItem__c       = oi != null ? oi.Id : null,
                        Opportunity__c            = opportunityId,
                        Contact__c                = contactId,
                        SCD__c                    = scd,
                        Asset_RDD__c              = rdd,
                        Inventory__c              = inventoryId,
                        Space__c                  = spaceId,
                        Odoo_IB_ID__c             = String.valueOf(taskId),  // ← Unique per asset
                        Odoo_Subscription_ID__c   = lineSubId,
                        Odoo_Sub_Line_ID__c       = subLineIdStr,
                        Odoo_Origin_Line_ID__c    = originLineIdStr,
                        Customer_Service_Reference__c = line.ns_customer_service_reference,
                        Status                    = line.stage_id  != null ? line.stage_id : 'In Service',
                        Asset_Lifecycle_Status__c = 'In Service',
                        InstallDate               = Date.today(),
                        A_Side_Asset__c           = line.ns_a_side_service_id,
                        Z_Side_Asset__c           = line.ns_z_side_service_id,
                    	Product_Attribute__c      = ( line.ns_product_attribute_value.toLowerCase() != 'false' ? line.ns_product_attribute_value : null)
                    );
                    // IBS fields — stored for future CO/QLI reference
                    if (line.charge_through_date != null) a.Charge_Through_Date__c = Date.valueOf(line.charge_through_date);
                    if (line.remarks != null)             a.Description = line.remarks;
                    if (line.billing_charge_type != null)  a.Billing_Charge_Type__c = line.billing_charge_type;
                    if (line.product_attribute != null)     a.Product_Attribute__c = line.product_attribute;
                    if (line.billing_multiplier != null)    a.Billing_Multiplier__c = line.billing_multiplier;
                    if (line.discount != null)              a.Discount_Percent__c = line.discount;
                    if (line.tax_rate != null)              a.Tax_Rate__c = line.tax_rate;
                    if (line.contracted_usd_amount != null) a.Contracted_USD_Amount__c = line.contracted_usd_amount;
                    if (line.ban_id != null)                a.Odoo_BAN_ID__c = String.valueOf(line.ban_id);
                    if (line.target_ban_id != null)         a.Odoo_Target_BAN_ID__c = String.valueOf(line.target_ban_id);
                    if (line.legacy_bill_no != null)        a.Legacy_Bill_No__c = line.legacy_bill_no;
                    toInsert.add(a);
                }
            }

            // Write Odoo line IDs back to OrderItem (only when OI was matched)
            if (oi != null && (line.id != null || line.origin_line_id != null || (line.project_task_ids != null && !line.project_task_ids.isEmpty()) || (line.sub_task_ids != null && !line.sub_task_ids.isEmpty()))) {
                OrderItem oiWrite = new OrderItem(Id = oi.Id);
                if (line.id              != null) oiWrite.Odoo_Sub_Line_ID__c    = String.valueOf(line.id);
                if (line.origin_line_id  != null) oiWrite.Odoo_Origin_Line_ID__c = String.valueOf(line.origin_line_id);
                if (line.project_task_ids != null && !line.project_task_ids.isEmpty()) {
                    oiWrite.Odoo_Project_Task_IDs__c = joinLongs(line.project_task_ids);
                }
                if (line.sub_task_ids != null && !line.sub_task_ids.isEmpty()) { oiWrite.Odoo_Sub_Task_IDs__c = joinLongs(line.sub_task_ids);
                }
                oiSubLineWrite.add(oiWrite);
            }
        }

        if (!toInsert.isEmpty())       upsert toInsert Odoo_IB_ID__c;
        if (!oiSubLineWrite.isEmpty()) update oiSubLineWrite;
        if (subIdStr != null) update new Order(Id = orderId, Odoo_Subscription_ID__c = subIdStr);

        // Stamp SCD__c on linked Inventory records from inserted Assets
        Map<Id, Date> invToScd = new Map<Id, Date>();
        for (Asset a : toInsert) {
            if (a.SCD__c == null) continue;
            if (a.Inventory__c != null) invToScd.put(a.Inventory__c, a.SCD__c);
            if (a.Space__c     != null) invToScd.put(a.Space__c,     a.SCD__c);
        }
        if (!invToScd.isEmpty()) { List<Inventory__c> invUpdates = new List<Inventory__c>();
            for (Id invId : invToScd.keySet()) { invUpdates.add(new Inventory__c(Id = invId, SCD__c = invToScd.get(invId))); } update invUpdates;
        }

        // After insert, Apex populates .Id on each inserted record in the list
        List<Id> ids = new List<Id>();
        for (Asset a : toInsert) ids.add(a.Id);
        return ids;
    }

    // ─── AMENDMENT ────────────────────────────────────────────────────────────

    @TestVisible
    static List<Id> handleAmendment(AssetEventPayload p) {
        Map<String, Asset> assetMap = fetchAssetsByIbId(p.lines);
        String subIdStr = p.odoo_sub_id != null
            ? String.valueOf(p.odoo_sub_id): (!p.lines.isEmpty() && p.lines[0].subscription_id != null ? String.valueOf(p.lines[0].subscription_id) : null);
        List<Asset> toUpdate = new List<Asset>();

        for (LineItem line : p.lines) {
            Decimal amendMrc = line.mrr != null ? line.mrr : line.price_unit;
            String lineSubId = line.subscription_id != null ? String.valueOf(line.subscription_id) : subIdStr;
            for (String ibId : ibKeys(line)) {
                Asset a = assetMap.get(ibId);
                if (a == null) {
                    OdooCalloutService.logError(null, 'IP-2', 'amendment: Asset not found for ib_id=' + ibId);
                    continue;
                }
                if (amendMrc     != null) { a.MRC__c = amendMrc; a.Price = amendMrc; }
                if (line.quantity != null) a.Quantity = line.quantity;
                if (lineSubId    != null) a.Odoo_Subscription_ID__c = lineSubId;
                a.Status                    = 'In Service';
                if(line.ns_product_attribute_value.toLowerCase() != 'false'){a.Product_Attribute__c      = line.ns_product_attribute_value;   
                }
                toUpdate.add(a);
            }
        }
        if (!toUpdate.isEmpty()) update toUpdate;
        List<Id> ids = new List<Id>();
        for (Asset a : toUpdate) ids.add(a.Id);
        return ids;
    }

    // ─── CHURN ────────────────────────────────────────────────────────────────

    @TestVisible
    static List<Id> handleChurn(AssetEventPayload p) {
        Map<String, Asset> assetMap = fetchAssetsByIbId(p.lines);
        List<Asset> toUpdate = new List<Asset>();
		List<Id> lstInvId = new List<Id>();
        for (LineItem line : p.lines) {
            // Accept both termination_date and stop_date (Odoo may use either)
            String termDate = line.termination_date != null ? line.termination_date : line.stop_date;
            for (String ibId : ibKeys(line)) {
                Asset a = assetMap.get(ibId);
                if (a == null) {  OdooCalloutService.logError(null, 'IP-2', 'churn: Asset not found for ib_id=' + ibId); continue;
                }
                a.Asset_Lifecycle_Status__c = 'Terminated';
                a.Termination_Date__c       = termDate != null ? Date.valueOf(termDate) : Date.today();
                a.Status                    = 'Closed';
                if(assetMap.get(ibId).Inventory__c != null){ lstInvId.add(assetMap.get(ibId).Inventory__c);
                }
                if(assetMap.get(ibId).Space__c != null){ lstInvId.add(assetMap.get(ibId).Space__c);
                }
                toUpdate.add(a);
            }
        }
        if (!toUpdate.isEmpty()) update toUpdate;
        if (!lstInvId.isEmpty()){
            List<Inventory__c> lstInvToUpdate = new List<Inventory__c> (); for(Id inID : lstInvId  ){ Inventory__c invRec = new Inventory__c(); invRec.Id = inID; invRec.Status__c = 'Available'; lstInvToUpdate.add(invRec); } if (!lstInvToUpdate.isEmpty()) update lstInvToUpdate;
        }
        List<Id> ids = new List<Id>();
        for (Asset a : toUpdate) ids.add(a.Id);
        return ids;
    }

    // ─── RENEWAL ──────────────────────────────────────────────────────────────

    @TestVisible
    static List<Id> handleRenewal(AssetEventPayload p) {
        Map<String, Asset> assetMap = fetchAssetsByIbId(p.lines);
        String subIdStr = p.odoo_sub_id != null
            ? String.valueOf(p.odoo_sub_id): (!p.lines.isEmpty() && p.lines[0].subscription_id != null ? String.valueOf(p.lines[0].subscription_id) : null);
        List<Asset> toUpdate = new List<Asset>();

        for (LineItem line : p.lines) {
            Decimal renewMrc = line.mrr != null ? line.mrr : line.price_unit;
            String lineSubId = line.subscription_id != null ? String.valueOf(line.subscription_id) : subIdStr;
            for (String ibId : ibKeys(line)) {
                Asset a = assetMap.get(ibId);
                if (a == null) { OdooCalloutService.logError(null, 'IP-2', 'renewal: Asset not found for ib_id=' + ibId); continue;
                }
                a.Asset_Lifecycle_Status__c = 'In Service';
                if (renewMrc     != null) { a.MRC__c = renewMrc; a.Price = renewMrc; }
                if (line.quantity != null) a.Quantity = line.quantity;
                if (lineSubId    != null) a.Odoo_Subscription_ID__c = lineSubId;
                toUpdate.add(a);
            }
        }
        if (!toUpdate.isEmpty()) update toUpdate;
        List<Id> ids = new List<Id>();
        for (Asset a : toUpdate) ids.add(a.Id);
        return ids;
    }

    // ─── SUSPENSION ───────────────────────────────────────────────────────────

    @TestVisible
    static List<Id> handleSuspension(AssetEventPayload p) {
        Map<String, Asset> assetMap = fetchAssetsByIbId(p.lines);
        List<Asset> toUpdate = new List<Asset>();
        for (LineItem line : p.lines) {
            for (String ibId : ibKeys(line)) {
                Asset a = assetMap.get(ibId);
                if (a == null) { OdooCalloutService.logError(null, 'IP-2', 'suspension: Asset not found for ib_id=' + ibId); continue; }
                a.Asset_Lifecycle_Status__c = 'Suspended';
                toUpdate.add(a);
            }
        }
        if (!toUpdate.isEmpty()) update toUpdate;
        List<Id> ids = new List<Id>();
        for (Asset a : toUpdate) ids.add(a.Id);
        return ids;
    }

    // ─── RESUMPTION ───────────────────────────────────────────────────────────

    @TestVisible
    static List<Id> handleResumption(AssetEventPayload p) {
        Map<String, Asset> assetMap = fetchAssetsByIbId(p.lines);
        List<Asset> toUpdate = new List<Asset>();
        for (LineItem line : p.lines) {
            for (String ibId : ibKeys(line)) {
                Asset a = assetMap.get(ibId);
                if (a == null) { OdooCalloutService.logError(null, 'IP-2', 'resumption: Asset not found for ib_id=' + ibId); continue; }
                a.Asset_Lifecycle_Status__c = 'In Service';
                toUpdate.add(a);
            }
        }
        if (!toUpdate.isEmpty()) update toUpdate;
        List<Id> ids = new List<Id>();
        for (Asset a : toUpdate) ids.add(a.Id);
        return ids;
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    // Single query for all Assets in this event by Odoo_IB_ID__c.
    // Collects ALL task IDs from project_task_ids (fan-out) across all lines.
    private static Map<String, Asset> fetchAssetsByIbId(List<LineItem> lines) {
        Set<String> ibIds = new Set<String>();
        for (LineItem line : lines) {
            ibIds.addAll(ibKeys(line));
        }
        Map<String, Asset> result = new Map<String, Asset>();
        for (Asset a : [
            SELECT Id, MRC__c, Quantity, Asset_Lifecycle_Status__c,
                   Termination_Date__c, Status, Price, Odoo_Subscription_ID__c,
                   Odoo_IB_ID__c,Space__c,Inventory__c
            FROM Asset
            WHERE Odoo_IB_ID__c IN :ibIds
        ]) {
            result.put(a.Odoo_IB_ID__c, a);
        }
        return result;
    }

    // Returns all IB ID strings for a line — all project_task_ids, or legacy odoo_ib_id.
    // Lifecycle events (churn/amendment/etc.) fan out to every task ID just like new_service.
    private static List<String> ibKeys(LineItem line) {
        List<String> ids = new List<String>();
        if (line.project_task_ids != null && !line.project_task_ids.isEmpty()) {
            for (Long tid : line.project_task_ids) ids.add(String.valueOf(tid));
        } else if (line.odoo_ib_id != null) {
            ids.add(String.valueOf(line.odoo_ib_id));
        }
        return ids;
    }

    // Joins a list of Long values into a comma-separated string for storage on text fields.
    private static String joinLongs(List<Long> values) {
        List<String> parts = new List<String>();
        for (Long v : values) parts.add(String.valueOf(v));
        return String.join(parts, ',');
    }
    
    // Converts a list of Long values to a list of Strings
    private static List<String> convertLongsToStrings(List<Long> values) {
        List<String> parts = new List<String>();
        for (Long v : values) parts.add(String.valueOf(v));
        return parts;
    }

    private static String jsonSafe(String s) {
        return s == null ? '' : s.replace('"', '\\"');
    }

    public class OdooHandlerException extends Exception {}
}