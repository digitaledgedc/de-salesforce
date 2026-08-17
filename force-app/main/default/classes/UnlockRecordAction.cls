/**
 * Invocable Apex: submits a record for a named approval process, then immediately
 * unlocks it so the record stays editable while the approval is pending.
 * Used for SBI approval on Quote — record must remain editable until Accept.
 */
public with sharing class UnlockRecordAction {

    public class Request {
        @InvocableVariable(label='Record ID' required=true)
        public Id recordId;
        @InvocableVariable(label='Approval Process Name' required=true)
        public String processName;
        @InvocableVariable(label='Comment')
        public String comment;
    }

    @InvocableMethod(label='Submit and Unlock' description='Submits for approval then unlocks the record' category='Approval')
    public static void submitAndUnlock(List<Request> requests) {
        for (Request req : requests) {
            Approval.ProcessSubmitRequest psr = new Approval.ProcessSubmitRequest();
            psr.setObjectId(req.recordId);
            psr.setProcessDefinitionNameOrId(req.processName);
            if (String.isNotBlank(req.comment)) {
                psr.setComments(req.comment);
            }
            psr.setSkipEntryCriteria(false);
            Approval.ProcessResult result = Approval.process(psr);
            if (result.isSuccess()) {
                Approval.unlock(new List<Id>{ req.recordId });
            }
        }
    }
}