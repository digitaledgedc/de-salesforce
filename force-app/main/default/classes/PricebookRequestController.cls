/**
 * PricebookRequestController
 *
 * Apex controller for the customPricebookBuilder LWC.
 * Supports the custom pricebook creation workflow:
 *   1. Load Quote context (account, currency, active pricebooks)
 *   2. Search products by pricebook and search term
 *   3. Create a Pricebook_Request__c + lines and submit for approval
 *   4. Load approved custom pricebooks for the Change Pricebook step
 */
public with sharing class PricebookRequestController {

    // ─── Wrapper classes ──────────────────────────────────────────────────────

    public class QuoteContext {
        @AuraEnabled public Id    quoteId;
        @AuraEnabled public Id    accountId;
        @AuraEnabled public String accountName;
        @AuraEnabled public String currencyCode;
        @AuraEnabled public Id    currentPricebookId;
        @AuraEnabled public String currentPricebookName;
        @AuraEnabled public Id     existingPricebookId;
        @AuraEnabled public String existingPricebookName;
        @AuraEnabled public List<ProductRow> existingProducts;
    }

    public class ProductRow {
        @AuraEnabled public Id     pricebookEntryId;
        @AuraEnabled public Id     productId;
        @AuraEnabled public String productName;
        @AuraEnabled public String productCode;
        @AuraEnabled public Decimal listPrice;
        @AuraEnabled public String currencyCode;
        @AuraEnabled public String family;
    }

    public class PricebookOption {
        @AuraEnabled public Id     id;
        @AuraEnabled public String name;
        @AuraEnabled public Boolean isCustom;
    }

    public class LineInput {
        @AuraEnabled public Id      productId;
        @AuraEnabled public String  productName;
        @AuraEnabled public Decimal unitPrice;
        @AuraEnabled public String  attributeValue;
    }

    // ─── Get Quote context ────────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static QuoteContext getQuoteContext(Id quoteId) {
        Quote q = [
            SELECT Id, AccountId, Account.Name,
                   Account.Customer_Pricebook__c, Account.Customer_Pricebook__r.Name,
                   CurrencyIsoCode, Pricebook2Id, Pricebook2.Name
            FROM Quote
            WHERE Id = :quoteId
            WITH SECURITY_ENFORCED
            LIMIT 1
        ];
        QuoteContext ctx        = new QuoteContext();
        ctx.quoteId             = q.Id;
        ctx.accountId           = q.AccountId;
        ctx.accountName         = q.Account?.Name;
        ctx.currencyCode        = q.CurrencyIsoCode;
        ctx.currentPricebookId  = q.Pricebook2Id;
        ctx.currentPricebookName = q.Pricebook2?.Name;

        // Surface existing account custom pricebook if one exists
        if (q.Account?.Customer_Pricebook__c != null) {
            ctx.existingPricebookId   = q.Account.Customer_Pricebook__c; ctx.existingPricebookName = q.Account.Customer_Pricebook__r?.Name; ctx.existingProducts      = new List<ProductRow>();
            for (PricebookEntry pbe : [
                SELECT Id, Product2Id, Product2.Name, Product2.ProductCode, UnitPrice, CurrencyIsoCode FROM PricebookEntry  WHERE Pricebook2Id    = :q.Account.Customer_Pricebook__c AND IsActive        = true AND CurrencyIsoCode = :q.CurrencyIsoCode WITH SECURITY_ENFORCED ORDER BY Product2.Name ASC
            ]) {
                ProductRow r       = new ProductRow(); r.pricebookEntryId = pbe.Id; r.productId        = pbe.Product2Id; r.productName      = pbe.Product2.Name; r.productCode      = pbe.Product2.ProductCode; r.listPrice        = pbe.UnitPrice; r.currencyCode     = pbe.CurrencyIsoCode; ctx.existingProducts.add(r);
            }
        }
        return ctx;
    }

    // ─── Get product details for pre-selected IDs ─────────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<ProductRow> getProductsByIds(String productIdsCsv, Id pricebookId, String currencyCode) {
        if (String.isBlank(productIdsCsv) || pricebookId == null) return new List<ProductRow>();
        List<Id> productIds = new List<Id>();
        for (String s : productIdsCsv.split(';')) {
            String t = s.trim();
            if (String.isNotBlank(t)) productIds.add((Id) t);
        }
        if (productIds.isEmpty()) return new List<ProductRow>();

        // Query ALL currencies — site PB defines availability, currency only affects price
        List<PricebookEntry> entries = [
            SELECT Id, Product2Id, Product2.Name, Product2.ProductCode, Product2.Family, UnitPrice, CurrencyIsoCode
            FROM PricebookEntry
            WHERE Pricebook2Id = :pricebookId
              AND Product2Id IN :productIds
              AND IsActive = true
            WITH SECURITY_ENFORCED
            ORDER BY Product2.Name ASC
        ];

        // Index currency-matched PBEs
        Map<Id, PricebookEntry> currencyMatched = new Map<Id, PricebookEntry>();
        if (String.isNotBlank(currencyCode)) {
            for (PricebookEntry pbe : entries) {
                if (pbe.CurrencyIsoCode == currencyCode) {
                    currencyMatched.put(pbe.Product2Id, pbe);
                }
            }
        }

        // Deduplicate by Product2Id — prefer currency-matched entry, $0 otherwise
        List<ProductRow> rows = new List<ProductRow>();
        Set<Id> seen = new Set<Id>();
        for (PricebookEntry pbe : entries) {
            if (seen.contains(pbe.Product2Id)) continue;
            seen.add(pbe.Product2Id);

            PricebookEntry usePbe = currencyMatched.containsKey(pbe.Product2Id)
                ? currencyMatched.get(pbe.Product2Id) : pbe;
            ProductRow r        = new ProductRow();
            r.pricebookEntryId  = usePbe.Id;
            r.productId         = usePbe.Product2Id;
            r.productName       = usePbe.Product2.Name;
            r.productCode       = usePbe.Product2.ProductCode;
            r.listPrice         = usePbe.UnitPrice;
            r.family            = usePbe.Product2.Family;
            r.currencyCode      = String.isNotBlank(currencyCode) ? currencyCode : usePbe.CurrencyIsoCode;
            rows.add(r);
        }
        return rows;
    }

    // ─── Get full product catalog for a pricebook ──────────────────────────
    // Site PB defines product availability — currency only affects pricing.
    // Products without a PBE in the quote's currency still show at $0.

    @AuraEnabled(cacheable=true)
    public static List<ProductRow> getCatalogProducts(Id pricebookId, String currencyCode) {
        if (pricebookId == null) return new List<ProductRow>();

        // Query ALL active PBEs (any currency) so every site product is visible
        List<PricebookEntry> entries = [
            SELECT Id, Product2Id, Product2.Name, Product2.ProductCode, Product2.Family, UnitPrice, CurrencyIsoCode
            FROM PricebookEntry
            WHERE Pricebook2Id = :pricebookId
              AND IsActive = true
            WITH SECURITY_ENFORCED
            ORDER BY Product2.Name ASC
            LIMIT 2000
        ];

        Map<Id, PricebookEntry> currencyMatched = new Map<Id, PricebookEntry>();
        if (String.isNotBlank(currencyCode)) {
            for (PricebookEntry pbe : entries) { if (pbe.CurrencyIsoCode == currencyCode) { currencyMatched.put(pbe.Product2Id, pbe);
                }
            }
        }

        List<ProductRow> rows = new List<ProductRow>();
        Set<Id> seen = new Set<Id>();
        for (PricebookEntry pbe : entries) {
            if (seen.contains(pbe.Product2Id)) continue;
            seen.add(pbe.Product2Id);

            PricebookEntry usePbe = currencyMatched.containsKey(pbe.Product2Id)
                ? currencyMatched.get(pbe.Product2Id) : pbe;
            ProductRow r        = new ProductRow();
            r.pricebookEntryId  = usePbe.Id;
            r.productId         = usePbe.Product2Id;
            r.productName       = usePbe.Product2.Name;
            r.productCode       = usePbe.Product2.ProductCode;
            r.listPrice         = usePbe.UnitPrice;
            r.family            = usePbe.Product2.Family;
            r.currencyCode      = String.isNotBlank(currencyCode) ? currencyCode : usePbe.CurrencyIsoCode;
            rows.add(r);
        }
        return rows;
    }

    // ─── Search products in a pricebook ──────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<ProductRow> searchProducts(Id pricebookId, String searchTerm) {
        String term = '%' + (String.isBlank(searchTerm) ? '' : searchTerm.trim()) + '%';
        List<PricebookEntry> entries = [
            SELECT Id, Product2Id, Product2.Name, Product2.ProductCode, UnitPrice, CurrencyIsoCode
            FROM PricebookEntry
            WHERE Pricebook2Id = :pricebookId
              AND IsActive = true
              AND (Product2.Name LIKE :term OR Product2.ProductCode LIKE :term)
            WITH SECURITY_ENFORCED
            ORDER BY Product2.Name ASC
            LIMIT 50
        ];
        List<ProductRow> rows = new List<ProductRow>();
        for (PricebookEntry pbe : entries) {
            ProductRow r        = new ProductRow();
            r.pricebookEntryId  = pbe.Id;
            r.productId         = pbe.Product2Id;
            r.productName       = pbe.Product2.Name;
            r.productCode       = pbe.Product2.ProductCode;
            r.listPrice         = pbe.UnitPrice;
            r.currencyCode      = pbe.CurrencyIsoCode;
            rows.add(r);
        }
        return rows;
    }

    // ─── Get available pricebooks ─────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<PricebookOption> getAvailablePricebooks() {
        List<PricebookOption> opts = new List<PricebookOption>();
        for (Pricebook2 pb : [
            SELECT Id, Name, IsStandard
            FROM Pricebook2
            WHERE IsActive = true
            WITH SECURITY_ENFORCED
            ORDER BY IsStandard DESC, Name ASC
            LIMIT 50
        ]) {
            PricebookOption o = new PricebookOption();
            o.id       = pb.Id;
            o.name     = pb.Name;
            o.isCustom = !pb.IsStandard;
            opts.add(o);
        }
        return opts;
    }

    // ─── Get approved custom pricebooks for an account ────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<PricebookOption> getApprovedPricebooksForAccount(Id accountId) {
        List<PricebookOption> opts = new List<PricebookOption>();
        for (Pricebook_Request__c req : [
            SELECT Id, Name, Pricebook2__c, Pricebook2__r.Name
            FROM Pricebook_Request__c
            WHERE Account__c = :accountId
              AND Status__c = 'Approved'
              AND Pricebook2__c != null
            WITH SECURITY_ENFORCED
            ORDER BY Name ASC
        ]) {
            PricebookOption o = new PricebookOption();
            o.id       = req.Pricebook2__c;
            o.name     = req.Pricebook2__r.Name;
            o.isCustom = true;
            opts.add(o);
        }
        return opts;
    }

    // ─── Variant pricing lookup from CMT ─────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static Map<String, Decimal> getVariantPrices(Id siteId) {
        // Get site code
        String siteCode = null;
        if (siteId != null) { List<Site__c> sites = [SELECT Site_Code__c FROM Site__c WHERE Id = :siteId LIMIT 1]; if (!sites.isEmpty()) siteCode = sites[0].Site_Code__c;
        }
        if (String.isBlank(siteCode)) return new Map<String, Decimal>();

        // Build price map from consolidated CMT: "productCode|attributeValue" -> USD price
        // Uses Product_Pricing_Tier__mdt (consolidated). Falls back to legacy PAV for coverage.
        Map<String, Decimal> prices = new Map<String, Decimal>();
        for (Product_Pricing_Tier__mdt t : Product_Pricing_Tier__mdt.getAll().values()) { if (t.Price__c == null || t.Price__c == 0) continue; if (!'USD'.equalsIgnoreCase(t.Currency_Code__c)) continue;
            if (t.Site_Code__c != null && t.Site_Code__c.equalsIgnoreCase(siteCode)) { String key = ((t.Product_Code__c != null ? t.Product_Code__c : '') + '|' + t.Attribute_Value__c).toLowerCase(); prices.put(key, t.Price__c);
            }
        }
        // Fill gaps from legacy PAV (transition period)
        for (Product_Attribute_Variant__mdt pav : Product_Attribute_Variant__mdt.getAll().values()) {  if (pav.Unit_Price__c == null) continue;
            if (pav.Site_Code__c != null && pav.Site_Code__c.equalsIgnoreCase(siteCode)) {  String key = (pav.Product_Code__c + '|' + pav.Attribute_Value__c).toLowerCase(); if (!prices.containsKey(key)) {  prices.put(key, pav.Unit_Price__c); }   } } return prices;
    }

    // ─── Create pricebook request + lines + submit for approval ──────────────

    @AuraEnabled
    public static Id submitPricebookRequest(
        Id quoteId,
        Id accountId,
        Id siteId,
        String currencyCode,
        String lines,
        String approvalNotes,
        Id nextApproverId
    ) {
        // Parse lines from JSON (bypasses inner class deserialization issues)
        List<Object> rawLines = (List<Object>) JSON.deserializeUntyped(lines);
        if (rawLines == null || rawLines.isEmpty()) {
            throw new AuraHandledException('At least one product line is required.');
        }

        if (nextApproverId == null) {
            throw new AuraHandledException('An approver must be selected before submitting.');
        }

        // Build product summary + line records
        List<String> summaryLines = new List<String>();
        List<Map<String, Object>> parsedLines = new List<Map<String, Object>>();
        for (Object raw : rawLines) {
            Map<String, Object> m = (Map<String, Object>) raw;
            parsedLines.add(m);
            Decimal price = m.get('unitPrice') != null ? Decimal.valueOf(String.valueOf(m.get('unitPrice'))) : 0;
            String  name  = m.get('productName') != null ? String.valueOf(m.get('productName')) : 'Product';
            String  attr  = m.get('attributeValue') != null ? String.valueOf(m.get('attributeValue')) : '';
            String  attrSuffix = String.isNotBlank(attr) ? ' [' + attr + ']' : '';
            summaryLines.add(name + attrSuffix + ' - ' + currencyCode + ' ' + price.setScale(2).toPlainString());
        }
        String productSummary = String.join(summaryLines, '\n');

        // CRUD checks
        if (!Schema.sObjectType.Pricebook_Request__c.isCreateable()) { throw new AuraHandledException('Insufficient permissions to create a Pricebook Request.');
        }
        if (!Schema.sObjectType.Pricebook_Request_Line__c.isCreateable()) { throw new AuraHandledException('Insufficient permissions to create Pricebook Request Lines.');
        }

        // Create header
        Pricebook_Request__c req = new Pricebook_Request__c(
            Quote__c               = quoteId,
            Account__c             = accountId,
            Target_Site__c         = siteId,
            Currency__c            = currencyCode,
            Status__c              = 'Pending Approval',
            Approval_Notes__c      = approvalNotes,
            Requested_Approver__c  = nextApproverId,
            Product_Summary__c     = productSummary
        );
        insert req;

        // Create lines from parsed JSON
        List<Pricebook_Request_Line__c> lineRecords = new List<Pricebook_Request_Line__c>();
        for (Map<String, Object> m : parsedLines) {
            String prodId = (String) m.get('productId');
            String name   = m.get('productName') != null ? String.valueOf(m.get('productName')) : 'Product';
            String attr   = m.get('attributeValue') != null ? String.valueOf(m.get('attributeValue')) : null;
            Decimal price = m.get('unitPrice') != null ? Decimal.valueOf(String.valueOf(m.get('unitPrice'))) : 0;

            String lineName = name;
            if (String.isNotBlank(attr)) lineName += ' [' + attr + ']';

            Pricebook_Request_Line__c line = new Pricebook_Request_Line__c(
                Pricebook_Request__c = req.Id,
                Name                 = lineName.left(80),
                Product2__c          = String.isNotBlank(prodId) ? (Id) prodId : null,
                Unit_Price__c        = price,
                Attribute_Value__c   = attr
            );
            lineRecords.add(line);
        }
        insert lineRecords;

        // Submit for approval
        Approval.ProcessSubmitRequest apr = new Approval.ProcessSubmitRequest();
        apr.setObjectId(req.Id);
        apr.setComments(String.isNotBlank(approvalNotes) ? approvalNotes : 'Submitted for approval via Custom Pricebook Builder.');
        try {
            Approval.ProcessResult result = Approval.process(apr);
            if (!result.isSuccess()) { throw new AuraHandledException('Approval submission failed: ' + result.getErrors()[0].getMessage()); } } catch (AuraHandledException e) { throw e; } catch (DmlException e) { throw new AuraHandledException('Approval submission error: ' + e.getMessage()); } catch (Exception e) {  throw new AuraHandledException('Approval submission error: ' + e.getMessage());
        }

        return req.Id;
    }
}