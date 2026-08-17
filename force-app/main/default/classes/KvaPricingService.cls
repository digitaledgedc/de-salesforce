/**
 * KvaPricingService
 *
 * Applies kVA Draw Capacity attribute-based pricing to QuoteLineItem records
 * for Cabinet products.
 *
 * Called from the QuoteLineItem_AfterSave_ApplyKvaPricing flow when Cabinet
 * product QLIs are created. Reads the selected kVA tier from
 * QuoteLineItemAttribute, looks up the monthly price from kVA_Draw_Pricing__mdt,
 * and updates QuoteLineItem.UnitPrice.
 *
 * Lookup key resolution:
 *   1. Product-specific key: "CAB001.RC_2KVA" — takes precedence
 *   2. Generic fallback key: "2KVA" — used when no product-specific record exists
 *
 * kVA_Draw_Pricing__mdt records are populated with pricing from the DE APAC
 * rate card. Records with 0.00 price = not yet configured — pricebook price is
 * preserved in that case.
 *
 * Bypass: TriggerBypass__mdt record with DeveloperName = 'KvaPricingService'
 * and Is_Active__c = true will suppress all pricing updates.
 */
public with sharing class KvaPricingService {

    /** Currency code → CMT field token map. Add a single line here to support a new currency. */
    private static final Map<String, Schema.SObjectField> CURRENCY_FIELDS = new Map<String, Schema.SObjectField>{
        'USD' => kVA_Draw_Pricing__mdt.Monthly_Price_USD__c,
        'SGD' => kVA_Draw_Pricing__mdt.Monthly_Price_SGD__c,
        'HKD' => kVA_Draw_Pricing__mdt.Monthly_Price_HKD__c,
        'JPY' => kVA_Draw_Pricing__mdt.Monthly_Price_JPY__c,
        'IDR' => kVA_Draw_Pricing__mdt.Monthly_Price_IDR__c,
        'KRW' => kVA_Draw_Pricing__mdt.Monthly_Price_KRW__c,
        'CNY' => kVA_Draw_Pricing__mdt.Monthly_Price_CNY__c,
        'PHP' => kVA_Draw_Pricing__mdt.Monthly_Price_PHP__c
    };

    /**
     * Invocable entry point — called from the QuoteLineItem after-save flow.
     * Accepts a list of QLI IDs and applies kVA pricing to each where applicable.
     *
     * @param qliIds  List of QuoteLineItem record IDs to process
     */
    @InvocableMethod(
        label='Apply kVA Draw Pricing'
        description='Reads the Draw Capacity attribute on Cabinet product QLIs and sets UnitPrice from kVA_Draw_Pricing__mdt.'
        category='Quote'
    )
    public static void applyKvaPricing(List<Id> qliIds) {
        TriggerBypass__mdt bypass = TriggerBypass__mdt.getInstance('KvaPricingService');
        if (bypass != null && bypass.Is_Active__c) {
            return;
        }
        applyPricingToQLIs(new Set<Id>(qliIds));
    }

    /**
     * Core pricing logic. Fetches required data and delegates computation.
     *
     * @param qliIdSet  Set of QuoteLineItem IDs to evaluate
     */
    public static void applyPricingToQLIs(Set<Id> qliIdSet) {
        if (qliIdSet == null || qliIdSet.isEmpty()) {
            return;
        }

        // Load all kVA pricing CMT records — no SOQL consumed
        Map<String, kVA_Draw_Pricing__mdt> pricingByKey = buildPricingMap();
        if (pricingByKey.isEmpty()) {
            return;
        }

        // Get QLI with product code, ListPrice and Quote currency
        Map<Id, QuoteLineItem> qliById = new Map<Id, QuoteLineItem>(
            (List<QuoteLineItem>) Security.stripInaccessible(
                AccessType.READABLE,
                [SELECT Id, ListPrice, UnitPrice, Product2.ProductCode, Quote.CurrencyIsoCode
                 FROM QuoteLineItem
                 WHERE Id IN :qliIdSet]
            ).getRecords()
        );

        // Get QLIAs that have a picklist value selected (kVA attribute has a value)
        List<QuoteLineItemAttribute> qlias = [
            SELECT Id, QuoteLineItemId, AttributePicklistValueId
            FROM QuoteLineItemAttribute
            WHERE QuoteLineItemId IN :qliIdSet
            AND AttributePicklistValueId != null
        ];

        // Try Revenue Cloud QuoteLineItemAttribute first
        Map<Id, Decimal> priceUpdates = new Map<Id, Decimal>();

        if (!qlias.isEmpty()) {
            // Resolve APV codes from IDs
            Set<Id> apvIds = new Set<Id>();
            for (QuoteLineItemAttribute qlia : qlias) {
                apvIds.add(qlia.AttributePicklistValueId);
            }
            Map<Id, String> apvCodeById = new Map<Id, String>();
            List<AttributePicklistValue> apvList = (List<AttributePicklistValue>) Security.stripInaccessible(
                AccessType.READABLE,
                [SELECT Id, Code FROM AttributePicklistValue WHERE Id IN :apvIds]
            ).getRecords();
            for (AttributePicklistValue apv : apvList) {
                apvCodeById.put(apv.Id, apv.Code);
            }
            priceUpdates = buildPriceUpdates(qliById, apvCodeById, qlias, pricingByKey);
        }

        // Fallback: use Product_Attribute_Value__c (custom field) when no Revenue Cloud attributes
        if (priceUpdates.isEmpty()) {
            // Re-query to get Product_Attribute_Value__c
            Map<Id, QuoteLineItem> qlisWithAttr = new Map<Id, QuoteLineItem>(
                [SELECT Id, Product2.ProductCode, Quote.CurrencyIsoCode, Product_Attribute_Value__c
                 FROM QuoteLineItem WHERE Id IN :qliIdSet AND Product_Attribute_Value__c != null]
            );
            for (QuoteLineItem qli : qlisWithAttr.values()) {
                String attrVal = qli.Product_Attribute_Value__c; // e.g. "6kVA", "4kVA"
                String kvaCode = attrVal.toUpperCase().replaceAll('[^0-9.]', '') + 'KVA'; // "6KVA"
                // Handle decimals: "2.2kVA" -> try "2.2KVA" then "2KVA"
                String productCode = qli.Product2 != null ? qli.Product2.ProductCode : null;
                String quoteCurrency = qli.Quote.CurrencyIsoCode;

                kVA_Draw_Pricing__mdt pricingRecord = null;
                // Try product-specific first
                if (String.isNotBlank(productCode)) {
                    pricingRecord = pricingByKey.get(productCode + '_' + kvaCode);
                }
                // Try generic fallback
                if (pricingRecord == null) {
                    pricingRecord = pricingByKey.get(kvaCode);
                }
                if (pricingRecord == null) continue;

                Decimal adjustedPrice = resolvePriceForCurrency(pricingRecord, quoteCurrency);
                if (adjustedPrice != null && adjustedPrice > 0) {
                    priceUpdates.put(qli.Id, adjustedPrice);
                }
            }
        }

        if (priceUpdates.isEmpty()) {
            return;
        }

        // For each QLI, find or create a PBE at the kVA price so ListPrice reflects
        // the attribute-specific rate. UnitPrice (Sales Price) stays untouched.
        // Re-query QLIs for their current PBE context
        Map<Id, QuoteLineItem> fullQlis = new Map<Id, QuoteLineItem>(
            [SELECT Id, PricebookEntryId, UnitPrice, Product2Id,
                    PricebookEntry.Pricebook2Id, PricebookEntry.CurrencyIsoCode
             FROM QuoteLineItem WHERE Id IN :priceUpdates.keySet()]
        );

        // Pre-query all candidate PBEs in one SOQL (replaces SOQL-in-loop)
        Set<Id> pbIds = new Set<Id>();
        Set<Id> prodIds = new Set<Id>();
        Set<String> currencies = new Set<String>();
        for (QuoteLineItem qli : fullQlis.values()) {
            pbIds.add(qli.PricebookEntry.Pricebook2Id);
            prodIds.add(qli.Product2Id);
            currencies.add(qli.PricebookEntry.CurrencyIsoCode);
        }
        // Key: pbId_prodId_curr_price → PBE Id
        Map<String, Id> pbeByPriceKey = new Map<String, Id>();
        for (PricebookEntry pbe : [
            SELECT Id, Pricebook2Id, Product2Id, CurrencyIsoCode, UnitPrice
            FROM PricebookEntry
            WHERE Pricebook2Id IN :pbIds AND Product2Id IN :prodIds
              AND CurrencyIsoCode IN :currencies AND IsActive = true
        ]) {
            String key = pbe.Pricebook2Id + '_' + pbe.Product2Id + '_' + pbe.CurrencyIsoCode + '_' + pbe.UnitPrice;
            pbeByPriceKey.put(key, pbe.Id);
        }

        List<QuoteLineItem> qliToUpdate = new List<QuoteLineItem>();

        for (Id qliId : priceUpdates.keySet()) {
            Decimal kvaPrice = priceUpdates.get(qliId);
            QuoteLineItem qli = fullQlis.get(qliId);
            if (qli == null) continue;

            Id pbId = qli.PricebookEntry.Pricebook2Id;
            String curr = qli.PricebookEntry.CurrencyIsoCode;
            Id prodId = qli.Product2Id;

            // Look for an existing PBE at this price (map lookup, no SOQL)
            String lookupKey = pbId + '_' + prodId + '_' + curr + '_' + kvaPrice;
            Id matchPbeId = pbeByPriceKey.get(lookupKey);

            // Set both List Price and Sales Price to the kVA rate
            qliToUpdate.add(new QuoteLineItem(Id = qliId, List_Price__c = kvaPrice, UnitPrice = kvaPrice));
        }

        if (!qliToUpdate.isEmpty()) {
            update qliToUpdate;
        }
    }

    /**
     * Pure computation: maps each QLI ID to the price it should be set to,
     * based on the kVA attribute value and the CMT pricing table.
     * Returns only QLIs where a positive price was found.
     *
     * Extracted for testability — no DML or SOQL.
     */
    @TestVisible
    private static Map<Id, Decimal> buildPriceUpdates(
        Map<Id, QuoteLineItem> qliById,
        Map<Id, String> apvCodeById,
        List<QuoteLineItemAttribute> qlias,
        Map<String, kVA_Draw_Pricing__mdt> pricingByKey
    ) {
        Map<Id, Decimal> result = new Map<Id, Decimal>();

        for (QuoteLineItemAttribute qlia : qlias) {
            Id qliId = qlia.QuoteLineItemId;
            Id apvId = qlia.AttributePicklistValueId;

            String apvCode = apvCodeById.get(apvId);
            if (String.isBlank(apvCode)) continue;

            QuoteLineItem qli = qliById.get(qliId);
            if (qli == null) continue;

            String productCode = qli.Product2 != null ? qli.Product2.ProductCode : null;
            String quoteCurrency = qli.Quote.CurrencyIsoCode;

            // Try product-specific key first, then generic fallback
            kVA_Draw_Pricing__mdt pricingRecord = null;
            if (String.isNotBlank(productCode)) {
                pricingRecord = pricingByKey.get(productCode + '_' + apvCode);
            }
            if (pricingRecord == null) {
                pricingRecord = pricingByKey.get(apvCode);
            }
            if (pricingRecord == null) continue;

            Decimal adjustedPrice = resolvePriceForCurrency(pricingRecord, quoteCurrency);
            if (adjustedPrice != null && adjustedPrice > 0) {
                result.put(qliId, adjustedPrice);
            }
        }

        return result;
    }

    /**
     * Returns the correct currency price from a CMT record, or null if the
     * currency is unsupported or the price is not configured (null or <= 0).
     */
    @TestVisible
    private static Decimal resolvePriceForCurrency(kVA_Draw_Pricing__mdt rec, String currencyCode) {
        Schema.SObjectField field = CURRENCY_FIELDS.get(currencyCode);
        if (field == null) {
            return null;
        }
        Decimal price = (Decimal) rec.get(field);
        return (price != null && price > 0) ? price : null;
    }

    /**
     * Builds a map of lookup key → pricing CMT record.
     *
     * Keys:
     *   - Product-specific: "CAB001.RC_2KVA" (when Product_Code__c is set)
     *   - Generic fallback: "2KVA" (when Product_Code__c is blank)
     *
     * DeveloperName pattern: KVA_02 (generic) or CAB001_KVA_02 (product-specific).
     * kVA integer is extracted from the tail after the last underscore + optional leading zero.
     *
     * No SOQL consumed — uses platform cache via getAll().
     */
    @TestVisible
    private static Map<String, kVA_Draw_Pricing__mdt> buildPricingMap() {
        Map<String, kVA_Draw_Pricing__mdt> result = new Map<String, kVA_Draw_Pricing__mdt>();
        for (kVA_Draw_Pricing__mdt rec : kVA_Draw_Pricing__mdt.getAll().values()) {
            String productCode = rec.Product_Code__c;
            String kvaCode = buildKvaCode(rec.DeveloperName);
            if (String.isBlank(kvaCode)) continue;

            if (String.isNotBlank(productCode)) {
                // Product-specific key: "CAB001.RC_2KVA"
                result.put(productCode + '_' + kvaCode, rec);
            } else {
                // Generic fallback key: "2KVA"
                result.put(kvaCode, rec);
            }
        }
        return result;
    }

    /**
     * Converts a CMT DeveloperName to a kVA code string.
     * KVA_02 → "2KVA", CAB001_KVA_04 → "4KVA", CAB003_KVA_01 → "1KVA".
     * Returns null if the DeveloperName doesn't match the expected pattern.
     */
    @TestVisible
    private static String buildKvaCode(String developerName) {
        if (String.isBlank(developerName)) return null;
        // Find the KVA_ segment — last occurrence covers both "KVA_02" and "CAB001_KVA_02"
        Integer kvaIdx = developerName.lastIndexOf('KVA_');
        if (kvaIdx < 0) return null;
        String numPart = developerName.substring(kvaIdx + 4); // digits after KVA_
        try {
            Integer kvaInt = Integer.valueOf(numPart);
            return String.valueOf(kvaInt) + 'KVA';
        } catch (Exception e) {
            return null;
        }
    }
}