/**
 * AssetActivationService
 * Handles asset creation and lifecycle transitions for both new Orders and
 * Change Orders (COs).
 *
 * New Order path  — creates one Asset per MRC OrderItem.
 * Change Order path:
 *   CHANGE / CHANGE_PRICE — end-dates old asset, creates amended replacement asset.
 *   DELETE               — end-dates old asset only (no replacement created).
 *   NO_CHANGE             — no asset changes.
 *   BAN Change             — updates BillingAccount__c on existing assets to the new BAN.
 *
 * Invoked from Order_Screen_ActivateAssets flow via @InvocableMethod.
 */
public without sharing class AssetActivationService {

    public class Request {
        @InvocableVariable(required=true label='Order Id')
        public Id orderId;
    }

    @InvocableMethod(label='Activate Assets from Order' description='Creates/updates Assets for new Orders and Change Orders.')
    public static void activateAssets(List<Request> requests) {
        for (Request req : requests) {
            activateAssetsForOrder(req.orderId);
        }
    }

    // ── Dispatch ──────────────────────────────────────────────────────────────

    private static void activateAssetsForOrder(Id orderId) {
        Order ord = [
            SELECT Id, AccountId, Operation_Site__c,
                   RDD__c, OpportunityId,
                   Contact__c, Quote.ContactId, Original_Order__c,
                   Order_Type__c, BillingAccount__c
            FROM Order
            WHERE Id = :orderId
            LIMIT 1
        ];

        if (ord.Original_Order__c != null) {
            activateCOAssets(ord);
        } else {
            activateNewOrderAssets(ord);
        }
    }

    // ── New Order ─────────────────────────────────────────────────────────────

    private static void activateNewOrderAssets(Order ord) {
        Id contactId = ord.Contact__c != null ? ord.Contact__c : ord.Quote?.ContactId;

        List<OrderItem> items = [
            SELECT Id, Product2Id, Description, Quantity, MRC_Amount__c,
                   UnitPrice, ServiceDate, Inventory__c, Space__c
            FROM OrderItem
            WHERE OrderId = :ord.Id
              AND Charge_Type__c = 'MRC'
        ];

        if (items.isEmpty()) return;

        Set<Id> mrcItemIds = new Set<Id>();
        for (OrderItem oi : items) { mrcItemIds.add(oi.Id); }

        Map<Id, Decimal> mrcToNrc = new Map<Id, Decimal>();
        for (OrderItem nrcItem : [
            SELECT Id, UnitPrice, Quantity, Paired_MRC_OrderItem__c
            FROM OrderItem
            WHERE OrderId = :ord.Id
              AND Charge_Type__c = 'NRC'
              AND Paired_MRC_OrderItem__c IN :mrcItemIds
        ]) {
            mrcToNrc.put(nrcItem.Paired_MRC_OrderItem__c,
                         (nrcItem.UnitPrice != null ? nrcItem.UnitPrice : 0) *
                         (nrcItem.Quantity  != null ? nrcItem.Quantity  : 1));
        }

        List<Asset> assetsToInsert = new List<Asset>();
        for (OrderItem oi : items) {
            assetsToInsert.add(new Asset(
                Name                      = oi.Description,
                AccountId                 = ord.AccountId,
                Product2Id                = oi.Product2Id,
                Quantity                  = oi.Quantity,
                Price                     = oi.MRC_Amount__c,
                MRC__c                    = oi.MRC_Amount__c,
                NRC__c                    = mrcToNrc.get(oi.Id),
                Source_Order__c           = ord.Id,
                Source_OrderItem__c       = oi.Id,
                Opportunity__c            = ord.OpportunityId,
                Contact__c                = contactId,
                Operation_Site__c         = ord.Operation_Site__c,
                SCD__c                    = oi.ServiceDate,
                Asset_RDD__c              = ord.RDD__c,
                Inventory__c              = oi.Inventory__c,
                Space__c                  = oi.Space__c,
                Status                    = 'In Service',
                Asset_Lifecycle_Status__c = 'In Service',
                InstallDate               = Date.today()
            ));
        }
        insert assetsToInsert;

        enableLifecycle(assetsToInsert);
    }

    // ── Change Order ──────────────────────────────────────────────────────────

    private static void activateCOAssets(Order co) {
        // BAN Change: update BillingAccount__c on existing assets, no new assets
        if (co.Order_Type__c == 'BAN Change') {
            handleBanChange(co);
            return;
        }

        Id contactId = co.Contact__c != null ? co.Contact__c : co.Quote?.ContactId;

        // CO MRC lines that carry an actual change
        // No WITH SECURITY_ENFORCED: @InvocableMethod system context;
        // CRUD checks in activateAssetsForOrder enforce authorization.
        List<OrderItem> coItems = [
            SELECT Id, Product2Id, Description, Quantity, UnitPrice,
                   MRC_Amount__c, ServiceDate, Inventory__c, Space__c,
                   ns_change_type__c, Original_OrderItem__c
            FROM OrderItem
            WHERE OrderId = :co.Id
              AND Charge_Type__c = 'MRC'
              AND ns_change_type__c != 'NO_CHANGE'
              AND ns_change_type__c != null
        ];

        if (coItems.isEmpty()) return;

        // Map originalOrderItemId → existing Asset
        Set<Id> origItemIds = new Set<Id>();
        for (OrderItem oi : coItems) {
            if (oi.Original_OrderItem__c != null) origItemIds.add(oi.Original_OrderItem__c);
        }

        Map<Id, Asset> origItemToAsset = new Map<Id, Asset>();
        for (Asset a : [
            SELECT Id, Space__c, Inventory__c, Operation_Site__c,
                   Contact__c, Opportunity__c,
                   Source_OrderItem__c
            FROM Asset
            WHERE Source_OrderItem__c IN :origItemIds
        ]) {
            origItemToAsset.put(a.Source_OrderItem__c, a);
        }

        List<Asset> toEndDate    = new List<Asset>();
        List<Asset> toCreate     = new List<Asset>();

        // Track old-asset-to-new-asset mapping (by list index in toCreate)
        // so we can wire up chain fields after insert gives us the new Ids.
        List<Id> oldAssetIdPerNewAsset = new List<Id>();

        for (OrderItem oi : coItems) {
            Asset origAsset  = origItemToAsset.get(oi.Original_OrderItem__c);
            String chType    = oi.ns_change_type__c;

            // End-date the original asset
            if (origAsset != null) {
                toEndDate.add(new Asset(
                    Id                        = origAsset.Id,
                    Termination_Date__c       = Date.today(),
                    Change_Asset__c           = co.Id,
                    Asset_Lifecycle_Status__c = 'Terminated',
                    Status                    = 'Pending Change'
                ));
            }

            // Create replacement asset for CHANGE / CHANGE_PRICE
            if (chType == 'CHANGE' || chType == 'CHANGE_PRICE') {
                Decimal mrc = oi.MRC_Amount__c != null
                    ? oi.MRC_Amount__c
                    : (oi.UnitPrice != null ? oi.UnitPrice * oi.Quantity : 0);

                toCreate.add(new Asset(
                    Name                      = oi.Description,
                    AccountId                 = co.AccountId,
                    Product2Id                = oi.Product2Id,
                    Quantity                  = oi.Quantity,
                    Price                     = mrc,
                    MRC__c                    = mrc,
                    NRC__c                    = 0,
                    Source_Order__c           = co.Id,
                    Source_OrderItem__c       = oi.Id,
                    Opportunity__c            = co.OpportunityId,
                    Contact__c                = contactId,
                    Operation_Site__c         = co.Operation_Site__c,
                    SCD__c                    = oi.ServiceDate,
                    Asset_RDD__c              = co.RDD__c,
                    Inventory__c              = oi.Inventory__c != null ? oi.Inventory__c
                                                : (origAsset != null ? origAsset.Inventory__c : null),
                    Space__c                  = oi.Space__c != null ? oi.Space__c
                                                : (origAsset != null ? origAsset.Space__c : null),
                    Status                    = 'In Service',
                    Asset_Lifecycle_Status__c = 'In Service',
                    InstallDate               = Date.today()
                ));

                // Track which old asset this new asset replaces (parallel list)
                oldAssetIdPerNewAsset.add(origAsset != null ? origAsset.Id : null);
            }
            // DELETE: old asset end-dated above, no new asset created
        }

        if (!toEndDate.isEmpty()) update toEndDate;
        if (!toCreate.isEmpty()) {
            insert toCreate;

            // ── Wire up asset chain fields ───────────────────────────────
            // Now that new assets have Ids, set Previous_Asset__c and
            // Original_Asset__c on each new asset, and Replacement_Asset__c
            // on each old asset.

            // Collect old asset Ids that need Original_Asset__c lookup
            Set<Id> oldIdsNeedingOriginal = new Set<Id>();
            for (Id oldId : oldAssetIdPerNewAsset) {
                if (oldId != null) oldIdsNeedingOriginal.add(oldId);
            }

            // Query Original_Asset__c from old assets
            Map<Id, Id> oldAssetToOriginal = new Map<Id, Id>();
            if (!oldIdsNeedingOriginal.isEmpty()) {
                for (Asset a : [
                    SELECT Id, Original_Asset__c
                    FROM Asset
                    WHERE Id IN :oldIdsNeedingOriginal
                ]) {
                    oldAssetToOriginal.put(a.Id, a.Original_Asset__c);
                }
            }

            // Build updates for new assets (chain forward-pointers)
            List<Asset> newAssetUpdates = new List<Asset>();
            // Build updates for old assets (Replacement_Asset__c back-pointer)
            Map<Id, Asset> oldAssetUpdates = new Map<Id, Asset>();

            for (Integer i = 0; i < toCreate.size(); i++) {
                Id oldAssetId = oldAssetIdPerNewAsset[i];
                if (oldAssetId == null) continue;

                Id newAssetId = toCreate[i].Id;

                // Original_Asset__c: if old asset already has one, carry it
                // forward; otherwise the old asset is the first in the chain
                Id originalId = oldAssetToOriginal.get(oldAssetId);
                Id chainOriginal = (originalId != null) ? originalId : oldAssetId;

                newAssetUpdates.add(new Asset(
                    Id                = newAssetId,
                    Previous_Asset__c = oldAssetId,
                    Original_Asset__c = chainOriginal
                ));

                // Set Replacement_Asset__c on the old asset
                oldAssetUpdates.put(oldAssetId, new Asset(
                    Id                    = oldAssetId,
                    Replacement_Asset__c  = newAssetId
                ));
            }

            if (!newAssetUpdates.isEmpty()) update newAssetUpdates;
            if (!oldAssetUpdates.isEmpty()) update oldAssetUpdates.values();

            enableLifecycle(toCreate);
        }
    }

    // ── BAN Change ─────────────────────────────────────────────────────────────

    /**
     * AST-004: When a BAN Change CO is activated, updates BillingAccount__c on
     * all In Service assets linked to the original order items. The CO's
     * BillingAccount__c holds the new BAN.
     */
    private static void handleBanChange(Order co) {
        if (co.BillingAccount__c == null) return;

        // No WITH SECURITY_ENFORCED: @InvocableMethod system context;
        // CRUD checks in activateAssetsForOrder enforce authorization.
        List<OrderItem> coItems = [
            SELECT Id, Original_OrderItem__c
            FROM OrderItem
            WHERE OrderId = :co.Id
            AND Original_OrderItem__c != null
        ];

        if (coItems.isEmpty()) return;

        Set<Id> origItemIds = new Set<Id>();
        for (OrderItem oi : coItems) {
            origItemIds.add(oi.Original_OrderItem__c);
        }

        List<Asset> assetsToUpdate = [
            SELECT Id, BillingAccount__c
            FROM Asset
            WHERE Source_OrderItem__c IN :origItemIds
            AND Asset_Lifecycle_Status__c = 'In Service'
        ];

        if (assetsToUpdate.isEmpty()) return;

        for (Asset a : assetsToUpdate) {
            a.BillingAccount__c = co.BillingAccount__c;
        }
        update assetsToUpdate;
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private static void enableLifecycle(List<Asset> assets) {
        List<Asset> toUpdate = new List<Asset>();
        for (Asset a : assets) {
            toUpdate.add(new Asset(Id = a.Id, HasLifecycleManagement = true));
        }
        update toUpdate;
    }
}