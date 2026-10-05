/**
 * OrderTriggerHandler
 * Handles Order trigger context. Collects Order IDs and enqueues appropriate Queueable.
 * Follows TriggerHandler pattern — no business logic, only routing.
 *
 * Integration routing (on Status → Activated):
 *   New Service / Renewal    → SendNewOrdersQueueable  (IP-1), gate: IP1_Enabled__c
 *   Change/Upsell / Churn / Partial Churn / Suspension / Resumption / BAN Change
 *                            → SendChangeOrdersQueueable (IP-1 Change Order), gate: IP1_Enabled__c
 *   Note: IP1_Enabled__c is the master integration kill-switch for all outbound Odoo callouts.
 *   IP2_Enabled__c controls the separate scheduled order-sync batch (OdooOrderSyncBatch).
 *
 * Inventory status lifecycle (on Status → Activated):
 *   All OrderItems with Space__c or Inventory__c (Breaker) links → update linked
 *   Inventory records to Status = 'Sold', stamp Order_Item__c and Order__c.
 *   Only transitions from Assigned/Quoted/Reserved — already-Sold/Installed records skipped.
 *
 * Change Order Asset sync (on Status → Activated, Change Orders only):
 *   QuoteLineItems with Change_Type__c of CHANGE or CHANGE_PRICE push their
 *   UnitPrice/Product_Attribute_Value__c onto the linked Asset (Asset__c) and
 *   clear it out of Pending Change, so the Asset reflects the CO immediately
 *   instead of waiting on the async Odoo amendment confirmation (IP-2).
 */
