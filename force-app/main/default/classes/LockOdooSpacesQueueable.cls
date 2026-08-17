/**
 * LockOdooSpacesQueueable
 * IP-3: Locks physical inventory (Space/Breaker) in Odoo after a New Service order is provisioned.
 * Chained from SendNewOrdersQueueable after IP-1 success.
 * Only processes OrderItems that have Space__c or Inventory__c assigned.
 *
 * Odoo endpoints:
 *   PATCH /api/ns.ns_space/{Odoo_Inventory_Id__c}   — for Space (cabinet/cage)
 *   PATCH /api/ns.ns_breaker/{Odoo_Inventory_Id__c} — for Breaker (power circuit)
 *
 * CRITICAL: Both ns_sold and ns_reserved must be sent on every PATCH even if only one changes.
 * On failure: creates DE_Integration_Error__c. No automatic retry — manual Odoo resolution required.
 *
 * GOVERNOR LIMIT: Max 100 callouts per async transaction. Each unique Space or Breaker Odoo ID
 * consumes one callout. Hyperscaler orders with >100 unique physical units will be truncated —
 * units beyond the limit are skipped and a single error record is created for manual follow-up.
 * Architectural fix (Batch Apex) required before any customer with >100 unique capacity units
 * is activated.
 */
public without sharing class LockOdooSpacesQueueable implements Queueable, Database.AllowsCallouts {

    @TestVisible private static final Integer MAX_CALLOUTS = 100;

    private List<Id> orderIds;

    public LockOdooSpacesQueueable(List<Id> orderIds) {
        this.orderIds = orderIds;
    }

    public void execute(QueueableContext ctx) {
        // Query OrderItems with Space or Inventory assignments
        List<OrderItem> items = [
            SELECT Id, OrderId,
                   Space__c, Space__r.Odoo_Inventory_Id__c,
                   Inventory__c, Inventory__r.Odoo_Inventory_Id__c,
                   Charge_Type__c
            FROM OrderItem
            WHERE OrderId IN :orderIds
              AND Is_Active__c = true
              AND (Space__c != null OR Inventory__c != null)
        ];

        // Build lock payload — same for both Space and Breaker
        String lockPayload = '{"ns_sold": true, "ns_reserved": false}';

        Set<String> processedIds = new Set<String>(); // avoid duplicate PATCHes for same unit
        Integer calloutCount = 0;

        // Collect errors to insert AFTER all callouts — DML between callouts blocks subsequent callouts
        List<DE_Integration_Error__c> errorsToInsert = new List<DE_Integration_Error__c>();

        for (OrderItem oi : items) {
            // Lock Space (cabinet/cage)
            if (oi.Space__c != null && oi.Space__r.Odoo_Inventory_Id__c != null) {
                String spaceIntId = extractOdooIntId(oi.Space__r.Odoo_Inventory_Id__c);
                if (spaceIntId == null) continue;
                if (!processedIds.contains('S-' + spaceIntId)) {
                    if (calloutCount >= MAX_CALLOUTS) {
                        errorsToInsert.add(new DE_Integration_Error__c(
                            Record_Id__c = String.valueOf(oi.OrderId), IP_Reference__c = 'IP-3',
                            Error_Message__c = 'Callout limit reached (100). Space ' + spaceIntId
                                + ' was NOT locked in Odoo. Manual lock required. '
                                + 'Upgrade to Batch Apex for orders with >100 unique capacity units.',
                            Status__c = 'Open'));
                        continue;
                    }
                    processedIds.add('S-' + spaceIntId);
                    OdooCalloutService.Response resp =
                        OdooCalloutService.patch('/api/ns.ns_space/' + spaceIntId, lockPayload);
                    calloutCount++;
                    if (!resp.isSuccess) {
                        errorsToInsert.add(new DE_Integration_Error__c(
                            Record_Id__c = String.valueOf(oi.OrderId), IP_Reference__c = 'IP-3',
                            Error_Message__c = 'Failed to lock Space ' + spaceIntId + ': ' + resp.errorBody,
                            Status__c = 'Open'));
                    }
                }
            }

            // Lock Breaker (power circuit)
            if (oi.Inventory__c != null && oi.Inventory__r.Odoo_Inventory_Id__c != null) {
                String breakerIntId = extractOdooIntId(oi.Inventory__r.Odoo_Inventory_Id__c);
                if (breakerIntId == null) continue;
                if (!processedIds.contains('B-' + breakerIntId)) {
                    if (calloutCount >= MAX_CALLOUTS) {
                        errorsToInsert.add(new DE_Integration_Error__c(
                            Record_Id__c = String.valueOf(oi.OrderId), IP_Reference__c = 'IP-3',
                            Error_Message__c = 'Callout limit reached (100). Breaker ' + breakerIntId
                                + ' was NOT locked in Odoo. Manual lock required. '
                                + 'Upgrade to Batch Apex for orders with >100 unique capacity units.',
                            Status__c = 'Open'));
                        continue;
                    }
                    processedIds.add('B-' + breakerIntId);
                    OdooCalloutService.Response resp =
                        OdooCalloutService.patch('/api/ns.ns_breaker/' + breakerIntId, lockPayload);
                    calloutCount++;
                    if (!resp.isSuccess) {
                        errorsToInsert.add(new DE_Integration_Error__c(
                            Record_Id__c = String.valueOf(oi.OrderId), IP_Reference__c = 'IP-3',
                            Error_Message__c = 'Failed to lock Breaker ' + breakerIntId + ': ' + resp.errorBody,
                            Status__c = 'Open'));
                    }
                }
            }
        }

        // All callouts complete — safe to DML
        if (!errorsToInsert.isEmpty()) {
            insert errorsToInsert;
        }
    }

    /**
     * Extracts the integer Odoo ID from Odoo_Inventory_Id__c.
     * Field stores prefixed values like "SPC-32196" or "BRK-3659".
     * Odoo API expects the integer only (32196, 3659).
     * Also handles bare integers (e.g. "32196") for forward compatibility.
     */
    @TestVisible
    private static String extractOdooIntId(String rawId) {
        if (String.isBlank(rawId)) return null;
        if (rawId.contains('-')) {
            return rawId.substringAfterLast('-');
        }
        return rawId;
    }
}