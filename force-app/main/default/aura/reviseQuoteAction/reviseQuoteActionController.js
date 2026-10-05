({
    handleCancel : function (component) {
        $A.get("e.force:closeQuickAction").fire();
    },

    handleConfirm : function (component) {
        if (component.get("v.isProcessing")) {
            return;
        }
        component.set("v.isProcessing", true);

        var action = component.get("c.reviseQuote");
        action.setParams({ quoteId : component.get("v.recordId") });
        action.setCallback(this, function (response) {
            var state = response.getState();
            if (state === "SUCCESS") {
                var newQuoteId = response.getReturnValue();
                $A.get("e.force:closeQuickAction").fire();
                if (newQuoteId) {
                    var navEvt = $A.get("e.force:navigateToSObject");
                    navEvt.setParams({ recordId : newQuoteId });
                    navEvt.fire();
                } else {
                    $A.get("e.force:refreshView").fire();
                }
            } else {
                component.set("v.isProcessing", false);
                $A.get("e.force:closeQuickAction").fire();
                var errors = response.getError();
                var msg = "An error occurred while revising the quote.";
                if (errors && errors[0] && errors[0].message) {
                    msg = errors[0].message;
                }
                var toastEvent = $A.get("e.force:showToast");
                toastEvent.setParams({
                    title   : "Error",
                    message : msg,
                    type    : "error"
                });
                toastEvent.fire();
            }
        });
        $A.enqueueAction(action);
    }
})