/**
 * InventoryController
 * Apex controller for the deCapacityReserve LWC — capacity assignment
 * component on the Quote record page.
 *
 * Resolves site via Quote → Opportunity → Target_Site__c.
 * Returns ALL Inventory_Space at the site in a single query so the
 * LWC can partition client-side (this quote / available / other held).
 *
 * Provisional assignment sets Assigned_To_Quote__c without changing
 * Status__c — formal status transitions (Quoted, Reserved, Sold)
 * are gated by validation rules requiring Quote_Line__c / Order__c /
 * Order_Item__c respectively.
 *
 * FLS enforced via Security.stripInaccessible on all reads.
 * CRUD checked before all DML.
 */
public with sharing class InventoryController {

    private static final Set<String> AVAILABLE_STATUSES = new Set<String>{ 'Available', 'Pending Available' };
    private static final Set<String> SPACE_BREAKER_RTS  = new Set<String>{ 'Inventory_Space', 'Inventory_Breaker' };

    // ── Read: Site info from Quote ──────────────────────────────────

    @AuraEnabled
    public static Map<String, String> getQuoteSiteInfo(Id quoteId) {
        List<Quote> quotes = [
            SELECT Id, OpportunityId, Opportunity.Target_Site__c,
                   Opportunity.Target_Site__r.Name,
                   Opportunity.Target_Site__r.Site_Code__c
            FROM Quote
            WHERE Id = :quoteId
            WITH SECURITY_ENFORCED
            LIMIT 1
        ];
        if (quotes.isEmpty() || quotes[0].Opportunity.Target_Site__c == null) {
            return null;
        }
        return new Map<String, String>{
            'id'       => quotes[0].Opportunity.Target_Site__c,
            'name'     => quotes[0].Opportunity.Target_Site__r.Name,
            'siteCode' => quotes[0].Opportunity.Target_Site__r.Site_Code__c,
            'oppId'    => quotes[0].OpportunityId
        };
    }

    // ── Read: All Space inventory at the quote's site ───────────────

    @AuraEnabled
    public static List<Inventory__c> getSiteInventoryForQuote(Id quoteId, String statusFilter) {
        List<Quote> quotes = [
            SELECT Id, Opportunity.Target_Site__c
            FROM Quote
            WHERE Id = :quoteId
            WITH SECURITY_ENFORCED
            LIMIT 1
        ];
        if (quotes.isEmpty() || quotes[0].Opportunity.Target_Site__c == null) {
            return new List<Inventory__c>();
        }
        Id siteId = quotes[0].Opportunity.Target_Site__c;

        String q = 'SELECT Id, Name, RecordType.DeveloperName, '
            + 'Site_Id__c, Site_Id__r.Site_Code__c, Site_Id__r.Name, '
            + 'Floor__c, Floor__r.Name, '
            + 'Data_Hall__c, Data_Hall__r.Name, '
            + 'Space_Type__c, Status__c, '
            + 'Unit_Reference__c, Hall__c, Cage_ID__c, '
            + 'Total_Capacity_kVA__c, Total_IT_Power_kVA__c, CabE_Count__c, '
            + 'Power_kVA__c, Total_Area_sqm__c, '
            + 'Account__c, Account__r.Name, '
            + 'Opportunity__c, Opportunity__r.Name, '
            + 'Assigned_To_Quote__c, Assigned_To_Quote__r.QuoteNumber, '
            + 'Quote_Line__c, Quote_Line__r.Product2.Name, '
            + 'Order__c, Order__r.Order_Number__c, '
            + 'Order_Item__c '
            + 'FROM Inventory__c '
            + 'WHERE Site_Id__c = :siteId '
            + 'AND RecordType.DeveloperName IN :SPACE_BREAKER_RTS';

        if (String.isNotBlank(statusFilter) && statusFilter != 'All') {
            q += ' AND Status__c = :statusFilter';
        }

        q += ' ORDER BY Floor__r.Name ASC NULLS LAST, '
           + 'Data_Hall__r.Name ASC NULLS LAST, Name ASC';

        List<Inventory__c> records = Database.query(q);
        return stripped(records);
    }

    // ── Read: Summary counts for the quote's site ───────────────────

    @AuraEnabled
    public static Map<String, Integer> getQuoteInventorySummary(Id quoteId) {
        List<Quote> quotes = [
            SELECT Id, Opportunity.Target_Site__c
            FROM Quote
            WHERE Id = :quoteId
            WITH SECURITY_ENFORCED
            LIMIT 1
        ];
        if (quotes.isEmpty() || quotes[0].Opportunity.Target_Site__c == null) {
            return new Map<String, Integer>();
        }
        Id siteId = quotes[0].Opportunity.Target_Site__c;

        // Status breakdown
        List<AggregateResult> agg = [
            SELECT Status__c s, COUNT(Id) c
            FROM Inventory__c
            WHERE Site_Id__c = :siteId
              AND RecordType.DeveloperName IN :SPACE_BREAKER_RTS
            WITH SECURITY_ENFORCED
            GROUP BY Status__c
        ];
        Map<String, Integer> m = new Map<String, Integer>();
        Integer total = 0;
        for (AggregateResult a : agg) {
            String status = (String) a.get('s');
            Integer cnt = (Integer) a.get('c');
            m.put(status, cnt);
            total += cnt;
        }
        m.put('total', total);

        // Count assigned to THIS quote
        Integer thisQuote = [
            SELECT COUNT()
            FROM Inventory__c
            WHERE Site_Id__c = :siteId
              AND RecordType.DeveloperName IN :SPACE_BREAKER_RTS
              AND Assigned_To_Quote__c = :quoteId
            WITH SECURITY_ENFORCED
        ];
        m.put('thisQuote', thisQuote);

        // Count assigned to OTHER quotes
        Integer otherHeld = [
            SELECT COUNT()
            FROM Inventory__c
            WHERE Site_Id__c = :siteId
              AND RecordType.DeveloperName IN :SPACE_BREAKER_RTS
              AND Assigned_To_Quote__c != null
              AND Assigned_To_Quote__c != :quoteId
            WITH SECURITY_ENFORCED
        ];
        m.put('otherHeld', otherHeld);

        return m;
    }

    // ── DML: Bulk assign inventory to quote ──────────────────────

    @AuraEnabled
    public static Integer bulkAssignToQuote(List<Id> inventoryIds, Id quoteId) {
        checkAssignmentFLS();
        List<Quote> quotes = [
            SELECT OpportunityId, Opportunity.AccountId
            FROM Quote WHERE Id = :quoteId
            WITH SECURITY_ENFORCED LIMIT 1
        ];
        if (quotes.isEmpty()) {
            throw new AuraHandledException('Quote not found.');
        }
        Id oppId = quotes[0].OpportunityId;
        Id acctId = quotes[0].Opportunity.AccountId;
        List<Inventory__c> toUpdate = new List<Inventory__c>();
        for (Id invId : inventoryIds) {
            toUpdate.add(new Inventory__c(
                Id                   = invId,
                Assigned_To_Quote__c = quoteId,
                Opportunity__c       = oppId,
                Account__c           = acctId
            ));
        }
        new InventorySystemDml().doUpdate(toUpdate);
        return toUpdate.size();
    }

    // ── DML: Bulk release assignment ──────────────────────────────

    @AuraEnabled
    public static Integer bulkReleaseFromQuote(List<Id> inventoryIds) {
        checkAssignmentFLS();
        List<Inventory__c> toUpdate = new List<Inventory__c>();
        for (Id invId : inventoryIds) {
            toUpdate.add(new Inventory__c(
                Id                   = invId,
                Assigned_To_Quote__c = null,
                Quote_Line__c        = null,
                Opportunity__c       = null,
                Account__c           = null,
                Status__c            = 'Available'
            ));
        }
        new InventorySystemDml().doUpdate(toUpdate);
        return toUpdate.size();
    }

    // ── Read: Inventory context for a specific Quote Line Item ─────

    @AuraEnabled
    public static Map<String, Object> getLineInventory(Id quoteLineItemId, Id quoteId, String inventoryType) {
        List<Quote> quotes = [
            SELECT Id, Opportunity.Target_Site__c
            FROM Quote WHERE Id = :quoteId
            WITH SECURITY_ENFORCED LIMIT 1
        ];
        if (quotes.isEmpty() || quotes[0].Opportunity.Target_Site__c == null) {
            return new Map<String, Object>{
                'assigned' => new List<Inventory__c>(),
                'available' => new List<Inventory__c>()
            };
        }
        Id siteId = quotes[0].Opportunity.Target_Site__c;

        // Determine which record types to query
        Set<String> rtFilter;
        if (inventoryType == 'Breaker') {
            rtFilter = new Set<String>{ 'Inventory_Breaker' };
        } else if (inventoryType == 'Space') {
            rtFilter = new Set<String>{ 'Inventory_Space' };
        } else {
            rtFilter = SPACE_BREAKER_RTS;
        }

        // Inventory assigned to this specific QLI
        List<Inventory__c> assigned = [
            SELECT Id, Name, RecordType.DeveloperName,
                   Unit_Reference__c, Space_Type__c, Status__c,
                   Floor__r.Name, Data_Hall__r.Name,
                   Total_IT_Power_kVA__c, Total_Capacity_kVA__c,
                   Power_kVA__c, CabE_Count__c
            FROM Inventory__c
            WHERE Quote_Line__c = :quoteLineItemId
              AND RecordType.DeveloperName IN :SPACE_BREAKER_RTS
        ];

        // Available inventory at the site — filtered by type
        List<Inventory__c> available = [
            SELECT Id, Name, RecordType.DeveloperName,
                   Unit_Reference__c, Space_Type__c, Status__c,
                   Floor__r.Name, Data_Hall__r.Name,
                   Total_IT_Power_kVA__c, Total_Capacity_kVA__c,
                   Power_kVA__c, CabE_Count__c
            FROM Inventory__c
            WHERE Site_Id__c = :siteId
              AND RecordType.DeveloperName IN :rtFilter
              AND Status__c IN :AVAILABLE_STATUSES
              AND Assigned_To_Quote__c = null
            ORDER BY Floor__r.Name ASC NULLS LAST,
                     Data_Hall__r.Name ASC NULLS LAST, Name ASC
            LIMIT 500
        ];

        return new Map<String, Object>{
            'assigned'  => stripped(assigned),
            'available' => stripped(available)
        };
    }

    // ── DML: Assign inventory to a specific Quote Line Item ─────────

    @AuraEnabled
    public static Integer assignInventoryToLine(List<Id> inventoryIds, Id quoteLineItemId, Id quoteId) {
        checkAssignmentFLS();
        List<Quote> quotes = [
            SELECT OpportunityId, Opportunity.AccountId
            FROM Quote WHERE Id = :quoteId
            WITH SECURITY_ENFORCED LIMIT 1
        ];
        if (quotes.isEmpty()) {
            throw new AuraHandledException('Quote not found.');
        }
        Id oppId  = quotes[0].OpportunityId;
        Id acctId = quotes[0].Opportunity.AccountId;

        // Reject assignments that would exceed the line's needed quantity — the UI
        // has client-side guards for this, but they can be bypassed by stale
        // selection state, so the server must enforce the cap independently.
        // FB-779: for a ramped line the needed quantity is the aggregate across
        // ramp phases (matching the Lines grid), not the Phase-1 record's raw
        // Quantity — see effectiveNeededQty.
        Decimal neededQty = effectiveNeededQty(quoteLineItemId);
        if (neededQty != null && neededQty > 0) {
            Integer alreadyAssigned = [
                SELECT COUNT() FROM Inventory__c
                WHERE Quote_Line__c = :quoteLineItemId AND Id NOT IN :inventoryIds
            ];
            if (alreadyAssigned + inventoryIds.size() > neededQty) {
                throw new AuraHandledException('Cannot assign ' + inventoryIds.size()
                    + ' item(s): this line only needs ' + neededQty.setScale(0) + ', and '
                    + alreadyAssigned + ' are already assigned.');
            }
        }

        List<Inventory__c> toUpdate = new List<Inventory__c>();
        for (Id invId : inventoryIds) {
            toUpdate.add(new Inventory__c(
                Id                   = invId,
                Assigned_To_Quote__c = quoteId,
                Quote_Line__c        = quoteLineItemId,
                Opportunity__c       = oppId,
                Account__c           = acctId,
                Status__c            = 'Assigned'
            ));
        }
        new InventorySystemDml().doUpdate(toUpdate);

        // Only mark as Reserved when ALL needed inventory is assigned (count >= Quantity)
        if (Schema.sObjectType.QuoteLineItem.isUpdateable()
            && Schema.sObjectType.QuoteLineItem.fields.Reserved__c.isUpdateable()) {
            Integer assignedCount = [
                SELECT COUNT() FROM Inventory__c
                WHERE Quote_Line__c = :quoteLineItemId
            ];
            List<QuoteLineItem> qlis = [
                SELECT Reserved__c FROM QuoteLineItem
                WHERE Id = :quoteLineItemId LIMIT 1
            ];
            // FB-779: reuse the ramp-aware needed quantity computed above so the
            // Reserved flip triggers only when the full ramp footprint is assigned.
            Decimal reservedNeededQty = (neededQty == null) ? 0 : neededQty;
            String newStatus = (reservedNeededQty > 0 && assignedCount >= reservedNeededQty) ? 'Reserved' : 'Not Reserved';
            String currentStatus = qlis.isEmpty() ? null : qlis[0].Reserved__c;
            if (newStatus != currentStatus) {
                new InventorySystemDml().doUpdate(
                    new List<QuoteLineItem>{ new QuoteLineItem(Id = quoteLineItemId, Reserved__c = newStatus) });
            }
        }

        return toUpdate.size();
    }

    // FB-779: A ramped product is stored as one QuoteLineItem per phase, linked
    // via Ramp_Parent_Line__c. The physical inventory footprint to reserve is the
    // peak across the schedule, which the Lines grid already shows. Mirror that
    // aggregation here so the server cap and the Reserved flip match the grid:
    //   • aggregate products (Merge_IB_Task) → last (running-peak) phase quantity
    //   • other ramp products → sum of net additions (unlinked phase quantities)
    //   • non-ramp lines → their own Quantity
    @TestVisible
    private static Decimal effectiveNeededQty(Id quoteLineItemId) {
        List<QuoteLineItem> lines = [
            SELECT Id, Quantity, Line_Origin__c, Ramp_Phase__c, Charge_Type__c,
                   Ramp_Parent_Line__c, Ramp_Linked_Phase__c,
                   Merge_IB_Task__c, Product2Id, Product2.Merge_IB_Task__c
            FROM QuoteLineItem
            WHERE Id = :quoteLineItemId
            LIMIT 1
        ];
        if (lines.isEmpty()) return null;
        QuoteLineItem line = lines[0];

        Boolean isRampParent = line.Line_Origin__c == 'Ramp'
            && line.Ramp_Phase__c == 1
            && line.Charge_Type__c != 'NRC';
        if (!isRampParent) return line.Quantity;

        List<QuoteLineItem> siblings = [
            SELECT Id, Quantity, Ramp_Phase__c, Ramp_Linked_Phase__c
            FROM QuoteLineItem
            WHERE Line_Origin__c = 'Ramp'
              AND Charge_Type__c != 'NRC'
              AND (Ramp_Parent_Line__c = :line.Id OR Id = :line.Id)
        ];
        if (siblings.isEmpty()) return line.Quantity;

        Boolean isAggregate = line.Merge_IB_Task__c == true
            || (line.Product2Id != null && line.Product2.Merge_IB_Task__c == true);
        if (isAggregate) {
            QuoteLineItem last = siblings[0];
            for (QuoteLineItem s : siblings) {
                Decimal sPhase = (s.Ramp_Phase__c == null) ? 0 : s.Ramp_Phase__c;
                Decimal lPhase = (last.Ramp_Phase__c == null) ? 0 : last.Ramp_Phase__c;
                if (sPhase > lPhase) last = s;
            }
            return (last.Quantity == null) ? 0 : last.Quantity;
        }
        Decimal sum = 0;
        for (QuoteLineItem s : siblings) {
            if (s.Ramp_Linked_Phase__c == null) {
                sum += (s.Quantity == null) ? 0 : s.Quantity;
            }
        }
        return sum;
    }

    // ── DML: Release inventory from a Quote Line Item ───────────────

    @AuraEnabled
    public static Integer releaseInventoryFromLine(List<Id> inventoryIds) {
        checkAssignmentFLS();

        // Capture affected QLI IDs before clearing the links
        Set<Id> affectedQliIds = new Set<Id>();
        for (Inventory__c inv : [
            SELECT Quote_Line__c FROM Inventory__c
            WHERE Id IN :inventoryIds AND Quote_Line__c != null
            WITH SECURITY_ENFORCED
        ]) {
            affectedQliIds.add(inv.Quote_Line__c);
        }

        List<Inventory__c> toUpdate = new List<Inventory__c>();
        for (Id invId : inventoryIds) {
            toUpdate.add(new Inventory__c(
                Id                   = invId,
                Assigned_To_Quote__c = null,
                Quote_Line__c        = null,
                Opportunity__c       = null,
                Account__c           = null,
                Status__c            = 'Available'
            ));
        }
        new InventorySystemDml().doUpdate(toUpdate);

        // Re-evaluate Reserved status for each affected QLI based on count vs Quantity
        if (!affectedQliIds.isEmpty()
            && Schema.sObjectType.QuoteLineItem.isUpdateable()
            && Schema.sObjectType.QuoteLineItem.fields.Reserved__c.isUpdateable()) {
            // Count remaining inventory per QLI
            Map<Id, Integer> remainingCounts = new Map<Id, Integer>();
            for (Id qliId : affectedQliIds) {
                remainingCounts.put(qliId, 0);
            }
            for (AggregateResult ar : [
                SELECT Quote_Line__c qli, COUNT(Id) cnt
                FROM Inventory__c
                WHERE Quote_Line__c IN :affectedQliIds
                GROUP BY Quote_Line__c
            ]) {
                remainingCounts.put((Id) ar.get('qli'), (Integer) ar.get('cnt'));
            }
            // Get Quantity for each QLI
            Map<Id, Decimal> qliQty = new Map<Id, Decimal>();
            Map<Id, String> currentReserved = new Map<Id, String>();
            for (QuoteLineItem qli : [
                SELECT Id, Quantity, Reserved__c FROM QuoteLineItem
                WHERE Id IN :affectedQliIds
            ]) {
                qliQty.put(qli.Id, qli.Quantity == null ? 0 : qli.Quantity);
                currentReserved.put(qli.Id, qli.Reserved__c);
            }
            // Set Reserved only when count >= Quantity, otherwise Not Reserved — skip if unchanged
            List<QuoteLineItem> qliUpdates = new List<QuoteLineItem>();
            for (Id qliId : affectedQliIds) {
                Integer remaining = remainingCounts.containsKey(qliId) ? remainingCounts.get(qliId) : 0;
                Decimal needed = qliQty.containsKey(qliId) ? qliQty.get(qliId) : 0;
                String newStatus = (needed > 0 && remaining >= needed) ? 'Reserved' : 'Not Reserved';
                if (newStatus != currentReserved.get(qliId)) {
                    qliUpdates.add(new QuoteLineItem(Id = qliId, Reserved__c = newStatus));
                }
            }
            if (!qliUpdates.isEmpty()) {
                new InventorySystemDml().doUpdate(qliUpdates);
            }
        }

        return toUpdate.size();
    }

    // ── Helper ─────────────────────────────────────────────────────

    /**
     * Validates CRUD + FLS on the four assignment fields before DML.
     * Throws AuraHandledException with a specific message listing
     * which fields the user cannot edit — prevents the silent no-op
     * that stripInaccessible causes when it strips required fields.
     */
    private static void checkAssignmentFLS() {
        if (!Schema.sObjectType.Inventory__c.isUpdateable()) {
            throw new AuraHandledException(
                'You do not have permission to edit Inventory records. Contact your administrator.');
        }
        List<String> missing = new List<String>();
        if (!Schema.sObjectType.Inventory__c.fields.Assigned_To_Quote__c.isUpdateable()) {
            missing.add('Assigned To Quote');
        }
        if (!Schema.sObjectType.Inventory__c.fields.Quote_Line__c.isUpdateable()) {
            missing.add('Quote Line');
        }
        if (!Schema.sObjectType.Inventory__c.fields.Opportunity__c.isUpdateable()) {
            missing.add('Opportunity');
        }
        if (!Schema.sObjectType.Inventory__c.fields.Account__c.isUpdateable()) {
            missing.add('Account');
        }
        if (!Schema.sObjectType.Inventory__c.fields.Status__c.isUpdateable()) {
            missing.add('Status');
        }
        if (!missing.isEmpty()) {
            throw new AuraHandledException(
                'Missing edit permission on Inventory fields: ' +
                String.join(missing, ', ') +
                '. Contact your administrator to update your permission set.');
        }
    }

    // ── Invocable: Mark inventory Sold on Order confirmation ──────

    /**
     * Called from Order_Screen_ConfirmOrder flow after Order is Activated.
     * Finds all Inventory__c linked via Quote_Line__c → OrderItem →
     * QuoteLineItemId, sets Status__c = 'Sold', and stamps Order__c /
     * Order_Item__c on each Inventory record.
     */
    @InvocableMethod(label='Mark Inventory Sold for Order'
                     description='Sets Status=Sold and tags Order/OrderItem on Inventory linked to this Order via QLI.'
                     category='Inventory')
    public static void markInventorySoldForOrder(List<Id> orderIds) {
        if (orderIds == null || orderIds.isEmpty()) return;
        Id orderId = orderIds[0];

        // Get OrderItems with their source QLI
        List<OrderItem> ois = [
            SELECT Id, QuoteLineItemId
            FROM OrderItem
            WHERE OrderId = :orderId
              AND QuoteLineItemId != null
        ];
        if (ois.isEmpty()) return;

        // Build QLI → OrderItem map and reverse map
        Map<Id, Id> qliToOi = new Map<Id, Id>();
        Map<Id, OrderItem> oiMap = new Map<Id, OrderItem>();
        Set<Id> qliIds = new Set<Id>();
        for (OrderItem oi : ois) {
            qliToOi.put(oi.QuoteLineItemId, oi.Id);
            oiMap.put(oi.Id, oi);
            qliIds.add(oi.QuoteLineItemId);
        }

        // Get all Inventory linked to those QLIs — include RecordType for Space vs Breaker
        List<Inventory__c> invRecords = [
            SELECT Id, Quote_Line__c, RecordType.DeveloperName
            FROM Inventory__c
            WHERE Quote_Line__c IN :qliIds
        ];
        if (invRecords.isEmpty()) return;

        // 1. Update Inventory records — stamp Order, OrderItem, Status=Sold
        List<Inventory__c> toUpdate = new List<Inventory__c>();
        // 2. Track first Space and first Breaker per OrderItem for IP-1 integration
        Map<Id, Id> oiToSpace   = new Map<Id, Id>();  // OrderItemId → first Space Inventory Id
        Map<Id, Id> oiToBreaker = new Map<Id, Id>();  // OrderItemId → first Breaker Inventory Id

        for (Inventory__c inv : invRecords) {
            Id orderItemId = qliToOi.get(inv.Quote_Line__c);
            toUpdate.add(new Inventory__c(
                Id           = inv.Id,
                Status__c    = 'Sold',
                Order__c     = orderId,
                Order_Item__c = orderItemId
            ));
            // Map first Space and first Breaker per OrderItem
            if (inv.RecordType.DeveloperName == 'Inventory_Space' && !oiToSpace.containsKey(orderItemId)) {
                oiToSpace.put(orderItemId, inv.Id);
            } else if (inv.RecordType.DeveloperName == 'Inventory_Breaker' && !oiToBreaker.containsKey(orderItemId)) {
                oiToBreaker.put(orderItemId, inv.Id);
            }
        }
        update toUpdate;

        // 3. Stamp OrderItem.Space__c and OrderItem.Inventory__c for IP-1 ns_space_ids / ns_breaker_ids
        List<OrderItem> oiUpdates = new List<OrderItem>();
        for (Id oiId : oiMap.keySet()) {
            Id spaceId   = oiToSpace.get(oiId);
            Id breakerId = oiToBreaker.get(oiId);
            if (spaceId != null || breakerId != null) {
                OrderItem upd = new OrderItem(Id = oiId);
                if (spaceId != null)   upd.Space__c     = spaceId;
                if (breakerId != null) upd.Inventory__c  = breakerId;
                oiUpdates.add(upd);
            }
        }
        if (!oiUpdates.isEmpty()) {
            update oiUpdates;
        }
    }

    private static List<SObject> stripped(List<SObject> records) {
        return Security.stripInaccessible(AccessType.READABLE, records)
            .getRecords();
    }

    /**
     * System-context DML for inventory assign/release. Inventory is Public-Read with
     * mixed ownership, so a Capacity Manager cannot edit inventory they do not own via
     * the sharing model. Assigning/releasing inventory is a controlled capacity operation
     * and must not depend on record ownership. FLS and Quote access are still enforced by
     * the callers (checkAssignmentFLS + WITH SECURITY_ENFORCED); only the row-level sharing
     * on the Inventory update is elevated here. QuoteLineItem updates remain in user context.
     * Approved by Alosh 2026-07-09.
     */
    private without sharing class InventorySystemDml {
        void doUpdate(List<Inventory__c> recs) {
            update recs;
        }
        // Reservation status (QuoteLineItem.Reserved__c) is a system-maintained capacity
        // field updated as a consequence of assign/release. Elevated so a Capacity Manager
        // can reserve inventory on a quote line regardless of who owns the quote (Quote OWD
        // is Private). ONLY Reserved__c is written here — no other quote/line data.
        // Approved by Alosh 2026-07-09 (extension of the inventory assign/release elevation).
        void doUpdate(List<QuoteLineItem> recs) {
            update recs;
        }
    }
}