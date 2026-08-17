/**
 * OrderNumberGenerator — generates Order_Number__c values for new Orders.
 *
 * Format: {Opportunity_Number__c}-OR-{N}
 *   where N = count of existing Orders on the same Opportunity + 1 (1-based).
 *   Example: 2600042-OR-1 (first Order), 2600042-OR-2 (amendment/second Order).
 *
 * IP-1 payload includes Order_Number__c — a null value breaks Odoo reconciliation.
 * This generator ensures Order_Number__c is never null on a confirmed Order.
 *
 * Design decisions:
 *   - without sharing: must read all sibling Orders on the Opportunity regardless
 *     of ownership (e.g. Orders owned by other reps on the same deal).
 *   - Bulkified: two SOQLs total regardless of batch size.
 *   - Gaps OK: a deleted Order leaves a gap in the sequence. Acceptable per SDD.
 *   - Orders without an OpportunityId are skipped with Order_Number__c left blank
 *     (standalone Orders are not in scope for Digital Edge Phase 1).
 *
 * Work item: G-20
 */
public without sharing class OrderNumberGenerator {

    public class OrderNumberGeneratorException extends Exception {}

    /**
     * Assigns Order_Number__c to all Orders in the list that do not already have
     * a number. Safe to call in before-insert context only.
     *
     * @param orders  List of Order records from Trigger.new
     */
    public static void assignNumbers(List<Order> orders) {
        if (orders == null || orders.isEmpty()) {
            return;
        }

        List<Order> needsNumber = new List<Order>();
        Set<Id> oppIds = new Set<Id>();

        for (Order ord : orders) {
            if (String.isBlank(ord.Order_Number__c) && ord.OpportunityId != null) {
                needsNumber.add(ord);
                oppIds.add(ord.OpportunityId);
            }
        }
        if (needsNumber.isEmpty()) {
            return;
        }

        // SOQL 1: fetch Opportunity_Number__c for all parent Opportunities
        Map<Id, String> oppNumberById = new Map<Id, String>();
        for (Opportunity opp : [
            SELECT Id, Opportunity_Number__c
            FROM Opportunity
            WHERE Id IN :oppIds
        ]) {
            oppNumberById.put(opp.Id, opp.Opportunity_Number__c);
        }

        // SOQL 2: count existing Orders per Opportunity so sequence continues correctly
        Map<Id, Integer> existingCountByOppId = new Map<Id, Integer>();
        for (AggregateResult ar : [
            SELECT OpportunityId, COUNT(Id) cnt
            FROM Order
            WHERE OpportunityId IN :oppIds
            GROUP BY OpportunityId
        ]) {
            existingCountByOppId.put(
                (Id) ar.get('OpportunityId'),
                Integer.valueOf(ar.get('cnt'))
            );
        }

        // In-memory sequence increment handles multiple Orders for the same Opp in one batch
        Map<Id, Integer> inBatchCountByOppId = new Map<Id, Integer>();

        for (Order ord : needsNumber) {
            String oppNumber = oppNumberById.get(ord.OpportunityId);
            if (String.isBlank(oppNumber)) {
                // Parent Opportunity has no number yet — skip; Order_Number__c stays blank.
                // This should not occur in normal flow (Opp number is set before Opp is confirmed).
                continue;
            }

            Integer existingCount = existingCountByOppId.containsKey(ord.OpportunityId)
                ? existingCountByOppId.get(ord.OpportunityId)
                : 0;
            Integer inBatchCount = inBatchCountByOppId.containsKey(ord.OpportunityId)
                ? inBatchCountByOppId.get(ord.OpportunityId)
                : 0;

            Integer sequence = existingCount + inBatchCount + 1;
            ord.Order_Number__c = oppNumber + '-OR-' + sequence;

            inBatchCountByOppId.put(ord.OpportunityId, inBatchCount + 1);
        }
    }
}