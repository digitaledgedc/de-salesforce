/**
 * QuoteCOAssetPendingChange
 * FB-755: Invocable called from Quote_AfterSave_COAssetPendingChange flow.
 * When a CO Quote is accepted, immediately sets Status = 'Pending Change' on all
 * assets linked to the CO lines, regardless of Odoo sync state.
 * This prevents a second change order from selecting the same asset in parallel.
 */
public with sharing class QuoteCOAssetPendingChange {

    public class Request {
        @InvocableVariable(required=true label='Quote ID')
        public Id quoteId;
    }

    @InvocableMethod(
        label='Set CO Assets to Pending Change'
        description='FB-755: Sets Status=Pending Change on assets linked to accepted CO quote lines.'
    )
    public static void setPendingChange(List<Request> requests) {
        Set<Id> quoteIds = new Set<Id>();
        for (Request r : requests) {
            if (r.quoteId != null) quoteIds.add(r.quoteId);
        }
        if (quoteIds.isEmpty()) return;

        // Collect original order item IDs from CO quote lines
        Set<Id> origOrderItemIds = new Set<Id>();
        for (QuoteLineItem qli : [
            SELECT Original_OrderItem__c
            FROM QuoteLineItem
            WHERE QuoteId IN :quoteIds
              AND Original_OrderItem__c != null
        ]) {
            origOrderItemIds.add(qli.Original_OrderItem__c);
        }
        if (origOrderItemIds.isEmpty()) return;

        // Update assets linked to those order items that are not already blocked
        List<Asset> toUpdate = [
            SELECT Id, Status
            FROM Asset
            WHERE Source_OrderItem__c IN :origOrderItemIds
              AND Status NOT IN ('Pending Change', 'Closed', 'Obsolete')
        ];

        for (Asset a : toUpdate) {
            a.Status = 'Pending Change';
        }
        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
    }
}