/**
 * OrderMrcRollupService
 *
 * FB-798 (Ramp MRC and TCV Calculation Spec): computes Order_MRC__c on each
 * OrderItem and Total_Order_MRC__c on each Order in a ramp chain — the
 * incremental MRC that specific ramp order adds, not the running total.
 * "Order TCV MRC" (delta x Remaining Terms) is explicitly deferred per the
 * spec's priority (#7: "Can be moved to post go-live... Elvira has said she's
 * okay to delay it") and is NOT built here.
 *
 * Per-product-line delta rule (spec section 5 + 8):
 *   - Aggregate products (Product2.Merge_IB_Task__c = true): delta is always
 *     this phase's amount minus the IMMEDIATELY PRECEDING phase's amount for
 *     the same product+attribute, regardless of Ramp_Linked_Phase__c.
 *   - Non-aggregate products: delta is this phase's amount minus the amount
 *     currently standing at the phase Ramp_Linked_Phase__c points to (if set).
 *     If not set (a fresh 'Add', no prior phase for this product), delta is the
 *     full (Quantity * UnitPrice) — there's nothing to net against.
 *   - Unchanged phases still get a real OrderItem (Salesforce only blocks
 *     Quantity = 0, not "no change"; see QuoteLineEditorController.isZeroQty),
 *     so a delta of exactly zero on an otherwise-real row is expected and
 *     correct, not a bug.
 *
 * "Link all phases" fan-out (multi-select link target): one repricing phase can
 * carry SEVERAL OrderItems of the same product+attribute, one per earlier phase
 * it supersedes — e.g. 2+2+2 cabs added across phases 1-3, then phase 4
 * repricing all six via three lines linked to phases 1, 2 and 3 respectively.
 * Two consequences this class has to handle:
 *
 *   1. A phase's amount for a family is the SUM of that family's lines in the
 *      phase, not any single line. Indexing one OrderItem per (phase, family)
 *      silently kept whichever line happened to come last in the caller's list
 *      (RampOrderService builds it in clone-loop order, no ORDER BY), so any
 *      later phase reading back into a fanned-out phase netted against one
 *      line instead of all of them.
 *   2. A second repricing phase must net against what the FIRST reprice left
 *      standing, not against the original 'Add'. Netting phase 5 straight back
 *      to phase 1's original price double-counts phase 4's uplift. So the
 *      superseding amount per (family, target phase) is carried forward as the
 *      chain is walked in ascending phase order, rather than re-read from the
 *      target phase's own lines every time.
 *
 * Called from RampOrderService.splitRampOrder once every Order/OrderItem in
 * the ramp chain has been created, so all phases are available to resolve
 * "the linked/preceding phase's amount" without extra round-trips.
 */
