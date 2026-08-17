/**
 * OrderApprovalService
 * Invocable Apex service called by the Order_Screen_SubmitForApproval flow.
 * Submits the Order record to the Order_Country_Manager_Approval approval process.
 *
 * Design notes:
 *   - The flow sets Status = Pending Approval before calling this action.
 *   - Approval process entry criteria requires Status = Pending Approval.
 *   - Approval is routed to the Country_Manager__c lookup field on the Order.
 *   - If Country_Manager__c is null, the approval process step will fail — the
 *     flow screen enforces that Country_Manager__c is set before submitting.
 */
public without sharing class OrderApprovalService {

    public class SubmitRequest {
        @InvocableVariable(required=true label='Order Id' description='Id of the Order to submit for Country Manager approval')
        public Id orderId;

        @InvocableVariable(label='Comments' description='Optional submission comments visible in the approval history feed')
        public String comments;
    }

    @InvocableMethod(
        label='Submit Order for Country Manager Approval'
        description='Submits the Order to the Order_Country_Manager_Approval process. Called by the Submit For Approval screen flow after Status is set to Pending Approval.'
    )
    public static void submitForApproval(List<SubmitRequest> requests) {
        if (requests == null || requests.isEmpty()) {
            return;
        }

        List<Approval.ProcessSubmitRequest> submitRequests = new List<Approval.ProcessSubmitRequest>();

        for (SubmitRequest req : requests) {
            if (req.orderId == null) {
                continue;
            }

            Approval.ProcessSubmitRequest aprReq = new Approval.ProcessSubmitRequest();
            aprReq.setObjectId(req.orderId);
            aprReq.setProcessDefinitionNameOrId('Order_Country_Manager_Approval');
            if (String.isNotBlank(req.comments)) {
                aprReq.setComments(req.comments);
            }
            submitRequests.add(aprReq);
        }

        if (!submitRequests.isEmpty()) {
            Approval.process(submitRequests);
        }
    }
}