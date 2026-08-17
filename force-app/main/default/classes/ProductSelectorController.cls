/**
 * ProductSelectorController
 *
 * AuraEnabled controller for the productSelectorComponent LWC (flow screen extension).
 * Returns active PricebookEntries for a given pricebook, used to populate
 * the product checkbox list in the Add Products flow.
 */
public with sharing class ProductSelectorController {

    public class PricebookItem {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public Boolean isStandard;
    }

    @AuraEnabled(cacheable=true)
    public static List<PricebookEntry> getProductsForPricebook(String pricebookId, String currencyIsoCode, Id accountId) {
        if (String.isBlank(pricebookId)) {
            return new List<PricebookEntry>();
        }
        // Query ALL active PBEs regardless of currency — products should be visible
        // even if they only have a different-currency PBE.  The quoteLineEditor's
        // ensureCurrencyPbe auto-creates the matching-currency PBE on add.
        List<PricebookEntry> allEntries = [
            SELECT Id, Product2Id, Name, UnitPrice, CurrencyIsoCode, Product2.ProductCode,
                   Product2.Family, Product2.Attribute_Type__c, Product2.Attribute_Values__c,
                   Product2.Invoice_Frequency__c, Product2.Available_Countries__c,
                   Product2.Available_Operation_Site__c
            FROM PricebookEntry
            WHERE Pricebook2Id = :pricebookId
            AND IsActive = true
            ORDER BY Name ASC
            LIMIT 2000
        ];
        allEntries = (List<PricebookEntry>) Security.stripInaccessible(AccessType.READABLE, allEntries).getRecords();

        // Deduplicate by Product2Id — prefer currency-matched PBEs
        // Skip customer-specific products (have sites but no countries) — those belong
        // in account pricebooks only, not in the general site pricebook selector
        Map<Id, PricebookEntry> bestByProduct = new Map<Id, PricebookEntry>();
        List<Id> orderedIds = new List<Id>();
        for (PricebookEntry pbe : allEntries) {
            String countries = pbe.Product2 != null ? pbe.Product2.Available_Countries__c : null;
            String opSites   = pbe.Product2 != null ? pbe.Product2.Available_Operation_Site__c : null;
            if (String.isBlank(countries) && String.isNotBlank(opSites)) continue;
            Id pid = pbe.Product2Id;
            if (!bestByProduct.containsKey(pid)) {
                bestByProduct.put(pid, pbe);
                orderedIds.add(pid);
            } else if (String.isNotBlank(currencyIsoCode) && pbe.CurrencyIsoCode == currencyIsoCode) {
                bestByProduct.put(pid, pbe); // prefer currency match
            }
        }

        // Merge global + country-specific products from Standard PB
        // Derive country from site pricebook name (e.g. "DE TYO2 Price Book" -> TYO2 -> JP)
        List<Pricebook2> currentPb = [SELECT Id, Name, IsStandard FROM Pricebook2 WHERE Id = :pricebookId LIMIT 1];
        if (!currentPb.isEmpty() && !currentPb[0].IsStandard) {
            String pbName = currentPb[0].Name;
            String siteCode = null;
            if (pbName != null && pbName.startsWith('DE ') && pbName.endsWith(' Price Book')) {
                siteCode = pbName.substringAfter('DE ').substringBefore(' Price Book').trim();
            }
            String siteCountry = null;
            if (String.isNotBlank(siteCode)) {
                List<Site__c> sites = [SELECT Country__c FROM Site__c WHERE Site_Code__c = :siteCode LIMIT 1];
                if (!sites.isEmpty()) siteCountry = sites[0].Country__c;
            }
            // Query Standard PB for global + country-specific products.
            // Standard Price Book records are not visible to a plain SOQL filter
            // in Apex test context, even after Test.getStandardPricebookId() has
            // been called — a platform limitation, not something a test can work
            // around from the outside.
            Id stdPbId = null;
            if (Test.isRunningTest()) {
                stdPbId = Test.getStandardPricebookId();
            } else {
                for (Pricebook2 spb : [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1]) {
                    stdPbId = spb.Id;
                }
            }
            if (stdPbId != null) {
                List<PricebookEntry> stdEntries = (List<PricebookEntry>) Security.stripInaccessible(
                    AccessType.READABLE,
                    [SELECT Id, Product2Id, Name, UnitPrice, CurrencyIsoCode, Product2.ProductCode,
                            Product2.Family, Product2.Attribute_Type__c, Product2.Attribute_Values__c,
                            Product2.Invoice_Frequency__c, Product2.Available_Countries__c,
                            Product2.Available_Operation_Site__c
                     FROM PricebookEntry
                     WHERE Pricebook2Id = :stdPbId
                       AND IsActive = true
                     ORDER BY Name ASC
                     LIMIT 2000]
                ).getRecords();
                for (PricebookEntry pbe : stdEntries) {
                    String countries = pbe.Product2 != null ? pbe.Product2.Available_Countries__c : null;
                    String opSites   = pbe.Product2 != null ? pbe.Product2.Available_Operation_Site__c : null;
                    Boolean isGlobal = String.isBlank(countries) && String.isBlank(opSites);
                    Boolean isCountryMatch = false;
                    if (String.isNotBlank(siteCountry) && String.isNotBlank(countries)) {
                        for (String c : countries.split(';')) {
                            if (c.trim() == siteCountry) { isCountryMatch = true; break; }
                        }
                    }
                    if (!isGlobal && !isCountryMatch) continue;
                    Id pid = pbe.Product2Id;
                    if (!bestByProduct.containsKey(pid)) {
                        bestByProduct.put(pid, pbe);
                        orderedIds.add(pid);
                    } else if (String.isNotBlank(currencyIsoCode) && pbe.CurrencyIsoCode == currencyIsoCode) {
                        bestByProduct.put(pid, pbe);
                    }
                }
            }
        }

        // Merge products from account's customer pricebook (Account.Customer_Pricebook__c)
        if (accountId != null) {
            List<Account> accts = [SELECT Customer_Pricebook__c FROM Account WHERE Id = :accountId AND Customer_Pricebook__c != null LIMIT 1];
            if (!accts.isEmpty() && accts[0].Customer_Pricebook__c != pricebookId) {
                Id acctPbId = accts[0].Customer_Pricebook__c;
                List<PricebookEntry> acctEntries = (List<PricebookEntry>) Security.stripInaccessible(
                    AccessType.READABLE,
                    [SELECT Id, Product2Id, Name, UnitPrice, CurrencyIsoCode, Product2.ProductCode,
                            Product2.Family, Product2.Attribute_Type__c, Product2.Attribute_Values__c,
                            Product2.Invoice_Frequency__c
                     FROM PricebookEntry
                     WHERE Pricebook2Id = :acctPbId
                       AND IsActive = true
                     ORDER BY Name ASC
                     LIMIT 2000]
                ).getRecords();
                for (PricebookEntry pbe : acctEntries) {
                    Id pid = pbe.Product2Id;
                    if (!bestByProduct.containsKey(pid)) {
                        bestByProduct.put(pid, pbe);
                        orderedIds.add(pid);
                    } else if (String.isNotBlank(currencyIsoCode) && pbe.CurrencyIsoCode == currencyIsoCode) {
                        bestByProduct.put(pid, pbe);
                    }
                }
            }
        }

        List<PricebookEntry> deduped = new List<PricebookEntry>();
        for (Id pid : orderedIds) {
            deduped.add(bestByProduct.get(pid));
        }
        return deduped;
    }

    /**
     * Returns available pricebooks for a quote's account:
     *   - Standard pricebook (always)
     *   - Current pricebook on the quote (always, even if not yet in an approved request)
     *   - Approved custom pricebooks where Account__c = accountId
     */
    @AuraEnabled(cacheable=true)
    public static List<PricebookItem> getPricebooksForQuote(Id accountId, Id currentPricebookId) {
        List<PricebookItem> items = new List<PricebookItem>();
        Set<Id> seen = new Set<Id>();

        // Standard pricebook — Pricebook2 is a catalog object; no FLS enforcement needed for reads.
        // WHERE IsStandard = true returns zero rows in Apex test context (a platform
        // limitation), but querying directly by Id still works there.
        List<Pricebook2> standardPbs = Test.isRunningTest()
            ? [SELECT Id, Name FROM Pricebook2 WHERE Id = :Test.getStandardPricebookId()]
            : [SELECT Id, Name FROM Pricebook2 WHERE IsStandard = true AND IsActive = true LIMIT 1];
        for (Pricebook2 pb : standardPbs) {
            PricebookItem i = new PricebookItem();
            i.id = pb.Id; i.name = pb.Name; i.isStandard = true;
            items.add(i);
            seen.add(pb.Id);
        }

        // Current pricebook on the quote — always include so the user can see what's active
        if (currentPricebookId != null && !seen.contains(currentPricebookId)) {
            for (Pricebook2 pb : [
                SELECT Id, Name FROM Pricebook2
                WHERE Id = :currentPricebookId AND IsActive = true
            ]) {
                PricebookItem i = new PricebookItem();
                i.id = pb.Id; i.name = pb.Name; i.isStandard = false;
                items.add(i);
                seen.add(pb.Id);
            }
        }

        // Approved custom pricebooks for the account
        if (accountId != null) {
            List<Pricebook_Request__c> reqs = [
                SELECT Pricebook2__c, Pricebook2__r.Name
                FROM Pricebook_Request__c
                WHERE Account__c = :accountId
                  AND Status__c = 'Approved'
                  AND Pricebook2__c != null
                ORDER BY Pricebook2__r.Name ASC
            ];
            reqs = (List<Pricebook_Request__c>) Security.stripInaccessible(AccessType.READABLE, reqs).getRecords();
            for (Pricebook_Request__c req : reqs) {
                if (req.Pricebook2__c != null && !seen.contains(req.Pricebook2__c)) {
                    seen.add(req.Pricebook2__c);
                    PricebookItem i = new PricebookItem();
                    i.id = req.Pricebook2__c; i.name = req.Pricebook2__r.Name; i.isStandard = false;
                    items.add(i);
                }
            }
        }
        return items;
    }

    /**
     * Updates the pricebook on a Quote. Fails if the quote already has line items
     * (Salesforce prevents changing pricebook on quotes with products).
     */
    // DML helper — without sharing to bypass Revenue Cloud / sharing restrictions
    private without sharing class DmlHelper {
        void doUpdate(SObject record) { update record; }
    }

    @AuraEnabled
    public static void updateQuotePricebook(Id quoteId, Id newPricebookId) {
        new DmlHelper().doUpdate(new Quote(Id = quoteId, Pricebook2Id = newPricebookId));
    }
}