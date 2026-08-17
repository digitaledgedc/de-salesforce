trigger PricebookRequestTrigger on Pricebook_Request__c (after update) {
    new PricebookRequestTriggerHandler().run();
}