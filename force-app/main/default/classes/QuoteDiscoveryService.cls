/**
 * QuoteDiscoveryService
 *
 * Invocable service for bulk-adding products to a Quote from the
 * Discover_Products screen flow (transactionLineTable side panel).
 * Accepts semicolon-delimited Product2 Ids, queries PricebookEntries
 * in a single SOQL call, and inserts all QLIs in a single DML statement.
 */
public with sharing class QuoteDiscoveryService {

    // DML helper — runs without sharing so the QLI insert (and the implicit
    // Quote total recalculation it triggers) bypasses Revenue Cloud edit restrictions.
    // Same pattern as QuoteLineEditorController.DmlHelper.
    private without sharing class DmlHelper {
        void doInsert(List<SObject> records) { insert records; }
        void doUpdate(List<SObject> records) { update records; }
    }

    public class HandledException extends Exception {}

    public class AddProductsRequest {
        @InvocableVariable(label='Quote Id' required=true)
        public String quoteId;

        @InvocableVariable(label='Pricebook Id' required=true)
        public String pricebookId;

        @InvocableVariable(label='Selected Product IDs (semicolon-delimited)' required=true)
        public String selectedProductIds;

        @InvocableVariable(label='Quantity')
        public Decimal quantity;

        @InvocableVariable(label='Attribute Map JSON')
        public String attributeMapJson;
    }

    public class AddProductsResult {
        @InvocableVariable(label='Created QLI Count')
        public Integer createdCount;

        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    @InvocableMethod(
        label='Add Products to Quote'
        description='Bulk-adds selected products as QuoteLineItems from the product discovery panel'
        category='Revenue Cloud'
    )
    public static List<AddProductsResult> addProductsToQuote(
        List<AddProductsRequest> requests
    ) {
        // Defer the MRC/TCV rollup for the whole invocation.
        //
        // QuoteLineItem behaves master-detail-like: every QLI DML forces a parent
        // Quote re-save, which re-runs all 14 active Quote record-triggered flows,
        // which updates the Opportunity (7 more before-save flows) and rolls up to
        // the Account — roughly 6 SOQL per Quote save cycle. On top of that the QLI
        // trigger calls QuoteMrcRollupService.recalculate() after every one of those
        // DMLs, and each recalculate() issues its own `update Quote`, triggering the
        // cascade all over again. Adding 4 products blew the 100-SOQL limit
        // (log 07L8500000EXaxYEAT: 101 queries, 8 Quote saves) and surfaced to the
        // user as "Quote - After Save - Stage Advance process failed" — that flow's
        // Get_Opportunity lookup just happened to be query #101.
        //
        // beginDefer() makes recalculate() accumulate Quote Ids instead of running,
        // so the rollup + its cascade fire exactly ONCE at the end. The rollup
        // recomputes both totals from scratch off a fresh query, so a single
        // end-of-run flush yields the same numbers as running it per DML.
        // Same pattern as QuoteLineEditorController.splitRampLines[Bulk].
        QuoteMrcRollupService.beginDefer();
        List<AddProductsResult> results = new List<AddProductsResult>();
        try {
            for (AddProductsRequest req : requests) {
                results.add(processRequest(req));
            }
            // All QLI DML done — run the deferred rollup once.
            QuoteMrcRollupService.endDeferAndFlush();
        } finally {
            // Never let the deferral flag leak past this method (error path rolls
            // back, so there is nothing to flush). No-op after a clean flush.
            QuoteMrcRollupService.clearDefer();
        }
        return results;
    }

    private static AddProductsResult processRequest(AddProductsRequest req) {
        AddProductsResult result = new AddProductsResult();

        if (String.isBlank(req.selectedProductIds)) {
            result.createdCount = 0;
            return result;
        }

        // Single query: Quote currency, pricebook, and account's customer pricebook
        Quote q = [SELECT CurrencyIsoCode, Pricebook2Id, Opportunity.Account.Customer_Pricebook__c
                   FROM Quote WHERE Id = :req.quoteId WITH SECURITY_ENFORCED LIMIT 1];
        String quoteCurrency = q.CurrencyIsoCode;
        Id acctPbId = q.Opportunity?.Account?.Customer_Pricebook__c;

        // If the Quote has no pricebook yet, assign the one from the product selector
        if (q.Pricebook2Id == null && String.isNotBlank(req.pricebookId)) {
            q.Pricebook2Id = req.pricebookId;
            new DmlHelper().doUpdate(new List<Quote>{ q });
        }

        // Cache standard pricebook ID (used for PBE auto-creation)
        Id stdPbId = Test.isRunningTest()
            ? Test.getStandardPricebookId()
            : [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;

        Decimal qty = (req.quantity != null && req.quantity > 0) ? req.quantity : 1;

        // Parse composite IDs: "productId::attributeValue" or plain "productId"
        List<String> rawEntries = req.selectedProductIds.split(';');
        Set<Id> uniqueProductIds = new Set<Id>();
        List<Map<String, String>> parsedEntries = new List<Map<String, String>>();
        for (String entry : rawEntries) {
            if (String.isBlank(entry)) continue;
            String prodId;
            String attrVal;
            if (entry.contains('::')) {
                Integer sep = entry.indexOf('::');
                prodId  = entry.substring(0, sep);
                attrVal = entry.substring(sep + 2);
            } else {
                prodId  = entry;
                attrVal = null;
            }
            uniqueProductIds.add(prodId);
            parsedEntries.add(new Map<String, String>{ 'productId' => prodId, 'attribute' => attrVal });
        }

        Map<Id, PricebookEntry> pbeByProduct = new Map<Id, PricebookEntry>();
        for (PricebookEntry pbe : [
            SELECT Id, Product2Id, UnitPrice
            FROM PricebookEntry
            WHERE Pricebook2Id = :req.pricebookId
            AND Product2Id IN :uniqueProductIds
            AND IsActive = true
            AND CurrencyIsoCode = :quoteCurrency
        ]) {
            pbeByProduct.put(pbe.Product2Id, pbe);
        }

        // Unified PBE resolution: site pricebook → account pricebook → any-currency fallback
        Map<Id, Decimal> acctPriceByProduct = new Map<Id, Decimal>();
        Set<Id> missingProducts = new Set<Id>();
        for (Id pid : uniqueProductIds) {
            if (!pbeByProduct.containsKey(pid)) missingProducts.add(pid);
        }

        if (!missingProducts.isEmpty()) {
            // Step 1: Check account pricebook (same currency)
            if (acctPbId != null) {
                for (PricebookEntry apbe : [
                    SELECT Product2Id, UnitPrice FROM PricebookEntry
                    WHERE Pricebook2Id = :acctPbId AND Product2Id IN :missingProducts
                      AND IsActive = true AND CurrencyIsoCode = :quoteCurrency
                ]) {
                    acctPriceByProduct.put(apbe.Product2Id, apbe.UnitPrice);
                }
            }

            // Step 2: For still-missing products, check any PBE in any currency
            Set<Id> resolvedFromAcct = acctPriceByProduct.keySet();
            Set<Id> needsFallback = new Set<Id>();
            for (Id pid : missingProducts) {
                if (!resolvedFromAcct.contains(pid)) needsFallback.add(pid);
            }
            if (!needsFallback.isEmpty()) {
                for (PricebookEntry apbe : [
                    SELECT Product2Id FROM PricebookEntry
                    WHERE Product2Id IN :needsFallback AND IsActive = true LIMIT 200
                ]) {
                    if (!resolvedFromAcct.contains(apbe.Product2Id)) {
                        acctPriceByProduct.put(apbe.Product2Id, (Decimal) 0);
                    }
                }
            }

            // Step 3: Batch-create all missing PBEs (standard + site) in one pass
            if (!acctPriceByProduct.isEmpty()) {
                Set<Id> allToCreate = acctPriceByProduct.keySet();
                // Check which already have standard PBE in quote currency
                Set<Id> hasStdPbe = new Set<Id>();
                for (PricebookEntry s : [SELECT Product2Id FROM PricebookEntry
                     WHERE Pricebook2Id = :stdPbId AND Product2Id IN :allToCreate
                       AND CurrencyIsoCode = :quoteCurrency AND IsActive = true]) {
                    hasStdPbe.add(s.Product2Id);
                }
                // Create missing standard PBEs
                List<PricebookEntry> newStdPbes = new List<PricebookEntry>();
                for (Id pid : allToCreate) {
                    if (!hasStdPbe.contains(pid)) {
                        newStdPbes.add(new PricebookEntry(
                            Pricebook2Id = stdPbId, Product2Id = pid,
                            UnitPrice = 0, CurrencyIsoCode = quoteCurrency, IsActive = true));
                    }
                }
                if (!newStdPbes.isEmpty()) new DmlHelper().doInsert(newStdPbes);

                // Create site PBEs for products that came from Standard PB merge
                // (global + country-specific). The selector already filters by country
                // availability, so only valid products reach this point.
                if (req.pricebookId != stdPbId) {
                    List<PricebookEntry> newSitePbes = new List<PricebookEntry>();
                    for (Id pid : allToCreate) {
                        Decimal price = acctPriceByProduct.get(pid) != null ? acctPriceByProduct.get(pid) : 0;
                        newSitePbes.add(new PricebookEntry(
                            Pricebook2Id = req.pricebookId, Product2Id = pid,
                            UnitPrice = price, CurrencyIsoCode = quoteCurrency, IsActive = true));
                    }
                    if (!newSitePbes.isEmpty()) new DmlHelper().doInsert(newSitePbes);
                    // Re-query to pick up the newly created PBEs
                    for (PricebookEntry pbe : [
                        SELECT Id, Product2Id, UnitPrice FROM PricebookEntry
                        WHERE Pricebook2Id = :req.pricebookId AND Product2Id IN :allToCreate
                          AND CurrencyIsoCode = :quoteCurrency AND IsActive = true
                    ]) {
                        pbeByProduct.put(pbe.Product2Id, pbe);
                    }
                }
            }
        }

        // Build account price overlay for ALL products (not just missing ones)
        // so products at $0 in the site pricebook get the account price as default
        if (acctPbId != null) {
            for (PricebookEntry apbe : [
                SELECT Product2Id, UnitPrice FROM PricebookEntry
                WHERE Pricebook2Id = :acctPbId AND Product2Id IN :uniqueProductIds
                  AND IsActive = true AND CurrencyIsoCode = :quoteCurrency AND UnitPrice > 0
            ]) {
                if (!acctPriceByProduct.containsKey(apbe.Product2Id)) {
                    acctPriceByProduct.put(apbe.Product2Id, apbe.UnitPrice);
                }
            }
        }

        List<QuoteLineItem> qlis = new List<QuoteLineItem>();
        for (Map<String, String> pe : parsedEntries) {
            Id productId = pe.get('productId');
            String attrVal = pe.get('attribute');
            if (pbeByProduct.containsKey(productId)) {
                PricebookEntry pbe = pbeByProduct.get(productId);
                // Use account price when PBE is $0 and account has a real price
                Decimal effectivePrice = pbe.UnitPrice;
                if (effectivePrice == 0 && acctPriceByProduct.containsKey(productId)) {
                    effectivePrice = acctPriceByProduct.get(productId);
                }
                QuoteLineItem qli = new QuoteLineItem(
                    QuoteId = req.quoteId,
                    Product2Id = productId,
                    PricebookEntryId = pbe.Id,
                    Quantity = qty,
                    UnitPrice = effectivePrice,
                    List_Price__c = effectivePrice
                );
                if (String.isNotBlank(attrVal)) {
                    qli.Product_Attribute_Value__c = attrVal;
                }
                qlis.add(qli);
            }
        }

        if (!qlis.isEmpty()) {
            try {
                new DmlHelper().doInsert(qlis);
            } catch (DmlException e) {
                throw new HandledException(e.getDmlMessage(0));
            }
            // Synchronously pair NRC charges so they appear immediately (no async delay)
            Set<Id> insertedIds = new Map<Id, QuoteLineItem>(qlis).keySet();
            NrcPairingService.pairNrcToMrc(insertedIds);

            // Recalculate NRC qty AFTER pairing
            Set<Id> nrcProductIds = new Set<Id>();
            for (QuoteLineItem qli : [
                SELECT Product2.Paired_NRC_Product__c FROM QuoteLineItem
                WHERE Id IN :insertedIds AND Product2.Paired_NRC_Product__c != null
            ]) {
                nrcProductIds.add(qli.Product2.Paired_NRC_Product__c);
            }
            if (!nrcProductIds.isEmpty()) {
                Map<String, Decimal> qtySum = new Map<String, Decimal>();
                for (QuoteLineItem mrc : [
                    SELECT Quantity, Product2.Paired_NRC_Product__c, QuoteId
                    FROM QuoteLineItem WHERE QuoteId = :req.quoteId
                      AND Product2.Paired_NRC_Product__c IN :nrcProductIds
                      AND Charge_Type__c != 'NRC' AND Line_Origin__c != 'Ramp'
                      AND (Change_Type__c = null OR Change_Type__c = 'NEW')
                ]) {
                    String key = mrc.QuoteId + '_' + mrc.Product2.Paired_NRC_Product__c;
                    Decimal s = qtySum.containsKey(key) ? qtySum.get(key) : 0;
                    qtySum.put(key, s + (mrc.Quantity != null ? mrc.Quantity : 0));
                }
                List<QuoteLineItem> nrcUpdates = new List<QuoteLineItem>();
                for (QuoteLineItem nrc : [
                    SELECT Id, Quantity, Product2Id, QuoteId FROM QuoteLineItem
                    WHERE QuoteId = :req.quoteId AND Product2Id IN :nrcProductIds
                      AND Charge_Type__c = 'NRC' AND Line_Origin__c != 'Ramp'
                ]) {
                    Decimal expected = qtySum.get(nrc.QuoteId + '_' + nrc.Product2Id);
                    if (expected != null && nrc.Quantity != expected) {
                        nrcUpdates.add(new QuoteLineItem(Id = nrc.Id, Quantity = expected));
                    }
                }
                if (!nrcUpdates.isEmpty()) new DmlHelper().doUpdate(nrcUpdates);
            }
        }
        // Sync Sales Price = List Price where kVA pricing set List Price but Sales Price stayed $0
        if (!qlis.isEmpty()) {
            Set<Id> qliIds = new Map<Id, QuoteLineItem>(qlis).keySet();
            List<QuoteLineItem> priceFix = new List<QuoteLineItem>();
            for (QuoteLineItem ql : [
                SELECT Id, UnitPrice, List_Price__c FROM QuoteLineItem
                WHERE Id IN :qliIds AND List_Price__c > 0 AND UnitPrice = 0
            ]) {
                priceFix.add(new QuoteLineItem(Id = ql.Id, UnitPrice = ql.List_Price__c));
            }
            if (!priceFix.isEmpty()) new DmlHelper().doUpdate(priceFix);
        }

        result.createdCount = qlis.size();
        return result;
    }
}