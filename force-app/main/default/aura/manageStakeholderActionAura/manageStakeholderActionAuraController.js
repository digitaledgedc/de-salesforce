({
    doInit: function(component, event, helper) {
        var flow = component.find('theFlow');
        var inputVars = [
            { name: 'recordId', type: 'String', value: component.get('v.recordId') }
        ];
        flow.startFlow('Opportunity_ManageStakeholders', inputVars);
    },

    handleStatusChange: function(component, event, helper) {
        var status = event.getParams().activeStages;
        if (status === 'FINISHED' || status === 'FINISHED_SCREEN') {
            $A.get('e.force:closeQuickAction').fire();
        }
    }
})