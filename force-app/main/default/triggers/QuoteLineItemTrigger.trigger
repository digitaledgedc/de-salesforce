trigger QuoteLineItemTrigger on QuoteLineItem (before insert, before update, before delete,
                                                after insert, after update, after delete) {
    QuoteLineItemTriggerHandler handler = new QuoteLineItemTriggerHandler();
    handler.dispatch();
}