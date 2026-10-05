/**
 * ChangeOrderController
 * Apex controller for the changeOrderCreator LWC.
 * Supports the CO creation modal: loads active subscription lines from the
 * original order and creates a Quote (+ backing Opportunity + QuoteLineItems)
 * for review before the Quote→Order→Odoo lifecycle executes.
 *
 * Flow:  Create CO → Quote (review/approval) → SOFHandler creates Order → IP-4 pushes to Odoo
 */
public with sharing class ChangeOrderController {

    /** Lightweight DTO — one row per Asset, enriched with OrderItem commercial data. */
    public class OrderLineRow {
        @AuraEnabled public Id    assetId;
        @AuraEnabled public Id    itemId;
        @AuraEnabled public Id    productId;
        @AuraEnabled public Id    pricebookEntryId;
        @AuraEnabled public String productName;
        @AuraEnabled public String productCode;
        @AuraEnabled public String category;
        @AuraEnabled public String description;
        @AuraEnabled public Decimal quantity;
        @AuraEnabled public Decimal unitPrice;
        @AuraEnabled public String billingMode;
        @AuraEnabled public String chargeType;
        @AuraEnabled public Decimal odooProductId;
        @AuraEnabled public String spaceName;
        @AuraEnabled public String inventoryName;
        @AuraEnabled public String subscriptionId;
        @AuraEnabled public String assetName;
        @AuraEnabled public String status;
        @AuraEnabled public String lifecycleStatus;
        @AuraEnabled public String odooIbId;
        @AuraEnabled public String attribute;
        @AuraEnabled public String attributeValues;
        @AuraEnabled public Boolean hasAttribute;
        @AuraEnabled public String currencyIsoCode;
        @AuraEnabled public String aSideAsset;
        @AuraEnabled public String zSideAsset;
        @AuraEnabled public Boolean mergeIbTask;  // ← NEW: Product2.Merge_IB_Task__c
    }

    /**
     * Returns Asset-level rows for the CO grid.
     * Each Asset is linked to its source OrderItem for PricebookEntryId / BillingMode.
     */
    @AuraEnabled(cacheable=true)
    public static List<OrderLineRow> getActiveOrderItems(Id orderId) {
        // Order currency — surfaced so the LWC formats amounts in the order's
        // currency instead of a hardcoded symbol.
        String orderCurrency;
        for (Order o : [SELECT CurrencyIsoCode FROM Order WHERE Id = :orderId LIMIT 1]) {
            orderCurrency = o.CurrencyIsoCode;
        }

        // Query Assets keyed off the Asset's own Source_Order__c — same pattern as
        // OrderAssetsController.getByOrder (the "Order Details / Asset Manager" view,
        // which never had this bug). Deriving eligibility from OrderItem.OrderId first
        // (the old approach) silently dropped Assets whose *original* OrderItem lives
        // on an older order even though the Asset itself correctly belongs to this
        // order (DE-Asset Manager parity bug: Cross Connect / AC Single Phase vanishing
        // from the CO modal on NEXJP-OR-003806). Source_OrderItem__c may legitimately
        // be null (imported data) or point at an OrderItem on a different order now —
        // the Charge_Type__c check below is null-safe for both, and every downstream
        // read of Source_OrderItem__r already null-checks before dereferencing.
        List<SObject> stripped = Security.stripInaccessible(AccessType.READABLE, [
            SELECT Id, Name, Product2Id, Product2.Name, Product2.ProductCode,
                   Product2.Billing_Charge_Type__c,
                   Product2.Attribute_Values__c, Product2.Attribute_Type__c,
                   Product2.Merge_IB_Task__c,  // ← NEW: Include Merge_IB_Task__c
                   Description, MRC__c, Price, Quantity,
                   Status, Asset_Lifecycle_Status__c,
                   Odoo_Subscription_ID__c, Odoo_IB_ID__c,
                   Source_OrderItem__c, Product_Attribute__c,
                   Source_OrderItem__r.PricebookEntryId,
                   Source_OrderItem__r.Billing_Mode__c,
                   Source_OrderItem__r.Odoo_Product_ID__c,
                   Source_OrderItem__r.UnitPrice,
                   Source_OrderItem__r.QuoteLineItem.Product_Attribute_Value__c,
                   Space__c, Space__r.Name,
                   Inventory__c, Inventory__r.Name,
                   A_Side_Asset__c, Z_Side_Asset__c
            FROM Asset
            WHERE Source_Order__c = :orderId
              AND Product2Id != null
              AND (Source_OrderItem__c = null OR Source_OrderItem__r.Charge_Type__c = 'MRC')
              AND Status NOT IN ('Pending Change', 'Closed', 'Obsolete')
            ORDER BY Product2.Name, Name
        ]).getRecords();

        // Resolve A/Z-side SF Asset IDs → human-readable Asset Names
        Set<Id> sideIds = new Set<Id>();
        for (SObject s : stripped) {
            Asset a = (Asset) s;
            if (a.A_Side_Asset__c != null) {
                try { sideIds.add((Id) a.A_Side_Asset__c); } catch (System.StringException e) {}
            }
            if (a.Z_Side_Asset__c != null) {
                try { sideIds.add((Id) a.Z_Side_Asset__c); } catch (System.StringException e) {}
            }
        }
        Map<String, String> sideNameMap = new Map<String, String>();
        if (!sideIds.isEmpty()) {
            for (Asset side : [SELECT Id, Name FROM Asset WHERE Id IN :sideIds]) {
                sideNameMap.put(String.valueOf(side.Id), side.Name);
            }
        }

        List<OrderLineRow> rows = new List<OrderLineRow>();
        for (SObject s : stripped) {
            Asset a = (Asset) s;
            OrderLineRow r = new OrderLineRow();
            r.assetId          = a.Id;
            r.itemId           = a.Source_OrderItem__c;
            r.productId        = a.Product2Id;
            r.pricebookEntryId = a.Source_OrderItem__r != null
                ? a.Source_OrderItem__r.PricebookEntryId : null;
            r.productName      = a.Product2 != null ? a.Product2.Name : a.Name;
            r.productCode      = a.Product2 != null ? a.Product2.ProductCode : '';
            r.category         = categoryFromCode(r.productCode);
            r.description      = a.Description;
            r.quantity         = a.Quantity != null ? a.Quantity : 1;
            // Use the Asset's current price as the baseline — it's kept current by the
            // Odoo sync handlers on every amendment/renewal. Fall back to the original
            // OrderItem's UnitPrice only for assets that predate any sync.
            r.unitPrice        = (a.Price != null) ? a.Price : (a.Source_OrderItem__r != null ? a.Source_OrderItem__r.UnitPrice : null);
            r.billingMode      = a.Source_OrderItem__r != null
                ? a.Source_OrderItem__r.Billing_Mode__c : null;
            r.chargeType       = a.Product2 != null ? a.Product2.Billing_Charge_Type__c : null;
            r.odooProductId    = a.Source_OrderItem__r != null
                ? a.Source_OrderItem__r.Odoo_Product_ID__c : null;
            r.spaceName        = a.Space__r != null ? a.Space__r.Name : null;
            r.inventoryName    = a.Inventory__r != null ? a.Inventory__r.Name : null;
            r.subscriptionId   = a.Odoo_Subscription_ID__c;
            r.assetName        = a.Name;
            r.status           = a.Status;
            r.lifecycleStatus  = a.Asset_Lifecycle_Status__c;
            
            r.attribute        = a.Product_Attribute__c;
            r.attributeValues  = a.Product2 != null ? a.Product2.Attribute_Values__c : null;
            r.hasAttribute     = a.Product2 != null && a.Product2.Attribute_Type__c != null;
            r.odooIbId         = a.Odoo_IB_ID__c;
            r.aSideAsset       = a.A_Side_Asset__c != null
                ? (sideNameMap.containsKey(a.A_Side_Asset__c) ? sideNameMap.get(a.A_Side_Asset__c) : a.A_Side_Asset__c)
                : null;
            r.zSideAsset       = a.Z_Side_Asset__c != null
                ? (sideNameMap.containsKey(a.Z_Side_Asset__c) ? sideNameMap.get(a.Z_Side_Asset__c) : a.Z_Side_Asset__c)
                : null;
            r.currencyIsoCode  = orderCurrency;
            r.mergeIbTask      = a.Product2 != null ? a.Product2.Merge_IB_Task__c : false;  // ← NEW
            rows.add(r);
        }
        return rows;
    }

    /**
     * Creates a CO Quote with backing Opportunity and QuoteLineItems.
     * Returns the Quote Id so the LWC can navigate to it for review.
     *
     * linesJson: JSON array of {itemId, productId, pricebookEntryId, changeType,
     *            newQuantity, newUnitPrice, quantity, unitPrice,
     *            billingMode, odooProductId, description, mergeIbTask}
     * Only rows with changeType != 'NO_CHANGE' produce a QLI (unless BAN Change).
     */
    @AuraEnabled
    public static Id createChangeOrder(
        Id      originalOrderId,
        String  orderType,
        String  amendmentReason,
        String  rddStr,
        String  poReference,
        String  linesJson,
        Id      newBillingAccountId,
        Integer renewalTermMonths
    ) {
        // ── CRUD checks ────────────────────────────────────────────────
        if (!Schema.sObjectType.Opportunity.isCreateable()) { throw new AuraHandledException('Insufficient permissions to create Opportunity records.');
        }
        if (!Schema.sObjectType.Quote.isCreateable()) { throw new AuraHandledException('Insufficient permissions to create Quote records.');
        }
        if (!Schema.sObjectType.QuoteLineItem.isCreateable()) { throw new AuraHandledException('Insufficient permissions to create Quote Line Item records.');
        }

        // ── Pending action guard: block all actions while unprocessed orders exist
       /* List<Map<String, String>> pendingActions = getPendingActions(originalOrderId);
        if (!pendingActions.isEmpty()) {
            String names = '';
            for (Map<String, String> pa : pendingActions) {
                if (names.length() > 0) names += ', ';
                names += pa.get('orderNumber');
            }
            throw new AuraHandledException(
                'This order has pending actions that must be processed first: ' + names
            );
        }*/

        try {
        // ── Query source order ─────────────────────────────────────────
        Order orig = [
            SELECT AccountId, Account.Name, Account.Account_Tier__c, BillingAccount__c, Operation_Site__c,
                   Pricebook2Id, Contract_Term_Months__c, Contract_End_Date__c,
                   Target_Site__c, Target_Site__r.Site_Code__c,
                   Target_Site__r.Pricebook2__c, Target_Site__r.DE_Entity__c,
                   Target_Site__r.Country_Name__c,
                   QuoteId,
                   OpportunityId, Opportunity.Target_Site__c,
                   Opportunity.Operation_Country__c,
                   Opportunity.DE_Entity__c,
                   Opportunity.Sales_Motion__c,
                   Order_Number__c, CurrencyIsoCode, Odoo_Subscription_ID__c
            FROM Order WHERE Id = :originalOrderId
        ];

        // ── Resolve site: Order lookup → Opp lookup → picklist fallback ──
        Id siteId = orig.Target_Site__c != null ? orig.Target_Site__c : orig.Opportunity.Target_Site__c;
        Id quotePricebookId = orig.Pricebook2Id;
        String siteCode = null;
        Id siteDeEntity = null;
        String siteCountry = null;
        if (orig.Target_Site__c != null) {
            // Prefer Order-level lookup (traversed in the main query)
            if (orig.Target_Site__r.Pricebook2__c != null) { quotePricebookId = orig.Target_Site__r.Pricebook2__c;
            }
            siteCode = orig.Target_Site__r.Site_Code__c; siteDeEntity = orig.Target_Site__r.DE_Entity__c; siteCountry = orig.Target_Site__r.Country_Name__c;
        } else if (siteId != null) {
            // Fallback: Opp-level lookup — needs separate query
            List<Site__c> sites = [SELECT Pricebook2__c, Site_Code__c, DE_Entity__c, Country_Name__c FROM Site__c WHERE Id = :siteId LIMIT 1];
            if (!sites.isEmpty()) { if (sites[0].Pricebook2__c != null) {  quotePricebookId = sites[0].Pricebook2__c; }
                siteCode = sites[0].Site_Code__c; siteDeEntity = sites[0].DE_Entity__c; siteCountry = sites[0].Country_Name__c;
            }
        }
        // Fallback: legacy picklist
        if (siteCode == null && orig.Operation_Site__c != null) { siteCode = orig.Operation_Site__c;
        }

        // ── Resolve managers from the source Order's Quote ───────────────
        Id cmId = null;
        Id capMgrId = null;
        Id quoteDeEntity = null;
        String origInvoiceFrequency = null;
        if (orig.QuoteId != null) {
            List<Quote> origQuotes = [SELECT Country_Manager__c, Capacity_Manager__c, DE_Entity__c, Invoice_Frequency__c FROM Quote WHERE Id = :orig.QuoteId LIMIT 1];
            if (!origQuotes.isEmpty()) {
                cmId = origQuotes[0].Country_Manager__c; capMgrId = origQuotes[0].Capacity_Manager__c; quoteDeEntity = origQuotes[0].DE_Entity__c;origInvoiceFrequency = origQuotes[0].Invoice_Frequency__c;
            }
        }
        // Fallback: pull managers from the resolved Site when source Quote lacks them.
        // Without this, CO quotes created from orders with no linked Quote (or a Quote
        // with blank managers) get null managers → "No applicable approval process found".
        if ((cmId == null || capMgrId == null) && siteId != null) {
            List<Site__c> siteMgr = [SELECT Country_Manager__c, Capacity_Manager__c FROM Site__c WHERE Id = :siteId LIMIT 1];
            if (!siteMgr.isEmpty()) { if (cmId == null) cmId = siteMgr[0].Country_Manager__c; if (capMgrId == null) capMgrId = siteMgr[0].Capacity_Manager__c;
            }
        }

        // Fallback: pull DE_Entity and Invoice_Frequency from BAN when
        // source Quote is null (common for imported historical orders).
        if (origInvoiceFrequency == null || quoteDeEntity == null) {
            List<BillingAccount__c> bans = [
                SELECT DE_Entity__c, Invoice_Frequency__c
                FROM BillingAccount__c WHERE Id = :orig.BillingAccount__c LIMIT 1
            ];
            if (!bans.isEmpty()) {
                if (origInvoiceFrequency == null) origInvoiceFrequency = bans[0].Invoice_Frequency__c;
                if (quoteDeEntity == null) quoteDeEntity = bans[0].DE_Entity__c;
            }
        }

        // ── Derive field values ────────────────────────────────────────
        String oppOrderType     = orderType;  // Change/Upsell, Churn, Partial Churn, BAN Change
        String oppDealType     = mapDealType(orderType);
        String oppBookingBucket = mapBookingBucket(orderType);
        String quoteType       = mapQuoteType(orderType);
        String quoteAmendReason = mapAmendmentReasonToQuote(orderType, amendmentReason);
        Date   rddDate         = (rddStr != null && rddStr != '') ? Date.valueOf(rddStr) : null;

        // Churn: users only supply RDD in the termination wizard. Term must be 0 so
        // Quote_BeforeSave_ContractEndDate (FB-946) derives end date as RDD + 0mo − 1 day.
        Decimal quoteContractTerm = (renewalTermMonths != null)
            ? renewalTermMonths : orig.Contract_Term_Months__c;
        if (orderType == 'Churn') {
            quoteContractTerm = 0;
        }

        // ── 1. Create Opportunity ──────────────────────────────────────
        // CO number format: {parentOrderNumber}-CO{N}.
        // FB-687: rapid/concurrent clicks each ran COUNT() before the others
        // committed, so every click saw the same count and produced duplicate
        // CO numbers (e.g. three 26000174-CO3). Two fixes:
        //   (a) Lock the parent Order row (FOR UPDATE) so concurrent CO creation
        //       on the same order is serialized — the 2nd click waits for the 1st
        //       to commit, then reads the updated max.
        //   (b) Derive N from the MAX existing -CO suffix (not COUNT) so deleting
        //       a CO opportunity never causes a number to be reissued.
        Map<Id, Order> lockParent = new Map<Id, Order>(
            [SELECT Id FROM Order WHERE Id = :originalOrderId FOR UPDATE]
        );

        Boolean isRenewal = (orderType == 'Renewal');
        Boolean isTermination = (orderType == 'Churn' || orderType == 'Partial Churn');
        String numPrefix = isRenewal ? (orig.Order_Number__c + '-RCO')
            : isTermination ? (orig.Order_Number__c + '-XCO')
            : (orig.Order_Number__c + '-CO');
        String numLike = numPrefix + '%';
        Integer maxNum = 0;
        for (Opportunity existingOpp : [
            SELECT Opportunity_Number__c FROM Opportunity
            WHERE Original_Order__c = :originalOrderId
              AND Opportunity_Number__c LIKE :numLike
        ]) {
            if (existingOpp.Opportunity_Number__c == null) continue; String suffix = existingOpp.Opportunity_Number__c.substring(numPrefix.length());
            if (suffix.isNumeric() && Integer.valueOf(suffix) > maxNum) { maxNum = Integer.valueOf(suffix);
            }
        }
        String coOppNumber = numPrefix + (maxNum + 1);

        String oppName = orig.Account.Name + ' - ' + coOppNumber; // Flow overwrites this — kept as fallback
        if (oppName.length() > 120) { oppName = oppName.substring(0, 120);
        }

        Opportunity opp = new Opportunity(
            Name                 = oppName,
            AccountId            = orig.AccountId,
            StageName            = '2-Prospect',
            CloseDate            = Date.today().addDays(30),
            Opportunity_Number__c = coOppNumber,
            Order_Type__c        = oppOrderType,
            Deal_Type__c         = oppDealType,
            Booking_Bucket__c    = oppBookingBucket,
            Sales_Motion__c      = orig.Opportunity.Sales_Motion__c,
            Original_Order__c    = originalOrderId,
            Operation_Country__c = orig.Opportunity.Operation_Country__c != null
                                        ? orig.Opportunity.Operation_Country__c : siteCountry,
            DE_Entity__c         = siteDeEntity != null ? siteDeEntity : orig.Opportunity.DE_Entity__c,
            Account_Type__c      = orig.Account.Account_Tier__c,
            Target_Site__c       = siteId,
            Skip_Stage_Gate__c   = true,
            CurrencyIsoCode      = orig.CurrencyIsoCode,
            Contract_End_Date__c = orig.Contract_End_Date__c
        );
        insert opp;

        // ── 2. Create Quote ────────────────────────────────────────────
        Quote q = new Quote(
            OpportunityId         = opp.Id,
            Name                  = (isRenewal ? 'RN-' : isTermination ? 'XCO-' : 'CO-') + orig.Order_Number__c,
            Pricebook2Id          = quotePricebookId,
            Quote_Type__c         = quoteType,
            Amendment_Reason__c   = quoteAmendReason,
            BillingAccount__c     = (orderType == 'BAN Change' && newBillingAccountId != null)
                                        ? newBillingAccountId : orig.BillingAccount__c,
            Contract_Term_Months__c = quoteContractTerm,
            Customer_PO_Reference__c = poReference,
            RDD__c                = rddDate,
            Target_Site__c        = siteId,
            Country_Manager__c    = cmId,
            Capacity_Manager__c   = capMgrId,
            DE_Entity__c          = siteDeEntity != null ? siteDeEntity : (quoteDeEntity != null ? quoteDeEntity : orig.Opportunity.DE_Entity__c),
            Original_Order__c     = originalOrderId,
            CurrencyIsoCode       = orig.CurrencyIsoCode,
            Invoice_Frequency__c  = origInvoiceFrequency,
            ExpirationDate = (system.Today() + 60 ),
            Contract_End_Date__c = orig.Contract_End_Date__c
        );
        insert q;

        // ── 3. Create QuoteLineItems ───────────────────────────────────
        List<Object> rawLines = (List<Object>) JSON.deserializeUntyped(linesJson);

        // Re-map PricebookEntryIds if the Quote's pricebook differs from the Order's
        Map<Id, Id> productToPbeId = new Map<Id, Id>();
        if (quotePricebookId != orig.Pricebook2Id) {
            Set<Id> productIds = new Set<Id>();
            for (Object rawLine : rawLines) {
                Map<String,Object> ln = (Map<String,Object>) rawLine; if (ln.get('productId') != null) productIds.add((Id) ln.get('productId'));
            }
            for (PricebookEntry pbe : [ SELECT Id, Product2Id FROM PricebookEntry WHERE Pricebook2Id = :quotePricebookId AND Product2Id IN :productIds AND CurrencyIsoCode = :orig.CurrencyIsoCode AND IsActive = true]) { productToPbeId.put(pbe.Product2Id, pbe.Id);
            }
        }

        // Renewal: unchanged-but-renewed lines must still produce a QuoteLineItem
        // (Change_Type__c = NO_CHANGE) so the renewed service carries over.
        Boolean includeNoChange = (orderType == 'BAN Change' || orderType == 'Renewal');

        List<QuoteLineItem> qlis = new List<QuoteLineItem>();
        Decimal totalMrcDelta = 0;
        List<String> assetIds = new List<String> ();
        for (Object rawLine : rawLines) {
            Map<String,Object> line = (Map<String,Object>) rawLine;
            String changeType = (String) line.get('changeType');
            Boolean isNoChange = (changeType == null || changeType == '' || changeType == 'NO_CHANGE');
            if (isNoChange && !includeNoChange) continue;

            Decimal origQty = line.get('quantity') != null
                ? Decimal.valueOf(String.valueOf(line.get('quantity'))) : 1;
            Decimal newQty = line.get('newQuantity') != null
                ? Decimal.valueOf(String.valueOf(line.get('newQuantity')))
                : origQty;
            Decimal currentPrice = line.get('unitPrice') != null
                ? Decimal.valueOf(String.valueOf(line.get('unitPrice'))) : 0;
            Decimal newEnteredPrice = line.get('newUnitPrice') != null
                ? Decimal.valueOf(String.valueOf(line.get('newUnitPrice'))) : currentPrice;

            // ← NEW: Check if Merge_IB_Task__c is TRUE
            Boolean mergeIbTask = line.get('mergeIbTask') != null  ? (Boolean) line.get('mergeIbTask') : false;

            // QLI stores the full new committed price so the binding quote reflects
            // the actual new service value, not an incremental delta.
            Decimal newPrice = newEnteredPrice;

            // Removals carry negative quantity
            if (changeType == 'DELETE') {
                newQty = -1 * newQty.abs();
            }

            // Accumulate incremental MRC delta for Opportunity.Amount / MRC__c
            if (changeType == 'NEW') { totalMrcDelta += newEnteredPrice * newQty;
            } else if (changeType == 'DELETE') {
                totalMrcDelta -= currentPrice * origQty;
            } else if (changeType == 'CHANGE' || changeType == 'CHANGE_PRICE') {
                // ← NEW: When Merge_IB_Task__c = TRUE and quantity changes, use new quantity
                // If Merge_IB_Task__c = FALSE, each asset has quantity = 1, so quantity changes
                // should not affect MRC delta (but price changes still work)
                Decimal effectiveOrigQty = mergeIbTask ? origQty : 1;
                Decimal effectiveNewQty = mergeIbTask ? newQty : 1;
                totalMrcDelta += (newEnteredPrice * effectiveNewQty) - (currentPrice * effectiveOrigQty);
            }

            Id productId = (Id) line.get('productId');
            Id pbeId = productToPbeId.containsKey(productId) ? productToPbeId.get(productId): (Id) line.get('pricebookEntryId');

            QuoteLineItem qli = new QuoteLineItem(
                QuoteId                = q.Id,
                Product2Id             = productId,
                PricebookEntryId       = pbeId,
                Quantity               = newQty,
                UnitPrice              = newPrice,
                Billing_Mode__c        = (String) line.get('billingMode'),
                Odoo_Product_ID__c     = line.get('odooProductId') != null
                    ? Decimal.valueOf(String.valueOf(line.get('odooProductId'))) : null,
                Change_Type__c         = changeType,
                Description            = (String) line.get('description'),
                Original_OrderItem__c  = line.get('itemId') != null ? (Id) line.get('itemId') : null,
                Subscription_Id__c    = orig.Odoo_Subscription_ID__c,
                Charge_Type__c         = 'MRC',
                Odoo_Project_Task_IDs__c = (String) line.get('odooIbId'),
                Product_Attribute_Value__c = (String) line.get('attribute'),
                Asset__c = (String)line.get('assetId'),
                Reserved__c = 'N/A'
            );
            qlis.add(qli);
            assetIds.add((String) line.get('assetId'));
        }
        if (!qlis.isEmpty()) {
            insert qlis;
        }
        if (!assetIds.isEmpty()) {
            List<Asset> lstAsset = new List<Asset>();
            for(String asstId : assetIds){
                Asset assetRec = new Asset();
                assetRec.Id = asstId;
                assetRec.status = 'Pending Change';
                lstAsset.add(assetRec);
            }
            update lstAsset;
        }
        // ── Set Opportunity.Amount and MRC__c to the net incremental MRC delta ──
        // totalMrcDelta was accumulated in the QLI loop above:
        //   NEW          → full new service MRC
        //   DELETE       → negative (revenue removed)
        //   CHANGE/CHANGE_PRICE → newPrice*newQty − oldPrice*oldQty
        opp.Amount = totalMrcDelta;
        opp.MRC__c = totalMrcDelta;
        // Remaining_Month__c / Total_Deal_MRC__c (TCV): same day-aware model as
        // RampOppService.fractionalMonthsBetween — this CO's RDD through the
        // original order's Contract_End_Date__c, times the net MRC delta.
        Decimal remainingMonths = fractionalMonthsBetween(rddDate, orig.Contract_End_Date__c).setScale(2);
        opp.Remaining_Month__c = remainingMonths;
        opp.Total_Deal_MRC__c = (totalMrcDelta * remainingMonths).setScale(2);
        update opp;

        // ── Auto-create paired NRC installation lines for NEW .RC products ──
        // Mirrors QuoteLineEditorController.addProductToQuote NRC pairing logic.
        /*List<QuoteLineItem> nrcQlis = new List<QuoteLineItem>();
        System.debug('NRC_DEBUG rawLines size=' + rawLines.size() + ' quotePricebookId=' + quotePricebookId + ' currency=' + orig.CurrencyIsoCode);
        for (Integer i = 0; i < rawLines.size(); i++) {
            Map<String,Object> line = (Map<String,Object>) rawLines[i];
            String dbgChangeType = (String) line.get('changeType');
            String dbgPCode = (String) line.get('productCode');
            System.debug('NRC_DEBUG row[' + i + '] changeType=' + dbgChangeType + ' productCode=' + dbgPCode);
            if (!'NEW'.equals((String) line.get('changeType'))) continue;
            String pCode = (String) line.get('productCode');
            if (String.isBlank(pCode) || !pCode.toUpperCase().endsWith('.RC')) {
                System.debug('NRC_DEBUG row[' + i + '] SKIP: blank or not .RC pCode=' + pCode);
                continue;
            }

            // Build NRC product code: swap trailing .RC → .NR
            String nrcCode = pCode.substring(0, pCode.length() - 3) + '.NR';
            System.debug('NRC_DEBUG row[' + i + '] nrcCode=' + nrcCode + ' quotePbId=' + quotePricebookId);
            Id pbeId = (Id) line.get('pricebookEntryId');

            // Look up the inserted MRC QLI so we can set Paired_MRC_Line__c
            QuoteLineItem mrcQli = null;
            for (QuoteLineItem inserted : qlis) {
                if (inserted.PricebookEntryId == pbeId) { mrcQli = inserted; break; }
            }

            List<PricebookEntry> nrcPbes = [
                SELECT Id, Product2Id, UnitPrice,
                       Product2.Charge_Frequency__c,
                       Product2.Billing_Charge_Type__c,
                       Product2.Odoo_Product_Id__c
                FROM PricebookEntry
                WHERE Pricebook2Id = :quotePricebookId
                  AND Product2.ProductCode = :nrcCode
                  AND CurrencyIsoCode = :orig.CurrencyIsoCode
                  AND IsActive = true
                LIMIT 1
            ];
            System.debug('NRC_DEBUG row[' + i + '] nrcPbes.size=' + nrcPbes.size());
            if (nrcPbes.isEmpty()) continue;

            PricebookEntry nrcPbe = nrcPbes[0];
            Decimal nrcQty = line.get('newQuantity') != null
                ? Decimal.valueOf(String.valueOf(line.get('newQuantity'))) : 1;

            QuoteLineItem nrcQli = new QuoteLineItem(
                QuoteId            = q.Id,
                PricebookEntryId   = nrcPbe.Id,
                Product2Id         = nrcPbe.Product2Id,
                Quantity           = nrcQty,
                UnitPrice          = nrcPbe.UnitPrice,
                Charge_Type__c     = 'NRC',
                Is_Auto_NRC__c     = true,
                Change_Type__c     = 'NEW',
                Paired_MRC_Line__c = (mrcQli != null ? mrcQli.Id : null)
            );
            if (nrcPbe.Product2.Odoo_Product_Id__c != null) {
                nrcQli.Odoo_Product_ID__c = nrcPbe.Product2.Odoo_Product_Id__c;
            }
            if (String.isNotBlank(nrcPbe.Product2.Charge_Frequency__c)) {
                nrcQli.Charge_Frequency__c = nrcPbe.Product2.Charge_Frequency__c;
            }
            if (String.isNotBlank(nrcPbe.Product2.Billing_Charge_Type__c)) {
                String bct = nrcPbe.Product2.Billing_Charge_Type__c.toLowerCase();
                nrcQli.Billing_Mode__c = bct.substring(0, 1).toUpperCase() + bct.substring(1);
            }
            nrcQlis.add(nrcQli);
        }
        if (!nrcQlis.isEmpty()) {
            insert nrcQlis;
        }*/

        return q.Id;
        } catch (DmlException e) {
            // Surface a meaningful reason instead of the LWC's generic "Failed to create change order".
            // The status code + field name live in getMessage(); getDmlMessage(0) only has the short text.
            String full = e.getMessage();
            String userMsg;
            if (full != null && full.contains('FIELD_FILTER_VALIDATION') && full.contains('BillingAccount__c')) {
                userMsg = 'Cannot create the change order: the order\'s billing account (BAN) does not match this order. '
                        + 'The BAN must have the same account, subsidiary, currency and invoice frequency as the order '
                        + '(most often the currency differs). Correct the BAN, or link a matching BAN, then try again.';
            } else {
                String dm = (e.getNumDml() > 0) ? e.getDmlMessage(0) : full;
                userMsg = 'Cannot create the change order: ' + (String.isNotBlank(dm) ? dm : 'unexpected error') + '.';
            }
            AuraHandledException ex = new AuraHandledException(userMsg);
            ex.setMessage(userMsg);
            throw ex;
        }
    }

    // ── Mapping helpers ─────────────────────────────────────────────────

    /** CO type → Opportunity.Deal_Type__c */
    private static String mapDealType(String coType) {
        if (coType == 'Churn') return 'Churn';
        if (coType == 'Renewal') return null;  // Renewal: no Deal_Type auto-set
        return 'Change Order';  // Change/Upsell, Partial Churn, BAN Change
    }

    /** CO type → Opportunity.Booking_Bucket__c */
    private static String mapBookingBucket(String coType) {
        if (coType == 'Churn') return 'Churn';
        return 'Bookings';  // Change/Upsell, Partial Churn, BAN Change
    }

    /** CO type → Quote.Quote_Type__c */
    private static String mapQuoteType(String coType) {
        if (coType == 'Churn') return 'Termination';
        if (coType == 'Renewal') return 'Renewal';
        return 'Amendment';  // Change/Upsell, Partial Churn, BAN Change
    }

    /**
     * LWC amendment reason → Quote.Amendment_Reason__c
     * The Quote picklist uses human-readable labels; the SOFHandler maps
     * to Order.Amendment_Reason__c API names when creating the Order.
     */
    private static String mapAmendmentReasonToQuote(String coType, String lwcReason) {
        if (lwcReason == null || lwcReason == '') return null;

        // Change/Upsell reasons
        if (lwcReason == 'Price_Change')    return 'Price Change';
        if (lwcReason == 'Quantity_Change') return 'Quantity Change';
        if (lwcReason == 'Product_Change')  return 'Product Change';
        if (lwcReason == 'Upsell_New_Add')  return 'Upsell';
        if (lwcReason == 'Site_Transfer')   return 'Transfer';

        // Churn reasons → all map to Termination
        if (lwcReason == 'End_of_Term' || lwcReason == 'Early_Termination'
                || lwcReason == 'Non_Payment') return 'Termination';

        // Partial Churn reasons → all map to Downgrade
        if (lwcReason == 'Capacity_Reduction' || lwcReason == 'Downsell'
                || lwcReason == 'Site_Consolidation') return 'Downgrade';

        // Customer Request — depends on CO type
        if (lwcReason == 'Customer_Request') {
            return coType == 'Churn' ? 'Termination' : 'Downgrade';
        }

        // BAN Change reasons
        if (lwcReason == 'BAN_Transfer' || lwcReason == 'Legal_Entity_Change'
                || lwcReason == 'Merger_Acquisition') return 'BAN Change';

        return 'Other';
    }

    // ── Product search for adding new services to CO ─────────────────────

    @AuraEnabled
    public static List<Map<String, Object>> searchAvailableProducts(Id orderId, String searchTerm) {
        Order o = [
            SELECT Pricebook2Id, CurrencyIsoCode,
                   Target_Site__c,
                   Opportunity.Target_Site__c,
                   Opportunity.Account.Customer_Pricebook__c
            FROM Order WHERE Id = :orderId
            LIMIT 1
        ];

        // Resolve site pricebook — Order lookup → Opp lookup → Order pricebook
        Id pbId = o.Pricebook2Id;
        Id siteId = o.Target_Site__c != null ? o.Target_Site__c : o.Opportunity.Target_Site__c;
        if (siteId != null) {
            List<Site__c> sites = [SELECT Pricebook2__c FROM Site__c WHERE Id = :siteId LIMIT 1];
            if (!sites.isEmpty() && sites[0].Pricebook2__c != null) { pbId = sites[0].Pricebook2__c;
            }
        }

        String term = '%' + String.escapeSingleQuotes(searchTerm) + '%';
        List<PricebookEntry> pbes = (List<PricebookEntry>) Security.stripInaccessible(
            AccessType.READABLE,
            [SELECT Id, Product2Id, Product2.Name, Product2.ProductCode,
                    Product2.Family, Product2.QuantityUnitOfMeasure, Product2.Allowed_UoM__c,
                    Product2.Charge_Type__c, Product2.Charge_Frequency__c,
                    Product2.Billing_Charge_Type__c, Product2.Odoo_Product_Id__c,
                    Product2.Attribute_Type__c, Product2.Attribute_Values__c,
                    Product2.Merge_IB_Task__c,  // ← NEW
                    UnitPrice
             FROM PricebookEntry
             WHERE Pricebook2Id = :pbId AND IsActive = true
               AND CurrencyIsoCode = :o.CurrencyIsoCode
               AND (Product2.Name LIKE :term OR Product2.ProductCode LIKE :term)
             ORDER BY Product2.Name ASC
             LIMIT 15]
        ).getRecords();

        // Account price overlay
        Map<Id, Decimal> acctPriceMap = new Map<Id, Decimal>();
        Id acctPbId = o.Opportunity?.Account?.Customer_Pricebook__c;
        if (acctPbId != null) {
            Set<Id> prodIds = new Set<Id>();
            for (PricebookEntry p : pbes) prodIds.add(p.Product2Id);
            for (PricebookEntry ap : [
                SELECT Product2Id, UnitPrice FROM PricebookEntry
                WHERE Pricebook2Id = :acctPbId AND Product2Id IN :prodIds
                  AND CurrencyIsoCode = :o.CurrencyIsoCode AND IsActive = true
            ]) {
                acctPriceMap.put(ap.Product2Id, ap.UnitPrice);
            }
        }

        List<Map<String, Object>> results = new List<Map<String, Object>>();
        for (PricebookEntry pbe : pbes) {
            Decimal effectivePrice = acctPriceMap.containsKey(pbe.Product2Id)
                ? acctPriceMap.get(pbe.Product2Id) : pbe.UnitPrice;
            results.add(new Map<String, Object>{
                'pbeId'        => pbe.Id,
                'productId'    => pbe.Product2Id,
                'productName'  => pbe.Product2.Name,
                'productCode'  => pbe.Product2.ProductCode,
                'family'       => pbe.Product2.Family,
                'unitPrice'    => effectivePrice,
                'unit'         => pbe.Product2.QuantityUnitOfMeasure,
                'allowedUom'   => pbe.Product2.Allowed_UoM__c,
                'chargeType'      => pbe.Product2.Charge_Type__c,
                'billingMode'     => pbe.Product2.Billing_Charge_Type__c,
                'odooProductId'   => pbe.Product2.Odoo_Product_Id__c,
                'attributeType'   => pbe.Product2.Attribute_Type__c,
                'attributeValues' => pbe.Product2.Attribute_Values__c,
                'mergeIbTask'     => pbe.Product2.Merge_IB_Task__c  // ← NEW
            });
        }
        return results;
    }

    /**
     * Returns Orders linked to the original order that Odoo has not yet
     * fully processed (assets not synced back via IP-2).
     * An order is "pending" until Integration_Status__c = 'Completed'.
     */
    @AuraEnabled
    public static List<Map<String, String>> getPendingActions(Id orderId) {
        List<Map<String, String>> pending = new List<Map<String, String>>();
        for (Order o : [
            SELECT Order_Number__c, Order_Type__c, Integration_Status__c
            FROM Order
            WHERE Original_Order__c = :orderId
              AND Integration_Status__c != 'Completed'
			 AND Integration_Status__c != 'Synced'
              AND Status != 'Cancelled'
            ORDER BY CreatedDate DESC
        ]) {
            pending.add(new Map<String, String>{
                'orderNumber' => o.Order_Number__c,
                'type'        => o.Order_Type__c,
                'status'      => o.Integration_Status__c != null ? o.Integration_Status__c : 'Pending'
            });
        }
        return pending;
    }

    /**
     * Returns true if this order has assets without Source_OrderItem__c (imported data).
     */
    @AuraEnabled
    public static Boolean hasUnlinkedAssets(Id orderId) {
        return ![
            SELECT Id FROM Asset
            WHERE Source_Order__c = :orderId
              AND Source_OrderItem__c = null
              AND Status NOT IN ('Closed', 'Obsolete')
            LIMIT 1
        ].isEmpty();
    }

    /** Product code prefix → display category for the CO grid. */
    private static String categoryFromCode(String code) {
        if (code == null || code.length() < 3) return 'Other';
        String prefix = code.substring(0, 3).toUpperCase();
        if (prefix == 'CAB' || prefix == 'CAG' || prefix == 'HYS' || prefix == 'SPC') return 'Space';
        if (prefix == 'POW' || prefix == 'PCM') return 'Power'; if (prefix == 'CCL' || prefix == 'CCX' || prefix == 'DPP' || prefix == 'RIS') return 'Cross Connect';
        if (prefix == 'IPT' || prefix == 'IXP') return 'IP & Internet'; if (prefix == 'RMH') return 'Remote Hands'; if (prefix == 'EMS' || prefix == 'VAS') return 'Managed Services'; return 'Other';
    }

    /**
     * Day-aware month count from fromDate through toDate, inclusive of both
     * endpoints — sums, for every calendar month the span touches, (days of
     * that month covered) / (that month's own length). Same model as
     * RampOppService.fractionalMonthsBetween / QuoteMrcRollupService's copy
     * (2026-09-03 client-confirmed day-summation model), mirrored here so
     * Change Order TCV/remaining-month uses the identical calculation ramps do.
     */
    private static Decimal fractionalMonthsBetween(Date fromDate, Date toDate) {
        if (fromDate == null || toDate == null || toDate < fromDate) return 0;
        Decimal total = 0;
        Integer year = fromDate.year();
        Integer month = fromDate.month();
        Integer startDay = fromDate.day();
        while (true) {
            Integer daysInThisMonth = Date.daysInMonth(year, month);
            Boolean isLastMonth = (year == toDate.year() && month == toDate.month());
            Integer endDay = isLastMonth ? toDate.day() : daysInThisMonth;
            Integer daysCounted = endDay - startDay + 1;
            total += Decimal.valueOf(daysCounted) / daysInThisMonth;
            if (isLastMonth) break;
            month += 1;
            if (month > 12) { month = 1; year += 1; }
            startDay = 1;
        }
        return total;
    }
}