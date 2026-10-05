({
    doInit : function (component) {
        var flow = component.find("flow");
        var inputVariables = [];
        var parentId = null;

        // 1) Some contexts pass the parent directly as recordId.
        var recId = component.get("v.recordId");
        if (recId) { parentId = recId; }

        // 2) Related-list "New" passes the parent via pageReference.state.inContextOfRef
        //    (base64-encoded reference). Decode it to recover the parent record Id.
        if (!parentId) {
            try {
                var pageRef = component.get("v.pageReference");
                var ref = pageRef && pageRef.state ? pageRef.state.inContextOfRef : null;
                if (ref) {
                    if (ref.indexOf("1.") === 0) { ref = ref.substring(2); }
                    // normalise base64url -> base64
                    ref = ref.replace(/-/g, "+").replace(/_/g, "/");
                    var ctx = JSON.parse(window.atob(ref));
                    if (ctx) {
                        parentId = (ctx.attributes && ctx.attributes.recordId)
                            || ctx.recordId || ctx.contextId || null;
                    }
                }
            } catch (e) {
                // Couldn't resolve parent — fall back to manual Account selection.
            }
        }

        // Only pass an Account parent (Id prefix 001); the flow keys on that to pre-fill Account.
        if (parentId && parentId.indexOf("001") === 0) {
            inputVariables.push({ name : "recordId", type : "String", value : parentId });
        }

        flow.startFlow("Opportunity_Screen_NewOpportunity", inputVariables);
    },
    handleStatusChange : function (component, event) {
        var status = event.getParam("status");
        if (status === "FINISHED" || status === "FINISHED_SCREEN") {
            // The flow's internal flowNavigateToRecord component redirects to the new Opportunity.
        }
    }
})