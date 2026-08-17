/**
 * QuoteLineItemTriggerHandler
 *
 * Handles trigger logic for the QuoteLineItem object.
 *
 * VR-QLI-01: Block deletion of QuoteLineItem records where Is_Auto_NRC__c = true
 * AND Paired_MRC_Line__c != null. Auto-generated NRC lines are structurally coupled
 * to their paired MRC line and must not be removed independently.
 *
 * Odoo Attribute Resolution: On insert/update, when Product_Attribute_Value__c is
 * populated, resolves the Odoo ns_product_product_attr combo ID from
 * Product_Attribute_Variant__mdt using {ProductCode, AttributeValue, SiteCode} and
 * stamps it on Odoo_Attribute_Value_ID__c. This flows to OrderItem via SOF Handler
 * and into IP-1 (SendNewOrdersQueueable).
 *
 * Inventory Status Lifecycle (after context):
 *   - After insert/update: when Space__c or Inventory__c is populated on a QLI,
 *     sets the linked Inventory record to Status = 'Assigned' and stamps Quote_Line__c.
 *   - When cleared or changed, reverts the old Inventory to 'Available' (if still Assigned).
 *   - After delete: reverts linked Inventory records to 'Available'.
 *   Implements transcript requirement: "items you reserve, status should change into assigned"
 *
 * Bypass: TriggerBypass__mdt record with DeveloperName = 'QuoteLineItemTriggerHandler'
 * and Is_Active__c = true will suppress all handler execution. Used for data
 * migrations and emergency suppression — no code deploy required.
 *
 * FB-798: After insert/update/delete, recalculates Quote.Total_MRC_2__c and
 * Quote.Total_Contract_Value_2__c via QuoteMrcRollupService (replaces the old
 * Total_MRC__c Roll-Up Summary / Total_Contract_Value__c formula fields, deleted
 * because Salesforce does not allow converting a Roll-Up Summary or Formula
 * field to Currency in place).
 */
