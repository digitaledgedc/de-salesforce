public with sharing class DE_QuotePDFAttachmentService {

    // ─── Input / Output wrappers for Flow ────────────────────────────────

    public class FlowInput {
        @InvocableVariable(label='Quote Record ID' description='The ID of the Quote record to generate PDF for' required=true)
        public Id quoteId;

        @InvocableVariable(label='File Title' description='Optional custom title for the file. Defaults to Quote Number + date.' required=false)
        public String fileTitle;

        @InvocableVariable(label='Language Code' description='Optional Salesforce language code. If blank, the Quote Account preferred language is used.' required=false)
        public String languageCode;
    }

    public class FlowOutput {
        @InvocableVariable(label='Success' description='True if PDF was generated and saved successfully')
        public Boolean isSuccess;

        @InvocableVariable(label='Content Document ID' description='ID of the saved ContentDocument')
        public Id contentDocumentId;

        @InvocableVariable(label='Content Version ID' description='ID of the saved ContentVersion')
        public Id contentVersionId;

        @InvocableVariable(label='Error Message' description='Error message if isSuccess is false')
        public String errorMessage;
    }

    // ─── Invocable entry point (called from Flow) ─────────────────────────

    @InvocableMethod(
        label='Generate and Save Quote PDF'
        description='Renders the DE_QuoteTemplate Visualforce page as a PDF and stores it as a related file on the Quote record.'
        category='Digital Edge'
    )
    public static List<FlowOutput> generateAndSaveQuotePDF(List<FlowInput> inputs) {
        List<FlowOutput> outputs = new List<FlowOutput>();

        for (FlowInput input : inputs) {
            FlowOutput result = new FlowOutput();
            try {
                result = savePDFToRecord(input.quoteId, input.fileTitle, input.languageCode, true);
            } catch (Exception e) {
                result.isSuccess    = false;
                result.errorMessage = e.getMessage();
            }
            outputs.add(result);
        }

        return outputs;
    }

    // ─── AuraEnabled version (callable from LWC / quick action too) ───────

    @AuraEnabled
    public static FlowOutput generateAndSaveQuotePDFFromLWC(
        Id quoteId,
        String fileTitle,
        String languageCode
    ) {
        try {
            return savePDFToRecord(quoteId, fileTitle, languageCode, false);
        } catch (Exception e) {
            FlowOutput err = new FlowOutput();
            err.isSuccess    = false;
            err.errorMessage = e.getMessage();
            return err;
        }
    }

    // ─── Core logic ───────────────────────────────────────────────────────

    private static FlowOutput savePDFToRecord(
        Id quoteId,
        String fileTitle,
        String languageCode,
        Boolean useAccountPreferenceWhenBlank
    ) {
        FlowOutput result = new FlowOutput();

        if (quoteId == null) {
            result.isSuccess    = false;
            result.errorMessage = 'Quote ID is required.';
            return result;
        }

        // 1. Fetch the Quote for naming purposes
        Quote q = [
            SELECT Id, Quote_Number__c, Name, Quote_Version__c,
                   Opportunity.Opportunity_Number__c, CreatedDate,
                   Account.Preferred_Language__c
            FROM Quote
            WHERE Id = :quoteId
            WITH SECURITY_ENFORCED
            LIMIT 1
        ];

        // 2. Render the VF page as PDF blob
        String resolvedLanguage = languageCode;
        if (String.isBlank(resolvedLanguage) && useAccountPreferenceWhenBlank) {
            resolvedLanguage = DE_QuotePDFLocalization.languageFromAccountPreference(
                q.Account?.Preferred_Language__c
            );
        }
        Blob pdfBlob = DE_QuotePDFLocalization.renderQuotePdf(quoteId, resolvedLanguage);

        // 3. Build the file title
        String resolvedTitle;
        if (String.isNotBlank(fileTitle)) {
            resolvedTitle = fileTitle;
        } else {
            String oppNum = String.isNotBlank(q.Opportunity?.Opportunity_Number__c)
                ? q.Opportunity.Opportunity_Number__c
                : (String.isNotBlank(q.Quote_Number__c) ? q.Quote_Number__c : q.Name);
            String version = q.Quote_Version__c != null ? String.valueOf(q.Quote_Version__c.intValue()) : '1';
            resolvedTitle = oppNum + ' - v' + version;
        }
        // Sanitise: remove characters invalid in file names
        resolvedTitle = resolvedTitle.replaceAll('[/\\\\:*?"<>|]', '_');
        String fileName = resolvedTitle + '.pdf';

        // 4. Create ContentVersion (this auto-creates ContentDocument)
        ContentVersion cv = new ContentVersion();
        cv.Title           = resolvedTitle;
        cv.PathOnClient    = fileName;
        cv.VersionData     = pdfBlob;
        cv.IsMajorVersion  = true;
        cv.ContentLocation = 'S'; // S = stored in Salesforce

        insert cv;

        // 5. Re-query to get the auto-created ContentDocumentId
        cv = [
            SELECT Id, ContentDocumentId
            FROM ContentVersion
            WHERE Id = :cv.Id
            LIMIT 1
        ];

        // 6. Link the ContentDocument to the Quote via ContentDocumentLink
        ContentDocumentLink cdl = new ContentDocumentLink();
        cdl.ContentDocumentId = cv.ContentDocumentId;
        cdl.LinkedEntityId    = quoteId;
        cdl.ShareType         = 'V'; // V = Viewer, I = Inferred, C = Collaborator
        cdl.Visibility        = 'AllUsers';

        insert cdl;

        // 7. Return result
        result.isSuccess        = true;
        result.contentDocumentId = cv.ContentDocumentId;
        result.contentVersionId  = cv.Id;
        return result;
    }
}