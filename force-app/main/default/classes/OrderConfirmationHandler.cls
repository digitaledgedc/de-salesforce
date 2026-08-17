/**
 * OrderConfirmationHandler
 * @InvocableMethod bridge between F-19 Screen Flow and the Queueable Apex layer.
 * Flows cannot directly enqueue a Queueable — this class is the bridge.
 * F-19 calls this as an Apex Action after all gates pass.
 */
public without sharing class OrderConfirmationHandler {

    @InvocableMethod(
        label='Confirm Order and Send to Odoo'
        description='Called by F-19 Order Confirmation Screen Flow after all gates pass. Routes to IP-1 New Order (New/Renewal) or IP-1 Change Order (Change/Churn/Suspension/Resumption).'
    )
    public static void confirmOrder(List<Id> orderIds) {
        // All Odoo routing is owned by OrderTriggerHandler.handleAfterUpdate, which fires
        // in the same transaction when Order Status → Activated.
        // Previously this method also enqueued OdooBanSyncQueueable via routeWithBanCheck(),
        // causing two concurrent jobs that both saw Odoo_BAN_ID__c = null and each called
        // create_partner + create_ban — creating duplicate Odoo partner and BAN records.
        // This method is intentionally a no-op; the trigger handles all routing.
    }
}