public with sharing class QuoteLineItemTriggerHandler {

    // Shared PBE context — loaded once per transaction, consumed by
    // stampOdooProductIds, stampChargeFields, and stampReservedStatus.
    // Eliminates 2 redundant SOQL queries per before-insert/update cycle.
    private Map<Id, PricebookEntry> sharedPbeContext;

    // @TestVisible: QuoteLineItem.PricebookEntryId is not updateable via DML for
    // any user (Salesforce platform restriction — see field describe:
    // updateable=false, permissionable=false). The "product changed on update"
    // branches in stampOdooProductIds/stampChargeFields therefore can only be
    // exercised by calling these methods directly with an in-memory oldMap
    // that simulates a PricebookEntryId change; no real update DML can ever
    // produce that trigger.oldMap state. No behavioral change.
    @TestVisible
    private void loadSharedPbeContext(List<QuoteLineItem> records) {
        Set<Id> pbeIds = new Set<Id>();
        for (QuoteLineItem qli : records) {
            if (qli.PricebookEntryId != null) pbeIds.add(qli.PricebookEntryId);
        }
        if (pbeIds.isEmpty()) {
            sharedPbeContext = new Map<Id, PricebookEntry>();
            return;
        }
        sharedPbeContext = new Map<Id, PricebookEntry>([
            SELECT Id, Product2Id, Product2.Odoo_Product_Id__c, Product2.ProductCode,
                   Product2.Charge_Type__c, Product2.Charge_Frequency__c,
                   Product2.Billing_Charge_Type__c, Product2.Capacity_Assignment__c
            FROM PricebookEntry
            WHERE Id IN :pbeIds
        ]);
    }

    /**
     * Entry point called by QuoteLineItemTrigger.
     * Routes to the appropriate context method based on trigger operation.
     */
    public void dispatch() {
        TriggerBypass__mdt bypass = TriggerBypass__mdt.getInstance('QuoteLineItemTriggerHandler');
        if (bypass != null && bypass.Is_Active__c) {
            return;
        }

        if (Trigger.isBefore && Trigger.isInsert) {
            beforeInsert(Trigger.new);
        }
        if (Trigger.isBefore && Trigger.isUpdate) {
            beforeUpdate(Trigger.new, (Map<Id, QuoteLineItem>) Trigger.oldMap);
        }
        if (Trigger.isBefore && Trigger.isDelete) {
            beforeDelete(Trigger.old);
        }
        if (Trigger.isAfter && Trigger.isInsert) {
            afterInsert(Trigger.new);
        }
        if (Trigger.isAfter && Trigger.isUpdate) {
            afterUpdate(Trigger.new, (Map<Id, QuoteLineItem>) Trigger.oldMap);
        }
        if (Trigger.isAfter && Trigger.isDelete) {
            afterDelete(Trigger.old);
        }
    }

    // ─── Before Insert ─────────────────────────────────────────────────────────

    private void beforeInsert(List<QuoteLineItem> newRecords) {
        blockNonRampInserts(newRecords);
        loadSharedPbeContext(newRecords);
        stampOdooProductIds(newRecords, null);
        stampChargeFields(newRecords, null);
        stampReservedStatus(newRecords);
        resolveOdooAttributeValueIds(newRecords, null);
    }

    /**
     * Prevents adding standalone products to a quote that has an active ramp.
     * All product changes should go through the Edit Ramp modal instead.
     * Allows: ramp phase inserts, auto-paired NRCs.
     */
    private void blockNonRampInserts(List<QuoteLineItem> newRecords) {
        Set<Id> quoteIds = new Set<Id>();
        List<QuoteLineItem> candidates = new List<QuoteLineItem>();
        for (QuoteLineItem qli : newRecords) {
            if (qli.QuoteId == null) continue;
            if (qli.Line_Origin__c == 'Ramp') continue;
            if (qli.Is_Auto_NRC__c == true) continue;
            quoteIds.add(qli.QuoteId);
            candidates.add(qli);
        }
        if (quoteIds.isEmpty()) return;

        Set<Id> quotesWithRamp = new Set<Id>();
        for (QuoteLineItem existing : [
            SELECT QuoteId FROM QuoteLineItem
            WHERE QuoteId IN :quoteIds AND Line_Origin__c = 'Ramp'
            LIMIT 1
        ]) {
            quotesWithRamp.add(existing.QuoteId);
        }
        if (quotesWithRamp.isEmpty()) return;

        for (QuoteLineItem qli : candidates) {
            if (quotesWithRamp.contains(qli.QuoteId)) {
                qli.addError('This quote has an active ramp schedule. Add or remove products through the Edit Ramp modal instead.');
            }
        }
    }

    /**
     * If a non-ramped line for the same product already exists on the quote,
     * increment its qty instead of creating a duplicate.
     * The new record's insert is NOT blocked (can't prevent in before-insert),
     * so we mark it for after-insert cleanup.
     *
     * NOTE: Not currently invoked from beforeInsert()/dispatch() — this method
     * (and its after-insert counterpart cleanupMergedLines) is orphaned code
     * from an earlier merge-on-insert design that was superseded by
     * mergeWithExistingLines being called nowhere in the trigger chain today.
     * Marked @TestVisible solely so QuoteLineItemTriggerHandlerTest2 can invoke
     * it directly for coverage; no behavioral change.
     */
    @TestVisible
    private void mergeWithExistingLines(List<QuoteLineItem> newRecords) {
        // Collect quoteId + product2Id for incoming lines
        Set<Id> quoteIds = new Set<Id>();
        Set<Id> productIds = new Set<Id>();
        for (QuoteLineItem qli : newRecords) {
            if (qli.QuoteId != null && qli.Product2Id != null) {
                quoteIds.add(qli.QuoteId);
                productIds.add(qli.Product2Id);
            }
        }
        if (quoteIds.isEmpty()) return;

        // Find existing non-ramped lines for the same products
        // Key includes attribute so CAB001.RC 2kVA and CAB001.RC 6kVA are distinct
        Map<String, QuoteLineItem> existingByKey = new Map<String, QuoteLineItem>();
        for (QuoteLineItem ex : [
            SELECT Id, QuoteId, Product2Id, Quantity, Product_Attribute_Value__c
            FROM QuoteLineItem
            WHERE QuoteId IN :quoteIds AND Product2Id IN :productIds
              AND (Line_Origin__c = null OR Line_Origin__c = 'New')
        ]) {
            String attr = ex.Product_Attribute_Value__c != null ? ex.Product_Attribute_Value__c : '';
            existingByKey.put(ex.QuoteId + '_' + ex.Product2Id + '_' + attr, ex);
        }
        if (existingByKey.isEmpty()) return;

        // Increment existing line's qty; mark new record for post-insert deletion
        Map<Id, QuoteLineItem> toUpdateMap = new Map<Id, QuoteLineItem>();
        Set<Id> mergedMrcIds = new Set<Id>();
        for (QuoteLineItem qli : newRecords) {
            String attr = qli.Product_Attribute_Value__c != null ? qli.Product_Attribute_Value__c : '';
            String key = qli.QuoteId + '_' + qli.Product2Id + '_' + attr;
            QuoteLineItem existing = existingByKey.get(key);
            if (existing != null && !qli.Is_Auto_NRC__c && qli.Line_Origin__c != 'Ramp'
                    && !toUpdateMap.containsKey(existing.Id)) {
                existing.Quantity = (existing.Quantity != null ? existing.Quantity : 0) + (qli.Quantity != null ? qli.Quantity : 1);
                toUpdateMap.put(existing.Id, existing);
                mergedMrcIds.add(existing.Id);
                qli.Line_Origin__c = 'Merge_Pending';
            }
        }
        List<QuoteLineItem> toUpdate = toUpdateMap.values();
        if (!toUpdate.isEmpty()) {
            update toUpdate;

            // Cascade qty to paired NRC lines — sum across ALL MRCs sharing the same NRC product
            // Find NRCs via QLI pairing AND via product-level Paired_NRC_Product__c
            Set<Id> mergedProductIds = new Set<Id>();
            for (QuoteLineItem u : toUpdate) mergedProductIds.add(u.Product2Id);
            Set<Id> pairedNrcProductIds = new Set<Id>();
            for (Product2 prod : [SELECT Paired_NRC_Product__c FROM Product2
                    WHERE Id IN :mergedProductIds AND Paired_NRC_Product__c != null]) {
                pairedNrcProductIds.add(prod.Paired_NRC_Product__c);
            }
            List<QuoteLineItem> nrcLines = [
                SELECT Id, Paired_MRC_Line__c, Quantity, Product2Id, QuoteId
                FROM QuoteLineItem
                WHERE Paired_MRC_Line__c IN :mergedMrcIds
                   OR (QuoteId IN :quoteIds AND Product2Id IN :pairedNrcProductIds)
            ];
            if (!nrcLines.isEmpty()) {
                // For each NRC, sum qty of ALL MRC lines on the same quote that share the same NRC product
                Set<Id> nrcQuoteIds = new Set<Id>();
                Set<Id> nrcProductIds = new Set<Id>();
                for (QuoteLineItem nrc : nrcLines) {
                    nrcQuoteIds.add(nrc.QuoteId);
                    nrcProductIds.add(nrc.Product2Id);
                }
                // Find ALL MRC lines paired to the same NRC products
                Map<String, Decimal> nrcQtySum = new Map<String, Decimal>();
                for (QuoteLineItem mrc : [
                    SELECT Quantity, Product2.Paired_NRC_Product__c, QuoteId
                    FROM QuoteLineItem
                    WHERE QuoteId IN :nrcQuoteIds
                      AND Product2.Paired_NRC_Product__c IN :nrcProductIds
                      AND Charge_Type__c != 'NRC'
                ]) {
                    String key = mrc.QuoteId + '_' + mrc.Product2.Paired_NRC_Product__c;
                    Decimal sum = nrcQtySum.containsKey(key) ? nrcQtySum.get(key) : 0;
                    nrcQtySum.put(key, sum + (mrc.Quantity != null ? mrc.Quantity : 0));
                }
                List<QuoteLineItem> nrcUpdates = new List<QuoteLineItem>();
                for (QuoteLineItem nrc : nrcLines) {
                    String key = nrc.QuoteId + '_' + nrc.Product2Id;
                    Decimal sumQty = nrcQtySum.get(key);
                    if (sumQty != null && nrc.Quantity != sumQty) {
                        nrc.Quantity = sumQty;
                        nrcUpdates.add(nrc);
                    }
                }
                if (!nrcUpdates.isEmpty()) {
                    update nrcUpdates;
                }
            }
        }
    }

    // ─── Before Update ─────────────────────────────────────────────────────────

    private void beforeUpdate(List<QuoteLineItem> newRecords, Map<Id, QuoteLineItem> oldMap) {
        loadSharedPbeContext(newRecords);
        stampOdooProductIds(newRecords, oldMap);
        stampChargeFields(newRecords, oldMap);
        resolveOdooAttributeValueIds(newRecords, oldMap);
    }

    // ─── Odoo Product ID Propagation ──────────────────────────────────────────

    /**
     * Stamps Odoo_Product_ID__c on QuoteLineItem from Product2.Odoo_Product_Id__c.
     * Runs on insert (always) and update (when product changes).
     * Ensures the value flows through regardless of how the QLI was created
     * (standard Add Products button, custom LWC editor, or Apex).
     */
    @TestVisible
    private void stampOdooProductIds(List<QuoteLineItem> lines, Map<Id, QuoteLineItem> oldMap) {
        List<QuoteLineItem> candidates = new List<QuoteLineItem>();
        Set<Id> pbeIds = new Set<Id>();

        for (QuoteLineItem qli : lines) {
            if (oldMap == null) {
                // Insert: stamp when not already set
                if (qli.Odoo_Product_ID__c == null && qli.PricebookEntryId != null) {
                    candidates.add(qli);
                    pbeIds.add(qli.PricebookEntryId);
                }
            } else {
                QuoteLineItem old = oldMap.get(qli.Id);
                // Update: re-stamp when product changed
                if (qli.PricebookEntryId != old.PricebookEntryId && qli.PricebookEntryId != null) {
                    candidates.add(qli);
                    pbeIds.add(qli.PricebookEntryId);
                }
            }
        }

        if (candidates.isEmpty()) return;

        Map<Id, Decimal> odooIdByPbeId = new Map<Id, Decimal>();
        for (Id pbeId : pbeIds) {
            PricebookEntry pbe = sharedPbeContext != null ? sharedPbeContext.get(pbeId) : null;
            if (pbe != null && pbe.Product2 != null && pbe.Product2.Odoo_Product_Id__c != null) {
                odooIdByPbeId.put(pbe.Id, pbe.Product2.Odoo_Product_Id__c);
            }
        }

        for (QuoteLineItem qli : candidates) {
            Decimal odooId = odooIdByPbeId.get(qli.PricebookEntryId);
            if (odooId != null) {
                qli.Odoo_Product_ID__c = odooId;
            }
        }
    }

    // ─── Charge Field Propagation ────────────────────────────────────────────

    /**
     * Stamps Charge_Type__c, Charge_Frequency__c, and Billing_Mode__c on
     * QuoteLineItem from the parent Product2 record.
     * Runs on insert (when not already set) and update (when product changes).
     * Ensures values flow through regardless of how the QLI was created
     * (standard Add Products button, custom LWC editor, or Apex).
     *
     * Charge_Type__c fallback: if Product2.Charge_Type__c is blank, derives
     * from ProductCode convention (.NR → NRC, .RC → MRC).
     *
     * Billing_Mode__c: Product2 stores ADVANCE/ARREAR; QLI picklist expects
     * Advance/Arrear — case-normalised on stamp.
     */
    @TestVisible
    private void stampChargeFields(List<QuoteLineItem> lines, Map<Id, QuoteLineItem> oldMap) {
        List<QuoteLineItem> candidates = new List<QuoteLineItem>();
        Set<Id> pbeIds = new Set<Id>();

        for (QuoteLineItem qli : lines) {
            if (qli.PricebookEntryId == null) continue;
            if (oldMap == null) {
                // Insert: stamp when any charge field is blank
                if (String.isBlank(qli.Charge_Type__c)
                    || String.isBlank(qli.Charge_Frequency__c)
                    || String.isBlank(qli.Billing_Mode__c)) {
                    candidates.add(qli);
                    pbeIds.add(qli.PricebookEntryId);
                }
            } else {
                QuoteLineItem old = oldMap.get(qli.Id);
                // Update: re-stamp when product changed
                if (qli.PricebookEntryId != old.PricebookEntryId) {
                    candidates.add(qli);
                    pbeIds.add(qli.PricebookEntryId);
                }
            }
        }

        if (candidates.isEmpty()) return;

        for (QuoteLineItem qli : candidates) {
            PricebookEntry pbe = sharedPbeContext != null ? sharedPbeContext.get(qli.PricebookEntryId) : null;
            if (pbe == null || pbe.Product2 == null) continue;
            Product2 prod = pbe.Product2;

            // Charge Type: product value, fallback to code convention
            if (String.isBlank(qli.Charge_Type__c)) {
                if (String.isNotBlank(prod.Charge_Type__c)) {
                    qli.Charge_Type__c = prod.Charge_Type__c;
                } else if (String.isNotBlank(prod.ProductCode)) {
                    String code = prod.ProductCode.toUpperCase();
                    if (code.endsWith('.NR')) {
                        qli.Charge_Type__c = 'NRC';
                    } else if (code.endsWith('.RC')) {
                        qli.Charge_Type__c = 'MRC';
                    }
                }
            }

            // Charge Frequency
            if (String.isBlank(qli.Charge_Frequency__c) && String.isNotBlank(prod.Charge_Frequency__c)) {
                qli.Charge_Frequency__c = prod.Charge_Frequency__c;
            }

            // Billing Mode (Product2.Billing_Charge_Type__c → QLI.Billing_Mode__c)
            if (String.isBlank(qli.Billing_Mode__c) && String.isNotBlank(prod.Billing_Charge_Type__c)) {
                String bct = prod.Billing_Charge_Type__c.toLowerCase();
                qli.Billing_Mode__c = bct.substring(0, 1).toUpperCase() + bct.substring(1);
            }
        }
    }

    // ─── Reserved Status Defaulting ─────────────────────────────────────────────

    /**
     * Stamps Reserved__c on new QuoteLineItem records based on the product's
     * Capacity_Assignment__c field:
     *
     * - NRC products (.NR code or Charge_Type__c = NRC): 'N/A'
     * - Products with no Capacity_Assignment__c (cross-connects, managed services,
     *   network services, additional charges): 'N/A'
     * - Products with Capacity_Assignment__c (Space ID, Breaker ID, Patch Panel ID,
     *   Port ID, Subduct ID): 'Not Reserved'
     *
     * The InventoryController sets Reserved__c = 'Reserved' when inventory is
     * actually assigned, and reverts to 'Not Reserved' when released.
     *
     * Runs on insert only — updates to Reserved__c are managed by inventory
     * assignment, not product changes.
     */
    private void stampReservedStatus(List<QuoteLineItem> newRecords) {
        for (QuoteLineItem qli : newRecords) {
            PricebookEntry pbe = (sharedPbeContext != null && qli.PricebookEntryId != null)
                ? sharedPbeContext.get(qli.PricebookEntryId) : null;
            if (pbe == null || pbe.Product2 == null) continue;

            String code = pbe.Product2.ProductCode;
            String cap  = pbe.Product2.Capacity_Assignment__c;

            // Ramp Phase 2+ lines don't need separate capacity reservation
            if (qli.Line_Origin__c == 'Ramp' && qli.Ramp_Phase__c != null && qli.Ramp_Phase__c > 1) {
                qli.Reserved__c = 'N/A';
                continue;
            }

            // NRC products never need capacity reservation
            Boolean isNrc = (String.isNotBlank(code) && code.toUpperCase().endsWith('.NR'))
                         || qli.Charge_Type__c == 'NRC';

            // Change Orders: only genuine new-add lines need a fresh reservation.
            // Removals, price changes, no-change, and quantity reductions do not.
            String ct = qli.Change_Type__c;
            Boolean coNoReservation =
                   ct == 'DELETE' || ct == 'REMOVE' || ct == 'CHANGE_PRICE' || ct == 'NO_CHANGE' || ct == 'CHANGE' || ct == 'RENEW'
                || (qli.Quantity != null && qli.Quantity < 0);

            if (isNrc || String.isBlank(cap) || coNoReservation) {
                qli.Reserved__c = 'N/A';
            } else {
                qli.Reserved__c = 'Not Reserved';
            }
        }
    }

    // ─── Odoo Attribute Resolution ─────────────────────────────────────────────

    /**
     * Resolves Odoo_Attribute_Value_ID__c from Product_Attribute_Variant__mdt.
     *
     * Lookup key: {Product2.ProductCode, Product_Attribute_Value__c, Quote.Target_Site__r.Site_Code__c}
     * Matching is case-insensitive (Odoo data has inconsistent kVA/kVa casing).
     * Uses getAll() — zero SOQL cost for CMT reads.
     *
     * @param lines   Trigger.new records
     * @param oldMap  Trigger.oldMap (null for insert context)
     */
    private void resolveOdooAttributeValueIds(List<QuoteLineItem> lines, Map<Id, QuoteLineItem> oldMap) {
        List<QuoteLineItem> candidates = new List<QuoteLineItem>();

        for (QuoteLineItem qli : lines) {
            String attrVal = qli.Product_Attribute_Value__c;

            if (oldMap == null) {
                // Insert: resolve when attribute value is populated
                if (String.isNotBlank(attrVal)) {
                    candidates.add(qli);
                }
            } else {
                QuoteLineItem old = oldMap.get(qli.Id);
                // Update: resolve when attribute value or product changed
                if (attrVal != old.Product_Attribute_Value__c || qli.PricebookEntryId != old.PricebookEntryId) {
                    if (String.isNotBlank(attrVal)) {
                        candidates.add(qli);
                    } else {
                        // Attribute cleared — clear the resolved ID
                        qli.Odoo_Attribute_Value_ID__c = null;
                    }
                }
            }
        }

        if (candidates.isEmpty()) {
            return;
        }

        // Collect parent IDs for bulk queries
        // Use PricebookEntryId (not Product2Id) because Product2Id is a derived
        // field that may not be populated during before insert trigger context.
        Set<Id> pbeIds   = new Set<Id>();
        Set<Id> quoteIds = new Set<Id>();
        for (QuoteLineItem qli : candidates) {
            pbeIds.add(qli.PricebookEntryId);
            quoteIds.add(qli.QuoteId);
        }

        // Query product codes via PricebookEntry → Product2 (1 SOQL)
        Map<Id, String> productCodeByPbeId = new Map<Id, String>();
        for (PricebookEntry pbe : [
            SELECT Id, Product2.ProductCode
            FROM PricebookEntry
            WHERE Id IN :pbeIds
        ]) {
            String pc = pbe.Product2 != null ? pbe.Product2.ProductCode : null;
            productCodeByPbeId.put(pbe.Id, pc);
        }

        // Query site codes + account IDs via Quote (1 SOQL)
        Map<Id, String> siteCodeByQuoteId = new Map<Id, String>();
        Map<Id, Id> accountIdByQuoteId = new Map<Id, Id>();
        for (Quote q : [
            SELECT Id, AccountId, Target_Site__c, Target_Site__r.Site_Code__c
            FROM Quote
            WHERE Id IN :quoteIds
        ]) {
            String sc = q.Target_Site__r != null ? q.Target_Site__r.Site_Code__c : null;
            siteCodeByQuoteId.put(q.Id, sc);
            accountIdByQuoteId.put(q.Id, q.AccountId);
        }

        // Query quote currency for price resolution (1 SOQL)
        Map<Id, String> currencyByQuoteId = new Map<Id, String>();
        for (Quote q : [
            SELECT Id, CurrencyIsoCode FROM Quote WHERE Id IN :quoteIds
        ]) {
            currencyByQuoteId.put(q.Id, q.CurrencyIsoCode);
        }

        // Build case-insensitive lookup map from consolidated CMT (0 SOQL)
        // Key: "product|attribute|site|currency" — all field-based, no name parsing
        Map<String, Product_Pricing_Tier__mdt> tierMap = new Map<String, Product_Pricing_Tier__mdt>();
        for (Product_Pricing_Tier__mdt t : Product_Pricing_Tier__mdt.getAll().values()) {
            String k = ((t.Product_Code__c != null ? t.Product_Code__c : '') + '|'
                      + (t.Attribute_Value__c != null ? t.Attribute_Value__c : '') + '|'
                      + (t.Site_Code__c != null ? t.Site_Code__c : '') + '|'
                      + (t.Currency_Code__c != null ? t.Currency_Code__c : '')).toLowerCase();
            tierMap.put(k, t);
        }

        // Also keep legacy PAV map for Odoo_Combo_Id (PAV has broader site coverage for combo IDs)
        Map<String, Product_Attribute_Variant__mdt> pavByKey = new Map<String, Product_Attribute_Variant__mdt>();
        for (Product_Attribute_Variant__mdt pav : Product_Attribute_Variant__mdt.getAll().values()) {
            String key = (pav.Product_Code__c + '|' + pav.Attribute_Value__c + '|' + pav.Site_Code__c).toLowerCase();
            pavByKey.put(key, pav);
        }

        // Stamp resolved combo ID + list price on each candidate
        for (QuoteLineItem qli : candidates) {
            String prodCode = productCodeByPbeId.get(qli.PricebookEntryId);
            String siteCode = siteCodeByQuoteId.get(qli.QuoteId);
            String attrVal  = qli.Product_Attribute_Value__c;
            String ccy      = currencyByQuoteId.get(qli.QuoteId);
            if (ccy == null) ccy = 'USD';

            if (String.isBlank(prodCode)) {
                qli.Odoo_Attribute_Value_ID__c = null;
                continue;
            }

            // 4-tier price lookup: site-specific → product-specific → generic-by-currency → attribute-only
            String pc = prodCode.toLowerCase();
            String av = (attrVal != null ? attrVal : '').toLowerCase();
            String sc = (siteCode != null ? siteCode : '').toLowerCase();
            String cc = ccy.toLowerCase();

            Product_Pricing_Tier__mdt tier = tierMap.get(pc + '|' + av + '|' + sc + '|' + cc);
            if (tier == null) tier = tierMap.get(pc + '|' + av + '|' + '|' + cc);
            if (tier == null) tier = tierMap.get('|' + av + '|' + '|' + cc);
            if (tier == null) tier = tierMap.get('|' + av + '|' + '|' + 'all');

            if (tier != null && tier.Price__c != null) {
                qli.List_Price__c = tier.Price__c;
            }

            // Odoo combo ID: check new CMT first, fall back to legacy PAV
            Decimal odooId = tier != null ? tier.Odoo_Combo_Id__c : null;
            if (odooId == null || odooId == 0) {
                String pavKey = (prodCode + '|' + attrVal + '|' + (siteCode != null ? siteCode : '')).toLowerCase();
                Product_Attribute_Variant__mdt pav = pavByKey.get(pavKey);
                odooId = pav != null ? pav.Odoo_Combo_Id__c : null;
            }
            qli.Odoo_Attribute_Value_ID__c = (odooId != null && odooId != 0) ? odooId : null;
        }

        // ── Account-specific price override ────────────────────────────────
        // After CMT stamps the standard list price, check if the account has
        // approved pricing that should override it. Works for ALL products —
        // both attributed (key includes attribute value) and non-attributed
        // (key has empty attribute portion).
        Set<Id> accountIds = new Set<Id>(accountIdByQuoteId.values());
        accountIds.remove(null);
        if (!accountIds.isEmpty()) {
            Map<String, Decimal> acctPrices = new AccountPriceLookup().getAccountPrices(accountIds);
            if (!acctPrices.isEmpty()) {
                for (QuoteLineItem qli : candidates) {
                    Id acctId = accountIdByQuoteId.get(qli.QuoteId);
                    String pc = productCodeByPbeId.get(qli.PricebookEntryId);
                    if (acctId == null || String.isBlank(pc)) continue;
                    String av = qli.Product_Attribute_Value__c;
                    String acctKey = (acctId + '|' + pc + '|' + (av != null ? av : '')).toLowerCase();
                    Decimal acctPrice = acctPrices.get(acctKey);
                    if (acctPrice != null) {
                        qli.List_Price__c = acctPrice;
                    }
                }
            }
        }

        // Sales Price defaults to List Price for genuine new-add lines at
        // creation (mirrors new-order behavior). Insert-only so it is a default,
        // not an override on later edits; never touches change-price/existing
        // lines, and stays 0 when there is no pricing tier (e.g. ROFR).
        if (oldMap == null) {
            for (QuoteLineItem qli : candidates) {
                if (qli.Change_Type__c == 'NEW'
                        && (qli.UnitPrice == null || qli.UnitPrice == 0)
                        && qli.List_Price__c != null && qli.List_Price__c != 0) {
                    qli.UnitPrice = qli.List_Price__c;
                }
            }
        }
    }

    /** System-level lookup for account-specific pricing (all products).
     *  Uses without sharing because approved request data may be owned
     *  by other users (product managers, admins).
     *  Returns prices for BOTH attributed products (key includes attribute)
     *  and non-attributed products (key has empty attribute portion).
     */
    private without sharing class AccountPriceLookup {
        public Map<String, Decimal> getAccountPrices(Set<Id> accountIds) {
            Map<Id, Id> latestReqByAcct = new Map<Id, Id>();
            for (Pricebook_Request__c req : [
                SELECT Id, Account__c FROM Pricebook_Request__c
                WHERE Account__c IN :accountIds AND Status__c = 'Approved'
                ORDER BY SystemModstamp DESC
            ]) {
                if (!latestReqByAcct.containsKey(req.Account__c)) {
                    latestReqByAcct.put(req.Account__c, req.Id);
                }
            }
            if (latestReqByAcct.isEmpty()) return new Map<String, Decimal>();

            Set<Id> reqIds = new Set<Id>(latestReqByAcct.values());
            Map<String, Decimal> priceMap = new Map<String, Decimal>();
            for (Pricebook_Request_Line__c prl : [
                SELECT Pricebook_Request__r.Account__c,
                       Product2__r.ProductCode,
                       Attribute_Value__c, Unit_Price__c
                FROM Pricebook_Request_Line__c
                WHERE Pricebook_Request__c IN :reqIds
                  AND Unit_Price__c != null
            ]) {
                String acctId = prl.Pricebook_Request__r.Account__c;
                String pc     = prl.Product2__r.ProductCode;
                if (String.isBlank(pc)) continue;
                String attr   = prl.Attribute_Value__c;
                priceMap.put((acctId + '|' + pc + '|' + (attr != null ? attr : '')).toLowerCase(), prl.Unit_Price__c);
            }
            return priceMap;
        }
    }

    // ─── After Insert ──────────────────────────────────────────────────────────

    private void afterInsert(List<QuoteLineItem> newRecords) {
        recalculateSharedNrcQty(newRecords);
        recalculateSharedNrcQtyForRamps(newRecords);
        autoAddAdditionalChargeProducts(newRecords);
        assignInventoryOnLink(newRecords, null);
        QuoteMrcRollupService.recalculate(collectQuoteIds(newRecords));
    }

    // ─── Total MRC / TCV Recalculation (FB-798) ─────────────────────────────────

    private Set<Id> collectQuoteIds(List<QuoteLineItem> lines) {
        Set<Id> quoteIds = new Set<Id>();
        for (QuoteLineItem qli : lines) {
            if (qli.QuoteId != null) quoteIds.add(qli.QuoteId);
        }
        return quoteIds;
    }

    /**
     * After any MRC insert, recalculate NRC qty for shared NRC products.
     * E.g., inserting POW011.RC (Redundant) should update POW001.NR qty to
     * sum(POW001.RC + POW011.RC) since both share Product2.Paired_NRC_Product__c -> POW001.NR.
     *
     * Discovery is broad: looks at ALL MRC products on the quote (not just the
     * newly inserted ones) to find NRC product pairings. This handles the case
     * where the new MRC (POW011.RC) is added via a flow/button that doesn't set
     * Paired_NRC_Product__c on the product itself, but a sibling MRC (POW001.RC)
     * already has the pairing defined.
     */
    private void recalculateSharedNrcQty(List<QuoteLineItem> newRecords) {
        // Collect quoteIds from ALL new non-NRC lines (including Merge_Pending,
        // because the merged-into line on the same quote needs its NRC qty updated)
        Set<Id> quoteIds = new Set<Id>();
        for (QuoteLineItem qli : newRecords) {
            if (qli.Line_Origin__c == 'Ramp') continue;
            if (qli.Charge_Type__c == 'NRC') continue;
            quoteIds.add(qli.QuoteId);
        }
        if (quoteIds.isEmpty()) return;

        // Single query: find ALL non-ramp MRC lines with NRC pairings, collect IDs + qty sums
        Set<Id> nrcProductIds = new Set<Id>();
        Map<String, Decimal> nrcQtySum = new Map<String, Decimal>();
        for (QuoteLineItem mrc : [
            SELECT Quantity, Product2.Paired_NRC_Product__c, QuoteId
            FROM QuoteLineItem
            WHERE QuoteId IN :quoteIds
              AND Product2.Paired_NRC_Product__c != null
              AND Charge_Type__c != 'NRC'
              AND Line_Origin__c != 'Ramp'
              AND (Change_Type__c = null OR Change_Type__c = 'NEW')
        ]) {
            Id nrcProdId = mrc.Product2.Paired_NRC_Product__c;
            nrcProductIds.add(nrcProdId);
            String key = mrc.QuoteId + '_' + nrcProdId;
            Decimal sum = nrcQtySum.containsKey(key) ? nrcQtySum.get(key) : 0;
            nrcQtySum.put(key, sum + (mrc.Quantity != null ? mrc.Quantity : 0));
        }
        if (nrcProductIds.isEmpty()) return;

        // Find existing non-ramp NRC QLIs on these quotes
        List<QuoteLineItem> nrcLines = [
            SELECT Id, Quantity, Product2Id, QuoteId
            FROM QuoteLineItem
            WHERE QuoteId IN :quoteIds AND Product2Id IN :nrcProductIds
              AND Line_Origin__c != 'Ramp'
        ];
        if (nrcLines.isEmpty()) return;

        List<QuoteLineItem> nrcUpdates = new List<QuoteLineItem>();
        for (QuoteLineItem nrc : nrcLines) {
            String key = nrc.QuoteId + '_' + nrc.Product2Id;
            Decimal sumQty = nrcQtySum.get(key);
            if (sumQty != null && nrc.Quantity != sumQty) {
                nrcUpdates.add(new QuoteLineItem(Id = nrc.Id, Quantity = sumQty));
            }
        }
        if (!nrcUpdates.isEmpty()) {
            update nrcUpdates;
        }
    }

    /**
     * Ramp-aware counterpart to recalculateSharedNrcQty. Ramp MRC/NRC lines pair
     * per phase (Ramp_Phase__c), so quantities must be summed and matched within
     * each phase rather than across the whole quote — otherwise phase 1's NRC
     * would inherit quantity contributed by phase 2/3 MRC lines.
     */
    private void recalculateSharedNrcQtyForRamps(List<QuoteLineItem> records) {
        Set<Id> quoteIds = new Set<Id>();
        for (QuoteLineItem qli : records) {
            if (qli.Line_Origin__c != 'Ramp') continue;
            if (qli.Charge_Type__c == 'NRC') continue;
            quoteIds.add(qli.QuoteId);
        }
        if (quoteIds.isEmpty()) return;

        Set<Id> nrcProductIds = new Set<Id>();
        Map<String, Decimal> nrcQtySum = new Map<String, Decimal>();
        for (QuoteLineItem mrc : [
            SELECT Quantity, Product2.Paired_NRC_Product__c, QuoteId, Ramp_Phase__c
            FROM QuoteLineItem
            WHERE QuoteId IN :quoteIds
              AND Product2.Paired_NRC_Product__c != null
              AND Charge_Type__c != 'NRC'
              AND Line_Origin__c = 'Ramp'
              AND (Change_Type__c = null OR Change_Type__c = 'NEW')
        ]) {
            Id nrcProdId = mrc.Product2.Paired_NRC_Product__c;
            nrcProductIds.add(nrcProdId);
            String key = mrc.QuoteId + '_' + nrcProdId + '_' + mrc.Ramp_Phase__c;
            Decimal sum = nrcQtySum.containsKey(key) ? nrcQtySum.get(key) : 0;
            nrcQtySum.put(key, sum + (mrc.Quantity != null ? mrc.Quantity : 0));
        }
        if (nrcProductIds.isEmpty()) return;

        List<QuoteLineItem> nrcLines = [
            SELECT Id, Quantity, Product2Id, QuoteId, Ramp_Phase__c
            FROM QuoteLineItem
            WHERE QuoteId IN :quoteIds AND Product2Id IN :nrcProductIds
              AND Line_Origin__c = 'Ramp'
        ];
        if (nrcLines.isEmpty()) return;

        List<QuoteLineItem> nrcUpdates = new List<QuoteLineItem>();
        for (QuoteLineItem nrc : nrcLines) {
            String key = nrc.QuoteId + '_' + nrc.Product2Id + '_' + nrc.Ramp_Phase__c;
            Decimal sumQty = nrcQtySum.get(key);
            if (sumQty != null && nrc.Quantity != sumQty) {
                nrcUpdates.add(new QuoteLineItem(Id = nrc.Id, Quantity = sumQty));
            }
        }
        if (!nrcUpdates.isEmpty()) {
            update nrcUpdates;
        }
    }

    /**
     * Re-syncs paired NRC quantities when an existing line's Quantity changes.
     * recalculateSharedNrcQty / recalculateSharedNrcQtyForRamps previously only
     * ran on insert; this closes the gap for edits made after the MRC and NRC
     * lines already exist (including manually-added NRC lines).
     */
    private void recalculateSharedNrcQtyOnUpdate(List<QuoteLineItem> newRecords, Map<Id, QuoteLineItem> oldMap) {
        List<QuoteLineItem> qtyChanged     = new List<QuoteLineItem>();
        List<QuoteLineItem> rampQtyChanged = new List<QuoteLineItem>();
        for (QuoteLineItem qli : newRecords) {
            QuoteLineItem old = oldMap.get(qli.Id);
            if (old == null || qli.Quantity == old.Quantity) continue;
            if (qli.Line_Origin__c == 'Ramp') {
                rampQtyChanged.add(qli);
            } else {
                qtyChanged.add(qli);
            }
        }
        if (!qtyChanged.isEmpty())     recalculateSharedNrcQty(qtyChanged);
        if (!rampQtyChanged.isEmpty()) recalculateSharedNrcQtyForRamps(rampQtyChanged);
    }

    /**
     * Auto-add Additional Charge child products when a parent Usage-Based product is inserted.
     * E.g., POW200.RC (Metered Power) → auto-adds POW201.RC (Extra Usage).
     * Uses Product2.Additional_Charge_Of__c to find children.
     */
    private void autoAddAdditionalChargeProducts(List<QuoteLineItem> newRecords) {
        // Find newly inserted MRC lines that have Additional Charge children
        Set<Id> productIds = new Set<Id>();
        Map<Id, QuoteLineItem> qliByProductId = new Map<Id, QuoteLineItem>();
        for (QuoteLineItem qli : newRecords) {
            if (qli.Line_Origin__c == 'Merge_Pending') continue;
            if (qli.Line_Origin__c == 'Ramp') continue;
            productIds.add(qli.Product2Id);
            qliByProductId.put(qli.Product2Id, qli);
        }
        if (productIds.isEmpty()) return;

        // Find child products whose Additional_Charge_Of__c points to these parent products
        List<Product2> children = [
            SELECT Id, ProductCode, Additional_Charge_Of__c, Charge_Type__c, Charge_Frequency__c,
                   Billing_Charge_Type__c, Odoo_Product_Id__c
            FROM Product2
            WHERE Additional_Charge_Of__c IN :productIds
              AND IsActive = true
        ];
        if (children.isEmpty()) return;

        // Get the parent QLIs with quote/pricebook context
        Set<Id> parentIds = new Set<Id>();
        for (QuoteLineItem qli : newRecords) parentIds.add(qli.Id);
        Map<Id, QuoteLineItem> parentQlis = new Map<Id, QuoteLineItem>(
            [SELECT Id, QuoteId, Quote.Pricebook2Id, Quote.CurrencyIsoCode, Product2Id, Quantity
             FROM QuoteLineItem WHERE Id IN :parentIds]
        );
        // Rebuild parent map with full data
        Map<Id, QuoteLineItem> parentByProdId = new Map<Id, QuoteLineItem>();
        for (QuoteLineItem pq : parentQlis.values()) {
            parentByProdId.put(pq.Product2Id, pq);
        }

        // Check if child QLIs already exist on these quotes (avoid duplicates)
        Set<Id> quoteIds = new Set<Id>();
        Set<Id> childProductIds = new Set<Id>();
        for (Product2 child : children) {
            childProductIds.add(child.Id);
            QuoteLineItem parent = parentByProdId.get(child.Additional_Charge_Of__c);
            if (parent != null) quoteIds.add(parent.QuoteId);
        }
        Set<String> existingKeys = new Set<String>();
        for (QuoteLineItem ex : [SELECT QuoteId, Product2Id FROM QuoteLineItem
                                  WHERE QuoteId IN :quoteIds AND Product2Id IN :childProductIds]) {
            existingKeys.add(ex.QuoteId + '_' + ex.Product2Id);
        }

        // Find PBEs for child products
        Set<String> currencies = new Set<String>();
        Set<Id> pricebookIds = new Set<Id>();
        for (QuoteLineItem pq : parentQlis.values()) {
            currencies.add(pq.Quote.CurrencyIsoCode);
            pricebookIds.add(pq.Quote.Pricebook2Id);
        }
        Map<String, PricebookEntry> pbeByKey = new Map<String, PricebookEntry>();
        for (PricebookEntry pbe : [
            SELECT Id, Product2Id, UnitPrice, Pricebook2Id, CurrencyIsoCode
            FROM PricebookEntry
            WHERE Product2Id IN :childProductIds AND Pricebook2Id IN :pricebookIds
              AND CurrencyIsoCode IN :currencies AND IsActive = true
        ]) {
            pbeByKey.put(pbe.Pricebook2Id + '_' + pbe.Product2Id + '_' + pbe.CurrencyIsoCode, pbe);
        }

        // Create child QLIs
        List<QuoteLineItem> childQlis = new List<QuoteLineItem>();
        for (Product2 child : children) {
            QuoteLineItem parent = parentByProdId.get(child.Additional_Charge_Of__c);
            if (parent == null) continue;
            String existKey = parent.QuoteId + '_' + child.Id;
            if (existingKeys.contains(existKey)) continue; // Already exists

            String pbeKey = parent.Quote.Pricebook2Id + '_' + child.Id + '_' + parent.Quote.CurrencyIsoCode;
            PricebookEntry pbe = pbeByKey.get(pbeKey);
            if (pbe == null) continue; // No PBE for this child in this pricebook

            QuoteLineItem childQli = new QuoteLineItem(
                QuoteId          = parent.QuoteId,
                PricebookEntryId = pbe.Id,
                Product2Id       = child.Id,
                Quantity         = parent.Quantity,
                UnitPrice        = pbe.UnitPrice,
                Charge_Type__c   = child.Charge_Type__c,
                Line_Origin__c   = 'New'
            );
            if (String.isNotBlank(child.Charge_Frequency__c)) {
                childQli.Charge_Frequency__c = child.Charge_Frequency__c;
            }
            if (String.isNotBlank(child.Billing_Charge_Type__c)) {
                String bct = child.Billing_Charge_Type__c.toLowerCase();
                childQli.Billing_Mode__c = bct.substring(0, 1).toUpperCase() + bct.substring(1);
            }
            if (child.Odoo_Product_Id__c != null) {
                childQli.Odoo_Product_ID__c = child.Odoo_Product_Id__c;
            }
            childQlis.add(childQli);
            existingKeys.add(existKey);
        }
        if (!childQlis.isEmpty()) {
            insert childQlis;
        }
    }

    /**
     * Delete lines marked 'Merge_Pending' by mergeWithExistingLines —
     * these are duplicates whose qty was already merged into the existing line.
     *
     * NOTE: Not currently invoked from afterInsert()/dispatch() — orphaned
     * alongside mergeWithExistingLines (see note there). Marked @TestVisible
     * solely for direct-call test coverage; no behavioral change.
     */
    @TestVisible
    private void cleanupMergedLines(List<QuoteLineItem> newRecords) {
        List<QuoteLineItem> toDelete = new List<QuoteLineItem>();
        for (QuoteLineItem qli : newRecords) {
            if (qli.Line_Origin__c == 'Merge_Pending') {
                toDelete.add(new QuoteLineItem(Id = qli.Id));
            }
        }
        if (!toDelete.isEmpty()) {
            delete toDelete;
        }
    }

    // ─── After Update ──────────────────────────────────────────────────────────

    private void afterUpdate(List<QuoteLineItem> newRecords, Map<Id, QuoteLineItem> oldMap) {
        applyKvaPricingOnAttributeChange(newRecords, oldMap);
        assignInventoryOnLink(newRecords, oldMap);
        reevaluateReservationOnQuantityChange(newRecords, oldMap);
        recalculateSharedNrcQtyOnUpdate(newRecords, oldMap);
        QuoteMrcRollupService.recalculate(collectQuoteIds(newRecords));
    }

    /**
     * When Quantity changes on a reservation-eligible QLI (Reserved__c is
     * 'Reserved' or 'Not Reserved' — NRC and no-capacity lines stay 'N/A' and
     * are skipped), re-counts actual assigned Inventory__c records and corrects
     * Reserved__c if it no longer matches. Without this, increasing Quantity
     * after a line was already fully reserved leaves Reserved__c stuck on
     * 'Reserved' even though the added units have no inventory assigned.
     */
    private void reevaluateReservationOnQuantityChange(List<QuoteLineItem> newRecords, Map<Id, QuoteLineItem> oldMap) {
        if (!Schema.sObjectType.QuoteLineItem.isUpdateable()
            || !Schema.sObjectType.QuoteLineItem.fields.Reserved__c.isUpdateable()) {
            return;
        }

        Set<Id> qliIds = new Set<Id>();
        for (QuoteLineItem qli : newRecords) {
            QuoteLineItem old = oldMap.get(qli.Id);
            if (old == null || qli.Quantity == old.Quantity) continue;
            if (qli.Reserved__c != 'Reserved' && qli.Reserved__c != 'Not Reserved') continue;
            qliIds.add(qli.Id);
        }
        if (qliIds.isEmpty()) return;

        Map<Id, Integer> assignedCounts = new Map<Id, Integer>();
        for (Id qliId : qliIds) assignedCounts.put(qliId, 0);
        for (AggregateResult ar : [
            SELECT Quote_Line__c qli, COUNT(Id) cnt
            FROM Inventory__c
            WHERE Quote_Line__c IN :qliIds
            GROUP BY Quote_Line__c
        ]) {
            assignedCounts.put((Id) ar.get('qli'), (Integer) ar.get('cnt'));
        }

        List<QuoteLineItem> updates = new List<QuoteLineItem>();
        for (QuoteLineItem qli : newRecords) {
            if (!qliIds.contains(qli.Id)) continue;
            Integer assigned = assignedCounts.get(qli.Id);
            Decimal needed = qli.Quantity != null ? qli.Quantity : 0;
            String newStatus = (needed > 0 && assigned >= needed) ? 'Reserved' : 'Not Reserved';
            if (newStatus != qli.Reserved__c) {
                updates.add(new QuoteLineItem(Id = qli.Id, Reserved__c = newStatus));
            }
        }
        if (!updates.isEmpty()) {
            update updates;
        }
    }

    /**
     * When Product_Attribute_Value__c changes to match an existing line
     * (same Quote + Product + Attribute), merge by incrementing the target
     * line's qty and deleting the source.
     *
     * NOTE: Not currently invoked from afterUpdate()/dispatch() — orphaned,
     * same family as mergeWithExistingLines/cleanupMergedLines (see notes
     * above). Marked @TestVisible solely for direct-call test coverage; no
     * behavioral change.
     */
    @TestVisible
    private void mergeOnAttributeChange(List<QuoteLineItem> newRecords, Map<Id, QuoteLineItem> oldMap) {
        // Collect lines whose attribute changed
        List<QuoteLineItem> changed = new List<QuoteLineItem>();
        Set<Id> quoteIds = new Set<Id>();
        Set<Id> productIds = new Set<Id>();
        for (QuoteLineItem qli : newRecords) {
            QuoteLineItem old = oldMap.get(qli.Id);
            if (old != null && qli.Product_Attribute_Value__c != old.Product_Attribute_Value__c
                    && qli.Line_Origin__c != 'Ramp') {
                changed.add(qli);
                quoteIds.add(qli.QuoteId);
                productIds.add(qli.Product2Id);
            }
        }
        if (changed.isEmpty()) return;

        // Find all non-ramp lines for these quotes+products, EXCLUDING the changed lines
        Set<Id> changedIds = new Set<Id>();
        for (QuoteLineItem c : changed) changedIds.add(c.Id);

        Map<String, QuoteLineItem> existingByKey = new Map<String, QuoteLineItem>();
        for (QuoteLineItem ex : [
            SELECT Id, QuoteId, Product2Id, Product_Attribute_Value__c, Quantity
            FROM QuoteLineItem
            WHERE QuoteId IN :quoteIds AND Product2Id IN :productIds
              AND Line_Origin__c != 'Ramp'
              AND Id NOT IN :changedIds
        ]) {
            String attr = ex.Product_Attribute_Value__c != null ? ex.Product_Attribute_Value__c : '';
            existingByKey.put(ex.QuoteId + '_' + ex.Product2Id + '_' + attr, ex);
        }

        List<QuoteLineItem> toUpdate = new List<QuoteLineItem>();
        List<QuoteLineItem> toDelete = new List<QuoteLineItem>();
        for (QuoteLineItem qli : changed) {
            String attr = qli.Product_Attribute_Value__c != null ? qli.Product_Attribute_Value__c : '';
            String key = qli.QuoteId + '_' + qli.Product2Id + '_' + attr;
            QuoteLineItem target = existingByKey.get(key);
            if (target != null) {
                target.Quantity = (target.Quantity != null ? target.Quantity : 0)
                    + (qli.Quantity != null ? qli.Quantity : 1);
                toUpdate.add(target);
                toDelete.add(new QuoteLineItem(Id = qli.Id));
            }
        }
        if (!toUpdate.isEmpty()) update toUpdate;
        if (!toDelete.isEmpty()) delete toDelete;
    }

    /**
     * DEPRECATED — pricing now handled synchronously in beforeUpdate via
     * resolveOdooAttributeValueIds reading Product_Pricing_Tier__mdt.
     * The old kVA after-save async flow is deactivated. Keeping shell
     * to avoid breaking the afterUpdate dispatch chain.
     */
    private void applyKvaPricingOnAttributeChange(List<QuoteLineItem> newRecords, Map<Id, QuoteLineItem> oldMap) {
        // No-op: consolidated pricing runs in beforeUpdate
    }

    // ─── After Delete ──────────────────────────────────────────────────────────

    private void afterDelete(List<QuoteLineItem> oldRecords) {
        releaseInventoryOnDelete(oldRecords);
        QuoteMrcRollupService.recalculate(collectQuoteIds(oldRecords));
    }

    // ─── Inventory Status: Available → Assigned on link ──────────────────────

    /**
     * When Space__c or Inventory__c (Breaker) is populated on a QLI, sets the
     * linked Inventory record's Status to 'Assigned' and stamps Quote_Line__c.
     * When cleared or changed to a different record, reverts the old Inventory
     * to 'Available' (only if still at Assigned or Quoted status).
     */
    private void assignInventoryOnLink(List<QuoteLineItem> lines, Map<Id, QuoteLineItem> oldMap) {
        Set<Id> toAssign  = new Set<Id>();
        Set<Id> toRelease = new Set<Id>();
        Map<Id, Id> invToQli = new Map<Id, Id>();

        for (QuoteLineItem qli : lines) {
            QuoteLineItem old = oldMap != null ? oldMap.get(qli.Id) : null;

            Id newSpace = qli.Space__c;
            Id oldSpace = old != null ? old.Space__c : null;
            if (newSpace != oldSpace) {
                if (newSpace != null) { toAssign.add(newSpace); invToQli.put(newSpace, qli.Id); }
                if (oldSpace != null) { toRelease.add(oldSpace); }
            }

            Id newBreaker = qli.Inventory__c;
            Id oldBreaker = old != null ? old.Inventory__c : null;
            if (newBreaker != oldBreaker) {
                if (newBreaker != null) { toAssign.add(newBreaker); invToQli.put(newBreaker, qli.Id); }
                if (oldBreaker != null) { toRelease.add(oldBreaker); }
            }
        }

        // Don't release something that's also being assigned (reassignment to same record)
        toRelease.removeAll(toAssign);

        if (toAssign.isEmpty() && toRelease.isEmpty()) return;

        List<Inventory__c> updates = new List<Inventory__c>();

        if (!toAssign.isEmpty()) {
            for (Inventory__c inv : [
                SELECT Id, Status__c FROM Inventory__c WHERE Id IN :toAssign
            ]) {
                if (inv.Status__c == 'Available' || inv.Status__c == 'Quoted') {
                    updates.add(new Inventory__c(
                        Id            = inv.Id,
                        Status__c     = 'Assigned',
                        Quote_Line__c = invToQli.get(inv.Id)
                    ));
                }
            }
        }

        if (!toRelease.isEmpty()) {
            for (Inventory__c inv : [
                SELECT Id, Status__c FROM Inventory__c WHERE Id IN :toRelease
            ]) {
                if (inv.Status__c == 'Assigned' || inv.Status__c == 'Quoted') {
                    updates.add(new Inventory__c(
                        Id            = inv.Id,
                        Status__c     = 'Available',
                        Quote_Line__c = null
                    ));
                }
            }
        }

        if (!updates.isEmpty()) update updates;
    }

    /**
     * When a QLI with linked inventory is deleted, reverts Status to 'Available'
     * if the Inventory is still at Assigned or Quoted.
     */
    private void releaseInventoryOnDelete(List<QuoteLineItem> oldRecords) {
        Set<Id> toRelease = new Set<Id>();
        for (QuoteLineItem qli : oldRecords) {
            if (qli.Space__c != null)     toRelease.add(qli.Space__c);
            if (qli.Inventory__c != null) toRelease.add(qli.Inventory__c);
        }
        if (toRelease.isEmpty()) return;

        List<Inventory__c> updates = new List<Inventory__c>();
        for (Inventory__c inv : [
            SELECT Id, Status__c FROM Inventory__c WHERE Id IN :toRelease
        ]) {
            if (inv.Status__c == 'Assigned' || inv.Status__c == 'Quoted') {
                updates.add(new Inventory__c(
                    Id            = inv.Id,
                    Status__c     = 'Available',
                    Quote_Line__c = null
                ));
            }
        }
        if (!updates.isEmpty()) update updates;
    }

    // ─── Before Delete (VR-QLI-01) ─────────────────────────────────────────────

    /**
     * VR-QLI-01 — Before Delete
     *
     * 1. Prevents deletion of auto-generated NRC lines that are still paired to
     *    an active MRC line. The MRC line must be removed first.
     * 2. Cascades: when an MRC line is deleted, auto-deletes its paired NRC lines
     *    via NrcPairingService.cascadeDeletePairedNrc to prevent orphan NRCs.
     *
     * @param oldRecords  The list of QuoteLineItem records being deleted (Trigger.old)
     */
    private void beforeDelete(List<QuoteLineItem> oldRecords) {
        Set<Id> mrcIdsBeingDeleted = new Set<Id>();

        for (QuoteLineItem qli : oldRecords) {
            if (qli.Is_Auto_NRC__c == true && qli.Paired_MRC_Line__c != null) {
                qli.addError(
                    'Auto-generated NRC lines cannot be deleted while the paired MRC line is active. ' +
                    'Remove the MRC line first.'
                );
            } else if (qli.Is_Auto_NRC__c != true) {
                mrcIdsBeingDeleted.add(qli.Id);
            }
        }

        // Cascade delete paired NRC lines when their MRC parent is removed
        if (!mrcIdsBeingDeleted.isEmpty()) {
            NrcPairingService.cascadeDeletePairedNrc(mrcIdsBeingDeleted);
        }
    }
}