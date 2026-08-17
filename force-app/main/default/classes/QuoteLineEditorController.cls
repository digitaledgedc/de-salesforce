public with sharing class QuoteLineEditorController {

    // DML helper — runs without sharing so users who can view a quote
    // (via the record page) can also edit its line items. CRUD checks
    // are performed in the calling methods before any DML executes.
    private without sharing class DmlHelper {
        void doInsert(List<SObject> records) { insert records; }
        void doInsert(SObject record) { insert record; }
        void doUpdate(List<SObject> records) { update records; }
        void doDelete(List<SObject> records) { delete records; }
        List<Database.SaveResult> doPartialUpdate(List<SObject> records) {
            return Database.update(records, false);
        }
    }

    // ── Pricebook context: site PB + account overlay PB ──────────────────

    @AuraEnabled(cacheable=true)
    public static Map<String, String> getQuotePricebookInfo(Id quoteId) {
        List<Quote> quotes = [
            SELECT Pricebook2Id, Pricebook2.Name,
                   Opportunity.Account.Customer_Pricebook__c,
                   Opportunity.Account.Customer_Pricebook__r.Name
            FROM Quote
            WHERE Id = :quoteId
            WITH SECURITY_ENFORCED
            LIMIT 1
        ];
        if (quotes.isEmpty()) return new Map<String, String>();
        Quote q = quotes[0];
        Map<String, String> info = new Map<String, String>{
            'sitePricebookId'   => q.Pricebook2Id,
            'sitePricebookName' => q.Pricebook2 != null ? q.Pricebook2.Name : null
        };
        if (q.Opportunity?.Account?.Customer_Pricebook__c != null) {
            info.put('accountPricebookId',   q.Opportunity.Account.Customer_Pricebook__c);
            info.put('accountPricebookName', q.Opportunity.Account.Customer_Pricebook__r != null
                ? q.Opportunity.Account.Customer_Pricebook__r.Name : null);
        }
        return info;
    }

    // ── Active approval processes on Quote + related BAN ────────────────
    // Queries ProcessInstance to check what approvals are actually in progress.
    // Returns list of {type, status} for each active approval.
    @AuraEnabled
    public static List<Map<String, String>> getActiveApprovals(Id quoteId) {
        List<Map<String, String>> results = new List<Map<String, String>>();

        // Active approvals on the Quote itself
        for (ProcessInstance pi : [
            SELECT Id, Status,
                   (SELECT Id, StepStatus, Comments, Actor.Name
                    FROM StepsAndWorkitems
                    WHERE StepStatus = 'Pending'
                    ORDER BY CreatedDate DESC LIMIT 1)
            FROM ProcessInstance
            WHERE TargetObjectId = :quoteId
              AND Status = 'Pending'
            ORDER BY CreatedDate ASC
        ]) {
            String stepName = '';
            if (!pi.StepsAndWorkitems.isEmpty()) {
                stepName = pi.StepsAndWorkitems[0].Actor.Name;
            }
            results.add(new Map<String, String>{
                'targetType' => 'Quote',
                'status'     => 'Pending',
                'approver'   => stepName
            });
        }

        // Active approvals on related BANs
        List<BillingAccount__c> bans = [
            SELECT Id, Name FROM BillingAccount__c
            WHERE Source_Quote__c = :quoteId
        ];
        if (!bans.isEmpty()) {
            Set<Id> banIds = new Set<Id>();
            Map<Id, String> banNameMap = new Map<Id, String>();
            for (BillingAccount__c b : bans) {
                banIds.add(b.Id);
                banNameMap.put(b.Id, b.Name);
            }
            for (ProcessInstance pi : [
                SELECT Id, Status, TargetObjectId
                FROM ProcessInstance
                WHERE TargetObjectId IN :banIds
                  AND Status = 'Pending'
            ]) {
                results.add(new Map<String, String>{
                    'targetType' => 'BAN',
                    'status'     => 'Pending',
                    'banName'    => banNameMap.get(pi.TargetObjectId)
                });
            }
        }

        return results;
    }

    @AuraEnabled(cacheable=true)
    public static List<QuoteLineItem> getQuoteLineItems(Id quoteId) {
        if (!Quote.sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED).isAccessible()) {
            throw new AuraHandledException('Insufficient permissions to view Quote Line Items.');
        }
        List<QuoteLineItem> lines = [
            SELECT Id, SortOrder,
                   Product2.Name, Product2.ProductCode, Product2.Family,
                   Product2.Description, Product2.QuantityUnitOfMeasure,
                   Quantity, ListPrice, List_Price__c, UnitPrice, Discount, TotalPrice,
                   BillingFrequency, StartDate, EndDate,
                   Ramp_Phase__c, Ramp_Start_Date__c, Ramp_Invoice_Display__c, Ramp_Line__c, Ramp_Identifier__c, Ramp_Parent_Line__c, Ramp_Linked_Phase__c,
                   Description,
                   Charge_Type__c, Charge_Frequency__c, Billing_Mode__c,
                   Line_Remarks__c, Ramp_Phase_Notes__c,
                   Paired_MRC_Line__c, Is_Auto_NRC__c,
                   Space__c, Inventory__c, CabE__c, Power_kVA__c,
                   Reserved__c,
                   Product_Attribute_Value__c,
                   Custom_Attribute_Value__c,
                   A_Side_Asset__c, Z_Side_Asset__c,
                   Asset__c, Asset__r.Name,
                   Product2.Attribute_Type__c, Product2.Attribute_Values__c,
                   Product2.Product_Attribute__c,
                   Product2.Show_Custom_Attribute_Value__c,
                   Product2.Capacity_Assignment__c,
                   Product2.Merge_IB_Task__c,
                   Line_Origin__c,
                   Merge_IB_Task__c,
                   CurrencyIsoCode,
                   Target_BAN__c,
                   Change_Type__c,
                   Original_OrderItem__c,
                   Original_OrderItem__r.UnitPrice,
                   Original_OrderItem__r.Product_Attribute_Value__c
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
            ORDER BY SortOrder ASC NULLS LAST, CreatedDate ASC
        ];
        return lines;
    }

    @AuraEnabled
    public static List<Map<String, Object>> searchProducts(String searchTerm, Id pricebook2Id, String currencyIsoCode, Id accountPricebookId) {
        String term = '%' + String.escapeSingleQuotes(searchTerm) + '%';

        // Query site pricebook — no currency filter so ALL products at the site
        // are visible regardless of whether a PBE exists in the quote's currency
        List<PricebookEntry> allSitePbes = (List<PricebookEntry>) Security.stripInaccessible(
            AccessType.READABLE,
            [SELECT Id, UnitPrice, CurrencyIsoCode, Product2Id,
                    Product2.Name, Product2.ProductCode, Product2.Family, Product2.QuantityUnitOfMeasure,
                    Product2.Attribute_Type__c, Product2.Attribute_Values__c,
                    Product2.Product_Attribute__c,
                    Product2.Show_Custom_Attribute_Value__c
             FROM PricebookEntry
             WHERE Pricebook2Id = :pricebook2Id
             AND   IsActive = true
             AND   (Product2.Name LIKE :term OR Product2.ProductCode LIKE :term)
             ORDER BY Product2.Name ASC
             LIMIT 200]
        ).getRecords();

        // Deduplicate by Product2Id — prefer currency-matched PBEs
        Map<Id, PricebookEntry> currencyMatchedPbes = new Map<Id, PricebookEntry>();
        List<Id> orderedProductIds = new List<Id>();
        Set<Id> seenProductIds = new Set<Id>();
        Map<Id, PricebookEntry> fallbackPbes = new Map<Id, PricebookEntry>();

        for (PricebookEntry pbe : allSitePbes) {
            Id pid = pbe.Product2Id;
            if (!seenProductIds.contains(pid)) {
                seenProductIds.add(pid);
                orderedProductIds.add(pid);
                fallbackPbes.put(pid, pbe);
            }
            if (pbe.CurrencyIsoCode == currencyIsoCode) {
                currencyMatchedPbes.put(pid, pbe);
            }
        }

        // Build deduped PBE list (top 15 unique products)
        List<PricebookEntry> sitePbes = new List<PricebookEntry>();
        Set<Id> noCurrencyProducts = new Set<Id>();
        Integer cnt = 0;
        for (Id pid : orderedProductIds) {
            if (cnt >= 15) break;
            if (currencyMatchedPbes.containsKey(pid)) {
                sitePbes.add(currencyMatchedPbes.get(pid));
            } else {
                sitePbes.add(fallbackPbes.get(pid));
                noCurrencyProducts.add(pid);
            }
            cnt++;
        }

        // Build account-specific price overlay + find account-only products
        Map<Id, Decimal> accountPriceMap = new Map<Id, Decimal>();
        List<PricebookEntry> accountOnlyPbes = new List<PricebookEntry>();
        if (accountPricebookId != null) {
            // Query ALL matching products in the account pricebook (not just site-overlapping ones)
            List<PricebookEntry> allAccountPbes = (List<PricebookEntry>) Security.stripInaccessible(
                AccessType.READABLE,
                [SELECT Id, UnitPrice, CurrencyIsoCode, Product2Id,
                        Product2.Name, Product2.ProductCode, Product2.Family, Product2.QuantityUnitOfMeasure,
                        Product2.Attribute_Type__c, Product2.Attribute_Values__c,
                        Product2.Product_Attribute__c,
                        Product2.Show_Custom_Attribute_Value__c
                FROM PricebookEntry
                WHERE Pricebook2Id = :accountPricebookId
                  AND IsActive = true
                   AND (Product2.Name LIKE :term OR Product2.ProductCode LIKE :term)
                 ORDER BY Product2.Name ASC
                 LIMIT 50]
            ).getRecords();

            for (PricebookEntry apbe : allAccountPbes) {
                if (seenProductIds.contains(apbe.Product2Id)) {
                    // Product exists in site PB — overlay price if currency matches
                    if (apbe.CurrencyIsoCode == currencyIsoCode) {
                accountPriceMap.put(apbe.Product2Id, apbe.UnitPrice);
                    }
                } else {
                    // Product is ONLY in account PB — add to results
                    if (!seenProductIds.contains(apbe.Product2Id)) {
                        seenProductIds.add(apbe.Product2Id);
                        accountOnlyPbes.add(apbe);
                    }
                }
            }
        }

        List<Map<String, Object>> results = new List<Map<String, Object>>();
        // Site pricebook products
        for (PricebookEntry pbe : sitePbes) {
            Boolean noCurrency = noCurrencyProducts.contains(pbe.Product2Id);
            Map<String, Object> row = new Map<String, Object>{
                'pbeId'       => pbe.Id,
                'productName' => pbe.Product2.Name,
                'productCode' => pbe.Product2.ProductCode,
                'family'      => pbe.Product2.Family,
                'unit'        => pbe.Product2.QuantityUnitOfMeasure,
                'unitPrice'   => noCurrency ? 0 : pbe.UnitPrice,
                'productAttribute'    => pbe.Product2.Product_Attribute__c,
                'showCustomValue'     => pbe.Product2.Show_Custom_Attribute_Value__c,
                'noCurrencyEntry'     => noCurrency
            };
            // Overlay account-specific price where it exists
            if (accountPriceMap.containsKey(pbe.Product2Id)) {
                row.put('accountPrice', accountPriceMap.get(pbe.Product2Id));
                row.put('priceSource', 'account');
            } else {
                row.put('priceSource', 'list');
            }
            results.add(row);
        }
        // Account-pricebook-only products (not in the site pricebook)
        for (PricebookEntry apbe : accountOnlyPbes) {
            Boolean noCurrency = apbe.CurrencyIsoCode != currencyIsoCode;
            results.add(new Map<String, Object>{
                'pbeId'       => apbe.Id,
                'productName' => apbe.Product2.Name,
                'productCode' => apbe.Product2.ProductCode,
                'family'      => apbe.Product2.Family,
                'unit'        => apbe.Product2.QuantityUnitOfMeasure,
                'unitPrice'   => noCurrency ? 0 : apbe.UnitPrice,
                'productAttribute'    => apbe.Product2.Product_Attribute__c,
                'showCustomValue'     => apbe.Product2.Show_Custom_Attribute_Value__c,
                'noCurrencyEntry'     => noCurrency,
                'accountPrice'        => noCurrency ? 0 : apbe.UnitPrice,
                'priceSource'         => 'account'
            });
        }
        return results;
    }

    @AuraEnabled
    public static void addProductToQuote(Id quoteId, Id pricebookEntryId, Decimal quantity, Decimal overrideUnitPrice) {
        // No stripInaccessible here — this is a system read to map product
        // config onto the QLI, not a user-facing query.  CRUD gate follows.
        PricebookEntry pbe = [
            SELECT Id, Pricebook2Id, Product2Id, UnitPrice, CurrencyIsoCode,
                   Product2.ProductCode, Product2.Charge_Type__c,
                   Product2.Charge_Frequency__c, Product2.Billing_Charge_Type__c,
                   Product2.Odoo_Product_Id__c, Product2.Merge_IB_Task__c
            FROM PricebookEntry WHERE Id = :pricebookEntryId
            LIMIT 1
        ];

        // Ensure PBE currency matches the quote — auto-create PBE if needed
        // (products visible at $0 because they only have a different-currency PBE)
        Quote q = [SELECT CurrencyIsoCode, Pricebook2Id FROM Quote WHERE Id = :quoteId LIMIT 1];
        String quoteCurr = q.CurrencyIsoCode;
        if (pbe.CurrencyIsoCode != quoteCurr) {
            pbe = ensureCurrencyPbe(pbe, quoteCurr);
        }

        // Ensure PBE belongs to the Quote's pricebook — auto-create if it's from
        // an account-specific pricebook (product visible via account overlay but
        // has no entry in the site pricebook the Quote uses)
        if (pbe.Pricebook2Id != q.Pricebook2Id) {
            pbe = ensureQuotePricebookEntry(pbe, q.Pricebook2Id, quoteCurr);
        }

        if (!Quote.sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED).isAccessible()) {
            throw new AuraHandledException('Insufficient permissions to access Quote.');
        }
        try {
            // Each add creates a new QLI — no merging with existing lines

            // Use account-specific price when provided, otherwise site list price
            Decimal effectivePrice = (overrideUnitPrice != null) ? overrideUnitPrice : pbe.UnitPrice;
            QuoteLineItem qli = new QuoteLineItem(
                QuoteId          = quoteId,
                PricebookEntryId = pbe.Id,
                Product2Id       = pbe.Product2Id,
                Quantity         = quantity,
                UnitPrice        = effectivePrice,
                List_Price__c    = effectivePrice
            );
            qli.Line_Origin__c = 'New';
            // ── Copy product-level fields to QLI ────────────────────────
            Product2 prod = pbe.Product2;

            // Charge Type: use product's value, fallback to code convention
            if (String.isNotBlank(prod.Charge_Type__c)) {
                qli.Charge_Type__c = prod.Charge_Type__c;
            } else {
                String code = prod.ProductCode;
                if (String.isNotBlank(code)) {
                    if (code.toUpperCase().endsWith('.NR')) {
                        qli.Charge_Type__c = 'NRC';
                    } else if (code.toUpperCase().endsWith('.RC')) {
                        qli.Charge_Type__c = 'MRC';
                    }
                }
            }
            // Charge Frequency
            if (String.isNotBlank(prod.Charge_Frequency__c)) {
                qli.Charge_Frequency__c = prod.Charge_Frequency__c;
            }
            // Billing Mode (Product2.Billing_Charge_Type__c → QLI.Billing_Mode__c)
            // Product2 stores ADVANCE/ARREAR; QLI picklist expects Advance/Arrear
            if (String.isNotBlank(prod.Billing_Charge_Type__c)) {
                String bct = prod.Billing_Charge_Type__c.toLowerCase();
                qli.Billing_Mode__c = bct.substring(0, 1).toUpperCase() + bct.substring(1);
            }
            // Odoo Product ID
            if (prod.Odoo_Product_Id__c != null) {
                qli.Odoo_Product_ID__c = prod.Odoo_Product_Id__c;
            }
            // Merge IB Task flag (integration)
            qli.Merge_IB_Task__c = prod.Merge_IB_Task__c == true;
            // NRC lines are not reservable
            if (qli.Charge_Type__c == 'NRC') {
                qli.Reserved__c = 'N/A';
            }

            new DmlHelper().doInsert(qli);

            // ── Auto-add Additional Charge products ──────────────────────
            // If this product has additional charge children (usage/overage),
            // add them to the quote automatically.
            List<Product2> addlChargeProducts = [
                SELECT Id, ProductCode
                FROM Product2
                WHERE Additional_Charge_Of__c = :pbe.Product2Id
                  AND IsActive = true
            ];
            if (!addlChargeProducts.isEmpty()) {
                Set<Id> acProductIds = new Set<Id>();
                for (Product2 acp : addlChargeProducts) {
                    acProductIds.add(acp.Id);
                }
                List<PricebookEntry> acPbes = [
                    SELECT Id, Product2Id, UnitPrice,
                           Product2.ProductCode, Product2.Charge_Frequency__c,
                           Product2.Billing_Charge_Type__c, Product2.Odoo_Product_Id__c
                    FROM PricebookEntry
                    WHERE Pricebook2Id = :pbe.Pricebook2Id
                      AND Product2Id IN :acProductIds
                      AND IsActive = true
                      AND CurrencyIsoCode = :quoteCurr
                ];
                List<QuoteLineItem> acLines = new List<QuoteLineItem>();
                for (PricebookEntry acPbe : acPbes) {
                    QuoteLineItem acQli = new QuoteLineItem(
                        QuoteId          = quoteId,
                        PricebookEntryId = acPbe.Id,
                        Product2Id       = acPbe.Product2Id,
                        Quantity         = quantity,
                        UnitPrice        = acPbe.UnitPrice,
                        Charge_Type__c   = 'Additional Charge',
                        Line_Origin__c   = 'New'
                    );
                    Product2 acProd = acPbe.Product2;
                    if (String.isNotBlank(acProd.Charge_Frequency__c)) {
                        acQli.Charge_Frequency__c = acProd.Charge_Frequency__c;
                    }
                    if (String.isNotBlank(acProd.Billing_Charge_Type__c)) {
                        String bct = acProd.Billing_Charge_Type__c.toLowerCase();
                        acQli.Billing_Mode__c = bct.substring(0, 1).toUpperCase() + bct.substring(1);
                    }
                    if (acProd.Odoo_Product_Id__c != null) {
                        acQli.Odoo_Product_ID__c = acProd.Odoo_Product_Id__c;
                    }
                    acLines.add(acQli);
                }
                if (!acLines.isEmpty()) {
                    new DmlHelper().doInsert(acLines);
                }
            }

            // ── Auto-add NRC installation charge (.RC → .NR) ────────────
            // Create the paired NRC QLI synchronously so the LWC shows
            // both lines immediately. The async NrcPairingService flow
            // has a duplicate guard and will skip if it already exists.
            // ── Auto-add NRC installation charge (.RC → .NR) ────────────
            // Each MRC line gets its own paired NRC — no duplicate check.
            // The async NrcPairingService flow has its own guard and will skip.
            String productCode = prod.ProductCode;
            if (String.isNotBlank(productCode) && productCode.toUpperCase().endsWith('.RC')) {
                String nrcCode = buildNrcCode(productCode);
                if (nrcCode != null) {
                    List<PricebookEntry> nrcPbes = (List<PricebookEntry>) Security.stripInaccessible(
                        AccessType.READABLE,
                        [SELECT Id, Product2Id, UnitPrice,
                                Product2.Charge_Frequency__c,
                                Product2.Billing_Charge_Type__c,
                                Product2.Odoo_Product_Id__c
                         FROM PricebookEntry
                         WHERE Pricebook2Id = :pbe.Pricebook2Id
                           AND Product2.ProductCode = :nrcCode
                           AND IsActive = true
                           AND CurrencyIsoCode = :quoteCurr
                         LIMIT 1]
                    ).getRecords();
                    if (!nrcPbes.isEmpty()) {
                        PricebookEntry nrcPbe = nrcPbes[0];
                        QuoteLineItem nrcQli = new QuoteLineItem(
                            QuoteId          = quoteId,
                            PricebookEntryId = nrcPbe.Id,
                            Product2Id       = nrcPbe.Product2Id,
                            Quantity         = quantity,
                            UnitPrice        = nrcPbe.UnitPrice,
                            Paired_MRC_Line__c = qli.Id,
                            Is_Auto_NRC__c   = true,
                            Charge_Type__c   = 'NRC',
                            Line_Origin__c   = 'New'
                        );
                        Product2 nrcProd = nrcPbe.Product2;
                        if (String.isNotBlank(nrcProd.Charge_Frequency__c)) {
                            nrcQli.Charge_Frequency__c = nrcProd.Charge_Frequency__c;
                        }
                        if (String.isNotBlank(nrcProd.Billing_Charge_Type__c)) {
                            String bct = nrcProd.Billing_Charge_Type__c.toLowerCase();
                            nrcQli.Billing_Mode__c = bct.substring(0, 1).toUpperCase() + bct.substring(1);
                        }
                        if (nrcProd.Odoo_Product_Id__c != null) {
                            nrcQli.Odoo_Product_ID__c = nrcProd.Odoo_Product_Id__c;
                        }
                        new DmlHelper().doInsert(nrcQli);
                    }
                }
            }
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static void updateQuoteLineItems(List<QuoteLineItem> lines) {
        if (!Quote.sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED).isAccessible()) {
            throw new AuraHandledException('Insufficient permissions to access Quote Line Items.');
        }
        for (QuoteLineItem l : lines) {
            ensureDatesNotSameDay(l);
        }
        try {
            new DmlHelper().doUpdate(lines);
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        }

        // ── MRC → NRC quantity cascade ──────────────────────────────────
        // After updating MRC lines, propagate Quantity to paired NRC lines.
        // SKIP if the MRC line has a Change_Type__c value (change order line)
        Set<Id> updatedIds = new Set<Id>();
        Map<Id, Decimal> idToQty = new Map<Id, Decimal>();
        
        // First, collect which MRC lines were updated
        for (QuoteLineItem l : lines) {
            if (l.Quantity != null) {
                updatedIds.add(l.Id);
                idToQty.put(l.Id, l.Quantity);
            }
        }
        if (updatedIds.isEmpty()) return;

        // Reload updated lines to get product code, quote context, and Change_Type
        List<QuoteLineItem> updatedMrcs = (List<QuoteLineItem>) Security.stripInaccessible(
            AccessType.READABLE,
            [SELECT Id, QuoteId, Product2.ProductCode, Product2.Paired_NRC_Product__c, 
                    Quantity, Change_Type__c
            FROM QuoteLineItem
            WHERE Id IN :updatedIds
            AND Product2.ProductCode LIKE '%.RC']
        ).getRecords();
        if (updatedMrcs.isEmpty()) return;

        // ── Filter out MRC lines that have Change_Type ──
        List<QuoteLineItem> mrcsToProcess = new List<QuoteLineItem>();
        Set<Id> skippedMrcIds = new Set<Id>();
        for (QuoteLineItem m : updatedMrcs) {
            // Skip if this MRC has a Change_Type value (change order line)
            if (m.Change_Type__c != null && m.Change_Type__c != '') {
                skippedMrcIds.add(m.Id);
                continue;
            }
            mrcsToProcess.add(m);
        }

        // If all MRCs were skipped, exit early
        if (mrcsToProcess.isEmpty()) {
            System.debug('Skipped NRC processing for MRC lines with Change_Type: ' + skippedMrcIds);
            return;
        }

        // Collect quote IDs and NRC info only for non-skipped MRCs
        Set<Id> quoteIds = new Set<Id>();
        Set<String> nrcCodes = new Set<String>();
        Set<Id> nrcProductIds = new Set<Id>();
        for (QuoteLineItem m : mrcsToProcess) {
            quoteIds.add(m.QuoteId);
            String nrcCode = buildNrcCode(m.Product2.ProductCode);
            if (nrcCode != null) nrcCodes.add(nrcCode);
            Id pairedNrcProdId = m.Product2.Paired_NRC_Product__c;
            if (pairedNrcProdId != null) nrcProductIds.add(pairedNrcProdId);
        }

        // Find NRC lines for eligible MRCs only
        List<QuoteLineItem> nrcLines = (List<QuoteLineItem>) Security.stripInaccessible(
            AccessType.READABLE,
            [SELECT Id, Quantity, Paired_MRC_Line__c,
                    Product2.ProductCode, Product2Id, QuoteId
            FROM QuoteLineItem
            WHERE QuoteId IN :quoteIds
            AND (Paired_MRC_Line__c IN :mrcsToProcess  // Only process eligible MRCs
                    OR Product2.ProductCode IN :nrcCodes
                    OR Product2Id IN :nrcProductIds)]
        ).getRecords();

        // Build NRC qty by summing ALL MRC lines that share the same NRC product
        // But ONLY include non-skipped MRCs
        List<QuoteLineItem> nrcUpdates = new List<QuoteLineItem>();
        {
            // Collect NRC Product2Ids from found NRC lines
            for (QuoteLineItem nrc : nrcLines) {
                nrcProductIds.add(nrc.Product2Id);
            }
            
            // Find ALL MRC lines whose Paired_NRC_Product__c points to these NRC products
            // But only include those WITHOUT Change_Type
            Map<String, Decimal> keyToMrcTotal = new Map<String, Decimal>();
            List<QuoteLineItem> allMrcLines = (List<QuoteLineItem>) Security.stripInaccessible(
                AccessType.READABLE,
                [SELECT Id, QuoteId, Product2.Paired_NRC_Product__c, Quantity, Change_Type__c
                FROM QuoteLineItem
                WHERE QuoteId IN :quoteIds
                AND Product2.Paired_NRC_Product__c IN :nrcProductIds
                AND (Change_Type__c = null OR Change_Type__c = '')]  // Exclude change order lines
            ).getRecords();
            
            for (QuoteLineItem allMrc : allMrcLines) {
                Id nrcProdId = allMrc.Product2.Paired_NRC_Product__c;
                if (nrcProdId == null) continue;
                // Use draft qty if this line was updated
                Decimal qty = idToQty.containsKey(allMrc.Id)
                    ? idToQty.get(allMrc.Id) : allMrc.Quantity;
                String key = allMrc.QuoteId + '_' + nrcProdId;
                Decimal cur = keyToMrcTotal.containsKey(key) ? keyToMrcTotal.get(key) : 0;
                keyToMrcTotal.put(key, cur + (qty != null ? qty : 0));
            }

            for (QuoteLineItem nrc : nrcLines) {
                String key = nrc.QuoteId + '_' + nrc.Product2Id;
                if (keyToMrcTotal.containsKey(key)) {
                    Decimal total = keyToMrcTotal.get(key);
                    // Only update if the NRC's Paired_MRC_Line__c is NOT skipped
                    // This prevents updating NRCs that belong to skipped MRCs
                    if (nrc.Paired_MRC_Line__c != null && !skippedMrcIds.contains(nrc.Paired_MRC_Line__c)) {
                        if (nrc.Quantity != total) {
                            nrcUpdates.add(new QuoteLineItem(
                                Id = nrc.Id, Quantity = total
                            ));
                        }
                    }
                }
            }
        }

        if (!nrcUpdates.isEmpty()) new DmlHelper().doPartialUpdate(nrcUpdates);
        
        // Log skipped MRCs for audit trail
        if (!skippedMrcIds.isEmpty()) {
            System.debug('Skipped NRC processing for MRC lines with Change_Type: ' + skippedMrcIds);
        }
    }

    /** Safely converts JSON.deserializeUntyped values (Integer/Double) to Decimal. */
    private static Decimal toDecimal(Object val) {
        if (val == null) return null;
        if (val instanceof Decimal) return (Decimal) val;
        return Decimal.valueOf(String.valueOf(val));
    }

    /**
     * Salesforce platform rejects Quantity = 0 on QuoteLineItem.
     * Returns true if qty is effectively zero (null or 0).
     * Callers should skip creating QLIs for zero-qty phases.
     */
    private static Boolean isZeroQty(Decimal qty) {
        return qty == null || qty == 0;
    }

    /** Converts .RC product code to .NR counterpart. Shared with NrcPairingService. */
    private static String buildNrcCode(String productCode) {
        if (String.isBlank(productCode) || !productCode.endsWith('.RC')) return null;
        String base = productCode.removeEnd('.RC');
        if (Pattern.matches('.*\\d[A-Z]$', base)) {
            base = base.left(base.length() - 1);
        }
        return base + '.NR';
    }

    /**
     * Finds or creates a PBE in the target currency for the same pricebook + product.
     * Used when a product exists at a site but has no PBE in the quote's currency —
     * the product shows at $0 and this method creates the missing PBE on Add.
     */
    private static PricebookEntry ensureCurrencyPbe(PricebookEntry sourcePbe, String targetCurrency) {
        // Check for existing PBE in the site pricebook for this currency
        List<PricebookEntry> existing = [
            SELECT Id, Pricebook2Id, Product2Id, UnitPrice, CurrencyIsoCode,
                   Product2.ProductCode, Product2.Charge_Type__c,
                   Product2.Charge_Frequency__c, Product2.Billing_Charge_Type__c,
                   Product2.Odoo_Product_Id__c, Product2.Merge_IB_Task__c
            FROM PricebookEntry
            WHERE Pricebook2Id = :sourcePbe.Pricebook2Id
              AND Product2Id = :sourcePbe.Product2Id
              AND CurrencyIsoCode = :targetCurrency
              AND IsActive = true
            LIMIT 1
        ];
        if (!existing.isEmpty()) return existing[0];

        // Ensure Standard Pricebook has an entry for this currency.
        // WHERE IsStandard = true returns zero rows in Apex test context even
        // after Test.getStandardPricebookId() has been called elsewhere — a
        // platform limitation, not something a test can work around.
        Id stdPbId = Test.isRunningTest()
            ? Test.getStandardPricebookId()
            : [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;
        List<PricebookEntry> stdEntries = [
            SELECT Id FROM PricebookEntry
            WHERE Pricebook2Id = :stdPbId
              AND Product2Id = :sourcePbe.Product2Id
              AND CurrencyIsoCode = :targetCurrency
              AND IsActive = true
            LIMIT 1
        ];
        if (stdEntries.isEmpty()) {
            new DmlHelper().doInsert(new PricebookEntry(
                Pricebook2Id    = stdPbId,
                Product2Id      = sourcePbe.Product2Id,
                UnitPrice       = 0,
                CurrencyIsoCode = targetCurrency,
                IsActive        = true
            ));
        }

        // Create site pricebook entry at $0
        PricebookEntry newPbe = new PricebookEntry(
            Pricebook2Id    = sourcePbe.Pricebook2Id,
            Product2Id      = sourcePbe.Product2Id,
            UnitPrice       = 0,
            CurrencyIsoCode = targetCurrency,
            IsActive        = true
        );
        new DmlHelper().doInsert(newPbe);

        // Re-query to get all product fields (must match addProductToQuote's source query)
        return [
            SELECT Id, Pricebook2Id, Product2Id, UnitPrice, CurrencyIsoCode,
                   Product2.ProductCode, Product2.Charge_Type__c,
                   Product2.Charge_Frequency__c, Product2.Billing_Charge_Type__c,
                   Product2.Odoo_Product_Id__c, Product2.Merge_IB_Task__c
            FROM PricebookEntry WHERE Id = :newPbe.Id
            LIMIT 1
        ];
    }

    /**
     * Ensure the product has a PricebookEntry in the Quote's pricebook.
     * Called when a product was found via an account-specific pricebook overlay
     * but has no entry in the site pricebook the Quote uses.
     */
    private static PricebookEntry ensureQuotePricebookEntry(PricebookEntry sourcePbe, Id quotePricebookId, String quoteCurrency) {
        // Check if a PBE already exists in the Quote's pricebook for this product + currency
        List<PricebookEntry> existing = [
            SELECT Id, Pricebook2Id, Product2Id, UnitPrice, CurrencyIsoCode,
                   Product2.ProductCode, Product2.Charge_Type__c,
                   Product2.Charge_Frequency__c, Product2.Billing_Charge_Type__c,
                   Product2.Odoo_Product_Id__c, Product2.Merge_IB_Task__c
            FROM PricebookEntry
            WHERE Pricebook2Id = :quotePricebookId
              AND Product2Id = :sourcePbe.Product2Id
              AND CurrencyIsoCode = :quoteCurrency
              AND IsActive = true
            LIMIT 1
        ];
        if (!existing.isEmpty()) return existing[0];

        // Ensure Standard Pricebook has an entry for this currency.
        // WHERE IsStandard = true returns zero rows in Apex test context even
        // after Test.getStandardPricebookId() has been called elsewhere — a
        // platform limitation, not something a test can work around.
        Id stdPbId = Test.isRunningTest()
            ? Test.getStandardPricebookId()
            : [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;
        List<PricebookEntry> stdEntries = [
            SELECT Id FROM PricebookEntry
            WHERE Pricebook2Id = :stdPbId
              AND Product2Id = :sourcePbe.Product2Id
              AND CurrencyIsoCode = :quoteCurrency
              AND IsActive = true
            LIMIT 1
        ];
        if (stdEntries.isEmpty()) {
            new DmlHelper().doInsert(new PricebookEntry(
                Pricebook2Id    = stdPbId,
                Product2Id      = sourcePbe.Product2Id,
                UnitPrice       = 0,
                CurrencyIsoCode = quoteCurrency,
                IsActive        = true
            ));
        }

        // Create PBE in the Quote's pricebook at $0 (actual price comes from override)
        PricebookEntry newPbe = new PricebookEntry(
            Pricebook2Id    = quotePricebookId,
            Product2Id      = sourcePbe.Product2Id,
            UnitPrice       = 0,
            CurrencyIsoCode = quoteCurrency,
            IsActive        = true
        );
        new DmlHelper().doInsert(newPbe);

        return [
            SELECT Id, Pricebook2Id, Product2Id, UnitPrice, CurrencyIsoCode,
                   Product2.ProductCode, Product2.Charge_Type__c,
                   Product2.Charge_Frequency__c, Product2.Billing_Charge_Type__c,
                   Product2.Odoo_Product_Id__c, Product2.Merge_IB_Task__c
            FROM PricebookEntry WHERE Id = :newPbe.Id
            LIMIT 1
        ];
    }

    /**
     * Bulk ramp split — processes all MRC lines in a single transaction.
     * Batches all DML across products to minimise flow/trigger re-entry
     * and stay within the 100 SOQL governor limit.
     * @param bulkPayloadJson JSON array of { sourceLineId, phasesJson }
     * @param rampType 'attribute' (always)
     */
    @AuraEnabled
    public static void splitRampLinesBulk(String bulkPayloadJson, String rampType) {
        if (!Quote.sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED).isAccessible()) {
            throw new AuraHandledException('Insufficient permissions to access Quote.');
        }
        try {
        // Defer the MRC/TCV rollup so the Quote-update -> flow/credit cascade runs
        // ONCE after all ramp DMLs instead of on every intermediate DML (was
        // hitting "Too many SOQL queries: 101" on multi-product ramps).
        QuoteMrcRollupService.beginDefer();

        Boolean isPriceRamp     = 'price'.equalsIgnoreCase(rampType);
        Boolean isAttributeRamp = 'attribute'.equalsIgnoreCase(rampType);

        List<Object> items = (List<Object>) JSON.deserializeUntyped(bulkPayloadJson);
        if (items.isEmpty()) return;

        // ── 1. Collect all source line IDs and parse phases ──
        Set<Id> allSourceIds = new Set<Id>();
        List<Map<String, Object>> entries = new List<Map<String, Object>>();
        for (Object item : items) {
            Map<String, Object> entry = (Map<String, Object>) item;
            Id srcId = (Id) entry.get('sourceLineId');
            allSourceIds.add(srcId);
            entries.add(entry);
        }

        // Single bulk query for all source QLIs
        Map<Id, QuoteLineItem> srcById = new Map<Id, QuoteLineItem>([
            SELECT Id, QuoteId, Product2Id, PricebookEntryId,
                   Quantity, UnitPrice,
                   StartDate, EndDate,
                   Description, SortOrder,
                   Product_Attribute_Value__c, Custom_Attribute_Value__c,
                   Charge_Type__c, Ramp_Invoice_Display__c, Line_Remarks__c,
                   Product2.ProductCode
            FROM QuoteLineItem
            WHERE Id IN :allSourceIds
        ]);

        // ── 2. Build Phase 1 updates and Phase 2+ inserts for all products ──
        List<QuoteLineItem> allP1Updates = new List<QuoteLineItem>();
        List<QuoteLineItem> allNewMrc    = new List<QuoteLineItem>();
        // Track per-source: end dates and indices for date patching later
        Map<Id, List<Date>>    endDatesBySrc   = new Map<Id, List<Date>>();
        Map<Id, List<Integer>> mrcIndicesBySrc = new Map<Id, List<Integer>>();
        // Track which source each new MRC line belongs to (for NRC pairing)
        List<Id> newMrcSourceIds = new List<Id>();

        for (Map<String, Object> entry : entries) {
            Id srcId = (Id) entry.get('sourceLineId');
            QuoteLineItem src = srcById.get(srcId);
            if (src == null) continue;
            String origRemarks = src.Line_Remarks__c;

            List<Object> rawPhases = (List<Object>) JSON.deserializeUntyped((String) entry.get('phasesJson'));
            if (rawPhases.isEmpty()) continue;

            // Collect end dates
            List<Date> phaseEndDates = new List<Date>();
            for (Object raw : rawPhases) {
                Map<String, Object> pm = (Map<String, Object>) raw;
                String eStr = (String) pm.get('endDate');
                phaseEndDates.add(String.isNotBlank(eStr) ? Date.valueOf(eStr) : null);
            }
            endDatesBySrc.put(srcId, phaseEndDates);

            // Phase 1 — update source in place
            Map<String, Object> p1 = (Map<String, Object>) rawPhases[0];
            if (isPriceRamp) {
                src.UnitPrice = toDecimal(p1.get('unitPrice'));
            } else if (isAttributeRamp) {
                Decimal p1Qty = toDecimal(p1.get('quantity'));
                src.Quantity  = isZeroQty(p1Qty) ? 1 : p1Qty;
                src.UnitPrice = toDecimal(p1.get('unitPrice'));
                src.Product_Attribute_Value__c = (String) p1.get('attributeValue');
                if (p1.containsKey('customValue') && p1.get('customValue') != null) {
                    src.Custom_Attribute_Value__c = Decimal.ValueOf(String.valueOf(p1.get('customValue')));
                }
            } else {
                Decimal p1Qty = toDecimal(p1.get('quantity'));
                src.Quantity = isZeroQty(p1Qty) ? 1 : p1Qty;
            }
            src.StartDate           = Date.valueOf((String) p1.get('startDate'));
            src.EndDate             = null;
            src.Ramp_Phase__c       = p1.containsKey('globalPhase') ? toDecimal(p1.get('globalPhase')) : 1;
            src.Ramp_Start_Date__c  = src.StartDate;
            src.Line_Origin__c      = 'Ramp';
            src.Ramp_Line__c        = true;
            // FB-815: the modal note is per-PHASE, so writing it to Line_Remarks__c
            // overwrote each product's own per-line remark with one shared string.
            // Phase notes now land in Ramp_Phase_Notes__c; Line_Remarks__c is the
            // user's to edit and is left untouched here.
            if (p1.containsKey('notes')) {
                src.Ramp_Phase_Notes__c = p1.get('notes') == null ? null : String.valueOf(p1.get('notes'));
            }
            if (p1.containsKey('invoiceDisplay') && p1.get('invoiceDisplay') != null) {
                src.Ramp_Invoice_Display__c = String.valueOf(p1.get('invoiceDisplay'));
            }
            if (p1.containsKey('rampIdentifier')) {
                src.Ramp_Identifier__c = String.valueOf(p1.get('rampIdentifier'));
            }
            if (p1.containsKey('rampLinkedPhase') && p1.get('rampLinkedPhase') != null) {
                src.Ramp_Linked_Phase__c = toDecimal(p1.get('rampLinkedPhase'));
            } else {
                src.Ramp_Linked_Phase__c = null;
            }
            allP1Updates.add(src);

            // Phases 2+ — build new MRC lines
            List<Integer> mrcPhaseIndices = new List<Integer>();
            if (rawPhases.size() > 1) {
                for (Integer i = 1; i < rawPhases.size(); i++) {
                    Map<String, Object> p = (Map<String, Object>) rawPhases[i];
                    Decimal phaseQty;
                    if (isPriceRamp) {
                        phaseQty = src.Quantity;
                    } else {
                        phaseQty = toDecimal(p.get('quantity'));
                    }
                    if (isZeroQty(phaseQty)) continue;

                    Date sDate = Date.valueOf((String) p.get('startDate'));
                    QuoteLineItem newLine = new QuoteLineItem(
                        QuoteId                 = src.QuoteId,
                        PricebookEntryId        = src.PricebookEntryId,
                        Product2Id              = src.Product2Id,
                        StartDate               = sDate,
                        EndDate                 = null,
                        Description             = src.Description,
                        SortOrder               = src.SortOrder,
                        Charge_Type__c          = src.Charge_Type__c,
                        Ramp_Phase__c           = p.containsKey('globalPhase') ? toDecimal(p.get('globalPhase')) : (i + 1),
                        Ramp_Start_Date__c      = sDate,
                        Ramp_Invoice_Display__c = src.Ramp_Invoice_Display__c,
                        Product_Attribute_Value__c = src.Product_Attribute_Value__c,
                        Line_Origin__c          = 'Ramp',
                        Ramp_Line__c            = true,
                        Ramp_Parent_Line__c     = src.Id,
                        Reserved__c             = 'N/A',
                        Quantity                = phaseQty,
                        Line_Remarks__c         = origRemarks
                    );
                    if (isPriceRamp) {
                        newLine.UnitPrice = toDecimal(p.get('unitPrice'));
                    } else if (isAttributeRamp) {
                        newLine.UnitPrice = toDecimal(p.get('unitPrice'));
                        newLine.Product_Attribute_Value__c = (String) p.get('attributeValue');
                        if (p.containsKey('customValue') && p.get('customValue') != null) {
                            newLine.Custom_Attribute_Value__c = Decimal.ValueOf(String.valueOf(p.get('customValue')));
                        }
                    } else {
                        newLine.UnitPrice = src.UnitPrice;
                    }
                    // FB-815: phase note → Ramp_Phase_Notes__c. Line_Remarks__c keeps
                    // origRemarks (set in the constructor above) so the source line's
                    // remark still carries forward to every phase.
                    if (p.containsKey('notes')) {
                        newLine.Ramp_Phase_Notes__c = p.get('notes') == null ? null : String.valueOf(p.get('notes'));
                    }
                    if (p.containsKey('invoiceDisplay') && p.get('invoiceDisplay') != null) {
                        newLine.Ramp_Invoice_Display__c = String.valueOf(p.get('invoiceDisplay'));
                    }
                    if (p.containsKey('rampIdentifier')) {
                        newLine.Ramp_Identifier__c = String.valueOf(p.get('rampIdentifier'));
                    }
                    if (p.containsKey('rampLinkedPhase') && p.get('rampLinkedPhase') != null) {
                        newLine.Ramp_Linked_Phase__c = toDecimal(p.get('rampLinkedPhase'));
                    }
                    allNewMrc.add(newLine);
                    newMrcSourceIds.add(srcId);
                    mrcPhaseIndices.add(i);
                }
            }
            mrcIndicesBySrc.put(srcId, mrcPhaseIndices);
        }

        // ── 3. Bulk DML: Phase 1 updates, then Phase 2+ inserts ──
        if (!allP1Updates.isEmpty()) {
            new DmlHelper().doUpdate(allP1Updates);
        }
        if (!allNewMrc.isEmpty()) {
            new DmlHelper().doInsert(allNewMrc);
        }

        // ── 4. Query ALL NRC pairs in one SOQL ──
        // Primary: by Paired_MRC_Line__c lookup
        Map<Id, QuoteLineItem> nrcByMrc = new Map<Id, QuoteLineItem>();
        for (QuoteLineItem nrc : [
            SELECT Id, QuoteId, Product2Id, PricebookEntryId,
                   UnitPrice, Description, SortOrder, Quantity,
                   Charge_Type__c, Ramp_Invoice_Display__c,
                   Is_Auto_NRC__c, Paired_MRC_Line__c
            FROM QuoteLineItem
            WHERE Paired_MRC_Line__c IN :allSourceIds
              AND Line_Origin__c != 'Ramp'
        ]) {
            nrcByMrc.put(nrc.Paired_MRC_Line__c, nrc);
        }
        // Fallback: by product code convention (.RC -> .NR)
        Set<Id> missingNrcSources = new Set<Id>();
        Map<Id, String> nrcCodeBySrc = new Map<Id, String>();
        for (Id srcId : allSourceIds) {
            if (!nrcByMrc.containsKey(srcId)) {
                QuoteLineItem src = srcById.get(srcId);
                if (src == null) continue;
                if (src.Product2.ProductCode != null && src.Product2.ProductCode.endsWithIgnoreCase('.RC')) {
                    missingNrcSources.add(srcId);
                    nrcCodeBySrc.put(srcId, src.Product2.ProductCode.removeEndIgnoreCase('.RC') + '.NR');
                }
            }
        }
        if (!missingNrcSources.isEmpty()) {
            Set<String> nrcCodes = new Set<String>(nrcCodeBySrc.values());
            Id anyQuoteId = srcById.values()[0].QuoteId;
            Map<String, QuoteLineItem> nrcByCode = new Map<String, QuoteLineItem>();
            for (QuoteLineItem nrc : [
                SELECT Id, QuoteId, Product2Id, Product2.ProductCode, PricebookEntryId,
                       UnitPrice, Description, SortOrder, Quantity,
                       Charge_Type__c, Ramp_Invoice_Display__c,
                       Is_Auto_NRC__c, Paired_MRC_Line__c
                FROM QuoteLineItem
                WHERE QuoteId = :anyQuoteId
                  AND Product2.ProductCode IN :nrcCodes
                  AND Line_Origin__c != 'Ramp'
            ]) {
                nrcByCode.put(nrc.Product2.ProductCode, nrc);
            }
            // FB: two MRC lines of the SAME product (e.g. CAB001.RC 2kVA and
            // CAB001.RC 3kVA) both resolve to the SAME .NR line by code. Claiming it
            // twice put one record id in the update list twice -> "Duplicate id in
            // list". One NRC belongs to one MRC line; aggregateRampNrcQty already sums
            // quantity across every MRC line sharing that NRC product per phase.
            Set<Id> claimedNrcIds = new Set<Id>();
            for (QuoteLineItem claimed : nrcByMrc.values()) {
                claimedNrcIds.add(claimed.Id);
            }
            for (Id srcId : missingNrcSources) {
                String code = nrcCodeBySrc.get(srcId);
                QuoteLineItem nrc = nrcByCode.get(code);
                if (nrc != null && !claimedNrcIds.contains(nrc.Id)) {
                    nrc.Paired_MRC_Line__c = srcId;
                    nrcByMrc.put(srcId, nrc);
                    claimedNrcIds.add(nrc.Id);
                }
            }
        }

        // ── 5. Build NRC Phase 1 updates + Phase 2+ inserts ──
        Map<Id, QuoteLineItem> allNrcP1Updates = new Map<Id, QuoteLineItem>();
        List<QuoteLineItem> allNewNrc       = new List<QuoteLineItem>();

        // Build a map of new MRC lines by source ID for NRC cloning
        Map<Id, List<QuoteLineItem>> newMrcBySrc = new Map<Id, List<QuoteLineItem>>();
        for (Integer i = 0; i < allNewMrc.size(); i++) {
            Id srcId = newMrcSourceIds[i];
            if (!newMrcBySrc.containsKey(srcId)) {
                newMrcBySrc.put(srcId, new List<QuoteLineItem>());
            }
            newMrcBySrc.get(srcId).add(allNewMrc[i]);
        }

        for (Id srcId : allSourceIds) {
            QuoteLineItem nrcSrc = nrcByMrc.get(srcId);
            if (nrcSrc == null) continue;

            QuoteLineItem mrcSrc = srcById.get(srcId);
            nrcSrc.Quantity           = mrcSrc.Quantity;
            nrcSrc.StartDate          = mrcSrc.StartDate;
            nrcSrc.EndDate            = null;
            nrcSrc.Ramp_Phase__c      = mrcSrc.Ramp_Phase__c;
            nrcSrc.Ramp_Start_Date__c = mrcSrc.StartDate;
            nrcSrc.Line_Origin__c     = 'Ramp';
            nrcSrc.Ramp_Line__c       = true;
            allNrcP1Updates.put(nrcSrc.Id, nrcSrc);

            List<QuoteLineItem> mrcPhases = newMrcBySrc.get(srcId);
            if (mrcPhases != null) {
                for (QuoteLineItem mrcPhase : mrcPhases) {
                    // Skip NRC for linked phases (Change/Price_Change) — no new
                    // installation when an existing phase is just being modified.
                    if (mrcPhase.Ramp_Linked_Phase__c != null) continue;
                    allNewNrc.add(new QuoteLineItem(
                        QuoteId                 = nrcSrc.QuoteId,
                        PricebookEntryId        = nrcSrc.PricebookEntryId,
                        Product2Id              = nrcSrc.Product2Id,
                        Quantity                = mrcPhase.Quantity,
                        UnitPrice               = nrcSrc.UnitPrice,
                        StartDate               = mrcPhase.StartDate,
                        EndDate                 = null,
                        Description             = nrcSrc.Description,
                        SortOrder               = nrcSrc.SortOrder,
                        Charge_Type__c          = nrcSrc.Charge_Type__c,
                        Ramp_Phase__c           = mrcPhase.Ramp_Phase__c,
                        Ramp_Start_Date__c      = mrcPhase.Ramp_Start_Date__c,
                        Ramp_Invoice_Display__c = nrcSrc.Ramp_Invoice_Display__c,
                        Paired_MRC_Line__c      = mrcPhase.Id,
                        Is_Auto_NRC__c          = nrcSrc.Is_Auto_NRC__c,
                        Line_Origin__c          = 'Ramp',
                        Ramp_Line__c            = true,
                        Ramp_Parent_Line__c     = nrcSrc.Id
                    ));
                }
            }
        }

        // ── 6. Bulk DML: NRC updates and inserts ──
        if (!allNrcP1Updates.isEmpty()) {
            new DmlHelper().doPartialUpdate(allNrcP1Updates.values());
        }
        if (!allNewNrc.isEmpty()) {
            new DmlHelper().doInsert(allNewNrc);
        }
        // Defensive NRC Phase 1 qty re-set
        if (!allNrcP1Updates.isEmpty()) {
            List<QuoteLineItem> nrcQtyFix = new List<QuoteLineItem>();
            for (QuoteLineItem nrcP1 : allNrcP1Updates.values()) {
                QuoteLineItem mrcSrc = srcById.get(nrcP1.Paired_MRC_Line__c);
                if (mrcSrc != null) {
                    nrcQtyFix.add(new QuoteLineItem(Id = nrcP1.Id, Quantity = mrcSrc.Quantity));
                }
            }
            if (!nrcQtyFix.isEmpty()) {
                new DmlHelper().doPartialUpdate(nrcQtyFix);
            }
        }

        // ── 7. Bulk date patch ──
        List<QuoteLineItem> datePatch = new List<QuoteLineItem>();
        for (Id srcId : allSourceIds) {
            List<Date> phaseEndDates = endDatesBySrc.get(srcId);
            if (phaseEndDates == null) continue;

            QuoteLineItem src = srcById.get(srcId);
            // Phase 1 source
            if (phaseEndDates[0] != null) {
                datePatch.add(new QuoteLineItem(Id = src.Id, EndDate = phaseEndDates[0]));
            }
            // NRC Phase 1
            QuoteLineItem nrcP1 = nrcByMrc.get(srcId);
            if (nrcP1 != null && phaseEndDates[0] != null) {
                datePatch.add(new QuoteLineItem(Id = nrcP1.Id, EndDate = phaseEndDates[0]));
            }
        }
        // MRC Phase 2+ end dates
        for (Integer i = 0; i < allNewMrc.size(); i++) {
            Id srcId = newMrcSourceIds[i];
            List<Integer> indices = mrcIndicesBySrc.get(srcId);
            List<Date> phaseEndDates = endDatesBySrc.get(srcId);
            if (phaseEndDates == null) continue;
            // Find position of this MRC line within its source's indices
            List<QuoteLineItem> srcMrcList = newMrcBySrc.get(srcId);
            if (srcMrcList == null) continue;
            Integer posInSrc = srcMrcList.indexOf(allNewMrc[i]);
            if (posInSrc >= 0 && posInSrc < indices.size()) {
                Integer phaseIdx = indices[posInSrc];
                if (phaseIdx < phaseEndDates.size() && phaseEndDates[phaseIdx] != null) {
                    datePatch.add(new QuoteLineItem(Id = allNewMrc[i].Id, EndDate = phaseEndDates[phaseIdx]));
                }
            }
        }
        // NRC Phase 2+ end dates — mirror their MRC phase
        // Build a lookup of MRC end dates first to avoid modifying datePatch while iterating
        Map<Id, Date> mrcEndDateById = new Map<Id, Date>();
        for (QuoteLineItem dp : datePatch) {
            if (dp.EndDate != null) mrcEndDateById.put(dp.Id, dp.EndDate);
        }
        for (QuoteLineItem nrc : allNewNrc) {
            Date mrcEnd = mrcEndDateById.get(nrc.Paired_MRC_Line__c);
            if (mrcEnd != null) {
                datePatch.add(new QuoteLineItem(Id = nrc.Id, EndDate = mrcEnd));
            }
        }
        if (!datePatch.isEmpty()) {
            new DmlHelper().doPartialUpdate(datePatch);
        }

        // All ramp DML done — run the deferred rollup once.
        QuoteMrcRollupService.endDeferAndFlush();

        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        } finally {
            // Never let the deferral flag leak past this method (error path rolls back).
            QuoteMrcRollupService.clearDefer();
        }
    }

    @AuraEnabled
    public static void splitRampLines(Id sourceLineId, String phasesJson, String rampType) {
        if (!Quote.sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED).isAccessible()) {
            throw new AuraHandledException('Insufficient permissions to access Quote.');
        }

        try {
        // Defer the MRC/TCV rollup so the Quote-update -> flow/credit cascade runs
        // ONCE after all ramp DMLs instead of on every intermediate DML (governor
        // limit relief — same fix as splitRampLinesBulk).
        QuoteMrcRollupService.beginDefer();

        QuoteLineItem src = [SELECT Id, QuoteId, Product2Id, PricebookEntryId,
                    Quantity, UnitPrice,
                    StartDate, EndDate,
                    Description, SortOrder,
                    Product_Attribute_Value__c, Custom_Attribute_Value__c,
                    Charge_Type__c, Ramp_Invoice_Display__c, Line_Remarks__c,
                    Product2.ProductCode
             FROM QuoteLineItem
             WHERE Id = :sourceLineId
             LIMIT 1];
        // Preserve the source line's remark so every ramp phase inherits it
        String origRemarks = src.Line_Remarks__c;

        Boolean isPriceRamp     = 'price'.equalsIgnoreCase(rampType);
        Boolean isAttributeRamp = 'attribute'.equalsIgnoreCase(rampType);

        List<Object> rawPhases = (List<Object>) JSON.deserializeUntyped(phasesJson);
        if (rawPhases.isEmpty()) {
            throw new AuraHandledException('At least one ramp phase is required.');
        }

        // ── Collect intended dates per phase from JSON ──────────────────
        // Insert/update all lines with EndDate=null first (avoids SF
        // FIELD_INTEGRITY_EXCEPTION on same-day dates), then patch EndDates
        // in a separate partial-success update.
        List<Date> phaseEndDates = new List<Date>();
        for (Object raw : rawPhases) {
            Map<String, Object> pm = (Map<String, Object>) raw;
            String eStr = (String) pm.get('endDate');
            phaseEndDates.add(String.isNotBlank(eStr) ? Date.valueOf(eStr) : null);
        }

        // Phase 1 — update the source line in place (preserves inventory links)
        Map<String, Object> p1 = (Map<String, Object>) rawPhases[0];
        if (isPriceRamp) {
            src.UnitPrice = toDecimal(p1.get('unitPrice'));
        } else if (isAttributeRamp) {
            Decimal p1Qty = toDecimal(p1.get('quantity'));
            src.Quantity  = isZeroQty(p1Qty) ? 1 : p1Qty;
            src.UnitPrice = toDecimal(p1.get('unitPrice'));
            src.Product_Attribute_Value__c = (String) p1.get('attributeValue');
            if (p1.containsKey('customValue') && p1.get('customValue') != null) {
                src.Custom_Attribute_Value__c = Decimal.ValueOf(String.valueOf(p1.get('customValue')));
            }
        } else {
            Decimal p1Qty = toDecimal(p1.get('quantity'));
            src.Quantity = isZeroQty(p1Qty) ? 1 : p1Qty;
        }
        src.StartDate           = Date.valueOf((String) p1.get('startDate'));
        src.EndDate             = null;  // Set later in patch
        src.Ramp_Phase__c       = p1.containsKey('globalPhase') ? toDecimal(p1.get('globalPhase')) : 1;
        src.Ramp_Start_Date__c  = src.StartDate;
        src.Line_Origin__c      = 'Ramp';
        src.Ramp_Line__c        = true;
        // Per-phase notes and invoice display for Phase 1
        // FB-815: phase note → Ramp_Phase_Notes__c, never Line_Remarks__c (see splitRampLinesBulk).
        if (p1.containsKey('notes')) {
            src.Ramp_Phase_Notes__c = p1.get('notes') == null ? null : String.valueOf(p1.get('notes'));
        }
        if (p1.containsKey('invoiceDisplay') && p1.get('invoiceDisplay') != null) {
            src.Ramp_Invoice_Display__c = String.valueOf(p1.get('invoiceDisplay'));
        }
        if (p1.containsKey('rampIdentifier')) {
            src.Ramp_Identifier__c = String.valueOf(p1.get('rampIdentifier'));
        }
        if (p1.containsKey('rampLinkedPhase') && p1.get('rampLinkedPhase') != null) {
            src.Ramp_Linked_Phase__c = toDecimal(p1.get('rampLinkedPhase'));
        } else {
            src.Ramp_Linked_Phase__c = null;
        }
        new DmlHelper().doUpdate(new List<QuoteLineItem>{ src });

        // Phases 2+ — insert new lines cloned from source (EndDate=null)
        List<QuoteLineItem> newMrcLines = new List<QuoteLineItem>();
        List<Integer> newMrcPhaseIndices = new List<Integer>(); // Track which phase index each line maps to
        if (rawPhases.size() > 1) {
            for (Integer i = 1; i < rawPhases.size(); i++) {
                Map<String, Object> p = (Map<String, Object>) rawPhases[i];
                // Determine qty for this phase
                Decimal phaseQty;
                if (isPriceRamp) {
                    phaseQty = src.Quantity;
                } else {
                    phaseQty = toDecimal(p.get('quantity'));
                }
                // Skip zero-qty phases — SF platform rejects Quantity=0
                if (isZeroQty(phaseQty)) continue;

                Date sDate = Date.valueOf((String) p.get('startDate'));
                QuoteLineItem newLine = new QuoteLineItem(
                    QuoteId                 = src.QuoteId,
                    PricebookEntryId        = src.PricebookEntryId,
                    Product2Id              = src.Product2Id,
                    StartDate               = sDate,
                    EndDate                 = null,
                    Description             = src.Description,
                    SortOrder               = src.SortOrder,
                    Charge_Type__c          = src.Charge_Type__c,
                    Ramp_Phase__c           = p.containsKey('globalPhase') ? toDecimal(p.get('globalPhase')) : (i + 1),
                    Ramp_Start_Date__c      = sDate,
                    Ramp_Invoice_Display__c = src.Ramp_Invoice_Display__c,
                    Product_Attribute_Value__c = src.Product_Attribute_Value__c,
                    Line_Origin__c          = 'Ramp',
                    Ramp_Line__c            = true,
                    Ramp_Parent_Line__c     = src.Id,
                    Reserved__c             = 'N/A',
                    Quantity                = phaseQty,
                    Line_Remarks__c         = origRemarks
                );
                if (isPriceRamp) {
                    newLine.UnitPrice = toDecimal(p.get('unitPrice'));
                } else if (isAttributeRamp) {
                    newLine.UnitPrice = toDecimal(p.get('unitPrice'));
                    newLine.Product_Attribute_Value__c = (String) p.get('attributeValue');
                    if (p.containsKey('customValue') && p.get('customValue') != null) {
                        newLine.Custom_Attribute_Value__c = Decimal.ValueOf(String.valueOf(p.get('customValue')));
                    }
                } else {
                    newLine.UnitPrice = src.UnitPrice;
                }
                // FB-815: phase note → Ramp_Phase_Notes__c. Line_Remarks__c keeps
                // origRemarks (set in the constructor above).
                if (p.containsKey('notes')) {
                    newLine.Ramp_Phase_Notes__c = p.get('notes') == null ? null : String.valueOf(p.get('notes'));
                }
                // Invoice Display override from UI
                if (p.containsKey('invoiceDisplay') && p.get('invoiceDisplay') != null) {
                    newLine.Ramp_Invoice_Display__c = String.valueOf(p.get('invoiceDisplay'));
                }
                if (p.containsKey('rampIdentifier')) {
                    newLine.Ramp_Identifier__c = String.valueOf(p.get('rampIdentifier'));
                }
                if (p.containsKey('rampLinkedPhase') && p.get('rampLinkedPhase') != null) {
                    newLine.Ramp_Linked_Phase__c = toDecimal(p.get('rampLinkedPhase'));
                }
                newMrcLines.add(newLine);
                newMrcPhaseIndices.add(i);
            }
            if (!newMrcLines.isEmpty()) {
                new DmlHelper().doInsert(newMrcLines);
            }
        }

        // ── Split paired NRC line to match MRC ramp phases ──────────────
        // Primary: find NRC paired via Paired_MRC_Line__c lookup
        List<QuoteLineItem> pairedNrcs = [SELECT Id, QuoteId, Product2Id, PricebookEntryId,
                    UnitPrice, Description, SortOrder,
                    Charge_Type__c, Ramp_Invoice_Display__c,
                    Is_Auto_NRC__c, Paired_MRC_Line__c
             FROM QuoteLineItem
             WHERE Paired_MRC_Line__c = :sourceLineId
               AND Line_Origin__c != 'Ramp'];

        // Fallback: find NRC by product code convention (.RC -> .NR) when not explicitly paired
        // Skip already-ramped NRCs — they were split by a previous call in the sequential chain
        if (pairedNrcs.isEmpty() && src.Product2.ProductCode != null
                && src.Product2.ProductCode.endsWithIgnoreCase('.RC')) {
            String nrcCode = src.Product2.ProductCode.removeEndIgnoreCase('.RC') + '.NR';
            pairedNrcs = [SELECT Id, QuoteId, Product2Id, PricebookEntryId,
                        UnitPrice, Description, SortOrder,
                        Charge_Type__c, Ramp_Invoice_Display__c,
                        Is_Auto_NRC__c, Paired_MRC_Line__c
                 FROM QuoteLineItem
                 WHERE QuoteId = :src.QuoteId
                   AND Product2.ProductCode = :nrcCode
                   AND Id != :sourceLineId
                   AND Line_Origin__c != 'Ramp'
                 LIMIT 1];
            // Set the pairing so future operations find it
            if (!pairedNrcs.isEmpty()) {
                pairedNrcs[0].Paired_MRC_Line__c = sourceLineId;
            }
        }

        List<QuoteLineItem> nrcUpdates = new List<QuoteLineItem>();
        List<QuoteLineItem> allNewNrcLines = new List<QuoteLineItem>();

        for (QuoteLineItem nrcSrc : pairedNrcs) {
            nrcSrc.Quantity           = src.Quantity;
            nrcSrc.StartDate          = src.StartDate;
            nrcSrc.EndDate            = null;
            nrcSrc.Ramp_Phase__c      = src.Ramp_Phase__c;
            nrcSrc.Ramp_Start_Date__c = src.StartDate;
            nrcSrc.Line_Origin__c     = 'Ramp';
            nrcSrc.Ramp_Line__c       = true;
            nrcUpdates.add(nrcSrc);

            for (QuoteLineItem mrcPhase : newMrcLines) {
                // Skip NRC for linked phases (Change/Price_Change)
                if (mrcPhase.Ramp_Linked_Phase__c != null) continue;
                allNewNrcLines.add(new QuoteLineItem(
                    QuoteId                 = nrcSrc.QuoteId,
                    PricebookEntryId        = nrcSrc.PricebookEntryId,
                    Product2Id              = nrcSrc.Product2Id,
                    Quantity                = mrcPhase.Quantity,
                    UnitPrice               = nrcSrc.UnitPrice,
                    StartDate               = mrcPhase.StartDate,
                    EndDate                 = null,
                    Description             = nrcSrc.Description,
                    SortOrder               = nrcSrc.SortOrder,
                    Charge_Type__c          = nrcSrc.Charge_Type__c,
                    Ramp_Phase__c           = mrcPhase.Ramp_Phase__c,
                    Ramp_Start_Date__c      = mrcPhase.Ramp_Start_Date__c,
                    Ramp_Invoice_Display__c = nrcSrc.Ramp_Invoice_Display__c,
                    Paired_MRC_Line__c      = mrcPhase.Id,
                    Is_Auto_NRC__c          = nrcSrc.Is_Auto_NRC__c,
                    Line_Origin__c          = 'Ramp',
                    Ramp_Line__c            = true,
                    Ramp_Parent_Line__c     = nrcSrc.Id
                ));
            }
        }

        if (!nrcUpdates.isEmpty()) {
            new DmlHelper().doPartialUpdate(nrcUpdates);
        }
        if (!allNewNrcLines.isEmpty()) {
            new DmlHelper().doInsert(allNewNrcLines);
        }

        // Defensive: re-set NRC Phase 1 qty after triggers may have modified it
        if (!nrcUpdates.isEmpty()) {
            List<QuoteLineItem> nrcQtyFix = new List<QuoteLineItem>();
            for (QuoteLineItem nrcP1 : nrcUpdates) {
                nrcQtyFix.add(new QuoteLineItem(Id = nrcP1.Id, Quantity = src.Quantity));
            }
            new DmlHelper().doPartialUpdate(nrcQtyFix);
        }

        // ── Patch EndDates (partial success — same-day dates silently skipped) ──
        List<QuoteLineItem> datePatch = new List<QuoteLineItem>();
        // Phase 1 source
        if (phaseEndDates[0] != null) {
            datePatch.add(new QuoteLineItem(Id = src.Id, EndDate = phaseEndDates[0]));
        }
        // MRC phases 2+ (use tracked phase indices in case zero-qty phases were skipped)
        for (Integer i = 0; i < newMrcLines.size(); i++) {
            Integer phaseIdx = newMrcPhaseIndices[i]; // actual phase index in phaseEndDates
            if (phaseEndDates[phaseIdx] != null) {
                datePatch.add(new QuoteLineItem(Id = newMrcLines[i].Id, EndDate = phaseEndDates[phaseIdx]));
            }
        }
        // NRC lines — mirror their MRC phase's EndDate
        for (QuoteLineItem nrcU : nrcUpdates) {
            if (phaseEndDates[0] != null) {
                datePatch.add(new QuoteLineItem(Id = nrcU.Id, EndDate = phaseEndDates[0]));
            }
        }
        for (Integer i = 0; i < allNewNrcLines.size(); i++) {
            Integer mrcIdx = Math.mod(i, newMrcLines.size());
            if (phaseEndDates[mrcIdx + 1] != null) {
                datePatch.add(new QuoteLineItem(Id = allNewNrcLines[i].Id, EndDate = phaseEndDates[mrcIdx + 1]));
            }
        }
        if (!datePatch.isEmpty()) {
            new DmlHelper().doPartialUpdate(datePatch);  // Partial success — same-day dates silently skipped
        }

        // All ramp DML done — run the deferred rollup once.
        QuoteMrcRollupService.endDeferAndFlush();
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        } finally {
            QuoteMrcRollupService.clearDefer();
        }
    }

    /**
     * When StartDate == EndDate, SF requires EndTime > StartTime.
     * Default both to avoid the FIELD_INTEGRITY_EXCEPTION.
     */
    private static void ensureDatesNotSameDay(QuoteLineItem qli) {
        if (qli.StartDate != null && qli.EndDate != null && qli.StartDate == qli.EndDate) {
            qli.EndDate = null;
        }
    }

    // ── Ramp view / edit / add / delete ──────────────────────────────

    /**
     * Returns ALL ramped MRC lines on the same quote, grouped by product code then phase.
     * Grouping uses Line_Origin__c = 'Ramp' + Ramp_Phase__c — no extra field needed.
     * NRC lines paired to each MRC are included inline.
     */
    @AuraEnabled
    public static List<Map<String, Object>> getRampSiblings(Id quoteLineItemId) {
        if (!QuoteLineItem.sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED).isAccessible()) {
            throw new AuraHandledException('Insufficient permissions.');
        }
        List<QuoteLineItem> srcList = [
            SELECT QuoteId, Line_Origin__c
            FROM QuoteLineItem WHERE Id = :quoteLineItemId LIMIT 1
        ];
        if (srcList.isEmpty() || srcList[0].Line_Origin__c != 'Ramp') {
            return new List<Map<String, Object>>();
        }
        QuoteLineItem src = srcList[0];

        // Get ALL ramped lines on this quote (MRC + standalone NRC, exclude auto-paired NRC)
        List<QuoteLineItem> allRamped = [
            SELECT Id, Product2Id, Quantity, UnitPrice, StartDate, EndDate,
                   Ramp_Phase__c, Ramp_Start_Date__c, Ramp_Parent_Line__c,
                   Ramp_Identifier__c, Ramp_Linked_Phase__c,
                   Product_Attribute_Value__c, Custom_Attribute_Value__c,
                   Ramp_Invoice_Display__c, Charge_Type__c,
                   Line_Remarks__c, Ramp_Phase_Notes__c,
                   Product2.Name, Product2.ProductCode,
                   Product2.Attribute_Type__c, Product2.Attribute_Values__c,
                   Product2.Show_Custom_Attribute_Value__c,
                   Product2.QuantityUnitOfMeasure
            FROM QuoteLineItem
            WHERE QuoteId = :src.QuoteId
              AND Line_Origin__c = 'Ramp'
              AND (Charge_Type__c != 'NRC' OR Is_Auto_NRC__c = false)
            ORDER BY Product2.ProductCode ASC, Ramp_Phase__c ASC NULLS LAST
        ];

        // Find paired NRC lines for all ramped MRC lines
        Set<Id> mrcIds = new Set<Id>();
        for (QuoteLineItem m : allRamped) { mrcIds.add(m.Id); }
        Map<Id, QuoteLineItem> nrcByMrc = new Map<Id, QuoteLineItem>();
        // Primary: find NRCs via Paired_MRC_Line__c
        for (QuoteLineItem nrc : [
            SELECT Id, Quantity, UnitPrice, Ramp_Phase__c,
                   Product2.Name, Product2.ProductCode,
                   Paired_MRC_Line__c
            FROM QuoteLineItem
            WHERE Paired_MRC_Line__c IN :mrcIds
        ]) {
            nrcByMrc.put(nrc.Paired_MRC_Line__c, nrc);
        }
        // Fallback: find NRCs by product code (.RC → .NR) for MRC lines with no paired NRC
        if (nrcByMrc.size() < mrcIds.size()) {
            Map<String, Id> codeToMrcId = new Map<String, Id>();
            for (QuoteLineItem m : allRamped) {
                if (!nrcByMrc.containsKey(m.Id) && m.Product2.ProductCode != null
                        && m.Product2.ProductCode.endsWithIgnoreCase('.RC')) {
                    String nrcCode = m.Product2.ProductCode.removeEndIgnoreCase('.RC') + '.NR';
                    codeToMrcId.put(nrcCode + '|' + m.Ramp_Phase__c, m.Id);
                }
            }
            if (!codeToMrcId.isEmpty()) {
                Set<String> nrcCodes = new Set<String>();
                for (String key : codeToMrcId.keySet()) {
                    nrcCodes.add(key.substringBefore('|'));
                }
                for (QuoteLineItem nrc : [
                    SELECT Id, Quantity, UnitPrice, Ramp_Phase__c,
                           Product2.Name, Product2.ProductCode, Paired_MRC_Line__c
                    FROM QuoteLineItem
                    WHERE QuoteId = :src.QuoteId
                      AND Product2.ProductCode IN :nrcCodes
                      AND Line_Origin__c = 'Ramp'
                ]) {
                    String key = nrc.Product2.ProductCode + '|' + nrc.Ramp_Phase__c;
                    Id mrcId = codeToMrcId.get(key);
                    if (mrcId != null && !nrcByMrc.containsKey(mrcId)) {
                        nrcByMrc.put(mrcId, nrc);
                    }
                }
            }
        }

        // Build flat result — each entry is one MRC line (one product × one phase)
        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (QuoteLineItem m : allRamped) {
            Map<String, Object> entry = new Map<String, Object>();
            entry.put('id', m.Id);
            entry.put('productId', m.Product2Id);
            entry.put('quantity', m.Quantity);
            entry.put('unitPrice', m.UnitPrice);
            entry.put('startDate', m.Ramp_Start_Date__c != null ? m.Ramp_Start_Date__c : m.StartDate);
            entry.put('endDate', m.EndDate);
            entry.put('rampPhase', m.Ramp_Phase__c);
            entry.put('parentLineId', m.Ramp_Parent_Line__c);
            entry.put('attributeValue', m.Product_Attribute_Value__c);
            entry.put('customValue', m.Custom_Attribute_Value__c);
            entry.put('invoiceDisplay', m.Ramp_Invoice_Display__c);
            entry.put('productName', m.Product2.Name);
            entry.put('productCode', m.Product2.ProductCode);
            entry.put('attributeType', m.Product2.Attribute_Type__c);
            entry.put('attributeValues', m.Product2.Attribute_Values__c);
            entry.put('showCustomValue', m.Product2.Show_Custom_Attribute_Value__c == true);
            entry.put('uom', m.Product2.QuantityUnitOfMeasure);
            // FB-815: the modal's phase-note box reads Ramp_Phase_Notes__c. Seeding it
            // from Line_Remarks__c meant a user's edited remark was pulled back into the
            // modal and re-stamped across the phase on the next Update Ramp.
            entry.put('notes', m.Ramp_Phase_Notes__c);
            entry.put('rampIdentifier', m.Ramp_Identifier__c);
            entry.put('rampLinkedPhase', m.Ramp_Linked_Phase__c);
            QuoteLineItem nrc = nrcByMrc.get(m.Id);
            if (nrc != null) {
                entry.put('nrcId', nrc.Id);
                entry.put('nrcCode', nrc.Product2.ProductCode);
                entry.put('nrcPrice', nrc.UnitPrice);
            }
            result.add(entry);
        }
        return result;
    }

    @AuraEnabled
    public static void deleteRampPhases(Id quoteLineItemId) {
        if (!QuoteLineItem.sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED).isAccessible()) {
            throw new AuraHandledException('Insufficient permissions.');
        }
        try {
            QuoteLineItem src = [
                SELECT QuoteId, Line_Origin__c
                FROM QuoteLineItem WHERE Id = :quoteLineItemId LIMIT 1
            ];

            // Get ALL ramped lines on this quote (all products, all phases, MRC + NRC)
            List<QuoteLineItem> allRamped = [
                SELECT Id, Ramp_Phase__c, Product2Id, Quantity, Charge_Type__c, Paired_MRC_Line__c, Ramp_Parent_Line__c
                FROM QuoteLineItem
                WHERE QuoteId = :src.QuoteId
                  AND Line_Origin__c = 'Ramp'
                ORDER BY Product2Id, Ramp_Phase__c ASC NULLS LAST
            ];
            if (allRamped.isEmpty()) return;

            // Sum total qty per product across all phases (to restore original qty on Phase 1)
            Map<Id, Decimal> totalQtyByProduct = new Map<Id, Decimal>();
            for (QuoteLineItem ql : allRamped) {
                Decimal running = totalQtyByProduct.containsKey(ql.Product2Id) ? totalQtyByProduct.get(ql.Product2Id) : 0;
                totalQtyByProduct.put(ql.Product2Id, running + (ql.Quantity != null ? ql.Quantity : 0));
            }

            // Separate parent lines (keep+reset) from clones (delete) for both MRC and NRC.
            // Use Ramp_Parent_Line__c (null = parent) instead of Ramp_Phase__c (unreliable
            // when Phase 1 is excluded — source QLI gets globalPhase > 1).
            List<QuoteLineItem> phase1Resets = new List<QuoteLineItem>();
            List<QuoteLineItem> toDelete = new List<QuoteLineItem>();
            for (QuoteLineItem ql : allRamped) {
                if (ql.Ramp_Parent_Line__c == null) {
                    // Parent line (original source) — reset to non-ramp
                    ql.Line_Origin__c      = 'New';
                    ql.Ramp_Phase__c       = null;
                    ql.Ramp_Start_Date__c  = null;
                    ql.Ramp_Parent_Line__c = null;
                    ql.Ramp_Line__c        = false;
                    Decimal totalQty = totalQtyByProduct.get(ql.Product2Id);
                    if (totalQty != null) ql.Quantity = totalQty;
                    phase1Resets.add(ql);
                } else {
                    // Clone — delete
                    toDelete.add(ql);
                }
            }

            if (!phase1Resets.isEmpty()) {
                new DmlHelper().doUpdate(phase1Resets);
            }

            // Delete NRC clones first, then MRC clones. Separate DML calls
            // prevent SELF_REFERENCE_FROM_TRIGGER — the MRC beforeDelete trigger
            // calls cascadeDeletePairedNrc, which would try to delete NRC records
            // already in the same delete batch if combined.
            List<QuoteLineItem> nrcToDelete = new List<QuoteLineItem>();
            List<QuoteLineItem> mrcToDelete = new List<QuoteLineItem>();
            for (QuoteLineItem ql : toDelete) {
                Boolean isNrc = ql.Charge_Type__c != null && ql.Charge_Type__c.equalsIgnoreCase('NRC');
                if (isNrc) { nrcToDelete.add(ql); } else { mrcToDelete.add(ql); }
            }
            if (!nrcToDelete.isEmpty()) {
                // Clear pairing so VR-QLI-01 doesn't block deletion
                for (QuoteLineItem nrc : nrcToDelete) { nrc.Paired_MRC_Line__c = null; }
                new DmlHelper().doUpdate(nrcToDelete);
                new DmlHelper().doDelete(nrcToDelete);
            }
            if (!mrcToDelete.isEmpty()) {
                new DmlHelper().doDelete(mrcToDelete);
            }
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * Post-split NRC qty aggregation. Called after ALL splitRampLines calls complete.
     * For each ramp NRC per phase, sets qty = sum of all MRC qtys sharing that NRC product for that phase.
     */
    @AuraEnabled
    public static void aggregateRampNrcQty(Id quoteId) {
        if (quoteId == null) return;
        try {
            // Get all ramp NRC lines on this quote
            List<QuoteLineItem> nrcLines = [
                SELECT Id, Quantity, Product2Id, Ramp_Phase__c
                FROM QuoteLineItem
                WHERE QuoteId = :quoteId AND Line_Origin__c = 'Ramp' AND Charge_Type__c = 'NRC'
            ];
            if (nrcLines.isEmpty()) return;

            Set<Id> nrcProductIds = new Set<Id>();
            for (QuoteLineItem nrc : nrcLines) nrcProductIds.add(nrc.Product2Id);

            // Sum MRC qtys per NRC product per phase
            Map<String, Decimal> qtyByNrcPhase = new Map<String, Decimal>();
            for (QuoteLineItem mrc : [
                SELECT Quantity, Product2.Paired_NRC_Product__c, Ramp_Phase__c
                FROM QuoteLineItem
                WHERE QuoteId = :quoteId AND Line_Origin__c = 'Ramp'
                  AND Charge_Type__c != 'NRC'
                  AND Product2.Paired_NRC_Product__c IN :nrcProductIds
            ]) {
                Integer mrcPhase = (mrc.Ramp_Phase__c != null) ? Integer.valueOf(mrc.Ramp_Phase__c) : 0;
                String key = mrc.Product2.Paired_NRC_Product__c + '_' + mrcPhase;
                Decimal sum = qtyByNrcPhase.containsKey(key) ? qtyByNrcPhase.get(key) : 0;
                qtyByNrcPhase.put(key, sum + (mrc.Quantity != null ? mrc.Quantity : 0));
            }

            // Update NRC lines where qty differs
            List<QuoteLineItem> updates = new List<QuoteLineItem>();
            for (QuoteLineItem nrc : nrcLines) {
                Integer nrcPhase = (nrc.Ramp_Phase__c != null) ? Integer.valueOf(nrc.Ramp_Phase__c) : 0;
                String key = nrc.Product2Id + '_' + nrcPhase;
                Decimal correctQty = qtyByNrcPhase.get(key);
                if (correctQty != null && nrc.Quantity != correctQty) {
                    updates.add(new QuoteLineItem(Id = nrc.Id, Quantity = correctQty));
                }
            }
            if (!updates.isEmpty()) {
                new DmlHelper().doUpdate(updates);
            }
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static Id addRampPhase(Id phase1Id, Decimal quantity, Decimal unitPrice,
                                   String startDate, String attributeValue) {
        if (!QuoteLineItem.sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED).isAccessible()) {
            throw new AuraHandledException('Insufficient permissions.');
        }
        try {
            QuoteLineItem p1 = [
                SELECT Id, QuoteId, Product2Id, PricebookEntryId,
                       Quantity, UnitPrice, Description, SortOrder,
                       Charge_Type__c, Ramp_Invoice_Display__c,
                       Product_Attribute_Value__c, Line_Origin__c,
                       Product2.ProductCode
                FROM QuoteLineItem WHERE Id = :phase1Id LIMIT 1
            ];

            // Determine next phase number
            List<QuoteLineItem> siblings = [
                SELECT Ramp_Phase__c FROM QuoteLineItem
                WHERE (Id = :phase1Id OR Ramp_Parent_Line__c = :phase1Id)
                  AND Line_Origin__c = 'Ramp'
            ];
            // Fallback for legacy
            if (siblings.size() <= 1) {
                siblings = [
                    SELECT Ramp_Phase__c FROM QuoteLineItem
                    WHERE QuoteId = :p1.QuoteId
                      AND Product2Id = :p1.Product2Id
                      AND Line_Origin__c = 'Ramp'
                ];
            }
            Decimal maxPhase = 0;
            for (QuoteLineItem s : siblings) {
                if (s.Ramp_Phase__c != null && s.Ramp_Phase__c > maxPhase) {
                    maxPhase = s.Ramp_Phase__c;
                }
            }
            Integer nextPhase = (Integer) maxPhase + 1;
            Date sDate = Date.valueOf(startDate);

            QuoteLineItem newLine = new QuoteLineItem(
                QuoteId                    = p1.QuoteId,
                PricebookEntryId           = p1.PricebookEntryId,
                Product2Id                 = p1.Product2Id,
                Quantity                   = isZeroQty(quantity) ? 1 : quantity,
                UnitPrice                  = unitPrice,
                StartDate                  = sDate,
                Description                = p1.Description,
                SortOrder                  = p1.SortOrder,
                Charge_Type__c             = p1.Charge_Type__c,
                Ramp_Phase__c              = nextPhase,
                Ramp_Start_Date__c         = sDate,
                Ramp_Invoice_Display__c    = p1.Ramp_Invoice_Display__c,
                Product_Attribute_Value__c = String.isNotBlank(attributeValue) ? attributeValue : p1.Product_Attribute_Value__c,
                Line_Origin__c             = 'Ramp',
                Ramp_Line__c               = true,
                Ramp_Parent_Line__c        = phase1Id,
                Reserved__c                = 'N/A'
            );
            new DmlHelper().doInsert(new List<QuoteLineItem>{ newLine });

            // Auto-create paired NRC for the new phase — primary + product code fallback
            List<QuoteLineItem> nrcP1List = [
                SELECT Id, QuoteId, Product2Id, PricebookEntryId,
                       UnitPrice, Description, SortOrder,
                       Charge_Type__c, Ramp_Invoice_Display__c,
                       Is_Auto_NRC__c
                FROM QuoteLineItem
                WHERE Paired_MRC_Line__c = :phase1Id
                LIMIT 1
            ];
            if (nrcP1List.isEmpty() && p1.Product2.ProductCode != null
                    && p1.Product2.ProductCode.endsWithIgnoreCase('.RC')) {
                String nrcCode = p1.Product2.ProductCode.removeEndIgnoreCase('.RC') + '.NR';
                nrcP1List = [
                    SELECT Id, QuoteId, Product2Id, PricebookEntryId,
                           UnitPrice, Description, SortOrder,
                           Charge_Type__c, Ramp_Invoice_Display__c,
                           Is_Auto_NRC__c
                    FROM QuoteLineItem
                    WHERE QuoteId = :p1.QuoteId AND Product2.ProductCode = :nrcCode
                      AND Ramp_Phase__c = 1
                    LIMIT 1
                ];
            }
            if (!nrcP1List.isEmpty()) {
                QuoteLineItem nrcP1 = nrcP1List[0];
                QuoteLineItem newNrc = new QuoteLineItem(
                    QuoteId                 = nrcP1.QuoteId,
                    PricebookEntryId        = nrcP1.PricebookEntryId,
                    Product2Id              = nrcP1.Product2Id,
                    Quantity                = isZeroQty(quantity) ? 1 : quantity,
                    UnitPrice               = nrcP1.UnitPrice,
                    StartDate               = sDate,
                    Description             = nrcP1.Description,
                    SortOrder               = nrcP1.SortOrder,
                    Charge_Type__c          = nrcP1.Charge_Type__c,
                    Ramp_Phase__c           = nextPhase,
                    Ramp_Start_Date__c      = sDate,
                    Ramp_Invoice_Display__c = nrcP1.Ramp_Invoice_Display__c,
                    Paired_MRC_Line__c      = newLine.Id,
                    Is_Auto_NRC__c          = nrcP1.Is_Auto_NRC__c,
                    Line_Origin__c          = 'Ramp',
                    Ramp_Line__c            = true,
                    Ramp_Parent_Line__c     = nrcP1.Id
                );
                new DmlHelper().doInsert(new List<QuoteLineItem>{ newNrc });
            }

            return newLine.Id;
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static void deleteQuoteLineItems(List<Id> lineIds) {
        if (!Quote.sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED).isAccessible()) {
            throw new AuraHandledException('Insufficient permissions to access Quote Line Items.');
        }
        // Block deletion of ramped lines — use Remove Ramp instead
        for (QuoteLineItem qli : [SELECT Id, Line_Origin__c FROM QuoteLineItem WHERE Id IN :lineIds AND Line_Origin__c = 'Ramp']) {
            throw new AuraHandledException('Cannot delete ramped lines. Use "Remove Ramp" on the Ramp Schedule tab instead.');
        }
        // If user selected both an MRC and its auto-generated NRC, strip the NRC from the
        // delete set — the trigger's NrcPairingService will cascade-delete it. Passing both
        // in one DML batch causes SELF_REFERENCE_FROM_TRIGGER.
        Set<Id> lineIdSet = new Set<Id>(lineIds);
        Set<Id> skipIds   = new Set<Id>();
        for (QuoteLineItem q : [SELECT Id FROM QuoteLineItem
                                 WHERE Id IN :lineIdSet
                                   AND Is_Auto_NRC__c = true
                                   AND Paired_MRC_Line__c IN :lineIdSet]) {
            skipIds.add(q.Id);
        }
        List<Id> toDelete = new List<Id>();
        for (Id i : lineIds) {
            if (!skipIds.contains(i)) toDelete.add(i);
        }
        try {
            new DmlHelper().doDelete([SELECT Id FROM QuoteLineItem WHERE Id IN :toDelete]);
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        }
    }

    // ── Column preferences (per-user, Hierarchy Custom Setting) ──────

    @AuraEnabled(cacheable=true)
    public static String getColumnPreferences() {
        Quote_Editor_Prefs__c prefs = Quote_Editor_Prefs__c.getInstance();
        return prefs != null ? prefs.Column_Config__c : null;
    }

    @AuraEnabled
    public static void saveColumnPreferences(String configJson) {
        Id userId = UserInfo.getUserId();
        Quote_Editor_Prefs__c prefs = Quote_Editor_Prefs__c.getInstance(userId);
        if (prefs == null || prefs.Id == null) {
            prefs = new Quote_Editor_Prefs__c(SetupOwnerId = userId);
        }
        prefs.Column_Config__c = configJson;
        upsert prefs;
    }

    @AuraEnabled
    public static void saveAutoSavePreference(Boolean autoSave) {
        Id userId = UserInfo.getUserId();
        Quote_Editor_Prefs__c prefs = Quote_Editor_Prefs__c.getInstance(userId);
        if (prefs == null || prefs.Id == null) {
            prefs = new Quote_Editor_Prefs__c(SetupOwnerId = userId);
        }
        prefs.Auto_Save__c = autoSave;
        upsert prefs;
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getBillingAccountOptions(Id quoteId) {
        List<Quote> quotes = [SELECT AccountId, BillingAccount__c, CurrencyIsoCode FROM Quote WHERE Id = :quoteId LIMIT 1];
        if (quotes.isEmpty()) return new Map<String, Object>{ 'options' => new List<Object>(), 'defaultBanId' => null };
        Quote q = quotes[0];
        List<Map<String, String>> opts = new List<Map<String, String>>();
        opts.add(new Map<String, String>{ 'label' => '--None--', 'value' => '' });
        for (BillingAccount__c ban : [
            SELECT Id, Name FROM BillingAccount__c
            WHERE Account__c = :q.AccountId AND Status__c = 'Active' AND CurrencyIsoCode = :q.CurrencyIsoCode
            ORDER BY Name ASC
        ]) {
            opts.add(new Map<String, String>{ 'label' => ban.Name, 'value' => ban.Id });
        }
        return new Map<String, Object>{ 'options' => opts, 'defaultBanId' => q.BillingAccount__c };
    }
}