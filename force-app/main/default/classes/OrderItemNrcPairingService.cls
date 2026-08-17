/**
 * OrderItemNrcPairingService
 *
 * After Quote_AfterSave_SOFHandler (F-15) bulk-creates OrderItems from QLIs,
 * sets Paired_MRC_OrderItem__c on each NRC OrderItem by deriving the expected
 * NRC product code from the MRC product code (.RC suffix → .NR suffix).
 *
 * Called from Quote_AfterSave_SOFHandler as an Apex action immediately after
 * the Create_OrderItems element.
 *
 * Pairing rule: strip ".RC" from MRC product code, append ".NR".
 * Single-letter variant suffixes (e.g. CAB001C.RC → CAB001.NR) are stripped
 * to match the way NrcPairingService creates the NRC QLI.
 *
 * Bypass: TriggerBypass__mdt DeveloperName = 'OrderItemNrcPairing', Is_Active__c = true.
 */
// without sharing: invocable called from Quote_AfterSave_SOFHandler (system-context flow).
// NRC pairing is a data-integrity operation that must succeed regardless of the running
// user's FLS access to OrderItem fields. Sales Reps should not be blocked from accepting
// a quote by profile restrictions on internal order linkage fields.
public without sharing class OrderItemNrcPairingService {

    public class Request {
        @InvocableVariable(required=true)
        public Id orderId;
    }

    @InvocableMethod(
        label='Pair NRC Order Items to MRC'
        description='Sets Paired_MRC_OrderItem__c on NRC order items after SOFHandler creates them. Call immediately after Create_OrderItems.'
        category='Order'
    )
    public static void pairNrcOrderItems(List<Request> requests) {
        TriggerBypass__mdt bypass = TriggerBypass__mdt.getInstance('OrderItemNrcPairing');
        if (bypass != null && bypass.Is_Active__c) {
            return;
        }
        if (requests == null || requests.isEmpty()) {
            return;
        }

        Set<Id> orderIds = new Set<Id>();
        for (Request r : requests) {
            if (r.orderId != null) {
                orderIds.add(r.orderId);
            }
        }
        if (orderIds.isEmpty()) {
            return;
        }

        List<OrderItem> allOIs = [
            SELECT Id, OrderId, Charge_Type__c, Is_Auto_NRC__c,
                   Product2.ProductCode,
                   Product2.Paired_NRC_Product__r.ProductCode
            FROM OrderItem
            WHERE OrderId IN :orderIds
        ];

        if (allOIs.isEmpty()) {
            return;
        }

        // Build: (orderId + ':' + derivedNrcCode) → MRC OrderItem Id
        Map<String, Id> nrcKeyToMrcOIId = new Map<String, Id>();
        for (OrderItem oi : allOIs) {
            if (oi.Charge_Type__c != 'MRC') continue;
            if (oi.Product2 == null || String.isBlank(oi.Product2.ProductCode)) continue;
            // Prefer explicit Paired_NRC_Product lookup; fall back to code-based derivation
            String nrcCode = oi.Product2.Paired_NRC_Product__r != null
                    && String.isNotBlank(oi.Product2.Paired_NRC_Product__r.ProductCode)
                ? oi.Product2.Paired_NRC_Product__r.ProductCode
                : deriveNrcCode(oi.Product2.ProductCode);
            if (nrcCode == null) continue;
            nrcKeyToMrcOIId.put(oi.OrderId + ':' + nrcCode, oi.Id);
        }

        List<OrderItem> toUpdate = new List<OrderItem>();
        for (OrderItem oi : allOIs) {
            if (!oi.Is_Auto_NRC__c) continue;
            if (oi.Product2 == null || String.isBlank(oi.Product2.ProductCode)) continue;
            String key = oi.OrderId + ':' + oi.Product2.ProductCode;
            Id mrcId = nrcKeyToMrcOIId.get(key);
            if (mrcId == null) continue;
            toUpdate.add(new OrderItem(Id = oi.Id, Paired_MRC_OrderItem__c = mrcId));
        }

        if (toUpdate.isEmpty()) {
            return;
        }
        if (!OrderItem.SObjectType.getDescribe().isUpdateable()) {
            return;
        }
        update toUpdate;
    }

    /**
     * Derives the expected NRC product code from an MRC product code.
     *   CAB001.RC  → CAB001.NR
     *   CAB001C.RC → CAB001.NR  (strips single-letter variant suffix preceded by digit)
     * Returns null if productCode is blank or does not end with '.RC'.
     */
    @TestVisible
    private static String deriveNrcCode(String mrcProductCode) {
        if (String.isBlank(mrcProductCode)) return null;
        if (!mrcProductCode.endsWith('.RC')) return null;
        String base = mrcProductCode.removeEnd('.RC');
        if (Pattern.matches('.*\\d[A-Z]$', base)) {
            base = base.left(base.length() - 1);
        }
        return base + '.NR';
    }
}