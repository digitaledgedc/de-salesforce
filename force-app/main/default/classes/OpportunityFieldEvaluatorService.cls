public with sharing class OpportunityFieldEvaluatorService {

    public class EvalRequest {
        @InvocableVariable(required=true label='Opportunity Id')
        public Id opportunityId;

        @InvocableVariable(required=true label='Field API Name')
        public String fieldApiName;
    }

    public class EvalResult {
        @InvocableVariable(label='Is Field Blank')
        public Boolean isFieldBlank;

        @InvocableVariable(label='Field Value As String')
        public String fieldValueString;
    }

    @InvocableMethod(
        label='Evaluate Opportunity Field'
        description='Dynamically evaluates whether a named field on an Opportunity record is blank.'
    )
    public static List<EvalResult> evaluateFields(List<EvalRequest> requests) {
        if (requests == null || requests.isEmpty()) {
            return new List<EvalResult>();
        }

        Set<Id> oppIds = new Set<Id>();
        Set<String> fieldApiNames = new Set<String>();
        Map<String, Schema.SObjectField> fieldMap = Schema.SObjectType.Opportunity.fields.getMap();

        for (EvalRequest req : requests) {
            if (req.opportunityId != null && String.isNotBlank(req.fieldApiName)) {
                String normalized = req.fieldApiName.toLowerCase();
                if (fieldMap.containsKey(normalized)) {
                    oppIds.add(req.opportunityId);
                    fieldApiNames.add(req.fieldApiName);
                }
            }
        }

        Map<Id, Opportunity> oppMap = new Map<Id, Opportunity>();
        if (!oppIds.isEmpty() && !fieldApiNames.isEmpty()) {
            String soql = 'SELECT Id, ' + String.join(new List<String>(fieldApiNames), ', ')
                        + ' FROM Opportunity WHERE Id IN :oppIds WITH SECURITY_ENFORCED';
            oppMap = new Map<Id, Opportunity>((List<Opportunity>) Database.query(soql));
        }

        List<EvalResult> results = new List<EvalResult>();
        for (EvalRequest req : requests) {
            EvalResult res = new EvalResult();
            Opportunity opp = oppMap.get(req.opportunityId);
            if (opp == null) {
                res.isFieldBlank = true;
                res.fieldValueString = '';
            } else {
                Object val = opp.get(req.fieldApiName);
                res.isFieldBlank = (val == null || String.valueOf(val).trim() == '');
                res.fieldValueString = val != null ? String.valueOf(val) : '';
            }
            results.add(res);
        }
        return results;
    }
}