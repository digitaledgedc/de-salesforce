/**
 * PricebookRequestService
 *
 * Business logic for Pricebook_Request__c automation.
 * Called from PricebookRequestTriggerHandler on Status__c → Approved.
 *
 * Materialise flow:
 *   1. Load requests + lines (skip any that already have a Pricebook2)
 *   2. Ensure all products exist in the Standard Pricebook (insert missing entries)
 *   3. Create a new active Pricebook2 per request
 *   4. Create PricebookEntries in the new pricebook at the requested prices
 *   5. Stamp Pricebook2__c back onto each request
 */
public without sharing class PricebookRequestService {
    // without sharing — creating Pricebook2/PricebookEntry records requires
    // system-level access; this class is only called from trigger context.

    public static void materializeOnApproval(Set<Id> requestIds) {
        if (requestIds == null || requestIds.isEmpty()) return;

        // ── 1. Load requests that don't already have a pricebook ─────────────
        List<Pricebook_Request__c> requests = [
            SELECT Id, Name, Account__c, Account__r.Name,
                   Quote__c, Quote__r.Pricebook2Id, CurrencyIsoCode,
                   (SELECT Id, Product2__c, Unit_Price__c, Attribute_Value__c FROM Lines__r
                    WHERE Product2__c != null)
            FROM Pricebook_Request__c
            WHERE Id IN :requestIds
              AND Pricebook2__c = null
            LIMIT 200
        ];
        if (requests.isEmpty()) return;

        // ── 2. Collect all product IDs across all requests ───────────────────
        Set<Id> productIds = new Set<Id>();
        for (Pricebook_Request__c req : requests) {
            for (Pricebook_Request_Line__c line : req.Lines__r) {
                productIds.add(line.Product2__c);
            }
        }
        if (productIds.isEmpty()) return;

        // ── 3. Get Standard Pricebook ────────────────────────────────────────
        Pricebook2 stdPb = [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1];

        // ── 4. Collect currencies for Standard PB entry dedup ────────────────
        Set<String> requestCurrencies = new Set<String>();
        for (Pricebook_Request__c req : requests) {
            requestCurrencies.add(req.CurrencyIsoCode);
        }

        // ── 5. Find products already in Standard Pricebook per currency ─────
        Set<String> stdPbeKeys = new Set<String>();
        for (PricebookEntry pbe : [
            SELECT Id, Product2Id, CurrencyIsoCode
            FROM PricebookEntry
            WHERE Pricebook2Id  = :stdPb.Id
              AND Product2Id    IN :productIds
              AND CurrencyIsoCode IN :requestCurrencies
              AND IsActive      = true
        ]) {
            stdPbeKeys.add(pbe.Product2Id + '_' + pbe.CurrencyIsoCode);
        }

        // ── 6. Insert Standard PB entries for any missing product+currency ──
        List<PricebookEntry> missingStdEntries = new List<PricebookEntry>();
        for (Pricebook_Request__c req : requests) {
            for (Pricebook_Request_Line__c line : req.Lines__r) {
                String key = line.Product2__c + '_' + req.CurrencyIsoCode;
                if (!stdPbeKeys.contains(key)) {
                    missingStdEntries.add(new PricebookEntry(  Pricebook2Id    = stdPb.Id, Product2Id      = line.Product2__c, UnitPrice       = 0, CurrencyIsoCode = req.CurrencyIsoCode, IsActive        = true ));
                    stdPbeKeys.add(key); // prevent duplicates across requests
                }
            }
        }
        if (!missingStdEntries.isEmpty()) {  insert missingStdEntries;
        }

        // ── 6a. Build site-availability filter ─────────────────────────────
        // Only include products in the customer PB that exist in the site PB.
        // This prevents the overlay from containing products unavailable at the site.
        Set<Id> sitePbIds = new Set<Id>();
        Map<Id, Id> requestToSitePb = new Map<Id, Id>();
        for (Pricebook_Request__c req : requests) {
            if (req.Quote__c != null && req.Quote__r.Pricebook2Id != null) {  sitePbIds.add(req.Quote__r.Pricebook2Id); requestToSitePb.put(req.Id, req.Quote__r.Pricebook2Id);
            }
        }
        Map<Id, Set<Id>> sitePbProducts = new Map<Id, Set<Id>>();
        if (!sitePbIds.isEmpty()) {
            for (PricebookEntry pbe : [ SELECT Pricebook2Id, Product2Id FROM PricebookEntry WHERE Pricebook2Id IN :sitePbIds AND Product2Id IN :productIds AND IsActive = true ]) {
                Set<Id> prods = sitePbProducts.get(pbe.Pricebook2Id);
                if (prods == null) { prods = new Set<Id>(); sitePbProducts.put(pbe.Pricebook2Id, prods); }  prods.add(pbe.Product2Id);
            }
        }

        // ── 6b. Create one Pricebook2 per request ────────────────────────────
        List<Pricebook2> newPricebooks = new List<Pricebook2>();
        for (Pricebook_Request__c req : requests) {
            newPricebooks.add(new Pricebook2(
                Name        = req.Name,
                Description = 'Custom pricebook — ' +
                              (req.Account__r != null ? req.Account__r.Name + ' — ' : '') +
                              'Request: ' + req.Name,
                IsActive    = true
            ));
        }
        insert newPricebooks;

        // ── 7. Create custom PricebookEntries, stamp Pricebook2__c, link to account ──
        // Account-specific pricebook is an ADD-ON (overlay) to the site pricebook.
        // Do NOT overwrite Site__c.Pricebook2__c or Quote.Pricebook2Id — the site
        // pricebook stays as the quote's catalog; account pricing layers on top.
        List<PricebookEntry>         customEntries      = new List<PricebookEntry>();
        List<Pricebook_Request__c>   requestsToUpdate   = new List<Pricebook_Request__c>();
        List<Account>                accountUpdates     = new List<Account>();

        for (Integer i = 0; i < requests.size(); i++) {
            Pricebook_Request__c req  = requests[i];
            Pricebook2           pb   = newPricebooks[i];

            // Only include products that exist in the site pricebook
            Id sitePbId = requestToSitePb.get(req.Id);
            Set<Id> validProducts = sitePbId != null ? sitePbProducts.get(sitePbId) : null;

            // Group by Product2Id — PBE allows one entry per product per pricebook per currency.
            // When multiple attribute variants exist for the same product, use the highest price.
            Map<Id, Decimal> highestPriceByProduct = new Map<Id, Decimal>();
            for (Pricebook_Request_Line__c line : req.Lines__r) {
                if (validProducts != null && !validProducts.contains(line.Product2__c)) {  continue;  }
                Decimal linePrice = line.Unit_Price__c != null ? line.Unit_Price__c : 0;
                Decimal existing = highestPriceByProduct.get(line.Product2__c);
                if (existing == null || linePrice > existing) {
                    highestPriceByProduct.put(line.Product2__c, linePrice);
                }
            }
            for (Id productId : highestPriceByProduct.keySet()) {
                customEntries.add(new PricebookEntry(
                    Pricebook2Id    = pb.Id,
                    Product2Id      = productId,
                    UnitPrice       = highestPriceByProduct.get(productId),
                    CurrencyIsoCode = req.CurrencyIsoCode,
                    IsActive        = true
                ));
            }

            requestsToUpdate.add(new Pricebook_Request__c(
                Id            = req.Id,
                Pricebook2__c = pb.Id
            ));

            // Set the account's custom pricebook (if account is linked)
            if (req.Account__c != null) {
                accountUpdates.add(new Account(
                    Id                    = req.Account__c,
                    Customer_Pricebook__c = pb.Id
                ));
            }

        }

        if (!customEntries.isEmpty()) {
            insert customEntries;
        }
        update requestsToUpdate;

        if (!accountUpdates.isEmpty()) {
            update accountUpdates;
        }
    }
}