public with sharing class OrderTriggerHandler {

    // Set by inbound Odoo handlers (e.g. OdooCrossConnectHandler/IP-6) immediately before
    // activating an Order that ALREADY originated in Odoo (Odoo_Order_ID__c is already
    // populated). Without this, activating such an Order would run the same IP-1 "new order"
    // routing used for SF-originated orders and send it right back to Odoo as if it were new —
    // a callout boomerang. Always false by default; set true only for the duration of that one
    // guarded DML, then reset to false so no other order activation in the org is affected.
    @TestVisible
    public static Boolean skipIntegrationRouting = false;

    // Fires when Orders are inserted already-Activated (e.g. from SOFHandler quote acceptance).
    // Runs the same IP-1/IP-4/Inventory routing as handleAfterUpdate.
    public static void handleAfterInsert(List<Order> newList) {
        if (skipIntegrationRouting) return;
        List<Id> activatedIds = new List<Id>();
        for (Order o : newList) {
            if (o.Status == 'Activated') activatedIds.add(o.Id);
        }
        if (!activatedIds.isEmpty()) {
            routeActivatedOrders(activatedIds);
        }
    }

    public static void handleAfterUpdate(
            List<Order> newList, Map<Id,Order> oldMap) {
        if (skipIntegrationRouting) return;

        List<Id> activatedIds = new List<Id>();
        for (Order o : newList) {
            Order old = oldMap.get(o.Id);
            if (o.Status == 'Activated' && old.Status != 'Activated') {
                activatedIds.add(o.Id);
            }
        }
        if (!activatedIds.isEmpty()) {
            routeActivatedOrders(activatedIds);
        }
    }

    // ─── Shared routing — called from both insert and update paths ────────────

    private static void routeActivatedOrders(List<Id> activatedIds) {

        List<Id> newServiceIds  = new List<Id>();
        List<Id> changeOrderIds = new List<Id>();
        List<Id> churnOrderIds  = new List<Id>();

        List<Order> orders = [
            SELECT Id, Order_Type__c
            FROM Order WHERE Id IN :activatedIds
        ];

        for (Order o : orders) {
            String ot = o.Order_Type__c;
            System.debug('INTEGRATION ▶ Order ' + o.Id + ' activated | Type: ' + ot);
            if (ot == 'New Service' ) {
                newServiceIds.add(o.Id);
            } else if (ot == 'Change/Upsell' || ot == 'Churn'
                    || ot == 'Partial Churn' || ot == 'Suspension'
                    || ot == 'Resumption'    || ot == 'BAN Change' || ot == 'Renewal') {
                changeOrderIds.add(o.Id);
                if (ot == 'Churn' || ot == 'Partial Churn') {
                    churnOrderIds.add(o.Id);
                }
            }
        }

        OdooIntegrationSettings__c s = OdooIntegrationSettings__c.getOrgDefaults();
        System.debug('INTEGRATION ▶ Settings — IP1_Enabled: ' + s.IP1_Enabled__c
            + ' | NewService count: ' + newServiceIds.size()
            + ' | ChangeOrder count: ' + changeOrderIds.size());

        // Both groups below feed into a SINGLE System.enqueueJob() call at the end of this method
        // (see "Combined routing" below) instead of one enqueue per order type. Two independent
        // enqueueJob() calls in one invocation of this method is exactly what used to throw
        // "Too many queueable jobs added to the queue: 2" whenever this trigger fired from inside
        // an already-executing async job (e.g. RampOrderService.splitRampOrder, an @InvocableMethod
        // that can activate several child Orders — mixing New Service and Change/Renewal types —
        // from a Flow's asynchronous path) — Salesforce caps an executing async job to at most one
        // additional enqueueJob() call, and this method could ask for two.
        Set<Id> unsyncedBanIds = new Set<Id>();

        if (!newServiceIds.isEmpty() && s.IP1_Enabled__c) {
            List<Order> newServiceOrders = [
                SELECT Id, BillingAccount__c,
                       BillingAccount__r.Odoo_BAN_ID__c,
                       BillingAccount__r.Odoo_Partner_ID__c,
                       BillingAccount__r.Odoo_Invoice_Freq_ID__c
                FROM Order WHERE Id IN :newServiceIds
            ];
            for (Order o : newServiceOrders) {
                System.debug('INTEGRATION ▶ BAN check — Order: ' + o.Id
                    + ' | Partner_ID: ' + o.BillingAccount__r.Odoo_Partner_ID__c
                    + ' | BAN_ID: ' + o.BillingAccount__r.Odoo_BAN_ID__c
                    + ' | Freq_ID: ' + o.BillingAccount__r.Odoo_Invoice_Freq_ID__c);
                if (o.BillingAccount__c != null
                        && (o.BillingAccount__r.Odoo_Partner_ID__c == null
                            || o.BillingAccount__r.Odoo_BAN_ID__c == null
                            || o.BillingAccount__r.Odoo_Invoice_Freq_ID__c == null)) {
                    unsyncedBanIds.add(o.BillingAccount__c);
                }
            }
            // Also collect line-level BAN overrides (OrderItem.BAN_ID__c) that aren't synced yet
            for (OrderItem oi : [
                SELECT BAN_ID__c,
                       BAN_ID__r.Odoo_Partner_ID__c,Target_BAN__c,
                       BAN_ID__r.Odoo_BAN_ID__c,
                       BAN_ID__r.Odoo_Invoice_Freq_ID__c
                FROM OrderItem
                WHERE OrderId IN :newServiceIds AND Target_BAN__c  != null
            ]) {
                if (oi.BAN_ID__r.Odoo_Partner_ID__c == null
                        || oi.BAN_ID__r.Odoo_BAN_ID__c == null
                        || oi.BAN_ID__r.Odoo_Invoice_Freq_ID__c == null) {
                    unsyncedBanIds.add(oi.Target_BAN__c );
                }
            }
        }

        if (!changeOrderIds.isEmpty() && s.IP1_Enabled__c) {
            List<Order> changeOrders = [
                SELECT Id, BillingAccount__c,
                       BillingAccount__r.Odoo_BAN_ID__c,
                       BillingAccount__r.Odoo_Partner_ID__c,
                       BillingAccount__r.Odoo_Invoice_Freq_ID__c
                FROM Order WHERE Id IN :changeOrderIds
            ];
            for (Order o : changeOrders) {
                if (o.BillingAccount__c != null
                        && (o.BillingAccount__r.Odoo_Partner_ID__c == null
                            || o.BillingAccount__r.Odoo_BAN_ID__c == null
                            || o.BillingAccount__r.Odoo_Invoice_Freq_ID__c == null)) {
                    unsyncedBanIds.add(o.BillingAccount__c);
                }
            }
            // Also collect line-level BAN overrides (OrderItem.BAN_ID__c) that aren't synced yet
            for (OrderItem oi : [
                SELECT BAN_ID__c,
                       BAN_ID__r.Odoo_Partner_ID__c,
                       BAN_ID__r.Odoo_BAN_ID__c,Target_BAN__c,
                       BAN_ID__r.Odoo_Invoice_Freq_ID__c
                FROM OrderItem
                WHERE OrderId IN :changeOrderIds AND Target_BAN__c  != null
            ]) {
                if (oi.BAN_ID__r.Odoo_Partner_ID__c == null
                        || oi.BAN_ID__r.Odoo_BAN_ID__c == null
                        || oi.BAN_ID__r.Odoo_Invoice_Freq_ID__c == null) {
                    unsyncedBanIds.add(oi.Target_BAN__c );
                }
            }
        }

        // Combined routing — exactly one System.enqueueJob() for both order types together.
        // OdooBanSyncQueueable already no-ops the BAN-sync portion cleanly when banIds is empty
        // (see its bans.isEmpty() branch), so routing through it unconditionally — instead of
        // branching between "enqueue OdooBanSyncQueueable" and "enqueue SendXxxOrdersQueueable
        // directly" per order type — is what keeps this to a single enqueue call in every case.
        if ((!newServiceIds.isEmpty() || !changeOrderIds.isEmpty()) && s.IP1_Enabled__c) {
            System.debug('INTEGRATION ▶ ROUTING → OdooBanSyncQueueable | BANs needing sync: ' + unsyncedBanIds
                + ' | IP-1 Orders: ' + newServiceIds + ' | IP-4 Orders: ' + changeOrderIds);
            System.enqueueJob(new OdooBanSyncQueueable(new List<Id>(unsyncedBanIds), newServiceIds, changeOrderIds));
        }

        // Inventory lifecycle: Assigned/Quoted/Reserved → Sold on order activation
        updateInventoryToSold(activatedIds);

        // Inventory lifecycle: Sold/Installed → Pending Available on termination order activation
        if (!churnOrderIds.isEmpty()) {
            updateInventoryToPendingAvailable(churnOrderIds);
        }

        // Change Order Asset sync: push CHANGE/CHANGE_PRICE line values onto the
        // linked Asset immediately, instead of waiting on the async Odoo callback.
        if (!changeOrderIds.isEmpty()) {
            //applyChangeOrderAssetUpdates(changeOrderIds);
            stampInventoryScdFromAsset(changeOrderIds);
        }
    }

    /**
     * Change Order Inventory sync: for CO lines whose QuoteLineItem.Asset__c
     * points to an existing Asset (set by the Change Order Creator for lines
     * that amend an already-installed product), copies that Asset's Service
     * Commencement Date (SCD__c) onto the linked Inventory record via
     * Quote_Line__c. New-Order lines never have Asset__c populated at this
     * point — their Inventory SCD__c still comes from the async Odoo IB
     * webhook path in OdooAssetStatusHandler, so this only affects Change Orders.
     */
    private static void stampInventoryScdFromAsset(List<Id> orderIds) {
        Map<Id, Id> qliToOrderItem = new Map<Id, Id>();
        for (OrderItem oi : [
            SELECT Id, QuoteLineItemId
            FROM OrderItem
            WHERE OrderId IN :orderIds AND QuoteLineItemId != null
        ]) {
            qliToOrderItem.put(oi.QuoteLineItemId, oi.Id);
        }
        if (qliToOrderItem.isEmpty()) return;

        Map<Id, Id> qliToAssetId = new Map<Id, Id>();
        for (QuoteLineItem qli : [
            SELECT Id, Asset__c
            FROM QuoteLineItem
            WHERE Id IN :qliToOrderItem.keySet() AND Asset__c != null
        ]) {
            qliToAssetId.put(qli.Id, qli.Asset__c);
        }
        if (qliToAssetId.isEmpty()) return;

        Map<Id, Date> assetToScd = new Map<Id, Date>();
        for (Asset a : [
            SELECT Id, SCD__c FROM Asset
            WHERE Id IN :qliToAssetId.values() AND SCD__c != null
        ]) {
            assetToScd.put(a.Id, a.SCD__c);
        }
        if (assetToScd.isEmpty()) return;

        List<Inventory__c> invUpdates = new List<Inventory__c>();
        for (Inventory__c inv : [
            SELECT Id, Quote_Line__c, SCD__c
            FROM Inventory__c
            WHERE Quote_Line__c IN :qliToAssetId.keySet()
        ]) {
            Id assetId = qliToAssetId.get(inv.Quote_Line__c);
            Date scd = assetId != null ? assetToScd.get(assetId) : null;
            if (scd != null && inv.SCD__c != scd) {
                invUpdates.add(new Inventory__c(Id = inv.Id, SCD__c = scd));
            }
        }

        if (!invUpdates.isEmpty()) {
            System.debug('LIFECYCLE ▶ Stamping SCD__c from Asset onto '
                + invUpdates.size() + ' Inventory record(s)');
            new InventorySystemDml().doUpdate(invUpdates);
        }
    }

    /**
     * Applies Change Order line-level updates to their linked Assets at Order
     * activation. For each QuoteLineItem with Change_Type__c of CHANGE or
     * CHANGE_PRICE, pushes UnitPrice and Product_Attribute_Value__c onto the
     * linked Asset (Asset__c) and moves it out of Pending Change into In Service.
     * Mirrors the fields OdooAssetStatusHandler.handleAmendment sets on the
     * async Odoo confirmation path, applied here synchronously at activation.
     */
    @TestVisible
    private static void applyChangeOrderAssetUpdates(List<Id> orderIds) {
        Map<Id, Id> qliToOrderItem = new Map<Id, Id>();
        for (OrderItem oi : [
            SELECT Id, QuoteLineItemId
            FROM OrderItem
            WHERE OrderId IN :orderIds AND QuoteLineItemId != null
        ]) {
            qliToOrderItem.put(oi.QuoteLineItemId, oi.Id);
        }
        if (qliToOrderItem.isEmpty()) return;

        List<Asset> assetsToUpdate = new List<Asset>();
        for (QuoteLineItem qli : [
            SELECT Id, Asset__c, UnitPrice, Product_Attribute_Value__c
            FROM QuoteLineItem
            WHERE Id IN :qliToOrderItem.keySet()
              AND Change_Type__c IN ('CHANGE', 'CHANGE_PRICE')
              AND Asset__c != null
        ]) {
            assetsToUpdate.add(new Asset(
                Id                   = qli.Asset__c,
                Status               = 'In Service',
                Price                = qli.UnitPrice,
                MRC__c               = qli.UnitPrice,
                Product_Attribute__c = qli.Product_Attribute_Value__c
            ));
        }

        if (!assetsToUpdate.isEmpty()) {
            System.debug('LIFECYCLE ▶ Applying CO price/attribute changes to '
                + assetsToUpdate.size() + ' Asset(s)');
            new AssetSystemDml().doUpdate(assetsToUpdate);
        }
    }

    /**
     * Sets linked Inventory records to Status = 'Sold' when an Order is activated.
     *
     * Two paths are checked:
     *   Path A — OrderItem.Space__c / OrderItem.Inventory__c populated directly
     *             (used by change orders or manually assigned inventory).
     *   Path B — OrderItem.QuoteLineItemId → Inventory__c.Quote_Line__c
     *             (used by new orders created from quotes — Space__c on OrderItem is null
     *              because inventory is linked at the quote line level, not the order item level).
     *
     * Only transitions Inventory from Assigned/Quoted/Reserved → Sold.
     */
    private static void updateInventoryToSold(List<Id> orderIds) {
        Map<Id, Id>   invToOrderItem   = new Map<Id, Id>();
        Map<Id, Id>   invToOrder       = new Map<Id, Id>();
        Map<Id, Date> invToContractEnd = new Map<Id, Date>();

        // Path A: direct lookup on OrderItem; Path B: collect QLI IDs for second pass
        Map<Id, Id>   qliToOrderItem = new Map<Id, Id>();
        Map<Id, Id>   qliToOrder     = new Map<Id, Id>();

        Map<Id, Date> orderContractEnd = new Map<Id, Date>();
        for (Order o : [SELECT Id, Service_End_Date__c FROM Order WHERE Id IN :orderIds]) {
            orderContractEnd.put(o.Id, o.Service_End_Date__c);
        }

        for (OrderItem oi : [
            SELECT Id, OrderId, Space__c, Inventory__c, QuoteLineItemId
            FROM OrderItem
            WHERE OrderId IN :orderIds
        ]) {
            if (oi.Space__c != null) {
                invToOrderItem.put(oi.Space__c, oi.Id);
                invToOrder.put(oi.Space__c, oi.OrderId);
                invToContractEnd.put(oi.Space__c, orderContractEnd.get(oi.OrderId));
            }
            if (oi.Inventory__c != null) {
                invToOrderItem.put(oi.Inventory__c, oi.Id);
                invToOrder.put(oi.Inventory__c, oi.OrderId);
                invToContractEnd.put(oi.Inventory__c, orderContractEnd.get(oi.OrderId));
            }
            if (oi.QuoteLineItemId != null) {
                qliToOrderItem.put(oi.QuoteLineItemId, oi.Id);
                qliToOrder.put(oi.QuoteLineItemId, oi.OrderId);
            }
        }

        // Path B: resolve Inventory records linked to QuoteLineItems
        if (!qliToOrderItem.isEmpty()) {
            for (Inventory__c inv : [
                SELECT Id, Quote_Line__c
                FROM Inventory__c
                WHERE Quote_Line__c IN :qliToOrderItem.keySet()
            ]) {
                if (!invToOrderItem.containsKey(inv.Id)) {
                    Id orderId = qliToOrder.get(inv.Quote_Line__c);
                    invToOrderItem.put(inv.Id, qliToOrderItem.get(inv.Quote_Line__c));
                    invToOrder.put(inv.Id, orderId);
                    invToContractEnd.put(inv.Id, orderContractEnd.get(orderId));
                }
            }
        }

        if (invToOrderItem.isEmpty()) return;

        List<Inventory__c> updates = new List<Inventory__c>();
        for (Inventory__c inv : [
            SELECT Id, Status__c FROM Inventory__c WHERE Id IN :invToOrderItem.keySet()
        ]) {
            if (inv.Status__c == 'Assigned' || inv.Status__c == 'Quoted'
                    || inv.Status__c == 'Reserved') {
                updates.add(new Inventory__c(
                    Id              = inv.Id,
                    Status__c       = 'Sold',
                    Order_Item__c   = invToOrderItem.get(inv.Id),
                    Order__c        = invToOrder.get(inv.Id),
                    Contract_End__c = invToContractEnd.get(inv.Id)
                ));
            }
        }

        if (!updates.isEmpty()) {
            System.debug('LIFECYCLE ▶ Setting ' + updates.size() + ' Inventory records to Sold');
            new InventorySystemDml().doUpdate(updates);
        }
    }

    /**
     * Sets linked Inventory records to Status = 'Pending Available' when a termination
     * order (Churn / Partial Churn) is activated. Mirrors updateInventoryToSold — same
     * two-path lookup but transitions Sold/Installed → Pending Available.
     * Assignment fields (Account__c, Order__c, etc.) are cleared later by OdooInventorySyncHandler
     * when Odoo confirms the inventory is back to available.
     */
    private static void updateInventoryToPendingAvailable(List<Id> orderIds) {
        Set<Id> invIds = new Set<Id>();
        Map<Id, Id> qliToOrderItem = new Map<Id, Id>();

        for (OrderItem oi : [
            SELECT Id, OrderId, Space__c, Inventory__c, QuoteLineItemId
            FROM OrderItem
            WHERE OrderId IN :orderIds
        ]) {
            if (oi.Space__c     != null) invIds.add(oi.Space__c);
            if (oi.Inventory__c != null) invIds.add(oi.Inventory__c);
            if (oi.QuoteLineItemId != null) qliToOrderItem.put(oi.QuoteLineItemId, oi.Id);
        }

        if (!qliToOrderItem.isEmpty()) {
            for (Inventory__c inv : [
                SELECT Id, Quote_Line__c
                FROM Inventory__c
                WHERE Quote_Line__c IN :qliToOrderItem.keySet()
            ]) {
                invIds.add(inv.Id);
            }
        }

        if (invIds.isEmpty()) return;

        List<Inventory__c> updates = new List<Inventory__c>();
        for (Inventory__c inv : [
            SELECT Id, Status__c FROM Inventory__c WHERE Id IN :invIds
        ]) {
            if (inv.Status__c == 'Sold' || inv.Status__c == 'Installed') {
                updates.add(new Inventory__c(Id = inv.Id, Status__c = 'Pending Available'));
            }
        }

        if (!updates.isEmpty()) {
            System.debug('LIFECYCLE ▶ Setting ' + updates.size() + ' Inventory records to Pending Available');
            new InventorySystemDml().doUpdate(updates);
        }
    }

    /**
     * System-context DML for the inventory lifecycle. Inventory records are owned by
     * role-less integration users with no sharing rules, so the accepting user has no
     * sharing-based edit access. The status transition on order activation is a system
     * operation and must not depend on who accepted the quote. Isolated here so the rest
     * of OrderTriggerHandler keeps enforcing the running user's sharing.
     */
    private without sharing class InventorySystemDml {
        void doUpdate(List<Inventory__c> recs) {
            update recs;
        }
    }

    /**
     * System-context DML for the Change Order Asset sync. Same rationale as
     * InventorySystemDml — this is a system-driven transition tied to Order
     * activation and must not depend on the accepting user's Asset edit access.
     */
    private without sharing class AssetSystemDml {
        void doUpdate(List<Asset> recs) {
            update recs;
        }
    }
}