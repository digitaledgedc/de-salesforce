public with sharing class OrderAssetsController {
    @AuraEnabled(cacheable=true)
    public static List<Asset> getByOrder(Id orderId) {
        List<Asset> assets = [
            SELECT Id, Name, Description, MRC__c, NRC__c, Status, Asset_Lifecycle_Status__c,
                   Odoo_IB_ID__c, Odoo_Subscription_ID__c, InstallDate, SCD__c,
                   Product2Id, Product2.Name, Product2.ProductCode, Product2.Family, Source_Order__c,
                   Source_OrderItem__c, Quantity, Product_Attribute__c,
                   Source_OrderItem__r.QuoteLineItem.Product_Attribute_Value__c,
                   Space__c, Space__r.Name,
                   Inventory__c, Inventory__r.Name,
                   A_Side_Asset__c, Z_Side_Asset__c
            FROM Asset
            WHERE Source_Order__c = :orderId
              AND Product2Id != null
              AND (Source_OrderItem__c = null OR Source_OrderItem__r.Charge_Type__c = 'MRC')
            ORDER BY Product2.Name, Name
        ];
        return (List<Asset>) Security.stripInaccessible(AccessType.READABLE, assets).getRecords();
    }

    public class LinkedQuoteInfo {
        @AuraEnabled public Id     quoteId;
        @AuraEnabled public String quoteName;
    }

    /**
     * Returns the Change Order Quote currently pending against this Asset, if any.
     * An Asset can accumulate QuoteLineItem rows from multiple Change Orders over
     * its lifetime (older ones already activated), so this returns only the most
     * recent CHANGE/CHANGE_PRICE line's Quote — callers should only surface this
     * while the Asset's Status is 'Pending Change'.
     */
    @AuraEnabled(cacheable=true)
    public static LinkedQuoteInfo getLinkedChangeOrderQuote(Id assetId) {
        List<QuoteLineItem> lines = (List<QuoteLineItem>) Security.stripInaccessible(
            AccessType.READABLE,
            [SELECT Id, QuoteId, Quote.Name FROM QuoteLineItem WHERE Asset__c = :assetId  AND Change_Type__c IN ('CHANGE', 'CHANGE_PRICE') ORDER BY CreatedDate DESC LIMIT 1]).getRecords();

        if (lines.isEmpty()) return null;LinkedQuoteInfo info = new LinkedQuoteInfo();info.quoteId   = lines[0].QuoteId; info.quoteName = lines[0].Quote.Name; return info;
    }

    public class NrcItem {
        @AuraEnabled public Id      itemId;
        @AuraEnabled public String  productName;
        @AuraEnabled public String  productCode;
        @AuraEnabled public String  description;
        @AuraEnabled public Decimal quantity;
        @AuraEnabled public Decimal unitPrice;
    }

    @AuraEnabled(cacheable=true)
    public static List<Asset> getByAccount(Id accountId) {
        List<Asset> assets = [
            SELECT Id, Name, Description, MRC__c, NRC__c, Status, Asset_Lifecycle_Status__c,
                   Odoo_IB_ID__c, Odoo_Subscription_ID__c, InstallDate, SCD__c,
                   Product2Id, Product2.Name, Product2.ProductCode, Product2.Family,
                   Source_Order__c, Source_Order__r.OrderNumber,
                   BillingAccount__c, BillingAccount__r.Name,
                   Quantity
            FROM Asset
            WHERE AccountId = :accountId
            ORDER BY Status ASC, Product2.Name ASC, Name ASC
        ];
        return (List<Asset>) Security.stripInaccessible(AccessType.READABLE, assets).getRecords();
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getAccountAssetSummary(Id accountId) {
        if (!Asset.sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED).isAccessible()) { throw new AuraHandledException('Insufficient permissions to view Assets.');
        }
        Map<String, Object> result = new Map<String, Object>();
        AggregateResult[] agg = [
            SELECT COUNT(Id) total,
                   SUM(MRC__c) totalMrc,
                   SUM(NRC__c) totalNrc
            FROM Asset
            WHERE AccountId = :accountId
        ];
        result.put('total', agg[0].get('total'));
        result.put('totalMrc', agg[0].get('totalMrc'));
        result.put('totalNrc', agg[0].get('totalNrc'));

        AggregateResult[] statusAgg = [
            SELECT Status, COUNT(Id) cnt
            FROM Asset
            WHERE AccountId = :accountId
            GROUP BY Status
        ];
        Map<String, Integer> byStatus = new Map<String, Integer>();
        for (AggregateResult ar : statusAgg) {
            byStatus.put((String)ar.get('Status'), (Integer)ar.get('cnt'));
        }
        result.put('byStatus', byStatus);
        return result;
    }

    @AuraEnabled(cacheable=true)
    public static List<NrcItem> getNrcItems(Id orderId) {
        List<NrcItem> result = new List<NrcItem>();
        List<OrderItem> rawItems = [
            SELECT Id, Product2Id, Product2.Name, Product2.ProductCode,
                   Description, Quantity, UnitPrice, Charge_Type__c
            FROM OrderItem
            WHERE OrderId = :orderId
              AND Charge_Type__c = 'NRC'
            ORDER BY Product2.Name, Description
        ];
        List<OrderItem> items = (List<OrderItem>) Security.stripInaccessible(
            AccessType.READABLE, rawItems).getRecords();
        for (OrderItem oi : items) {
            NrcItem n    = new NrcItem();
            n.itemId     = oi.Id;
            n.productName = oi.Product2 != null ? oi.Product2.Name : '';
            n.productCode = oi.Product2 != null ? oi.Product2.ProductCode : '';
            n.description = oi.Description;
            n.quantity    = oi.Quantity;
            n.unitPrice   = oi.UnitPrice;
            result.add(n);
        }
        return result;
    }
}