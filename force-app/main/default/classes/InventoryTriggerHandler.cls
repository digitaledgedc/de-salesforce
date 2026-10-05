/**
 * InventoryTriggerHandler
 * Handles Inventory__c trigger context.
 *
 * after insert - creates sharing records for site ops groups and platform ops.
 * after update - recalculates sharing when Site_Id__c changes; pushes field updates to
 * Odoo (IP-3) for tracked fields, and fires the dedicated decommission event to Odoo
 * whenever Status__c transitions to 'Decommissioned' — regardless of which code path
 * made the change (LWC, Data Loader, API, other Apex).
 *
 * Bypass: set TriggerBypass__mdt record 'InventoryTriggerHandler'.Is_Active__c = true
 * to disable the handler without a code deployment.
 */
public with sharing class InventoryTriggerHandler {

    public static void handleAfterInsert(List<Inventory__c> newList) {
        TriggerBypass__mdt bypass = TriggerBypass__mdt.getInstance('InventoryTriggerHandler');
        if (bypass != null && bypass.Is_Active__c) return;

        // FB-924 (2026-07-14): Inventory__c is now a master-detail child of Site__c
        // (Controlled by Parent). OwnerId and Inventory__Share no longer exist, so the
        // custom sharing engine is retired. Disabled here ahead of deleting the class.
        // InventorySharingService.recalculateSharing(newList, null);

        // IP-3 outbound: push newly inserted inventory to Odoo
        //if (!System.isBatch() && !System.isFuture()) {
            List<Id> ids = new List<Id>();
            for (Inventory__c inv : newList) ids.add(inv.Id);
            if (!ids.isEmpty()) System.enqueueJob(new CreateOdooInventoryQueueable(ids));
        //}
    }

    public static void handleAfterUpdate(List<Inventory__c> newList, Map<Id, Inventory__c> oldMap) {
        TriggerBypass__mdt bypass = TriggerBypass__mdt.getInstance('InventoryTriggerHandler');
        if (bypass != null && bypass.Is_Active__c) return;

        // FB-924: sharingChanged no longer needed — see recalculateSharing note above.
        // List<Inventory__c> sharingChanged = new List<Inventory__c>();
        List<Id> odooUpdateIds = new List<Id>();
        List<Id> odooDecommissionIds = new List<Id>();

        for (Inventory__c inv : newList) {
            Inventory__c old = oldMap.get(inv.Id);
            // FB-924: sharing recalculation on Site change retired (master-detail now).
            // if (inv.Site_Id__c != old.Site_Id__c) {
            //     sharingChanged.add(inv);
            // }

            Boolean becameDecommissioned = inv.Status__c == 'Decommissioned' && old.Status__c != 'Decommissioned';

            // IP-3: push update to Odoo when tracked fields change (skip if being decommissioned —
            // that path sends event_type:"decommission" via DecommissionOdooInventoryQueueable).
            // Space records carry their Odoo ref in Odoo_Space_ID__c; Breaker records carry it
            // in Odoo_Inventory_Id__c — check both, or Breaker updates never sync.
            Boolean hasOdooRef = String.isNotBlank(inv.Odoo_Space_ID__c) || String.isNotBlank(inv.Odoo_Inventory_Id__c);
            if (hasOdooRef && inv.Status__c != 'Decommissioned') {
                if (inv.Name              != old.Name
                    || inv.Status__c      != old.Status__c
                    || inv.Space_Type__c  != old.Space_Type__c
                    || inv.Site_Id__c     != old.Site_Id__c
                    || inv.Data_Hall__c   != old.Data_Hall__c
                    || inv.Hall__c        != old.Hall__c
                    || inv.CabE_Count__c  != old.CabE_Count__c
                    || inv.Breaker_Panel__c != old.Breaker_Panel__c
                    || inv.Notes__c       != old.Notes__c
                    // SFDEV-18 (2026-09-23): these are now written into the
                    // Odoo payload by UpdateOdooInventoryQueueable, so a
                    // change to just one of them (with nothing else tracked
                    // above also changing) must still trigger a sync.
                    || inv.Unit_Reference__c != old.Unit_Reference__c
                    || inv.TH_Sensor_ID__c != old.TH_Sensor_ID__c
                    || inv.TH_Sensor_Group_ID__c != old.TH_Sensor_Group_ID__c) {
                    odooUpdateIds.add(inv.Id);
                }
            }

            // IP-3: fire the dedicated decommission event exactly once, on the transition
            // into Decommissioned — no matter which code path made the change.
            if (becameDecommissioned) {
                odooDecommissionIds.add(inv.Id);
            }
        }

        // FB-924: custom sharing recalculation retired (Inventory__c is now Controlled by Parent).
        // if (!sharingChanged.isEmpty()) {
        //     InventorySharingService.recalculateSharing(sharingChanged, oldMap);
        // }
        if (!odooUpdateIds.isEmpty()) {
            System.enqueueJob(new UpdateOdooInventoryQueueable(odooUpdateIds));
        }
        if (!odooDecommissionIds.isEmpty()) {
            System.enqueueJob(new DecommissionOdooInventoryQueueable(odooDecommissionIds));
        }
    }
}