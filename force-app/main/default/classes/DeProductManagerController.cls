public with sharing class DeProductManagerController {

    // ─── Safe field readers (return null when field was stripped by FLS) ────────
    private static String safeChargeType(SObject rec) {
        try { return (String) rec.get('Charge_Type__c'); } catch (SObjectException e) { return null; }
    }
    private static Id safeLookupId(SObject rec, String fieldName) {
        try { return (Id) rec.get(fieldName); } catch (SObjectException e) { return null; }
    }
    private static String safeString(SObject rec, String fieldName) {
        if (rec == null) return null;
        try { return (String) rec.get(fieldName); } catch (SObjectException e) { return null; }
    }

    // ─── Site-code fallback classifier (name-based if no Site__c link found) ──
    // Match pricebook names containing a known site code (3-letter airport code + digit)
    // 2-letter codes (HK, SG) are country/regional pricebooks, not site-specific
    private static final Pattern SITE_CODE = Pattern.compile('[A-Z]{3}\\d');
    private static String classifyBook(String name, Boolean isStandard) {
        if (isStandard == true) return 'Standard';
        // "Custom Pricelist" in name = account-specific, even if site code is present
        if (name != null && name.containsIgnoreCase('Custom Pricelist')) return 'Account';
        if (name != null && name.containsIgnoreCase('Custom pricelist')) return 'Account';
        if (name != null && name.containsIgnoreCase('Customized Pricelist')) return 'Account';
        if (name != null && name.containsIgnoreCase('Local Pricing')) return 'Account';
        if (name != null && SITE_CODE.matcher(name).find()) return 'Site';
        return 'Account';
    }

    // ─── Products ──────────────────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<ProductRow> getProducts() {
        SObjectAccessDecision dec = Security.stripInaccessible(
            AccessType.READABLE,
            [SELECT Id, Name, ProductCode, Family, IsActive, Description,
                    Charge_Type__c, Paired_NRC_Product__c,
                    Paired_NRC_Product__r.Name, Paired_NRC_Product__r.ProductCode,
                    Attribute_Type__c, Attribute_Values__c,
                    Show_Custom_Attribute_Value__c, Capacity_Assignment__c,
                    Additional_Charge_Of__c, Additional_Charge_Of__r.Name,
                    Additional_Charge_Of__r.ProductCode,
                    QuantityUnitOfMeasure, Tied_Product_RC__c,
                    Available_Operation_Site__c, Available_Countries__c,
                    Odoo_Product_ID__c
             FROM Product2
             ORDER BY Family NULLS LAST, Name
             LIMIT 2000]
        );
        List<Product2> products = (List<Product2>) dec.getRecords();
        Set<Id> productIds = new Map<Id, Product2>(products).keySet();
        Map<Id, Integer> entryCounts = new Map<Id, Integer>();
        for (AggregateResult ar : [
            SELECT Product2Id, COUNT_DISTINCT(Pricebook2Id) cnt
            FROM PricebookEntry
            WHERE IsActive = true AND Product2Id IN :productIds
            GROUP BY Product2Id
        ]) {
            entryCounts.put((Id) ar.get('Product2Id'), (Integer) ar.get('cnt'));
        }

        // Build reverse map: NRC product Id → MRC product that links to it
        Map<Id, Product2> nrcToMrc = new Map<Id, Product2>();
        // Build code → product map for code convention fallback
        Map<String, Product2> productByCode = new Map<String, Product2>();
        for (Product2 p : products) {
            Id nrcId = safeLookupId(p, 'Paired_NRC_Product__c');
            if (nrcId != null) nrcToMrc.put(nrcId, p);
            if (String.isNotBlank(p.ProductCode)) {
                productByCode.put(p.ProductCode.toUpperCase(), p);
            }
        }

        List<ProductRow> rows = new List<ProductRow>();
        for (Product2 p : products) {
            ProductRow row  = new ProductRow();
            row.id          = p.Id;
            row.name        = p.Name;
            row.productCode = p.ProductCode;
            row.family      = p.Family;
            row.isActive    = p.IsActive;
            row.description = p.Description;
            row.chargeType  = safeChargeType(p);
            row.entryCount  = entryCounts.containsKey(p.Id) ? entryCounts.get(p.Id) : 0;
            row.attributeType       = safeString(p, 'Attribute_Type__c');
            row.attributeValues     = safeString(p, 'Attribute_Values__c');
            row.showCustomValue     = p.Show_Custom_Attribute_Value__c == true;
            row.capacityAssignment  = safeString(p, 'Capacity_Assignment__c');
            row.uom                 = p.QuantityUnitOfMeasure;
            row.availableSites      = safeString(p, 'Available_Operation_Site__c');
            row.availableCountries  = safeString(p, 'Available_Countries__c');
            row.odooProductId       = p.Odoo_Product_ID__c;
            Id addlChargeOfId = safeLookupId(p, 'Additional_Charge_Of__c');
            if (addlChargeOfId != null) {row.additionalChargeOfId   = addlChargeOfId;
                row.additionalChargeOfName = safeString(p.getSObject('Additional_Charge_Of__r'), 'Name');row.additionalChargeOfCode = safeString(p.getSObject('Additional_Charge_Of__r'), 'ProductCode');
            }

            // Priority 1: explicit lookup (MRC → NRC)
            Id nrcId = safeLookupId(p, 'Paired_NRC_Product__c');
            if (nrcId != null) {
                row.pairedProductId   = nrcId;
                row.pairedProductName = safeString(p.getSObject('Paired_NRC_Product__r'), 'Name');
                row.pairedProductCode = safeString(p.getSObject('Paired_NRC_Product__r'), 'ProductCode');
                row.isExplicitPair    = true;
            }
            // Priority 1b: reverse lookup (NRC ← MRC)
            else if (nrcToMrc.containsKey(p.Id)) {
                Product2 mrc = nrcToMrc.get(p.Id);
                row.pairedProductId   = mrc.Id;
                row.pairedProductName = mrc.Name;
                row.pairedProductCode = mrc.ProductCode;
                row.isExplicitPair    = true;
            }
            // Priority 2: code convention fallback
            else if (String.isNotBlank(p.ProductCode)) {
                String code = p.ProductCode.toUpperCase();
                String pairedCode = null;
                if (code.endsWith('.RC')) pairedCode = code.substring(0, code.length() - 3) + '.NR';
                else if (code.endsWith('.NR')) pairedCode = code.substring(0, code.length() - 3) + '.RC';
                if (pairedCode != null && productByCode.containsKey(pairedCode)) {
                    Product2 paired    = productByCode.get(pairedCode);
                    row.pairedProductId   = paired.Id;row.pairedProductName = paired.Name;row.pairedProductCode = paired.ProductCode;row.isExplicitPair    = false;
                }
            }
            rows.add(row);
        }
        return rows;
    }

    @AuraEnabled
    public static void deleteProduct(String productId) {
        if (String.isBlank(productId)) throw new AuraHandledException('Product ID is required.');
        if (!Product2.SObjectType.getDescribe().isDeletable()) { throw new AuraHandledException('Insufficient permissions to delete products.');
        }
        // Check if product has PricebookEntries - can't delete if it does
        Integer pbeCount = [SELECT COUNT() FROM PricebookEntry WHERE Product2Id = :productId];
        if (pbeCount > 0) {
            throw new AuraHandledException('Cannot delete product with ' + pbeCount + ' pricebook entries. Remove all pricebook entries first.');
        }
        delete new Product2(Id = productId);
    }

    @AuraEnabled
    public static void toggleProductActive(String productId, Boolean isActive) {
        if (String.isBlank(productId)) throw new AuraHandledException('Product ID is required.');
        if (!Product2.SObjectType.getDescribe().isUpdateable()) { throw new AuraHandledException('Insufficient permissions to update Product.');
        }
        update new Product2(Id = productId, IsActive = isActive);
    }

    @AuraEnabled
    public static ProductDetailRow getProductDetail(String productId) {
        if (String.isBlank(productId)) throw new AuraHandledException('Product ID is required.');
        SObjectAccessDecision prodDec = Security.stripInaccessible(
            AccessType.READABLE,
            [SELECT Id, Name, ProductCode, Family, IsActive, Description,
                    Charge_Type__c, Paired_NRC_Product__c,
                    Paired_NRC_Product__r.Name, Paired_NRC_Product__r.ProductCode
             FROM Product2
             WHERE Id = :productId
             LIMIT 1]
        );
        List<Product2> prods = (List<Product2>) prodDec.getRecords();
        if (prods.isEmpty()) throw new AuraHandledException('Product not found.');
        Product2 p = prods[0];

        List<PricebookEntry> entries = [
            SELECT Id, Pricebook2Id, Pricebook2.Name, Pricebook2.IsStandard,
                   UnitPrice, CurrencyIsoCode, IsActive
            FROM PricebookEntry
            WHERE Product2Id = :productId
            WITH SECURITY_ENFORCED
            ORDER BY Pricebook2.IsStandard DESC, Pricebook2.Name
        ];

        ProductDetailRow row  = new ProductDetailRow();
        row.id          = p.Id;
        row.name        = p.Name;
        row.productCode = p.ProductCode;
        row.family      = p.Family;
        row.isActive    = p.IsActive;
        row.description = p.Description;
        row.chargeType  = safeChargeType(p);

        // Priority 1: explicit lookup (MRC → NRC)
        Id nrcId = safeLookupId(p, 'Paired_NRC_Product__c');
        if (nrcId != null) {
            row.pairedProductId   = nrcId;
            row.pairedProductName = safeString(p.getSObject('Paired_NRC_Product__r'), 'Name');
            row.pairedProductCode = safeString(p.getSObject('Paired_NRC_Product__r'), 'ProductCode');
            row.isExplicitPair    = true;
        }
        // Priority 1b: reverse lookup (this NRC ← some MRC)
        if (row.pairedProductId == null) {
            List<Product2> reverseMatch = [
                SELECT Id, Name, ProductCode
                FROM Product2
                WHERE Paired_NRC_Product__c = :productId
                WITH SECURITY_ENFORCED
                LIMIT 1
            ];
            if (!reverseMatch.isEmpty()) {
                row.pairedProductId   = reverseMatch[0].Id;
                row.pairedProductName = reverseMatch[0].Name;
                row.pairedProductCode = reverseMatch[0].ProductCode;
                row.isExplicitPair    = true;
            }
        }
        // Priority 2: code convention fallback (.RC ↔ .NR)
        if (row.pairedProductId == null && String.isNotBlank(p.ProductCode)) {
            String code = p.ProductCode.toUpperCase();
            String pairedCode = null;
            if (code.endsWith('.RC')) {
                pairedCode = code.substring(0, code.length() - 3) + '.NR';
            } else if (code.endsWith('.NR')) {  pairedCode = code.substring(0, code.length() - 3) + '.RC';
            }
            if (pairedCode != null) {
                List<Product2> paired = [
                    SELECT Id, Name, ProductCode
                    FROM Product2
                    WHERE ProductCode = :pairedCode
                    WITH SECURITY_ENFORCED
                    LIMIT 1
                ];
                if (!paired.isEmpty()) {
                    row.pairedProductId   = paired[0].Id;
                    row.pairedProductName = paired[0].Name;
                    row.pairedProductCode = paired[0].ProductCode;
                    row.isExplicitPair    = false;
                }
            }
        }

        row.pricingMatrix = new List<PriceMatrixRow>();
        for (PricebookEntry pe : entries) {
            PriceMatrixRow mr   = new PriceMatrixRow();
            mr.pricebookId      = pe.Pricebook2Id;
            mr.pricebookName    = pe.Pricebook2.Name;
            mr.entryId          = pe.Id;
            mr.unitPrice        = pe.UnitPrice;
            mr.currencyIsoCode  = pe.CurrencyIsoCode;
            mr.isActive         = pe.IsActive;
            mr.isStandard       = pe.Pricebook2.IsStandard;
            mr.pricebookType    = classifyBook(pe.Pricebook2.Name, pe.Pricebook2.IsStandard);
            row.pricingMatrix.add(mr);
        }
        return row;
    }

    // ─── Pricebooks ────────────────────────────────────────────────────────────

    @AuraEnabled
    public static List<PricebookRow> getPricebooks() {
        Map<Id, Integer> entryCounts = new Map<Id, Integer>();
        for (AggregateResult ar : [
            SELECT Pricebook2Id, COUNT_DISTINCT(Product2Id) cnt
            FROM PricebookEntry
            WHERE IsActive = true
            GROUP BY Pricebook2Id
        ]) {
            entryCounts.put((Id) ar.get('Pricebook2Id'), (Integer) ar.get('cnt'));
        }
        List<Pricebook2> books = [
            SELECT Id, Name, IsActive, IsStandard, Description
            FROM Pricebook2
            WITH SECURITY_ENFORCED
            ORDER BY IsStandard DESC, Name
        ];
        Set<Id> pbIds = new Map<Id, Pricebook2>(books).keySet();

        // Site → pricebook (via Pricebook2__c lookup — set by Quote_BeforeSave_AutoSetup flow)
        Map<Id, String> siteNameByPb = new Map<Id, String>();
        for (Site__c s : [
            SELECT Id, Name, Pricebook2__c
            FROM Site__c
            WHERE Pricebook2__c != null
            WITH SECURITY_ENFORCED
        ]) {
            Id pbId = s.Pricebook2__c;
            if (pbIds.contains(pbId)) {
                siteNameByPb.put(pbId, s.Name);
            }
        }

        // Account customer pricebook - resolve names
        Map<Id, List<String>> custNamesByPb = new Map<Id, List<String>>();
        for (Account a : [
            SELECT Name, Customer_Pricebook__c FROM Account
            WHERE Customer_Pricebook__c IN :pbIds
        ]) {
            if (!custNamesByPb.containsKey(a.Customer_Pricebook__c)) {
                custNamesByPb.put(a.Customer_Pricebook__c, new List<String>());
            }
            custNamesByPb.get(a.Customer_Pricebook__c).add(a.Name);
        }

        // Account reseller pricebook counts
        Map<Id, Integer> resellerCountByPb = new Map<Id, Integer>();
        for (AggregateResult ar : [
            SELECT Reseller_Pricebook__c, COUNT(Id) cnt
            FROM Account
            WHERE Reseller_Pricebook__c IN :pbIds
            WITH SECURITY_ENFORCED
            GROUP BY Reseller_Pricebook__c ]) { resellerCountByPb.put((Id) ar.get('Reseller_Pricebook__c'), (Integer) ar.get('cnt'));
        }

        List<PricebookRow> rows = new List<PricebookRow>();
        for (Pricebook2 pb : books) {
            PricebookRow row  = new PricebookRow();
            row.id            = pb.Id;
            row.name          = pb.Name;
            row.isActive      = pb.IsActive;
            row.isStandard    = pb.IsStandard;
            row.description   = pb.Description;
            row.entryCount    = entryCounts.containsKey(pb.Id) ? entryCounts.get(pb.Id) : 0;

            if (pb.IsStandard) {
                row.pricebookType = 'Standard'; row.linkedTo      = null;
            } else if (siteNameByPb.containsKey(pb.Id)) {
                row.pricebookType = 'Site';
                row.linkedTo      = siteNameByPb.get(pb.Id);
            } else if (custNamesByPb.containsKey(pb.Id)) {
                List<String> names = custNamesByPb.get(pb.Id);
                row.pricebookType = 'Account';
                row.linkedTo      = String.join(names, ', ');
            } else if (resellerCountByPb.containsKey(pb.Id)) {
                Integer cnt = resellerCountByPb.get(pb.Id); row.pricebookType = 'Reseller';
                row.linkedTo      = cnt + ' reseller' + (cnt != 1 ? 's' : '');
            } else {
                row.pricebookType = classifyBook(pb.Name, pb.IsStandard);
                row.linkedTo      = null;
            }
            rows.add(row);
        }
        return rows;
    }

    @AuraEnabled(cacheable=true)
    public static List<SiteRow> getSites() {
        List<SiteRow> rows = new List<SiteRow>();
        for (Site__c s : [
            SELECT Id, Name, Pricebook2__c, Pricebook2__r.Name
            FROM Site__c
            WITH SECURITY_ENFORCED
            ORDER BY Name
            LIMIT 200
        ]) {
            SiteRow row              = new SiteRow();
            row.id                   = s.Id;
            row.name                 = s.Name;
            row.currentPricebookId   = s.Pricebook2__c;
            row.currentPricebookName = s.Pricebook2__r != null ? s.Pricebook2__r.Name : null;
            rows.add(row);
        }
        return rows;
    }

    @AuraEnabled
    public static List<EntryRow> getPricebookEntries(String pricebookId) {
        if (String.isBlank(pricebookId)) return new List<EntryRow>();
        SObjectAccessDecision entryDec = Security.stripInaccessible(
            AccessType.READABLE,
            [SELECT Id, Product2Id, Product2.Name, Product2.ProductCode, Product2.Family,
                    Product2.Charge_Type__c, Product2.Product_Attribute__c, Product2.Attribute_Values__c,
                    Product2.Available_Countries__c,
                    Product2.Available_Operation_Site__c,
                    UnitPrice, CurrencyIsoCode, IsActive
             FROM PricebookEntry
             WHERE Pricebook2Id = :pricebookId
             ORDER BY Product2.Family NULLS LAST, Product2.Name
             LIMIT 10000]
        );
        List<PricebookEntry> entries = (List<PricebookEntry>) entryDec.getRecords();
        List<EntryRow> rows = new List<EntryRow>();
        Set<Id> productIds = new Set<Id>();
        for (PricebookEntry pe : entries) {
            EntryRow row        = new EntryRow();
            row.id              = pe.Id;
            row.productId       = pe.Product2Id;
            row.productName     = pe.Product2.Name;
            row.productCode     = pe.Product2.ProductCode;
            row.family          = pe.Product2.Family;
            row.chargeType      = pe.Product2 != null ? safeChargeType(pe.Product2) : null;
            row.unitPrice       = pe.UnitPrice;
            row.currencyIsoCode = pe.CurrencyIsoCode;
            row.isActive        = pe.IsActive;
            row.productAttribute = pe.Product2 != null ? pe.Product2.Product_Attribute__c : null;
            row.attributeValues  = pe.Product2 != null ? pe.Product2.Attribute_Values__c : null;
            row.availableCountries = pe.Product2 != null ? safeString(pe.Product2, 'Available_Countries__c') : null;
            row.availableSites    = pe.Product2 != null ? safeString(pe.Product2, 'Available_Operation_Site__c') : null;
            rows.add(row);
            productIds.add(pe.Product2Id);
        }

        // Standard PB sub-rows removed — site pricebooks only show their own entries.
        // Multi-currency pricing handled by PBEs within the site pricebook itself.
        return rows;
    }

    @AuraEnabled
    public static void updatePricebookEntry(String entryId, Decimal unitPrice) {
        if (String.isBlank(entryId)) throw new AuraHandledException('Entry ID is required.');
        if (unitPrice == null || unitPrice < 0) throw new AuraHandledException('Price must be 0 or greater.');
        if (!PricebookEntry.SObjectType.getDescribe().isUpdateable()) {
            throw new AuraHandledException('Insufficient permissions to update Pricebook Entry.');
        }
        update new PricebookEntry(Id = entryId, UnitPrice = unitPrice);
    }

    @AuraEnabled
    public static void toggleEntryActive(String entryId, Boolean isActive) {
        if (String.isBlank(entryId)) throw new AuraHandledException('Entry ID is required.');
        if (!PricebookEntry.SObjectType.getDescribe().isUpdateable()) { throw new AuraHandledException('Insufficient permissions to update Pricebook Entry.');
        }
        update new PricebookEntry(Id = entryId, IsActive = isActive);
    }

    @AuraEnabled
    public static void deletePricebookEntry(String entryId) {
        if (String.isBlank(entryId)) throw new AuraHandledException('Entry ID is required.');
        if (!PricebookEntry.SObjectType.getDescribe().isDeletable()) {throw new AuraHandledException('Insufficient permissions to delete Pricebook Entry.');
        }
        delete new PricebookEntry(Id = entryId);
    }

    @AuraEnabled
    public static String createPricebook(String name, String description, Boolean isActive, String siteId, String accountId) {
        if (String.isBlank(name)) throw new AuraHandledException('Pricebook name is required.');
        if (!Pricebook2.SObjectType.getDescribe().isCreateable()) {  throw new AuraHandledException('Insufficient permissions to create a Pricebook.');
        }
        Pricebook2 pb = new Pricebook2(
            Name        = name.trim(),
            Description = description,
            IsActive    = (isActive != null) ? isActive : true
        );
        insert pb;

        // Assign to site if requested — sets the Pricebook2__c lookup, which is
        // read by the getPricebooks classifier and the Quote_BeforeSave_AutoSetup flow.
        if (!String.isBlank(siteId) && Site__c.SObjectType.getDescribe().isUpdateable()) {
            update new Site__c(Id = siteId, Pricebook2__c = pb.Id);
        }

        // Assign to account if requested — creates a Named Account pricebook
        if (!String.isBlank(accountId) && Account.SObjectType.getDescribe().isUpdateable()) {
            update new Account(Id = accountId, Customer_Pricebook__c = pb.Id);
        }
        return pb.Id;
    }

    @AuraEnabled
    public static List<RequestLineRow> getVariantPricing(Id pricebookId) {
        if (pricebookId == null) return new List<RequestLineRow>();
        // Find accounts linked to this pricebook
        List<Account> accts = [SELECT Id FROM Account WHERE Customer_Pricebook__c = :pricebookId LIMIT 10];
        if (accts.isEmpty()) return new List<RequestLineRow>();
        Set<Id> acctIds = new Set<Id>();
        for (Account a : accts) acctIds.add(a.Id);
        // Find latest approved request per account
        Map<Id, Id> latestReqByAcct = new Map<Id, Id>();
        for (Pricebook_Request__c req : [
            SELECT Id, Account__c FROM Pricebook_Request__c
            WHERE Account__c IN :acctIds AND Status__c = 'Approved'
            ORDER BY SystemModstamp DESC
        ]) {
            if (!latestReqByAcct.containsKey(req.Account__c)) {
                latestReqByAcct.put(req.Account__c, req.Id);
            }
        }
        if (latestReqByAcct.isEmpty()) return new List<RequestLineRow>();
        Set<Id> reqIds = new Set<Id>(latestReqByAcct.values());
        List<RequestLineRow> rows = new List<RequestLineRow>();
        for (Pricebook_Request_Line__c ln : [
            SELECT Id, Name, Product2__c, Product2__r.Name, Product2__r.ProductCode, Product2__r.Family,
                   Unit_Price__c, Attribute_Value__c
            FROM Pricebook_Request_Line__c
            WHERE Pricebook_Request__c IN :reqIds
            ORDER BY Product2__r.Name, Attribute_Value__c NULLS LAST
        ]) {
            RequestLineRow r = new RequestLineRow();
            r.id = ln.Id;
            r.productId = ln.Product2__c;
            r.productName = ln.Product2__r != null ? ln.Product2__r.Name : ln.Name;
            r.productCode = ln.Product2__r != null ? ln.Product2__r.ProductCode : null;
            r.family = ln.Product2__r != null ? ln.Product2__r.Family : null;
            r.unitPrice = ln.Unit_Price__c;
            r.attributeValue = ln.Attribute_Value__c;
            rows.add(r);
        }
        return rows;
    }

    @AuraEnabled
    public static void linkPricebookToAccount(Id pricebookId, Id accountId) {
        if (pricebookId == null || accountId == null) throw new AuraHandledException('Pricebook and Account are required.');
        if (!Account.SObjectType.getDescribe().isUpdateable()) throw new AuraHandledException('Insufficient permissions.');
        update new Account(Id = accountId, Customer_Pricebook__c = pricebookId);
    }

    @AuraEnabled
    public static void linkPricebookToSite(Id pricebookId, Id siteId) {
        if (pricebookId == null || siteId == null) throw new AuraHandledException('Pricebook and Site are required.');
        if (!Site__c.SObjectType.getDescribe().isUpdateable()) throw new AuraHandledException('Insufficient permissions.');
        update new Site__c(Id = siteId, Pricebook2__c = pricebookId);
    }

    @AuraEnabled
    public static void unlinkPricebook(Id pricebookId) {
        if (pricebookId == null) throw new AuraHandledException('Pricebook is required.');
        // Clear Customer_Pricebook__c on any accounts linked to this pricebook
        List<Account> accts = [SELECT Id FROM Account WHERE Customer_Pricebook__c = :pricebookId];
        if (!accts.isEmpty()) {
            if (!Account.SObjectType.getDescribe().isUpdateable()) throw new AuraHandledException('Insufficient permissions.');
            for (Account a : accts) { a.Customer_Pricebook__c = null; }
            update accts;
        }
        // Clear Pricebook2__c on any sites linked to this pricebook
        List<Site__c> sites = [SELECT Id FROM Site__c WHERE Pricebook2__c = :pricebookId];
        if (!sites.isEmpty()) {
            if (!Site__c.SObjectType.getDescribe().isUpdateable()) throw new AuraHandledException('Insufficient permissions.');
            for (Site__c s : sites) { s.Pricebook2__c = null; }
            update sites;
        }
    }

    @AuraEnabled
    public static List<AccountSearchRow> searchAccounts(String searchTerm) {
        if (String.isBlank(searchTerm) || searchTerm.length() < 2) return new List<AccountSearchRow>();
        if (!Account.SObjectType.getDescribe().isAccessible()) {  throw new AuraHandledException('Insufficient permissions to access Accounts.');
        }
        String term = '%' + String.escapeSingleQuotes(searchTerm.trim()) + '%';
        List<AccountSearchRow> rows = new List<AccountSearchRow>();
        for (Account a : [
            SELECT Id, Name, Customer_Pricebook__c, Customer_Pricebook__r.Name
            FROM Account
            WHERE Name LIKE :term
            WITH SECURITY_ENFORCED
            ORDER BY Name
            LIMIT 10
        ]) {
            AccountSearchRow row    = new AccountSearchRow();
            row.id                  = a.Id;
            row.name                = a.Name;
            row.currentPricebook    = a.Customer_Pricebook__r != null ? a.Customer_Pricebook__r.Name : null;
            rows.add(row);
        }
        return rows;
    }

    // ─── Pricebook Requests ─────────────────────────────────────────────────────

    @AuraEnabled
    public static List<Pricebook_Request__c> getPricebookRequests(String statusFilter) {
        String q = 'SELECT Id, Name, Account__c, Account__r.Name, Quote__c, Quote__r.Name, ' +
                   'Status__c, Currency__c, Pricebook2__c, Pricebook2__r.Name, ' +
                   'Requested_Approver__c, Requested_Approver__r.Name, ' +
                   'CreatedById, CreatedBy.Name, CreatedDate ' +
                   'FROM Pricebook_Request__c ';
        if (!String.isBlank(statusFilter) && statusFilter != 'All') {
            q += 'WHERE Status__c = :statusFilter ';
        }
        q += 'WITH SECURITY_ENFORCED ORDER BY CreatedDate DESC LIMIT 200';
        return Database.query(q);
    }

    @AuraEnabled
    public static RequestDetailRow getRequestDetail(String requestId) {
        if (String.isBlank(requestId)) throw new AuraHandledException('Request ID is required.');
        List<Pricebook_Request__c> reqs = [
            SELECT Id, Name, Account__c, Account__r.Name, Quote__c, Quote__r.Name,
                   Status__c, Currency__c, Pricebook2__c, Pricebook2__r.Name,
                   Requested_Approver__c, Requested_Approver__r.Name,
                   Approval_Notes__c, Product_Summary__c,
                   CreatedById, CreatedBy.Name, CreatedDate
            FROM Pricebook_Request__c
            WHERE Id = :requestId
            WITH SECURITY_ENFORCED
            LIMIT 1
        ];
        if (reqs.isEmpty()) throw new AuraHandledException('Request not found.');
        Pricebook_Request__c r = reqs[0];

        List<Pricebook_Request_Line__c> lines = [
            SELECT Id, Name, Product2__c, Product2__r.Name, Product2__r.ProductCode, Product2__r.Family,
                   Product_Name__c, Unit_Price__c, Attribute_Value__c
            FROM Pricebook_Request_Line__c
            WHERE Pricebook_Request__c = :requestId
            WITH SECURITY_ENFORCED
            ORDER BY Product2__r.Name NULLS LAST
        ];

        RequestDetailRow row      = new RequestDetailRow();
        row.id                    = r.Id;
        row.name                  = r.Name;
        row.accountName           = r.Account__r != null ? r.Account__r.Name : null;
        row.quoteName             = r.Quote__r   != null ? r.Quote__r.Name   : null;
        row.status                = r.Status__c;
        row.currencyCode          = r.Currency__c;
        row.pricebookName         = r.Pricebook2__r != null ? r.Pricebook2__r.Name : null;
        row.requestedApproverName = r.Requested_Approver__r != null ? r.Requested_Approver__r.Name : null;
        row.approvalNotes         = r.Approval_Notes__c;
        row.productSummary        = r.Product_Summary__c;
        row.createdByName         = r.CreatedBy != null ? r.CreatedBy.Name : null;
        row.createdDate           = String.valueOf(r.CreatedDate);
        row.lines                 = new List<RequestLineRow>();
        for (Pricebook_Request_Line__c ln : lines) {
            RequestLineRow lr = new RequestLineRow();
            lr.id             = ln.Id;
            lr.productId      = ln.Product2__c;
            // Resolve product name: relationship first, then Product_Name__c field, then standard Name
            lr.productName    = (ln.Product2__r != null && ln.Product2__r.Name != null)
                ? ln.Product2__r.Name : (String.isNotBlank(ln.Product_Name__c) ? ln.Product_Name__c : ln.Name);
            lr.productCode    = ln.Product2__r != null ? ln.Product2__r.ProductCode : null;
            lr.family         = ln.Product2__r != null ? ln.Product2__r.Family : null;
            lr.unitPrice      = ln.Unit_Price__c;
            lr.attributeValue = ln.Attribute_Value__c;
            row.lines.add(lr);
        }
        return row;
    }

    @AuraEnabled
    public static void upsertRequestLine(String requestId, String productId, String productName, Decimal unitPrice) {
        if (String.isBlank(requestId) || String.isBlank(productId)) {
            throw new AuraHandledException('Request ID and Product ID are required.');
        }
        List<Pricebook_Request_Line__c> existing = [
            SELECT Id FROM Pricebook_Request_Line__c
            WHERE Pricebook_Request__c = :requestId AND Product2__c = :productId
            WITH SECURITY_ENFORCED
            LIMIT 1
        ];
        if (!existing.isEmpty()) {
            if (!Pricebook_Request_Line__c.SObjectType.getDescribe().isUpdateable()) {  throw new AuraHandledException('Insufficient permissions to update request line.');
            }
            update new Pricebook_Request_Line__c(Id = existing[0].Id, Unit_Price__c = unitPrice);
        } else {
            if (!Pricebook_Request_Line__c.SObjectType.getDescribe().isCreateable()) {  throw new AuraHandledException('Insufficient permissions to create request line.');
            }
            insert new Pricebook_Request_Line__c(
                Pricebook_Request__c = requestId,
                Product2__c          = productId,
                Name                 = String.isNotBlank(productName) ? productName : 'Product',
                Unit_Price__c        = unitPrice
            );
        }
    }

    @AuraEnabled
    public static void deleteRequestLine(String lineId) {
        if (String.isBlank(lineId)) throw new AuraHandledException('Line ID is required.');
        if (!Pricebook_Request_Line__c.SObjectType.getDescribe().isDeletable()) { throw new AuraHandledException('Insufficient permissions to delete request line.');
        }
        delete new Pricebook_Request_Line__c(Id = lineId);
    }

    @AuraEnabled
    public static void approveRequest(String requestId, String notes) {
        if (String.isBlank(requestId)) throw new AuraHandledException('Request ID is required.');
        Id workItemId = findOrCreateWorkItem(requestId, notes);
        Approval.ProcessWorkitemRequest req = new Approval.ProcessWorkitemRequest();
        req.setAction('Approve'); req.setComments(notes); req.setWorkitemId(workItemId); req.setNextApproverIds(new List<Id>{ UserInfo.getUserId() });
        Approval.ProcessResult result = Approval.process(req);
        if (!result.isSuccess()) {  throw new AuraHandledException('Approval failed: ' + result.getErrors()[0].getMessage());
        }
    }

    @AuraEnabled
    public static void rejectRequest(String requestId, String notes) {
        if (String.isBlank(requestId)) throw new AuraHandledException('Request ID is required.');
        Id workItemId = findOrCreateWorkItem(requestId, notes);
        Approval.ProcessWorkitemRequest req = new Approval.ProcessWorkitemRequest();
        req.setAction('Reject'); req.setComments(notes); req.setWorkitemId(workItemId);
        req.setNextApproverIds(new List<Id>{ UserInfo.getUserId() });
        Approval.ProcessResult result = Approval.process(req);
        if (!result.isSuccess()) { throw new AuraHandledException('Rejection failed: ' + result.getErrors()[0].getMessage());
        }
    }

    // ─── Approval helper ─────────────────────────────────────────────────────────
    // Finds an existing pending work item, or submits the request for approval
    // first (creating the work item) then returns it. Never bypasses the standard
    // approval process — always goes through Approval API.
    private static Id findOrCreateWorkItem(String requestId, String notes) {
        // Check if already processed
        Pricebook_Request__c req = [SELECT Status__c FROM Pricebook_Request__c WHERE Id = :requestId LIMIT 1];
        if (req.Status__c == 'Approved') {
            throw new AuraHandledException('This request has already been approved.');
        }
        if (req.Status__c == 'Rejected') { throw new AuraHandledException('This request has already been rejected.');
        }

        List<ProcessInstanceWorkitem> items = [
            SELECT Id FROM ProcessInstanceWorkitem
            WHERE ProcessInstance.TargetObjectId = :requestId
              AND ProcessInstance.Status = 'Pending'
            LIMIT 1
        ];
        if (!items.isEmpty()) return items[0].Id;

        // No work item — submit for approval to create one
        Approval.ProcessSubmitRequest submitReq = new Approval.ProcessSubmitRequest();
        submitReq.setObjectId(requestId);
        submitReq.setComments(String.isNotBlank(notes) ? notes : 'Submitted via Product Manager');
        Approval.ProcessResult submitResult = Approval.process(submitReq);
        if (!submitResult.isSuccess()) { throw new AuraHandledException('Could not submit for approval: ' + submitResult.getErrors()[0].getMessage());
        }
        List<ProcessInstanceWorkitem> newItems = [SELECT Id FROM ProcessInstanceWorkitem WHERE ProcessInstance.TargetObjectId = :requestId AND ProcessInstance.Status = 'Pending' LIMIT 1];
        if (newItems.isEmpty()) { throw new AuraHandledException('Approval submitted but no work item was created. Check the approval process configuration.');
        }
        return newItems[0].Id;
    }

    // ─── Product Category Mappings (Product_Category_Map__mdt) ─────────────────

    @AuraEnabled(cacheable=true)
    public static List<CategoryMapRow> getCategoryMappings() {
        List<CategoryMapRow> rows = new List<CategoryMapRow>();
        for (Product_Category_Map__mdt m : Product_Category_Map__mdt.getAll().values()) {
            CategoryMapRow r = new CategoryMapRow();
            r.prefix    = m.Prefix__c;
            r.category  = m.Category__c;
            r.sortOrder = m.Sort_Order__c != null ? Integer.valueOf(m.Sort_Order__c) : 99;
            rows.add(r);
        }
        rows.sort();
        return rows;
    }

    // ─── Product Family picklist ────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<String> getProductFamilies() {
        List<String> vals = new List<String>();
        for (Schema.PicklistEntry pe : Product2.Family.getDescribe().getPicklistValues()) {
            if (pe.isActive()) vals.add(pe.getValue());
        }
        return vals;
    }

    @AuraEnabled
    public static String createProduct(String name, String productCode, String family, String description, Boolean isActive, String chargeType, String productAttribute, String attributeValues, Boolean showCustomAttrVal, String availableCountries, String availableSites) {
        if (String.isBlank(name)) throw new AuraHandledException('Product name is required.');
        if (!Product2.SObjectType.getDescribe().isCreateable()) {  throw new AuraHandledException('Insufficient permissions to create a Product.');
        }
        Product2 p = new Product2(
            Name        = name.trim(),
            ProductCode = String.isBlank(productCode) ? null : productCode.trim(),
            Family      = String.isBlank(family)      ? null : family,
            Description = description,
            IsActive    = true
        );
        if (String.isNotBlank(chargeType)) {
            p.Charge_Type__c = chargeType;
        }
        if (String.isNotBlank(productAttribute)) {
            p.Product_Attribute__c = productAttribute;
            p.Attribute_Type__c = productAttribute;
        }
        if (String.isNotBlank(attributeValues)) {
            p.Attribute_Values__c = attributeValues;
        }
        if (showCustomAttrVal != null && showCustomAttrVal) {
            p.Show_Custom_Attribute_Value__c = true;
        }
        if (String.isNotBlank(availableCountries)) {
            p.Available_Countries__c = availableCountries;
        }
        if (String.isNotBlank(availableSites)) {
            p.Available_Operation_Site__c = availableSites;
        }
        insert p;
        return p.Id;
    }

    // ─── Add initial products when creating a pricebook ─────────────────────────

    @AuraEnabled
    public static void addProductsToPricebook(String pricebookId, String productsJson) {
        if (String.isBlank(pricebookId) || String.isBlank(productsJson)) return;
        List<ProductPriceInput> products =
            (List<ProductPriceInput>) JSON.deserialize(productsJson, List<ProductPriceInput>.class);
        if (products == null || products.isEmpty()) return;

        Set<Id> productIds = new Set<Id>();
        for (ProductPriceInput p : products) {
            if (!String.isBlank(p.productId)) productIds.add(p.productId);
        }

        // Determine currency from input (all products share the same pricebook currency)
        String targetCurrency = null;
        for (ProductPriceInput p : products) {
            if (String.isNotBlank(p.currencyIsoCode)) { targetCurrency = p.currencyIsoCode; break; }
        }

        // Ensure standard pricebook entries exist for every product (in the target currency)
        Pricebook2 stdPb = [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1];
        Map<Id, Boolean> hasStdEntry = new Map<Id, Boolean>();
        List<PricebookEntry> stdCheck = targetCurrency != null
            ? [SELECT Product2Id FROM PricebookEntry WHERE Pricebook2Id = :stdPb.Id AND Product2Id IN :productIds AND CurrencyIsoCode = :targetCurrency]
            : [SELECT Product2Id FROM PricebookEntry WHERE Pricebook2Id = :stdPb.Id AND Product2Id IN :productIds];
        for (PricebookEntry pbe : stdCheck) {
            hasStdEntry.put(pbe.Product2Id, true);
        }
        List<PricebookEntry> stdToInsert = new List<PricebookEntry>();
        for (Id pid : productIds) {
            if (!hasStdEntry.containsKey(pid)) {
                PricebookEntry stdPbe = new PricebookEntry(Pricebook2Id = stdPb.Id, Product2Id = pid, UnitPrice = 0, IsActive = true);
                if (targetCurrency != null) stdPbe.CurrencyIsoCode = targetCurrency;
                stdToInsert.add(stdPbe);
            }
        }
        if (!stdToInsert.isEmpty()) insert stdToInsert;

        // Ensure entries in the target pricebook
        Map<Id, Boolean> hasTargetEntry = new Map<Id, Boolean>();
        for (PricebookEntry pbe : [SELECT Product2Id FROM PricebookEntry WHERE Pricebook2Id = :pricebookId AND Product2Id IN :productIds]) {
            hasTargetEntry.put(pbe.Product2Id, true);
        }
        List<PricebookEntry> targetToInsert = new List<PricebookEntry>();
        for (ProductPriceInput p : products) {
            if (!String.isBlank(p.productId) && !hasTargetEntry.containsKey((Id) p.productId)) {
                PricebookEntry tPbe = new PricebookEntry(
                    Pricebook2Id = pricebookId, Product2Id   = p.productId,
                    UnitPrice    = (p.unitPrice != null && p.unitPrice >= 0) ? p.unitPrice : 0, IsActive     = true
                );
                if (targetCurrency != null) tPbe.CurrencyIsoCode = targetCurrency; targetToInsert.add(tPbe);
            }
        }
        // ── Auto-detect NRC pairs for MRC products (.RC → .NR) ──
        Set<String> nrcCodes = new Set<String>();
        Set<Id> addedProductIds = new Set<Id>();
        for (ProductPriceInput p : products) { if (!String.isBlank(p.productId)) addedProductIds.add(p.productId);
        }
        for (Product2 mrc : [SELECT ProductCode FROM Product2 WHERE Id IN :addedProductIds AND ProductCode LIKE '%.RC']) {
            String nrcCode = mrc.ProductCode.removeEndIgnoreCase('.RC') + '.NR'; nrcCodes.add(nrcCode);
        }
        if (!nrcCodes.isEmpty()) {
            for (Product2 nrc : [SELECT Id FROM Product2 WHERE ProductCode IN :nrcCodes AND IsActive = true]) {
                if (!hasStdEntry.containsKey(nrc.Id)) {
                    stdToInsert.clear(); // reuse list
                    stdToInsert.add(new PricebookEntry(Pricebook2Id = stdPb.Id, Product2Id = nrc.Id, UnitPrice = 0, IsActive = true));
                    insert stdToInsert;
                }
                if (!hasTargetEntry.containsKey(nrc.Id)) {  targetToInsert.add(new PricebookEntry(Pricebook2Id = pricebookId, Product2Id = nrc.Id, UnitPrice = 0, IsActive = true));
                }
            }
        }

        if (!targetToInsert.isEmpty()) { if (!PricebookEntry.SObjectType.getDescribe().isCreateable()) { throw new AuraHandledException('Insufficient permissions to create pricebook entries.');
            }
            insert targetToInsert;
        }
    }

    // ─── Mass price update ───────────────────────────────────────────────────────

    @AuraEnabled
    public static void massUpdatePricebookEntries(List<String> entryIds, Decimal unitPrice) {
        if (entryIds == null || entryIds.isEmpty()) return;
        if (unitPrice == null || unitPrice < 0) throw new AuraHandledException('Price must be 0 or greater.');
        if (!PricebookEntry.SObjectType.getDescribe().isUpdateable()) { throw new AuraHandledException('Insufficient permissions to update Pricebook Entries.');
        }
        List<PricebookEntry> updates = new List<PricebookEntry>();
        for (String eid : entryIds) {
            if (!String.isBlank(eid)) updates.add(new PricebookEntry(Id = eid, UnitPrice = unitPrice));
        }
        if (!updates.isEmpty()) update updates;
    }

    // ─── MRC ↔ NRC Product Pairing ─────────────────────────────────────────────

    @AuraEnabled
    public static List<ProductRow> searchProductsForPairing(String productId, String searchTerm) {
        if (String.isBlank(productId) || String.isBlank(searchTerm) || searchTerm.length() < 2) {
            return new List<ProductRow>();
        }
        if (!Product2.SObjectType.getDescribe().isAccessible()) { throw new AuraHandledException('Insufficient permissions to access products.');
        }
        String term = '%' + String.escapeSingleQuotes(searchTerm.trim()) + '%';
        SObjectAccessDecision dec = Security.stripInaccessible(
            AccessType.READABLE,
            [SELECT Id, Name, ProductCode, Family, Charge_Type__c
             FROM Product2
             WHERE Id != :productId
               AND IsActive = true
               AND (Name LIKE :term OR ProductCode LIKE :term)
             ORDER BY Name
             LIMIT 10]
        );
        List<ProductRow> rows = new List<ProductRow>();
        for (Product2 p : (List<Product2>) dec.getRecords()) {
            ProductRow row  = new ProductRow();
            row.id          = p.Id;
            row.name        = p.Name;
            row.productCode = p.ProductCode;
            row.family      = p.Family;
            row.chargeType  = safeChargeType(p);
            rows.add(row);
        }
        return rows;
    }

    @AuraEnabled
    public static void linkProducts(String mrcProductId, String nrcProductId) {
        if (String.isBlank(mrcProductId) || String.isBlank(nrcProductId)) {
            throw new AuraHandledException('Both MRC and NRC product IDs are required.');
        }
        if (!Product2.SObjectType.getDescribe().isUpdateable()) { throw new AuraHandledException('Insufficient permissions to update products.');
        }
        update new List<Product2>{
            new Product2(Id = mrcProductId, Paired_NRC_Product__c = nrcProductId),
            new Product2(Id = nrcProductId, Tied_Product_RC__c = mrcProductId)
        };
    }

    @AuraEnabled
    public static void unlinkProducts(String mrcProductId) {
        if (String.isBlank(mrcProductId)) {
            throw new AuraHandledException('MRC Product ID is required.');
        }
        if (!Product2.SObjectType.getDescribe().isUpdateable()) { throw new AuraHandledException('Insufficient permissions to update products.');
        }
        // Find the NRC product to clear its reverse link
        Product2 mrc = [SELECT Paired_NRC_Product__c FROM Product2 WHERE Id = :mrcProductId LIMIT 1];
        List<Product2> toUpdate = new List<Product2>{
            new Product2(Id = mrcProductId, Paired_NRC_Product__c = null)
        };
        if (mrc.Paired_NRC_Product__c != null) {
            toUpdate.add(new Product2(Id = mrc.Paired_NRC_Product__c, Tied_Product_RC__c = null));
        }
        update toUpdate;
    }

    // ─── Product Update ──────────────────────────────────────────────────────────

    @AuraEnabled
    public static void updateProduct(String productId, String name, String description,
                                      String attributeType, String attributeValues,
                                      Boolean showCustomValue, String capacityAssignment,
                                      String uom) {
        if (!Product2.SObjectType.getDescribe().isUpdateable()) {  throw new AuraHandledException('Insufficient permissions to update products.');
        }
        Product2 p = new Product2(Id = productId);
        if (name != null) p.Name = name;
        if (description != null) p.Description = description;
        p.Attribute_Type__c = attributeType;
        p.Attribute_Values__c = attributeValues;
        p.Show_Custom_Attribute_Value__c = showCustomValue == true;
        p.Capacity_Assignment__c = capacityAssignment;
        p.QuantityUnitOfMeasure = uom;
        update p;
    }

    // ─── Product Update (Catalog inline edit) ─────────────────────────────────────

    @AuraEnabled
    public static void updateProductCatalog(String productId, String name, String productCode,
                                             String family, String chargeType,
                                             String productAttribute, String attributeValues,
                                             Boolean showCustomAttrVal, String availableCountries,
                                             String availableSites) {
        if (String.isBlank(productId)) throw new AuraHandledException('Product ID is required.');
        if (String.isBlank(name)) throw new AuraHandledException('Product name is required.');
        if (!Product2.SObjectType.getDescribe().isUpdateable()) {  throw new AuraHandledException('Insufficient permissions to update products.');
        }
        Product2 p = new Product2(
            Id = productId,
            Name = name.trim(),
            ProductCode = String.isBlank(productCode) ? null : productCode.trim(),
            Family = String.isBlank(family) ? null : family
        );
        if (String.isNotBlank(chargeType)) p.Charge_Type__c = chargeType;
        if (String.isNotBlank(productAttribute)) {
            p.Product_Attribute__c = productAttribute;
            p.Attribute_Type__c = productAttribute;
        } else { p.Product_Attribute__c = null;  p.Attribute_Type__c = null;
        }
        p.Attribute_Values__c = String.isBlank(attributeValues) ? null : attributeValues;
        p.Show_Custom_Attribute_Value__c = showCustomAttrVal != null && showCustomAttrVal;
        p.Available_Countries__c = String.isBlank(availableCountries) ? null : availableCountries;
        p.Available_Operation_Site__c = String.isBlank(availableSites) ? null : availableSites;
        update p;
    }

    // ─── Delete Pricing Tier (soft-delete: set price to 0) ────────────────────────

    @AuraEnabled
    public static String deletePricingTier(String developerName) {
        if (String.isBlank(developerName)) throw new AuraHandledException('Developer Name is required.');
        Metadata.CustomMetadata cmRecord = new Metadata.CustomMetadata();
        cmRecord.fullName = 'Product_Pricing_Tier__mdt.' + developerName;
        cmRecord.label = developerName.replace('_', ' ');
        Metadata.CustomMetadataValue priceField = new Metadata.CustomMetadataValue();
        priceField.field = 'Price__c';
        priceField.value = 0;
        cmRecord.values.add(priceField);
        Metadata.DeployContainer container = new Metadata.DeployContainer();
        container.addMetadata(cmRecord);
        Id jobId = Metadata.Operations.enqueueDeployment(container, null); return String.valueOf(jobId);
    }

    // ─── kVA Pricing Management ─────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<KvaPricingRow> getKvaPricing() {
        List<KvaPricingRow> rows = new List<KvaPricingRow>();
        for (kVA_Draw_Pricing__mdt rec : kVA_Draw_Pricing__mdt.getAll().values()) {
            KvaPricingRow r = new KvaPricingRow();
            r.developerName = rec.DeveloperName;
            r.label         = rec.Label;
            r.productCode   = rec.Product_Code__c;
            r.kvaValue      = rec.kVA_Value__c;
            r.priceUSD      = rec.Monthly_Price_USD__c;
            r.priceJPY      = rec.Monthly_Price_JPY__c;
            r.priceIDR      = rec.Monthly_Price_IDR__c;
            r.priceKRW      = rec.Monthly_Price_KRW__c;
            r.priceSGD      = rec.Monthly_Price_SGD__c;
            r.priceHKD      = rec.Monthly_Price_HKD__c;
            r.priceCNY      = rec.Monthly_Price_CNY__c;
            r.pricePHP      = rec.Monthly_Price_PHP__c;
            rows.add(r);
        }
        rows.sort();
        return rows;
    }

    // ─── Site-specific attribute pricing (Product_Attribute_Variant__mdt) ───────

    @AuraEnabled(cacheable=true)
    public static List<AttributeVariantRow> getAttributeVariants() {
        List<AttributeVariantRow> rows = new List<AttributeVariantRow>();
        for (Product_Attribute_Variant__mdt pav : Product_Attribute_Variant__mdt.getAll().values()) {
            AttributeVariantRow r = new AttributeVariantRow();
            r.developerName   = pav.DeveloperName;
            r.productCode     = pav.Product_Code__c;
            r.attributeValue  = pav.Attribute_Value__c;
            r.siteCode        = pav.Site_Code__c;
            r.unitPrice       = pav.Unit_Price__c;
            r.odooComboId     = pav.Odoo_Combo_Id__c;
            rows.add(r);
        }
        return rows;
    }

    // ─── Consolidated Pricing Tiers (Product_Pricing_Tier__mdt) ─────────────────

    @AuraEnabled
    public static List<PricingTierRow> getPricingTiers() {
        List<PricingTierRow> rows = new List<PricingTierRow>();
        for (Product_Pricing_Tier__mdt t : Product_Pricing_Tier__mdt.getAll().values()) {
            PricingTierRow r = new PricingTierRow();
            r.developerName  = t.DeveloperName;
            r.productCode    = t.Product_Code__c;
            r.attributeValue = t.Attribute_Value__c;
            r.siteCode       = t.Site_Code__c;
            r.currencyCode   = t.Currency_Code__c;
            r.price          = t.Price__c;
            r.odooComboId    = t.Odoo_Combo_Id__c;
            rows.add(r);
        }
        return rows;
    }

    @AuraEnabled
    public static String updatePricingTier(String developerName, Decimal newPrice) {
        Metadata.CustomMetadata cmRecord = new Metadata.CustomMetadata();
        cmRecord.fullName = 'Product_Pricing_Tier__mdt.' + developerName;
        cmRecord.label    = developerName.replace('_', ' ');

        Metadata.CustomMetadataValue priceField = new Metadata.CustomMetadataValue();
        priceField.field = 'Price__c';
        priceField.value = newPrice;
        cmRecord.values.add(priceField);

        Metadata.DeployContainer container = new Metadata.DeployContainer();
        container.addMetadata(cmRecord);

        Id jobId = Metadata.Operations.enqueueDeployment(container, null); return String.valueOf(jobId);
    }

    @AuraEnabled
    public static String createPricingTier(String productCode, String attributeValue,
            String siteCode, String currencyCode, Decimal price, Decimal odooComboId) {
        if (String.isBlank(attributeValue) || String.isBlank(currencyCode)) {
            throw new AuraHandledException('Attribute Value and Currency are required.');
        }
        // Build a clean DeveloperName from fields
        String devName = '';
        if (String.isNotBlank(productCode)) devName += productCode.replace('.', '_') + '_';
        devName += attributeValue.replace('.', '_');
        if (String.isNotBlank(siteCode)) devName += '_' + siteCode;
        devName += '_' + currencyCode;
        devName = devName.replaceAll('[^a-zA-Z0-9_]', '');
        if (devName.length() > 40) devName = devName.substring(0, 40);

        Metadata.CustomMetadata cmRecord = new Metadata.CustomMetadata();
        cmRecord.fullName = 'Product_Pricing_Tier__mdt.' + devName;
        cmRecord.label    = devName.replace('_', ' ');

        List<Metadata.CustomMetadataValue> vals = new List<Metadata.CustomMetadataValue>();
        vals.add(cmVal('Product_Code__c', productCode));
        vals.add(cmVal('Attribute_Value__c', attributeValue));
        vals.add(cmVal('Site_Code__c', siteCode));
        vals.add(cmVal('Currency_Code__c', currencyCode));
        vals.add(cmValNum('Price__c', price));
        vals.add(cmValNum('Odoo_Combo_Id__c', odooComboId));
        cmRecord.values = vals;

        Metadata.DeployContainer container = new Metadata.DeployContainer();
        container.addMetadata(cmRecord);
        Id jobId = Metadata.Operations.enqueueDeployment(container, null); return String.valueOf(jobId);
    }

    @AuraEnabled
    public static String importPricingTiers(String rowsJson) {
        List<Object> rows = (List<Object>) JSON.deserializeUntyped(rowsJson);
        if (rows == null || rows.isEmpty()) throw new AuraHandledException('No rows to import.');
        if (rows.size() > 200) throw new AuraHandledException('Maximum 200 records per import (Metadata API limit).');

        Metadata.DeployContainer container = new Metadata.DeployContainer();
        for (Object row : rows) {
            Map<String, Object> r = (Map<String, Object>) row;
            String pc  = (String) r.get('productCode');
            String av  = (String) r.get('attributeValue');
            String sc  = (String) r.get('siteCode');
            String cc  = (String) r.get('currencyCode');
            Decimal pr = r.get('price') != null ? Decimal.valueOf(String.valueOf(r.get('price'))) : 0;
            Decimal oi = r.get('odooComboId') != null ? Decimal.valueOf(String.valueOf(r.get('odooComboId'))) : null;

            String devName = '';
            if (String.isNotBlank(pc)) devName += pc.replace('.', '_') + '_';
            devName += av.replace('.', '_');
            if (String.isNotBlank(sc)) devName += '_' + sc;
            devName += '_' + cc;
            devName = devName.replaceAll('[^a-zA-Z0-9_]', '');
            if (devName.length() > 40) devName = devName.substring(0, 40);

            Metadata.CustomMetadata cm = new Metadata.CustomMetadata();
            cm.fullName = 'Product_Pricing_Tier__mdt.' + devName;
            cm.label    = devName.replace('_', ' ');
            cm.values   = new List<Metadata.CustomMetadataValue>{
                cmVal('Product_Code__c', pc), cmVal('Attribute_Value__c', av),
                cmVal('Site_Code__c', sc), cmVal('Currency_Code__c', cc),
                cmValNum('Price__c', pr), cmValNum('Odoo_Combo_Id__c', oi)
            };
            container.addMetadata(cm);
        }
        Id jobId = Metadata.Operations.enqueueDeployment(container, null); return String.valueOf(jobId);
    }

    private static Metadata.CustomMetadataValue cmVal(String field, String value) {
        Metadata.CustomMetadataValue v = new Metadata.CustomMetadataValue();
        v.field = field;
        v.value = value;
        return v;
    }
    private static Metadata.CustomMetadataValue cmValNum(String field, Decimal value) {
        Metadata.CustomMetadataValue v = new Metadata.CustomMetadataValue();
        v.field = field;
        v.value = value;
        return v;
    }

    // ─── Add Currency Entry (PricebookEntry in new currency) ────────────────────

    @AuraEnabled
    public static String addCurrencyEntry(String pricebookId, String productId, String currencyCode, Decimal unitPrice) {
        if (String.isBlank(pricebookId) || String.isBlank(productId) || String.isBlank(currencyCode)) {
            throw new AuraHandledException('Pricebook, Product, and Currency are required.');
        }
        if (!PricebookEntry.SObjectType.getDescribe().isCreateable()) {   throw new AuraHandledException('Insufficient permissions to create Pricebook Entry.');
        }
        // Ensure Standard PB entry exists for this product + currency
        Pricebook2 stdPb = [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1];
        List<PricebookEntry> existingStd = [SELECT Id FROM PricebookEntry WHERE Pricebook2Id = :stdPb.Id AND Product2Id = :productId AND CurrencyIsoCode = :currencyCode LIMIT 1];
        if (existingStd.isEmpty()) {
            insert new PricebookEntry(Pricebook2Id = stdPb.Id, Product2Id = productId, UnitPrice = 0, IsActive = true, CurrencyIsoCode = currencyCode);
        }
        // Check if entry already exists in target pricebook
        if (pricebookId != stdPb.Id) {
            List<PricebookEntry> existingTarget = [SELECT Id FROM PricebookEntry WHERE Pricebook2Id = :pricebookId AND Product2Id = :productId AND CurrencyIsoCode = :currencyCode LIMIT 1];
            if (!existingTarget.isEmpty()) {
                throw new AuraHandledException('Entry already exists for this product in ' + currencyCode + '.');
            }
            insert new PricebookEntry(Pricebook2Id = pricebookId, Product2Id = productId, UnitPrice = unitPrice != null ? unitPrice : 0, IsActive = true, CurrencyIsoCode = currencyCode);
        }
        return 'OK';
    }

    // ─── CMT Price Updates (async via Metadata API) — LEGACY, kept for backward compat ─────────────────────────────

    @AuraEnabled
    public static String updateAttributeVariantPrice(String developerName, Decimal newPrice) {
        Metadata.CustomMetadata cmRecord = new Metadata.CustomMetadata();
        cmRecord.fullName = 'Product_Attribute_Variant__mdt.' + developerName;
        cmRecord.label    = developerName.replace('_', ' ');

        Metadata.CustomMetadataValue priceField = new Metadata.CustomMetadataValue();
        priceField.field = 'Unit_Price__c';
        priceField.value = newPrice;
        cmRecord.values.add(priceField);

        Metadata.DeployContainer container = new Metadata.DeployContainer();
        container.addMetadata(cmRecord);

        Id jobId = Metadata.Operations.enqueueDeployment(container, null); return String.valueOf(jobId);
    }

    @AuraEnabled
    public static String updateKvaPrice(String developerName, String currencyField, Decimal newPrice) {
        Metadata.CustomMetadata cmRecord = new Metadata.CustomMetadata();
        cmRecord.fullName = 'kVA_Draw_Pricing__mdt.' + developerName;
        cmRecord.label    = developerName.replace('_', ' ');

        Metadata.CustomMetadataValue priceField = new Metadata.CustomMetadataValue();
        priceField.field = currencyField;
        priceField.value = newPrice;
        cmRecord.values.add(priceField);

        Metadata.DeployContainer container = new Metadata.DeployContainer();
        container.addMetadata(cmRecord);

        Id jobId = Metadata.Operations.enqueueDeployment(container, null);  return String.valueOf(jobId);
    }

    // ─── Product Pricebook List (inline expansion on Catalog badge click) ──────

    @AuraEnabled
    public static List<PricebookInfo> getProductPricebooks(String productId) {
        if (String.isBlank(productId)) return new List<PricebookInfo>();
        List<PricebookInfo> result = new List<PricebookInfo>();
        Set<Id> pbIds = new Set<Id>();
        for (PricebookEntry pbe : [SELECT Pricebook2Id FROM PricebookEntry WHERE Product2Id = :productId AND IsActive = true]) {
            pbIds.add(pbe.Pricebook2Id);
        }
        if (pbIds.isEmpty()) return result;
        for (Pricebook2 pb : [SELECT Id, Name, IsStandard FROM Pricebook2 WHERE Id IN :pbIds ORDER BY Name]) {
            PricebookInfo info = new PricebookInfo();
            info.id = pb.Id;
            info.name = pb.Name;
            info.isStandard = pb.IsStandard;
            result.add(info);
        }
        return result;
    }

    // ─── Wrapper Classes ─────────────────────────────────────────────────────────

    public class ProductRow {
        @AuraEnabled public String  id;
        @AuraEnabled public String  name;
        @AuraEnabled public String  productCode;
        @AuraEnabled public String  family;
        @AuraEnabled public Boolean isActive;
        @AuraEnabled public String  description;
        @AuraEnabled public String  chargeType;
        @AuraEnabled public Integer entryCount;
        @AuraEnabled public String  pairedProductId;
        @AuraEnabled public String  pairedProductName;
        @AuraEnabled public String  pairedProductCode;
        @AuraEnabled public Boolean isExplicitPair;
        @AuraEnabled public String  attributeType;
        @AuraEnabled public String  attributeValues;
        @AuraEnabled public Boolean showCustomValue;
        @AuraEnabled public String  capacityAssignment;
        @AuraEnabled public String  additionalChargeOfId;
        @AuraEnabled public String  additionalChargeOfName;
        @AuraEnabled public String  additionalChargeOfCode;
        @AuraEnabled public String  uom;
        @AuraEnabled public String  availableSites;
        @AuraEnabled public String  availableCountries;
        @AuraEnabled public Decimal odooProductId;
    }

    public class ProductDetailRow {
        @AuraEnabled public String  id;
        @AuraEnabled public String  name;
        @AuraEnabled public String  productCode;
        @AuraEnabled public String  family;
        @AuraEnabled public Boolean isActive;
        @AuraEnabled public String  description;
        @AuraEnabled public String  chargeType;
        @AuraEnabled public String  pairedProductId;
        @AuraEnabled public String  pairedProductName;
        @AuraEnabled public String  pairedProductCode;
        @AuraEnabled public Boolean isExplicitPair;
        @AuraEnabled public List<PriceMatrixRow> pricingMatrix;
    }

    public class PriceMatrixRow {
        @AuraEnabled public String  pricebookId;
        @AuraEnabled public String  pricebookName;
        @AuraEnabled public String  entryId;
        @AuraEnabled public Decimal unitPrice;
        @AuraEnabled public String  currencyIsoCode;
        @AuraEnabled public Boolean isActive;
        @AuraEnabled public Boolean isStandard;
        @AuraEnabled public String  pricebookType;
    }

    public class PricebookRow {
        @AuraEnabled public String  id;
        @AuraEnabled public String  name;
        @AuraEnabled public Boolean isActive;
        @AuraEnabled public Boolean isStandard;
        @AuraEnabled public String  description;
        @AuraEnabled public Integer entryCount;
        @AuraEnabled public String  pricebookType;  // Standard | Site | Account | Reseller
        @AuraEnabled public String  linkedTo;        // site name, "N accounts", etc.
    }

    public class SiteRow {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String currentPricebookId;
        @AuraEnabled public String currentPricebookName;
    }

    public class AccountSearchRow {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String currentPricebook;
    }

    public class EntryRow {
        @AuraEnabled public String  id;
        @AuraEnabled public String  productId;
        @AuraEnabled public String  productName;
        @AuraEnabled public String  productCode;
        @AuraEnabled public String  family;
        @AuraEnabled public String  chargeType;
        @AuraEnabled public Decimal unitPrice;
        @AuraEnabled public String  currencyIsoCode;
        @AuraEnabled public Boolean isActive;
        @AuraEnabled public Boolean isStandardEntry = false;
        @AuraEnabled public String  productAttribute;
        @AuraEnabled public String  attributeValues;
        @AuraEnabled public String  availableCountries;
        @AuraEnabled public String  availableSites;
    }

    public class CategoryMapRow implements Comparable {
        @AuraEnabled public String  prefix;
        @AuraEnabled public String  category;
        @AuraEnabled public Integer sortOrder;
        public Integer compareTo(Object other) {
            CategoryMapRow o = (CategoryMapRow) other;
            Integer a = this.sortOrder != null ? this.sortOrder : 99;
            Integer b = o.sortOrder != null ? o.sortOrder : 99;
            if (a != b) return a - b;
            return (this.category != null ? this.category : '').compareTo(o.category != null ? o.category : '');
        }
    }

    public class PricingTierRow {
        @AuraEnabled public String  developerName;
        @AuraEnabled public String  productCode;
        @AuraEnabled public String  attributeValue;
        @AuraEnabled public String  siteCode;
        @AuraEnabled public String  currencyCode;
        @AuraEnabled public Decimal price;
        @AuraEnabled public Decimal odooComboId;
    }

    public class RequestDetailRow {
        @AuraEnabled public String  id;
        @AuraEnabled public String  name;
        @AuraEnabled public String  accountName;
        @AuraEnabled public String  quoteName;
        @AuraEnabled public String  status;
        @AuraEnabled public String  currencyCode;
        @AuraEnabled public String  pricebookName;
        @AuraEnabled public String  requestedApproverName;
        @AuraEnabled public String  approvalNotes;
        @AuraEnabled public String  productSummary;
        @AuraEnabled public String  createdByName;
        @AuraEnabled public String  createdDate;
        @AuraEnabled public List<RequestLineRow> lines;
    }

    public class RequestLineRow {
        @AuraEnabled public String  id;
        @AuraEnabled public String  productId;
        @AuraEnabled public String  productName;
        @AuraEnabled public String  productCode;
        @AuraEnabled public String  family;
        @AuraEnabled public Decimal unitPrice;
        @AuraEnabled public String  attributeValue;
    }

    public class PricebookInfo {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public Boolean isStandard;
    }

    public class ProductPriceInput {
        @AuraEnabled public String  productId;
        @AuraEnabled public Decimal unitPrice;
        @AuraEnabled public String  currencyIsoCode;
    }

    public class AttributeVariantRow {
        @AuraEnabled public String  developerName;
        @AuraEnabled public String  productCode;
        @AuraEnabled public String  attributeValue;
        @AuraEnabled public String  siteCode;
        @AuraEnabled public Decimal unitPrice;
        @AuraEnabled public Decimal odooComboId;
    }

    public class KvaPricingRow implements Comparable {
        @AuraEnabled public String  developerName;
        @AuraEnabled public String  label;
        @AuraEnabled public String  productCode;
        @AuraEnabled public Decimal kvaValue;
        @AuraEnabled public Decimal priceUSD;
        @AuraEnabled public Decimal priceJPY;
        @AuraEnabled public Decimal priceIDR;
        @AuraEnabled public Decimal priceKRW;
        @AuraEnabled public Decimal priceSGD;
        @AuraEnabled public Decimal priceHKD;
        @AuraEnabled public Decimal priceCNY;
        @AuraEnabled public Decimal pricePHP;

        public Integer compareTo(Object other) {
            KvaPricingRow o = (KvaPricingRow) other;
            String a = (this.productCode != null ? this.productCode : 'ZZZ') + '_' + String.valueOf(this.kvaValue != null ? this.kvaValue : 999);
            String b = (o.productCode != null ? o.productCode : 'ZZZ') + '_' + String.valueOf(o.kvaValue != null ? o.kvaValue : 999);
            return a.compareTo(b);
        }
    }

    // ─── Pricebook Sync ─────────────────────────────────────────────────────────

    @AuraEnabled
    public static String syncSitePricebooks() {
        Id jobId = Database.executeBatch(new PricebookSyncBatch(), 50);
        return String.valueOf(jobId);
    }
}