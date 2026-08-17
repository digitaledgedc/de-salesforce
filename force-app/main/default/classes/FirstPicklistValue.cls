public with sharing class FirstPicklistValue {
    private static final Map<String, String> COUNTRY_NAME_TO_CODE = new Map<String, String>{
        'Japan' => 'JP', 'Korea' => 'KR', 'China' => 'CN',
        'Philippines' => 'PH', 'Indonesia' => 'ID', 'Hong Kong' => 'HK',
        'Singapore' => 'SG', 'Thailand' => 'TH', 'India' => 'IN'
    };

    public class Request {
        @InvocableVariable(label='Multi-Select Picklist Value' required=true)
        public String picklistValue;
    }

    public class Result {
        @InvocableVariable(label='First Value')
        public String firstValue;
    }

    @InvocableMethod(label='Get First Picklist Value' description='Returns the first value from a semicolon-separated multi-select picklist string, converted to country code if applicable')
    public static List<Result> getFirst(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result r = new Result();
            if (String.isBlank(req.picklistValue)) {
                r.firstValue = null;
            } else {
                String first = req.picklistValue.substringBefore(';').trim();
                String code = COUNTRY_NAME_TO_CODE.get(first);
                r.firstValue = code != null ? code : first;
            }
            results.add(r);
        }
        return results;
    }
}