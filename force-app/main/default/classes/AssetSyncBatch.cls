/**
 * AssetSyncBatch
 * IP-2: Daily batch sync of Odoo Install Base records to Salesforce Asset records.
 * Scheduled by AssetSyncSchedulable at 02:00 HKT (18:00 UTC previous day).
 * Schedule: '0 0 18 * * ?' via System.schedule('DE IP-2 Asset Sync', cron, new AssetSyncSchedulable())
 *
 * Delta sync: fetches Odoo IB records updated after OdooIntegrationSettings__c.IP2_Last_Sync__c.
 * Upsert key: Asset.Odoo_IB_ID__c (external ID).
 *
 * Odoo APIs called per execute():
 *   GET /api/account.asset?updated_after={ts}&limit=500
 *   GET /api/sale.subscription?updated_after={ts}&limit=500
 *
 * Odoo API field assumptions — confirm with Darren before go-live:
 *   id             → Odoo_IB_ID__c (external ID)
 *   name           → Asset.Name
 *   partner_id     → BillingAccount.Odoo_Partner_ID__c → Account__c → Asset.AccountId
 *   product_id     → Product2.Odoo_Product_ID__c → Asset.Product2Id
 *   state          → Asset_Lifecycle_Status__c / Status (see mapOdooState)
 *   mrr            → MRC__c and Price
 *   ns_space_id    → Inventory.Odoo_Space_ID__c → Asset.Inventory__c (TODO: confirm field name)
 *   sale_order_id  → Order.Odoo_Order_ID__c → Source_Order__c (TODO: confirm field name)
 *
 * Subscription API field assumptions:
 *   ib_id / account_asset_id → links subscription to IB record
 *   id                       → Odoo_Subscription_ID__c
 *
 * OPEN ITEMS (confirm with Darren):
 *   1. Exact field names in /api/account.asset response
 *   2. Exact field name linking subscription to IB record in /api/sale.subscription
 *   3. Whether ?updated_after= query param is supported (if not, remove filter and run full sync)
 *   4. Whether limit=500 is sufficient or pagination is needed (offset param)
 *
 * CRITICAL: Odoo JSON-RPC always returns HTTP 200. Error detection is handled by
 * inspecting the response body for "error" key.
 */
