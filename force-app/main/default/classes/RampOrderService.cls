/**
 * RampOrderService
 *
 * Called from Quote_AfterSave_SOFHandler (F-15) after OrderItems and NRC pairing
 * are complete. Splits a single ramp-deal Order into one Order per ramp phase.
 *
 * Phase 1 items remain on the original (parent) Order.
 * Phases 2-6 get new child Orders linked via Parent_Order__c.
 *
 * OrderItem.OrderId is master-detail (non-reparentable), so child-phase items
 * are cloned onto the new Order and the originals are deleted from the parent.
 * NRC pairing is re-run on each child Order via OrderItemNrcPairingService.
 *
 * FB-1041: once each phase's MRC is rolled up, RampOppService gives EVERY
 * phase — 1 through N — its own child Opportunity (Parent_Opportunity__c =
 * the deal's Opp, StageName = 5-Won) and re-points that phase's Order onto
 * it, before the child Orders below are activated. After this, the deal's
 * own Opportunity holds no Order directly.
 */
// without sharing: system-context invocable called from SOFHandler (after-save flow).
// Ramp splitting is a data-integrity operation that must succeed regardless of the
// running user's field-level access to Order or OrderItem fields.
public without sharing class RampOrderService {

    public class Request {
        @InvocableVariable(required=true description='Id of the Order to split by ramp phase')
        public Id orderId;
    }

    @InvocableMethod(
        label='Split Ramp Deal into Phase Orders'
        description='Creates one Order per ramp phase. Phase 1 stays on original; phases 2+ get new child Orders linked via Parent_Order__c.'
        category='Order'
    )
    public static void splitRampOrder(List<Request> requests) {
        if (requests == null || requests.isEmpty()) return;

        Id parentOrderId = requests[0].orderId;
        if (parentOrderId == null) return;

        Order parentOrder = [
            SELECT Id, AccountId, BillingAccount__c, Contract_Term_Months__c,
                   Customer_PO_Reference__c, EffectiveDate, FX_Billing_Flag__c,
                   FX_Rate_Model__c, FX_Rate_Terms__c, Free_Months__c,
                   Free_Period_End_Date__c, Free_Period_Start_Date__c,
                   Is_Ramp_Deal__c, OpportunityId, Order_Number__c, Order_Type__c,
                   Original_Order__c, Amendment_Reason__c, Integration_Status__c,
                   Pricebook2Id, QuoteId, Quote__c, RDD__c, Ramp_Phases__c,
                   SBI_Finance_Comments__c, SBI_Flag__c, SBI_Notes__c,
                   Operation_Site__c, CurrencyIsoCode,
                   Operation_Country__c, Contract_End_Date__c
            FROM Order
            WHERE Id = :parentOrderId
            LIMIT 1
        ];

        // Gate removed: Is_Ramp_Deal__c on Quote is deleted — ramp detection is
        // now derived from OrderItem.Ramp_Phase__c.  The childPhaseMap.isEmpty()
        // check below already handles the non-ramp case.

        List<OrderItem> allItems = [
            SELECT Id, OrderId, Product2Id, PricebookEntryId, Quantity, UnitPrice,
                   Description, ServiceDate, Charge_Type__c, Billing_Mode__c,
                   Charge_Frequency__c, Is_Auto_NRC__c, Line_Booking_Bucket__c,
                   Ramp_Phase__c, Ramp_Start_Date__c, Free_Months_Override__c,
                   Product_Attribute_Value__c, Ramp_Invoice_Display__c, Power_kVA__c,
                   UoM__c,
                   Ramp_Identifier__c, Ramp_Linked_Phase__c,
                   ns_change_type__c, Original_OrderItem__c, Odoo_Product_ID__c,
                   Is_Active__c, Paired_MRC_OrderItem__c,
                   Line_Remarks__c
            FROM OrderItem
            WHERE OrderId = :parentOrderId
        ];

        // Group items by ramp phase; Phase 1 (or null) stays on parent.
        // Also capture each phase's start date (held on the lines, not the header)
        // for the per-phase remaining-term calc below.
        Map<Integer, List<OrderItem>> childPhaseMap = new Map<Integer, List<OrderItem>>();
        Map<Integer, Date> phaseStartByPhase = new Map<Integer, Date>();
        List<OrderItem> phase1Items = new List<OrderItem>();
        for (OrderItem oi : allItems) {
            Integer phase = (oi.Ramp_Phase__c != null) ? Integer.valueOf(oi.Ramp_Phase__c) : 1;
            if (oi.Ramp_Start_Date__c != null && !phaseStartByPhase.containsKey(phase)) {
                phaseStartByPhase.put(phase, oi.Ramp_Start_Date__c);
            }
            if (phase <= 1) {
                phase1Items.add(oi);
                continue;
            }
            if (!childPhaseMap.containsKey(phase)) {
                childPhaseMap.put(phase, new List<OrderItem>());
            }
            childPhaseMap.get(phase).add(oi);
        }

        if (childPhaseMap.isEmpty()) return;

        // Capture original number before renaming so child orders derive from it
        String originalOrderNumber = parentOrder.Order_Number__c;

        // Tag the parent order as Phase 1 and rename to -RO1.
        // FB-864: remaining term is OFFSET-based — contract term minus the whole
        // months this phase starts after phase 1. Deliberately independent of
        // Contract_End_Date__c: every other remaining-term rule in the org counts
        // down from the term (Order_BeforeSave_SetRemainingTerm gives a New Service
        // order a flat Contract_Term_Months__c), so phase 1 must equal the full term.
        // This also keeps ramps immune to FB-852 (contract end moving to D-1).
        // NOTE: Order_BeforeSave_SetRemainingTerm is guarded to skip ramp phase
        // orders (ISBLANK(Ramp_Phase__c)), so this Apex is the ONLY thing that
        // sets Remaining_Term__c on a ramp order. Remove it and every phase —
        // including phase 1 — comes out null.
        parentOrder.Ramp_Phase__c = 1;
        parentOrder.Order_Number__c = originalOrderNumber + '-RO1';
        Decimal contractTerm = parentOrder.Contract_Term_Months__c;
        Date phase1Start = phaseStartByPhase.get(1);
        // Each phase order's RDD is that phase's start date picked in the ramp
        // editor (carried on the lines as Ramp_Start_Date__c). The header RDD is
        // only a fallback for phases whose lines carry no start date.
        Date headerRdd = parentOrder.RDD__c;
        if (phase1Start != null) parentOrder.RDD__c = phase1Start;
        if (contractTerm != null) parentOrder.Remaining_Term__c = contractTerm; // phase 1 = full term
        update parentOrder;

        // Create child Orders — one per phase 2+
        List<Integer> phases = new List<Integer>(childPhaseMap.keySet());
        phases.sort();

        List<Order> childOrders = new List<Order>();
        for (Integer phase : phases) {
            Order child = parentOrder.clone(false, true, false, false);
            child.Parent_Order__c = parentOrderId;
            child.Ramp_Phase__c = phase;
            child.Order_Number__c = originalOrderNumber + '-RO' + phase;
            child.Status = 'Draft';
            // FB-864: remaining term = contract term − whole months since phase-1 start
            Date phaseStart = phaseStartByPhase.get(phase);
            child.RDD__c = (phaseStart != null) ? phaseStart : headerRdd;
            if (contractTerm != null && phase1Start != null && phaseStart != null) {
                Decimal rem = contractTerm - phase1Start.monthsBetween(phaseStart);
                child.Remaining_Term__c = Math.max(0, Math.min(contractTerm, rem));
            } else if (contractTerm != null) {
                child.Remaining_Term__c = contractTerm;
            }
            childOrders.add(child);
        }

        insert childOrders;

        // Chain ramp orders: each phase's Original_Order__c → previous phase
        for (Integer i = 0; i < childOrders.size(); i++) {
            childOrders[i].Original_Order__c = (i == 0) ? parentOrderId : childOrders[i - 1].Id;
        }
        update childOrders;

        // Clone items BEFORE deleting originals (clone needs field values)
        List<OrderItem> newItems = new List<OrderItem>();
        List<OrderItem> itemsToDelete = new List<OrderItem>();

        for (Integer i = 0; i < phases.size(); i++) {
            Integer phase = phases[i];
            Id childOrderId = childOrders[i].Id;
            for (OrderItem orig : childPhaseMap.get(phase)) {
                OrderItem cloned = orig.clone(false, true, false, false);
                cloned.OrderId = childOrderId;
                cloned.Paired_MRC_OrderItem__c = null; // re-paired below
                newItems.add(cloned);
                itemsToDelete.add(orig);
            }
        }

        delete itemsToDelete;
        insert newItems;

        // Re-run NRC pairing on each child Order
        List<OrderItemNrcPairingService.Request> pairRequests = new List<OrderItemNrcPairingService.Request>();
        for (Order child : childOrders) {
            OrderItemNrcPairingService.Request req = new OrderItemNrcPairingService.Request();
            req.orderId = child.Id;
            pairRequests.add(req);
        }
        OrderItemNrcPairingService.pairNrcOrderItems(pairRequests);

        // FB-798 (Ramp MRC and TCV Calculation Spec): compute Order_MRC__c /
        // Total_Order_MRC__c — the incremental MRC each ramp order adds, not
        // the running total — now that every phase's Order/OrderItems exist.
        List<Order> ordersInPhaseOrder = new List<Order>{ parentOrder };
        ordersInPhaseOrder.addAll(childOrders);

        Map<Id, List<OrderItem>> itemsByOrderId = new Map<Id, List<OrderItem>>();
        itemsByOrderId.put(parentOrderId, phase1Items);
        for (OrderItem cloned : newItems) {
            if (!itemsByOrderId.containsKey(cloned.OrderId)) {
                itemsByOrderId.put(cloned.OrderId, new List<OrderItem>());
            }
            itemsByOrderId.get(cloned.OrderId).add(cloned);
        }

        OrderMrcRollupService.calculateForRampChain(ordersInPhaseOrder, itemsByOrderId);

        // FB-1041 (Ramp Child Opportunity Spec): give EVERY phase — 1 through
        // N — its own child Opportunity (Parent_Opportunity__c = the deal's
        // Opp), closed Won, and re-point that phase's Order onto it. Must run
        // BEFORE activation below — Order_AfterSave_WonAutoClose resolves the
        // Opportunity from the Order's OpportunityId at the moment Status
        // flips to Activated, so the repoint has to be in place first. Phase
        // 1's own Order (parentOrder) is activated later, outside this
        // method, by the calling flow — but it is already re-pointed by now.
        RampOppService.createRampChildren(parentOrder, childOrders);

        // Activate child orders — Salesforce does not allow inserting an Order as Activated;
        // must be created as Draft first and then updated to Activated in a separate DML.
        // This fires OrderTriggerHandler.handleAfterUpdate for each child, which routes
        // them to IP-1/IP-4 exactly as the parent order was routed by the SOFHandler flow.
        List<Order> toActivate = new List<Order>();
        for (Order child : childOrders) {
            toActivate.add(new Order(Id = child.Id, Status = 'Activated'));
        }
        update toActivate;
    }
}