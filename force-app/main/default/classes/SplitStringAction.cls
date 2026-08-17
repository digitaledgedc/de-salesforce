global class SplitStringAction {

    @InvocableMethod(label='Split String by Delimiter'
                     description='Splits a delimited string into a list of strings. Use to split Salesforce multi-select picklist values.')
    global static List<List<String>> split(List<SplitRequest> requests) {
        List<List<String>> results = new List<List<String>>();
        for (SplitRequest req : requests) {
            List<String> parts = new List<String>();
            if (String.isNotBlank(req.inputString)) {
                for (String s : req.inputString.split(req.delimiter)) {
                    String trimmed = s.trim();
                    if (String.isNotBlank(trimmed)) {
                        parts.add(trimmed);
                    }
                }
            }
            results.add(parts);
        }
        return results;
    }

    global class SplitRequest {
        @InvocableVariable(label='Input String' required=true)
        global String inputString;

        @InvocableVariable(label='Delimiter' description='Delimiter character, e.g. semicolon for multi-select picklists' required=true)
        global String delimiter;
    }
}