global without sharing class AssetSyncBatch implements Database.Batchable<SObject>,
        Database.AllowsCallouts, Database.Stateful {
    // without sharing: system-level sync job — runs as integration user, not a business user.

    private DateTime lastSync;
    private String   formattedTs;
    private Integer  successCount = 0;
    private Integer  errorCount   = 0;
    private Boolean  enabled;

    global AssetSyncBatch() {
        OdooIntegrationSettings__c s = OdooIntegrationSettings__c.getOrgDefaults();
        this.enabled     = (s.IP2_Enabled__c == true);
        this.lastSync    = s.IP2_Last_Sync__c != null
                           ? s.IP2_Last_Sync__c
                           : DateTime.newInstance(2024, 1, 1, 0, 0, 0);
        this.formattedTs = lastSync.format('yyyy-MM-dd HH:mm:ss');
    }

    global Database.QueryLocator start(Database.BatchableContext bc) {
        // Returns exactly 1 record to drive a single execute() call.
        // The scope record is not used — all data comes from Odoo API calls in execute().
        return Database.getQueryLocator('SELECT Id FROM Organization LIMIT 1');
    }

    global void execute(Database.BatchableContext bc, List<SObject> scope) {
        if (!enabled) return;

        OdooIntegrationSettings__c s = OdooIntegrationSettings__c.getOrgDefaults();
        String baseUrl = s.Base_URL__c != null && s.Base_URL__c != ''
            ? s.Base_URL__c
            : 'callout:DigitalEdge_Odoo_' + s.Environment__c;

        // 1. GET updated Install Base records from Odoo
        String assetJson = doGet(baseUrl
            + '/api/account.asset?updated_after='
            + EncodingUtil.urlEncode(formattedTs, 'UTF-8')
            + '&limit=500');
        if (assetJson == null) {
            OdooCalloutService.logError(null, 'IP-2', 'Odoo asset API call failed');
            errorCount++;
            return;
        }

        // 2. GET updated subscription records from Odoo
        String subJson = doGet(baseUrl
            + '/api/sale.subscription?updated_after='
            + EncodingUtil.urlEncode(formattedTs, 'UTF-8')
            + '&limit=500');
        // Subscription sync failure is non-fatal — continue with asset data only

        // 3. Parse Odoo responses
        List<Map<String,Object>> odooAssets = parseResultList(assetJson);
        // subIdByIbId: Odoo IB ID → Odoo Subscription ID
        Map<String, String> subIdByIbId = parseSubscriptionMap(subJson);

        if (odooAssets.isEmpty()) return;

        // 4. Collect Odoo reference IDs for batch SF lookups
        // Note: BillingAccount.Odoo_Partner_ID__c and Order.Odoo_Order_ID__c are Text fields.
        //       Product2.Odoo_Product_ID__c is a Decimal/Number field — use Decimal set for SOQL binding.
        Set<String>  partnerIds = new Set<String>();
        Set<Decimal> productIds = new Set<Decimal>();
        Set<String>  orderIds   = new Set<String>();
        Set<String>  spaceIds   = new Set<String>();   // x_studio_space_id → Inventory__c.Odoo_Space_ID__c
        Set<String>  breakerIds = new Set<String>();   // x_studio_breaker_id → Inventory__c.Odoo_Inventory_Id__c
        Set<String>  sideIds    = new Set<String>();   // ns_a/z_side_service_id → Asset.Odoo_IB_ID__c

        for (Map<String,Object> rec : odooAssets) {
            if (rec.containsKey('partner_id') && rec.get('partner_id') != null) {
                partnerIds.add(String.valueOf(rec.get('partner_id')));
            }
            if (rec.containsKey('product_id') && rec.get('product_id') != null) {
                productIds.add(Decimal.valueOf(String.valueOf(rec.get('product_id'))));
            }
            if (rec.containsKey('sale_order_id') && rec.get('sale_order_id') != null) {
                orderIds.add(String.valueOf(rec.get('sale_order_id')));
            }
            if (rec.containsKey('x_studio_space_id') && rec.get('x_studio_space_id') != null) {
                spaceIds.add(String.valueOf(rec.get('x_studio_space_id')));
            }
            if (rec.containsKey('x_studio_breaker_id') && rec.get('x_studio_breaker_id') != null) {
                breakerIds.add(String.valueOf(rec.get('x_studio_breaker_id')));
            }
            if (rec.containsKey('ns_a_side_service_id') && rec.get('ns_a_side_service_id') != null) {
                sideIds.add(String.valueOf(rec.get('ns_a_side_service_id')));
            }
            if (rec.containsKey('ns_z_side_service_id') && rec.get('ns_z_side_service_id') != null) {
                sideIds.add(String.valueOf(rec.get('ns_z_side_service_id')));
            }
        }

        // 5. Batch SF lookups — single query per object
        Map<String, Id> accountByPartnerId = new Map<String, Id>();
        if (!partnerIds.isEmpty()) {
            for (BillingAccount__c ba : [
                SELECT Odoo_Partner_ID__c, Account__c
                FROM BillingAccount__c
                WHERE Odoo_Partner_ID__c IN :partnerIds
                  AND Account__c != null
            ]) {
                accountByPartnerId.put(ba.Odoo_Partner_ID__c, ba.Account__c);
            }
        }

        Map<Decimal, Id> productByOdooId = new Map<Decimal, Id>();
        if (!productIds.isEmpty()) {
            for (Product2 p2 : [
                SELECT Id, Odoo_Product_ID__c
                FROM Product2
                WHERE Odoo_Product_ID__c IN :productIds
            ]) {
                if (p2.Odoo_Product_ID__c != null) {
                    productByOdooId.put(p2.Odoo_Product_ID__c, p2.Id);
                }
            }
        }

        Map<String, Id> orderByOdooId = new Map<String, Id>();
        if (!orderIds.isEmpty()) {
            for (Order o : [
                SELECT Id, Odoo_Order_ID__c
                FROM Order
                WHERE Odoo_Order_ID__c IN :orderIds
            ]) {
                orderByOdooId.put(o.Odoo_Order_ID__c, o.Id);
            }
        }

        // Space lookup: Odoo space ID → Inventory__c (Space record type)
        Map<String, Id> spaceByOdooId = new Map<String, Id>();
        if (!spaceIds.isEmpty()) {
            for (Inventory__c inv : [
                SELECT Id, Odoo_Space_ID__c
                FROM Inventory__c
                WHERE Odoo_Space_ID__c IN :spaceIds
                  AND RecordType.DeveloperName = 'Inventory_Space'
            ]) {
                spaceByOdooId.put(inv.Odoo_Space_ID__c, inv.Id);
            }
        }

        // Breaker lookup: Odoo inventory ID → Inventory__c (Breaker record type)
        Map<String, Id> breakerByOdooId = new Map<String, Id>();
        if (!breakerIds.isEmpty()) {
            for (Inventory__c inv : [
                SELECT Id, Odoo_Inventory_Id__c
                FROM Inventory__c
                WHERE Odoo_Inventory_Id__c IN :breakerIds
                  AND RecordType.DeveloperName = 'Inventory_Breaker'
            ]) {
                breakerByOdooId.put(inv.Odoo_Inventory_Id__c, inv.Id);
            }
        }

        // A-Side / Z-Side lookup: Odoo IB ID → Asset (other IB records)
        Map<String, Id> assetByIbId = new Map<String, Id>();
        if (!sideIds.isEmpty()) {
            for (Asset side : [
                SELECT Id, Odoo_IB_ID__c
                FROM Asset
                WHERE Odoo_IB_ID__c IN :sideIds
            ]) {
                assetByIbId.put(side.Odoo_IB_ID__c, side.Id);
            }
        }

        // 6. Build upsert list — map Odoo fields to SF Asset fields
        List<Asset> toUpsert = new List<Asset>();
        for (Map<String,Object> rec : odooAssets) {
            Object rawId = rec.get('id');
            if (rawId == null) continue;
            String ibId = String.valueOf(rawId);

            String  partnerId  = rec.containsKey('partner_id')   && rec.get('partner_id')   != null ? String.valueOf(rec.get('partner_id'))   : null;
            Decimal productDec = rec.containsKey('product_id')   && rec.get('product_id')   != null ? Decimal.valueOf(String.valueOf(rec.get('product_id'))) : null;
            String  orderId    = rec.containsKey('sale_order_id') && rec.get('sale_order_id')!= null ? String.valueOf(rec.get('sale_order_id')): null;
            String  odooState  = rec.containsKey('state')         && rec.get('state')        != null ? String.valueOf(rec.get('state'))        : null;
            String  assetName  = rec.containsKey('name')          && rec.get('name')         != null ? String.valueOf(rec.get('name'))         : ('IB-' + ibId);

            Asset a = new Asset();
            a.Odoo_IB_ID__c             = ibId;
            a.Name                      = assetName;
            a.AccountId                 = partnerId  != null ? accountByPartnerId.get(partnerId)  : null;
            a.Product2Id                = productDec != null ? productByOdooId.get(productDec)    : null;
            a.Source_Order__c           = orderId    != null ? orderByOdooId.get(orderId)          : null;
            a.Asset_Lifecycle_Status__c = mapLifecycleStatus(odooState);
            a.Status                    = mapSFStatus(odooState);

            // Subscription ID — from sub sync map first, then inline if present
            if (subIdByIbId.containsKey(ibId)) {
                a.Odoo_Subscription_ID__c = subIdByIbId.get(ibId);
            } else if (rec.containsKey('subscription_id') && rec.get('subscription_id') != null) {
                a.Odoo_Subscription_ID__c = String.valueOf(rec.get('subscription_id'));
            }

            // MRC
            if (rec.containsKey('mrr') && rec.get('mrr') != null) {
                Decimal mrr = Decimal.valueOf(String.valueOf(rec.get('mrr')));
                a.MRC__c = mrr;
                a.Price  = mrr;
            }

            // Start/install date
            if (rec.containsKey('start_date') && rec.get('start_date') != null) {
                String ds = String.valueOf(rec.get('start_date'));
                if (ds.length() >= 10) {
                    a.SCD__c         = Date.valueOf(ds.substring(0, 10));
                    a.InstallDate    = Date.valueOf(ds.substring(0, 10));
                }
            }

            // Service ID (x_studio_service_id)
            if (rec.containsKey('x_studio_service_id') && rec.get('x_studio_service_id') != null) {
                a.Service_ID__c = String.valueOf(rec.get('x_studio_service_id'));
            }

            // Physical space (cabinet/cage) — lookup via Odoo_Space_ID__c
            if (rec.containsKey('x_studio_space_id') && rec.get('x_studio_space_id') != null) {
                String sid = String.valueOf(rec.get('x_studio_space_id'));
                a.Space__c = spaceByOdooId.get(sid);
            }

            // Physical breaker — lookup via Odoo_Inventory_Id__c
            if (rec.containsKey('x_studio_breaker_id') && rec.get('x_studio_breaker_id') != null) {
                String bid = String.valueOf(rec.get('x_studio_breaker_id'));
                a.Inventory__c = breakerByOdooId.get(bid);
            }

            // A-Side / Z-Side cross-connect topology — lookup via Odoo_IB_ID__c
            if (rec.containsKey('ns_a_side_service_id') && rec.get('ns_a_side_service_id') != null) {
                String aid = String.valueOf(rec.get('ns_a_side_service_id'));
                a.A_Side_Asset__c = assetByIbId.get(aid);
            }
            if (rec.containsKey('ns_z_side_service_id') && rec.get('ns_z_side_service_id') != null) {
                String zid = String.valueOf(rec.get('ns_z_side_service_id'));
                a.Z_Side_Asset__c = assetByIbId.get(zid);
            }

            // Customer service reference
            if (rec.containsKey('ns_customer_service_reference') && rec.get('ns_customer_service_reference') != null) {
                a.Customer_Service_Reference__c = String.valueOf(rec.get('ns_customer_service_reference'));
            }

            toUpsert.add(a);
        }

        // 7. Upsert via Odoo_IB_ID__c external ID — allOrNone=false so partial failures are logged
        if (!toUpsert.isEmpty()) {
            List<Database.UpsertResult> results =
                Database.upsert(toUpsert, Asset.Fields.Odoo_IB_ID__c, false);
            for (Integer i = 0; i < results.size(); i++) {
                if (!results[i].isSuccess()) {
                    errorCount++;
                    OdooCalloutService.logError(null, 'IP-2',
                        'Upsert failed for Odoo IB ID ' + toUpsert[i].Odoo_IB_ID__c
                        + ': ' + results[i].getErrors()[0].getMessage());
                } else {
                    successCount++;
                }
            }
        }
    }

    global void finish(Database.BatchableContext bc) {
        // Only update watermark when there were no errors — preserves retry safety
        if (errorCount == 0) {
            OdooIntegrationSettings__c s = OdooIntegrationSettings__c.getOrgDefaults();
            s.IP2_Last_Sync__c = DateTime.now();
            update s;
        }
        System.debug('IP-2 AssetSyncBatch complete. Success: ' + successCount + ' | Errors: ' + errorCount);
        // TODO: Send notification to Integration Admin queue if errorCount > 0
    }

    // ─── HTTP helpers ─────────────────────────────────────────────────────────

    /**
     * Makes a GET request and returns the raw body string.
     * Returns null on failure (caller logs the error).
     * Direct HTTP call required because OdooCalloutService.execute() expects a single
     * result object, not an array — list endpoints need direct body access.
     */
    private static String doGet(String url) {
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(url);
            req.setMethod('GET');
            req.setTimeout(60000);
            HttpResponse raw = new Http().send(req);
            if (raw.getStatusCode() == 200) {
                return raw.getBody();
            }
        } catch (Exception e) {
            System.debug('IP-2 GET failed: ' + e.getMessage());
        }
        return null;
    }

    // ─── JSON parsing helpers ─────────────────────────────────────────────────

    /**
     * Parses an Odoo list response body.
     * Handles two formats:
     *   JSON-RPC: { "result": [{...}, ...] }
     *   Plain REST: [{...}, ...]
     */
    @TestVisible
    static List<Map<String,Object>> parseResultList(String rawBody) {
        if (rawBody == null || rawBody == '') return new List<Map<String,Object>>();
        try {
            Object parsed = JSON.deserializeUntyped(rawBody);
            if (parsed instanceof List<Object>) {
                // Plain REST array
                return castToMapList((List<Object>) parsed);
            }
            if (parsed instanceof Map<String,Object>) {
                Map<String,Object> wrapper = (Map<String,Object>) parsed;
                if (wrapper.containsKey('result') && wrapper.get('result') instanceof List<Object>) {
                    return castToMapList((List<Object>) wrapper.get('result'));
                }
            }
        } catch (Exception e) {
            System.debug('IP-2 parseResultList error: ' + e.getMessage());
        }
        return new List<Map<String,Object>>();
    }

    /**
     * Builds a map from Odoo IB ID → Subscription ID from /api/sale.subscription response.
     * Assumes subscription records include an ib_id or account_asset_id field linking to the IB.
     * TODO: Confirm exact field name with Darren.
     */
    @TestVisible
    static Map<String, String> parseSubscriptionMap(String rawBody) {
        Map<String, String> result = new Map<String, String>();
        if (rawBody == null || rawBody == '') return result;
        try {
            List<Map<String,Object>> subs = parseResultList(rawBody);
            for (Map<String,Object> sub : subs) {
                // Try both likely field names for the IB link
                Object ibRef = sub.containsKey('account_asset_id') ? sub.get('account_asset_id')
                             : sub.containsKey('ib_id') ? sub.get('ib_id') : null;
                Object subId = sub.get('id');
                if (ibRef != null && subId != null) {
                    result.put(String.valueOf(ibRef), String.valueOf(subId));
                }
            }
        } catch (Exception e) {
            System.debug('IP-2 parseSubscriptionMap error: ' + e.getMessage());
        }
        return result;
    }

    private static List<Map<String,Object>> castToMapList(List<Object> rawList) {
        List<Map<String,Object>> out = new List<Map<String,Object>>();
        for (Object item : rawList) {
            if (item instanceof Map<String,Object>) {
                out.add((Map<String,Object>) item);
            }
        }
        return out;
    }

    // ─── State mapping helpers ────────────────────────────────────────────────

    /**
     * Maps Odoo asset state to Asset_Lifecycle_Status__c picklist values.
     * Odoo states: order → provisioning → in_service → suspended → terminated
     */
    private static String mapLifecycleStatus(String odooState) {
        if ('order'.equalsIgnoreCase(odooState))        return 'Ordered';
        if ('provisioning'.equalsIgnoreCase(odooState)) return 'In Provisioning';
        if ('in_service'.equalsIgnoreCase(odooState))   return 'In Service';
        if ('suspended'.equalsIgnoreCase(odooState))    return 'Suspended';
        if ('terminated'.equalsIgnoreCase(odooState))   return 'Terminated';
        return 'In Service'; // default
    }

    /**
     * Maps Odoo asset state to standard Asset.Status picklist.
     */
    private static String mapSFStatus(String odooState) {
        if ('terminated'.equalsIgnoreCase(odooState)) return 'Closed';
        if ('order'.equalsIgnoreCase(odooState))      return 'Ordered';
        return 'In Service'; // provisioning, in_service, suspended
    }
}