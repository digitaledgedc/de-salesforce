/**
 * QuoteApprovalSubmitter
 * Invocable action for the Submit for Approval screen flow.
 * Submits a Quote to whichever approval process matches.
 */
public with sharing class QuoteApprovalSubmitter {

    public class Request {
        @InvocableVariable(label='Quote ID' required=true)
        public Id quoteId;
    }

    public class Result {
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;
        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    @InvocableMethod(label='Submit Quote for Approval' description='Submits a Quote to the approval process')
    public static List<Result> submit(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result r = new Result();
            try {
                Approval.ProcessSubmitRequest psr = new Approval.ProcessSubmitRequest();
                psr.setObjectId(req.quoteId);
                psr.setSubmitterId(UserInfo.getUserId());
                Approval.ProcessResult pr = Approval.process(psr);
                r.isSuccess = pr.isSuccess();
                if (!pr.isSuccess() && !pr.getErrors().isEmpty()) {
                    r.errorMessage = pr.getErrors()[0].getMessage();
                }
            } catch (Exception e) {
                r.isSuccess = false;
                r.errorMessage = e.getMessage();
            }
            results.add(r);
        }
        return results;
    }
}