/**
 * Batch job that syncs PricebookEntries across site-specific pricebooks.
 * For each product with Available_Countries__c or Available_Operation_Site__c set,
 * ensures PBEs exist in the correct site pricebooks.
 *
 * Price source: Standard Price Book entry for the matching currency.
 * If no Standard PB entry exists, creates one at $0 (platform prerequisite).
 */
public with sharing class PricebookSyncBatch implements Database.Batchable<SObject>, Database.Stateful {

    public Integer created = 0;
    public Integer skipped = 0;
    public Integer stdCreated = 0;
    public List<String> errors = new List<String>();

    // Site data cached across batches
    private Map<String, List<SiteInfo>> sitesByCountry;
    private Id stdPbId;

    private class SiteInfo {
        public Id siteId;
        public String siteCode;
        public String country;
        public Id pricebookId;
        public String primaryCurrency;
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        // Cache site data
        sitesByCountry = new Map<String, List<SiteInfo>>();
        for (Site__c s : [SELECT Id, Site_Code__c, Country__c, Pricebook2__c
                          FROM Site__c WHERE Is_Active__c = true AND Pricebook2__c != null]) {
            SiteInfo si = new SiteInfo();
            si.siteId = s.Id;
            si.siteCode = s.Site_Code__c;
            si.country = s.Country__c;
            si.pricebookId = s.Pricebook2__c;
            // Derive primary currency from country
            si.primaryCurrency = currencyForCountry(s.Country__c);
            if (!sitesByCountry.containsKey(s.Country__c)) {
                sitesByCountry.put(s.Country__c, new List<SiteInfo>());
            }
            sitesByCountry.get(s.Country__c).add(si);
        }

        // Standard Price Book records are not visible to a plain SOQL filter in
        // Apex test context, even after Test.getStandardPricebookId() has been
        // called — a platform limitation, not something a test can work around.
        stdPbId = Test.isRunningTest()
            ? Test.getStandardPricebookId()
            : [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;

        return Database.getQueryLocator([
            SELECT Id, ProductCode, Available_Countries__c, Available_Operation_Site__c
            FROM Product2
            WHERE IsActive = true
              AND (Available_Countries__c != null OR Available_Operation_Site__c != null)
        ]);
    }

    public void execute(Database.BatchableContext bc, List<Product2> products) {
        Set<Id> productIds = new Set<Id>();
        for (Product2 p : products) productIds.add(p.Id);

        // Get ALL existing PBEs for these products (active only)
        Map<String, PricebookEntry> existingPBEs = new Map<String, PricebookEntry>();
        for (PricebookEntry pbe : [
            SELECT Id, Product2Id, Pricebook2Id, CurrencyIsoCode, UnitPrice
            FROM PricebookEntry
            WHERE Product2Id IN :productIds AND IsActive = true
        ]) {
            String key = pbe.Product2Id + '|' + pbe.Pricebook2Id + '|' + pbe.CurrencyIsoCode;
            existingPBEs.put(key, pbe);
        }

        // Build Standard PB price map: productId + currency → price
        Map<String, Decimal> stdPrices = new Map<String, Decimal>();
        for (PricebookEntry pbe : existingPBEs.values()) {
            if (pbe.Pricebook2Id == stdPbId) {
                stdPrices.put(pbe.Product2Id + '|' + pbe.CurrencyIsoCode, pbe.UnitPrice);
            }
        }

        List<PricebookEntry> stdToInsert = new List<PricebookEntry>();
        List<PricebookEntry> siteToInsert = new List<PricebookEntry>();

        for (Product2 p : products) {
            // Determine which sites this product should be in
            Set<Id> targetPricebookIds = new Set<Id>();
            Map<Id, String> pbToCurrency = new Map<Id, String>();

            // Country-level availability
            if (String.isNotBlank(p.Available_Countries__c)) {
                for (String country : p.Available_Countries__c.split(';')) {
                    country = country.trim();
                    if (sitesByCountry.containsKey(country)) {
                        for (SiteInfo si : sitesByCountry.get(country)) {
                            targetPricebookIds.add(si.pricebookId);
                            pbToCurrency.put(si.pricebookId, si.primaryCurrency);
                        }
                    }
                }
            }

            // Site-specific availability
            if (String.isNotBlank(p.Available_Operation_Site__c)) {
                for (String siteCode : p.Available_Operation_Site__c.split(';')) {
                    siteCode = siteCode.trim();
                    // Find the site by code
                    for (String country : sitesByCountry.keySet()) {
                        for (SiteInfo si : sitesByCountry.get(country)) {
                            if (si.siteCode == siteCode) {
                                targetPricebookIds.add(si.pricebookId);
                                pbToCurrency.put(si.pricebookId, si.primaryCurrency);
                            }
                        }
                    }
                }
            }

            // For each target pricebook, check if PBE exists
            for (Id pbId : targetPricebookIds) {
                String ccy = pbToCurrency.get(pbId);
                if (String.isBlank(ccy)) continue;

                String siteKey = p.Id + '|' + pbId + '|' + ccy;
                if (existingPBEs.containsKey(siteKey)) {
                    skipped++;
                    continue;
                }

                // Ensure Standard PB entry exists for this currency
                String stdKey = p.Id + '|' + stdPbId + '|' + ccy;
                Decimal price = 0;
                if (existingPBEs.containsKey(stdKey)) {
                    price = existingPBEs.get(stdKey).UnitPrice;
                } else if (!stdPrices.containsKey(p.Id + '|' + ccy)) {
                    // Need to create Standard PB entry
                    PricebookEntry stdPbe = new PricebookEntry(
                        Pricebook2Id = stdPbId,
                        Product2Id = p.Id,
                        UnitPrice = 0,
                        IsActive = true,
                        CurrencyIsoCode = ccy
                    );
                    stdToInsert.add(stdPbe);
                    stdPrices.put(p.Id + '|' + ccy, 0);
                    // Mark as existing so we don't create again
                    existingPBEs.put(stdKey, stdPbe);
                }

                // Create site PBE
                siteToInsert.add(new PricebookEntry(
                    Pricebook2Id = pbId,
                    Product2Id = p.Id,
                    UnitPrice = price,
                    IsActive = true,
                    CurrencyIsoCode = ccy
                ));
            }
        }

        // Insert Standard PB entries first (platform prerequisite)
        if (!stdToInsert.isEmpty()) {
            try {
                insert stdToInsert;
                stdCreated += stdToInsert.size();
            } catch (DmlException e) {
                errors.add('Standard PB insert: ' + e.getMessage());
            }
        }

        // Insert site PBEs
        if (!siteToInsert.isEmpty()) {
            List<Database.SaveResult> results = Database.insert(siteToInsert, false);
            for (Integer i = 0; i < results.size(); i++) {
                if (results[i].isSuccess()) {
                    created++;
                } else {
                    errors.add(siteToInsert[i].Product2Id + ': ' + results[i].getErrors()[0].getMessage());
                }
            }
        }
    }

    public void finish(Database.BatchableContext bc) {
        System.debug('PricebookSyncBatch complete: created=' + created + ' skipped=' + skipped + ' stdCreated=' + stdCreated + ' errors=' + errors.size());
    }

    private static String currencyForCountry(String country) {
        Map<String, String> ccyMap = new Map<String, String>{
            'JP' => 'JPY', 'KR' => 'KRW', 'ID' => 'IDR',
            'PH' => 'PHP', 'CN' => 'CNY', 'IN' => 'INR',
            'TH' => 'THB', 'MY' => 'MYR', 'SG' => 'SGD',
            'HK' => 'HKD'
        };
        return ccyMap.containsKey(country) ? ccyMap.get(country) : 'USD';
    }
}