public without sharing class OrderMrcRollupService {

    /**
     * @param ordersInPhaseOrder  Every Order in the ramp chain (the phase-1
     *        parent plus every child phase order), in ascending Ramp_Phase__c
     *        order.
     * @param itemsByOrderId      That Order's current (post-split) OrderItems,
     *        keyed by Order Id.
     */
    public static void calculateForRampChain(List<Order> ordersInPhaseOrder, Map<Id, List<OrderItem>> itemsByOrderId) {
        if (ordersInPhaseOrder == null || ordersInPhaseOrder.isEmpty()) return;

        Set<Id> productIds = new Set<Id>();
        for (List<OrderItem> items : itemsByOrderId.values()) {
            for (OrderItem oi : items) {
                if (oi.Product2Id != null) productIds.add(oi.Product2Id);
            }
        }

        Map<Id, Boolean> isAggregateByProduct = new Map<Id, Boolean>();
        if (!productIds.isEmpty()) {
            for (Product2 p : [SELECT Id, Merge_IB_Task__c FROM Product2 WHERE Id IN :productIds]) {
                isAggregateByProduct.put(p.Id, p.Merge_IB_Task__c == true);
            }
        }

        // Index every OrderItem by phase number + product/attribute family, so
        // "the linked phase's amount" or "the immediately preceding phase's
        // amount" can be resolved by lookup rather than re-querying per line.
        // A family maps to a LIST: fan-out (and the "multiple quote lines with
        // the same product" case that enables it) can put more than one line of
        // the same family in one phase, and the phase's amount is their sum.
        Map<Integer, Map<String, List<OrderItem>>> itemsByPhaseAndFamily = new Map<Integer, Map<String, List<OrderItem>>>();
        for (Order o : ordersInPhaseOrder) {
            Integer phase = o.Ramp_Phase__c != null ? Integer.valueOf(o.Ramp_Phase__c) : 1;
            Map<String, List<OrderItem>> familyMap = new Map<String, List<OrderItem>>();
            List<OrderItem> items = itemsByOrderId.containsKey(o.Id) ? itemsByOrderId.get(o.Id) : new List<OrderItem>();
            for (OrderItem oi : items) {
                String fam = familyKey(oi);
                if (!familyMap.containsKey(fam)) familyMap.put(fam, new List<OrderItem>());
                familyMap.get(fam).add(oi);
            }
            itemsByPhaseAndFamily.put(phase, familyMap);
        }

        // Amount currently standing at each superseded slot, keyed
        // family|targetPhase. Seeded lazily from the target phase's own lines
        // the first time something links to it, then advanced by each
        // successive reprice so a second one nets against the first.
        Map<String, Decimal> standingByFamilyAndTarget = new Map<String, Decimal>();

        List<OrderItem> itemUpdates = new List<OrderItem>();
        List<Order> orderUpdates = new List<Order>();

        for (Order o : ordersInPhaseOrder) {
            Integer phase = o.Ramp_Phase__c != null ? Integer.valueOf(o.Ramp_Phase__c) : 1;
            List<OrderItem> items = itemsByOrderId.containsKey(o.Id) ? itemsByOrderId.get(o.Id) : new List<OrderItem>();

            Decimal orderTotal = 0;
            for (OrderItem oi : items) {
                // Order_MRC__c / Total_Order_MRC__c are MRC figures — one-off
                // installation charges must never land in them. Without this the
                // header total came out as (MRC delta + full NRC): on 2600154,
                // RO1 read 5,920,000 instead of 3,420,000 (+2.5M of CAB001.NR).
                // Filter is "not NRC", NOT "== MRC", mirroring the quote-side
                // convention (quoteLineEditor.js:463) — Usage-Based products
                // (e.g. Metered Power) ARE part of the recurring footprint and
                // are counted in the spec's own 26000729 worked example.
                if (oi.Charge_Type__c == 'NRC') {
                    itemUpdates.add(new OrderItem(Id = oi.Id, Order_MRC__c = null));
                    continue;
                }
                Decimal currentAmount = amountOf(oi);
                Boolean aggregate = isAggregateByProduct.containsKey(oi.Product2Id) ? isAggregateByProduct.get(oi.Product2Id) : false;
                String fam = familyKey(oi);

                Decimal previousAmount = 0;
                if (aggregate) {
                    // Aggregate: consecutive-phase difference, link ignored.
                    // (The UI blocks linking aggregates — quoteLineEditor.js
                    // isLinkable && !isAggregate — so fan-out never applies
                    // here; the sum still guards the multiple-lines case.)
                    previousAmount = familyAmountAt(itemsByPhaseAndFamily, phase - 1, fam);
                } else if (oi.Ramp_Linked_Phase__c != null) {
                    Integer target = Integer.valueOf(oi.Ramp_Linked_Phase__c);
                    String slot = fam + '|' + target;
                    if (!standingByFamilyAndTarget.containsKey(slot)) {
                        standingByFamilyAndTarget.put(slot, familyAmountAt(itemsByPhaseAndFamily, target, fam));
                    }
                    previousAmount = standingByFamilyAndTarget.get(slot);
                    // This line now supersedes that slot for any later phase.
                    standingByFamilyAndTarget.put(slot, currentAmount);
                }
                // else: fresh 'Add', no prior phase for this product — previousAmount stays 0, delta = full amount.

                Decimal delta = (currentAmount - previousAmount).setScale(2);

                itemUpdates.add(new OrderItem(Id = oi.Id, Order_MRC__c = delta));
                orderTotal += delta;
            }

            orderUpdates.add(new Order(Id = o.Id, Total_Order_MRC__c = orderTotal.setScale(2)));
        }

        if (!itemUpdates.isEmpty()) update itemUpdates;
        if (!orderUpdates.isEmpty()) update orderUpdates;
    }

    /** Total amount of one product+attribute family across all its lines in a phase. */
    private static Decimal familyAmountAt(Map<Integer, Map<String, List<OrderItem>>> index, Integer phase, String fam) {
        Map<String, List<OrderItem>> familyMap = index.get(phase);
        if (familyMap == null || !familyMap.containsKey(fam)) return 0;
        Decimal total = 0;
        for (OrderItem oi : familyMap.get(fam)) {
            total += amountOf(oi);
        }
        return total;
    }

    private static Decimal amountOf(OrderItem oi) {
        Decimal qty = oi.Quantity != null ? oi.Quantity : 0;
        Decimal price = oi.UnitPrice != null ? oi.UnitPrice : 0;
        return qty * price;
    }

    private static String familyKey(OrderItem oi) {
        return oi.Product2Id + '|' + (oi.Product_Attribute_Value__c != null ? oi.Product_Attribute_Value__c : '');
    }
}