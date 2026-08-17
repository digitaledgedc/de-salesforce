/**
 * PricebookRequestTriggerHandler
 *
 * After-update handler for Pricebook_Request__c.
 * Delegates to PricebookRequestService when Status__c transitions to Approved.
 */
public with sharing class PricebookRequestTriggerHandler {

    public void run() {
        Set<Id> approvedIds = new Set<Id>();
        for (Pricebook_Request__c rec : (List<Pricebook_Request__c>) Trigger.new) {
            Pricebook_Request__c old = (Pricebook_Request__c) Trigger.oldMap.get(rec.Id);
            if (rec.Status__c == 'Approved' && old.Status__c != 'Approved') {
                approvedIds.add(rec.Id);
            }
        }
        if (!approvedIds.isEmpty()) {
            PricebookRequestService.materializeOnApproval(approvedIds);
        }
    }
}