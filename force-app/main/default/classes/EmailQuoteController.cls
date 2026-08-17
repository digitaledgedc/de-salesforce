public with sharing class EmailQuoteController {

    /**
     * Wrapper for T&C combobox options returned to the LWC.
     */
    public class TermsOption implements Comparable {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        @AuraEnabled public String termsText;
        @AuraEnabled public String subscriptionManagement;
        @AuraEnabled public String company;

        public Integer compareTo(Object o) {
            TermsOption other = (TermsOption) o;
            return label.compareTo(other.label);
        }
    }

    /**
     * Derive Subscription Management label from Quote_Type__c.
     *   New        → Creation
     *   Amendment  → Change Order
     *   Renewal    → Renewal
     */
    private static String deriveSubscriptionManagement(String quoteType) {
        if (quoteType == null) return '';
        if (quoteType == 'New')       return 'Creation';
        if (quoteType == 'Amendment') return 'Change Order';
        if (quoteType == 'Renewal')   return 'Renewal'; if (quoteType == 'Termination')   return 'Termination'; return '';
    }

    private static String mapPreferredLanguage(String preferredLanguage) {
        if (String.isBlank(preferredLanguage)) return 'en_US';
        switch on preferredLanguage.toLowerCase() {
            when 'japanese' { return 'ja'; }
            when 'korean'   { return 'ko'; }
            when 'chinese'  { return 'zh_CN'; }
            when else       { return 'en_US'; }
        }
    }

    /**
     * Pick the language-appropriate T&C body for a template record.
     * Returns the translation for the requested languageCode (ja/ko/zh_CN) when
     * populated, otherwise falls back to the English Terms_Text__c. en_US and any
     * unrecognized code also return English.
     */
    private static String pickTermsText(Special_Instruction__c rec, String languageCode) {
        String translated;
        if (languageCode == 'ja')          translated = rec.Terms_Text_ja__c;
        else if (languageCode == 'ko')     translated = rec.Terms_Text_ko__c;
        else if (languageCode == 'zh_CN')  translated = rec.Terms_Text_zh_CN__c;
        return String.isNotBlank(translated) ? translated : rec.Terms_Text__c;
    }

    /**
     * Return APPROVED Quote T&C templates from Custom Metadata filtered by:
     *   1. Stage__c = 'Approved'
     *   2. Subscription_Management__c = derived from quoteType
     *   3. Company__c LIKE '%companyName%'  (DE_Entity__c Account Name)
     *
     * Ordered by Sequence__c ASC.
     * Cacheable — no side effects.
     */
    @AuraEnabled(cacheable=true)
    public static List<TermsOption> getTermsOptions(
        String quoteType,
        String companyName,
        String customerName,
        String languageCode
    ) {
        String subMgmt = deriveSubscriptionManagement(quoteType);

        // Fetch Approved Special_Instruction__c records (Terms and Conditions record type)
        // Company_Names__c and Customer_Names__c are text fields — filter in memory
        List<Special_Instruction__c> allRecords = [
            SELECT Id, TandC_Name__c, Terms_Text__c,
                   Terms_Text_ja__c, Terms_Text_ko__c, Terms_Text_zh_CN__c,
                   Customer_Names__c,
                   Subscription_Management__c, Sequence__c, Company_Names__c
            FROM   Special_Instruction__c
            WHERE  Status__c                  = 'Approved'
            AND    RecordType.DeveloperName   = 'Terms_and_Conditions'
            AND    Subscription_Management__c = :subMgmt
            ORDER BY Sequence__c ASC NULLS LAST
        ];

        // Filter in memory: show record if company matches AND customer is blank (generic) or matches
        String companyLower  = String.isBlank(companyName)  ? '' : companyName.toLowerCase();
        String customerLower = String.isBlank(customerName) ? '' : customerName.toLowerCase();
        List<TermsOption> opts = new List<TermsOption>();
        for (Special_Instruction__c rec : allRecords) {
            Boolean companyMatch =
                String.isBlank(companyName) || String.isBlank(rec.Company_Names__c) || rec.Company_Names__c.toLowerCase().contains(companyLower);
            Boolean customerMatch =
                String.isBlank(customerName) ||  String.isBlank(rec.Customer_Names__c) || rec.Customer_Names__c.toLowerCase().contains(customerLower);
            if (companyMatch && customerMatch) {
                TermsOption o            = new TermsOption();
                o.label                  = rec.TandC_Name__c;
                o.value                  = rec.TandC_Name__c;
                o.termsText              = pickTermsText(rec, languageCode);
                o.subscriptionManagement = rec.Subscription_Management__c;
                o.company                = rec.Company_Names__c;
                opts.add(o);
            }
        }
        return opts;
    }

    /**
     * Load quote defaults for pre-populating the email modal.
     * Returns:
     *   quoteName, toEmail, toName, accountName, subject,
     *   financeApprovalPhase, isBinding,
     *   quoteType, subscriptionMgmt,
     *   company   (DE_Entity__c → Account Name),
     *   specialNotes
     */
    @AuraEnabled(cacheable=true)
    public static Map<String, String> getQuoteDefaults(Id quoteId) {
        Quote q = [
            SELECT Name,
                   Quote_Number__c,
                   ContactId, Contact.Email, Contact.Name,
                   Account.Name, Account.Finance_Approval_Phase__c,
                   Account.Preferred_Language__c,
                   Is_Binding__c,
                   Quote_Type__c,
                   Special_Notes__c,
                   Service_Order_Terms__c,
                   DE_Entity__r.Name,
                   Opportunity.Opportunity_Number__c
            FROM   Quote
            WHERE  Id = :quoteId
            LIMIT  1
        ];

        Map<String, String> d = new Map<String, String>();
        d.put('quoteName',            q.Name ?? '');
        d.put('quoteNumber',          q.Quote_Number__c ?? q.Name ?? '');
        d.put('orderNumber',          q.Opportunity?.Opportunity_Number__c ?? '');
        d.put('toEmail',              q.Contact?.Email ?? '');
        d.put('toName',               q.Contact?.Name  ?? '');
        d.put('accountName',          q.Account?.Name  ?? '');
        d.put('subject',              'Quote: ' + q.Name);
        d.put('financeApprovalPhase', String.valueOf(q.Account?.Finance_Approval_Phase__c ?? ''));
        d.put('isBinding',            String.valueOf(q.Is_Binding__c));
        d.put('quoteType',            q.Quote_Type__c ?? '');
        d.put('subscriptionMgmt',     deriveSubscriptionManagement(q.Quote_Type__c));
        d.put('company',              q.DE_Entity__r?.Name ?? '');
        d.put('specialNotes',         q.Special_Notes__c   ?? '');
        d.put('preferredLanguage',    mapPreferredLanguage(String.valueOf(q.Account?.Preferred_Language__c)));
        // ===== FB-739 START — return product (line item) count so UI can block empty quotes =====
        Integer fb739LineCount = [SELECT COUNT() FROM QuoteLineItem WHERE QuoteId = :quoteId];
        d.put('lineItemCount',        String.valueOf(fb739LineCount));
        // ===== FB-739 END =====
        return d;
    }

    // FB-739 fix — non-cacheable so the UI always gets a FRESH product count.
    // The cacheable getQuoteDefaults count goes stale when products are added,
    // which wrongly blocked Send on quotes that do have products.
    @AuraEnabled
    public static Integer getLineItemCount(Id quoteId) { if (quoteId == null) return 0; return [SELECT COUNT() FROM QuoteLineItem WHERE QuoteId = :quoteId];
    }

    /**
     * Toggle Is_Binding__c and optionally set Service_Order_Terms__c
     * in a single DML so the approved-lock VR does not reject a
     * second sequential update.
     */
    @AuraEnabled
    public static void saveBindingToQuote(
        Id quoteId,
        Boolean isBinding,
        String termsHtml,
        String languageCode
    ) {
        String resolvedTerms = isBinding ? termsHtml
            : DE_QuotePDFLocalization.buildNonBindingTermsHtml(languageCode);
        Quote q = new Quote(
            Id                     = quoteId,
            Is_Binding__c          = isBinding,
            Service_Order_Terms__c = resolvedTerms
        );
        try {
            new DmlHelper().doUpdate(new List<Quote>{ q }); } catch (Exception e) {  throw new AuraHandledException('Could not update binding status: ' + e.getMessage());
        }
    }

    /**
     * Save the selected T&C HTML onto the Quote record so the PDF
     * template (DE_QuoteTemplate) renders it.
     */
    @AuraEnabled
    public static void saveTermsToQuote(Id quoteId, String termsHtml) {
        Quote q = new Quote(Id = quoteId, Service_Order_Terms__c = termsHtml);
        try {
            new DmlHelper().doUpdate(new List<Quote>{ q });  } catch (Exception e) {   throw new AuraHandledException('Terms save failed: ' + e.getMessage());
        }
    }

    /**
     * Save Special Notes back to the Quote record.
     */
    @AuraEnabled
    public static void saveSpecialNotes(Id quoteId, String specialNotes) {
        Quote q = new Quote(Id = quoteId, Special_Notes__c = specialNotes);
        try {
            new DmlHelper().doUpdate(new List<Quote>{ q });  } catch (Exception e) {  throw new AuraHandledException('Special Notes save failed: ' + e.getMessage());
        }
    }

    private static final String NON_BINDING_DISCLAIMER =
        '<br/><br/>' +
        '<hr style="border:none;border-top:1px solid #ccc;margin:24px 0 16px 0;" />' +
        '<div style="font-size:10px;color:#666;line-height:1.6;">' +
        '<p style="font-weight:bold;text-transform:uppercase;margin-bottom:8px;">Non-Binding Disclaimer</p>' +
        '<ol style="padding-left:18px;margin:0;">' +
        '<li>This document does not constitute a formal offer or binding commitment by Digital Edge or any of its subsidiaries.</li>' +
        '<li>The pricing, terms, and configurations described herein are indicative only and are subject to change without notice.</li>' +
        '<li>A binding agreement will only come into effect upon execution of a formal service order or contract by both parties.</li>' +
        '<li>This document contains proprietary and/or confidential information belonging to Digital Edge. It is intended solely for the recipient and may not be reproduced, distributed, or disclosed to any third party without the prior written consent of Digital Edge.</li>' +
        '</ol></div>';

    /**
     * Render DE_QuoteTemplate as PDF and send via email.
     * When isNonBinding = true, appends non-binding disclaimer and
     * marks the Quote as non-binding.
     */
    @AuraEnabled
    public static void sendQuotePdf(
        Id      quoteId,
        String  toAddress,
        String  ccAddress,
        String  subject,
        String  body,
        Boolean isNonBinding,
        String  languageCode
    ) {
        if (String.isBlank(toAddress)) {
            throw new AuraHandledException('A "To" email address is required.');
        }
        // ===== FB-739 START — block sending a quote that has no products =====
        Integer fb739LineCount = [SELECT COUNT() FROM QuoteLineItem WHERE QuoteId = :quoteId];
        if (fb739LineCount == 0) { throw new AuraHandledException('Cannot send this quote — no products have been added. Add at least one product before sending.');
        }
        // ===== FB-739 END =====
		//system.assert(false,ccAddress);
        // Render the VF page as PDF
        Blob pdfBlob = DE_QuotePDFLocalization.renderQuotePdf(quoteId, languageCode);

        Quote qForName = [
            SELECT Quote_Number__c, Name, Quote_Version__c, Opportunity.Opportunity_Number__c, ContactId
            FROM Quote WHERE Id = :quoteId LIMIT 1
        ];
        String oppNum  = String.isNotBlank(qForName.Opportunity?.Opportunity_Number__c)
            ? qForName.Opportunity.Opportunity_Number__c : (String.isNotBlank(qForName.Quote_Number__c) ? qForName.Quote_Number__c : qForName.Name);
        String version = qForName.Quote_Version__c != null ? String.valueOf(qForName.Quote_Version__c.intValue()) : '1';
        String pdfName = (oppNum + ' - v' + version).replaceAll('[/\\\\:*?"<>|]', '_') + '.pdf';

        Messaging.EmailFileAttachment att = new Messaging.EmailFileAttachment();
        att.setFileName(pdfName);
        att.setBody(pdfBlob);
        att.setContentType('application/pdf');
        att.setInline(false);

        // Email sent via 'Email from Salesforce with Office 365' relay.
        // No org-wide email address or sender display name needed — Office 365 handles sender identity.
        Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
        email.setToAddresses(new List<String>{ toAddress.trim() });
        if (String.isNotBlank(ccAddress)) {
            List<String> ccList = new List<String>();
            // Split on comma AND/OR whitespace — mirrors the LWC-side validation so a
            // space-separated list of addresses (no commas) parses into individual
            // recipients instead of being sent as one malformed CC string.
            for (String addr : ccAddress.split('[\\s,]+')) {
                String trimmed = addr.trim();
                if (String.isNotBlank(trimmed)) ccList.add(trimmed);
            }
            if (!ccList.isEmpty()) email.setCcAddresses(ccList);
        }
        email.setSubject(subject);

        String htmlBody = String.isNotBlank(body)
            ? body.replace('\n', '<br/>') : 'Please find the attached quote for your review.';
        if (isNonBinding == true) {
            htmlBody += NON_BINDING_DISCLAIMER;
        }
        email.setHtmlBody(htmlBody);
        email.setFileAttachments(new List<Messaging.EmailFileAttachment>{ att });
        if (qForName.ContactId != null) { email.setTargetObjectId(qForName.ContactId); email.setTreatTargetObjectAsRecipient(false); // log activity only, do not send duplicate email to contact
        }
        email.setWhatId(quoteId);
        email.setSaveAsActivity(true);

        Messaging.SendEmailResult[] results;
        try {
            results = Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ email }); } catch (Exception e) { throw new AuraHandledException('Email failed: ' + e.getMessage());
        }
        if (!results[0].isSuccess()) {throw new AuraHandledException('Email failed: ' + results[0].getErrors()[0].getMessage());
        }

        // Save the sent PDF as a file on the Quote record
        ContentVersion cv = new ContentVersion();
        cv.Title           = oppNum + ' - v' + version;
        cv.PathOnClient    = pdfName;
        cv.VersionData     = pdfBlob;
        cv.IsMajorVersion  = true;
        cv.ContentLocation = 'S';
        insert cv;
        cv = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id LIMIT 1];
        ContentDocumentLink cdl = new ContentDocumentLink();
        cdl.ContentDocumentId = cv.ContentDocumentId;
        cdl.LinkedEntityId    = quoteId;
        cdl.ShareType         = 'V';
        cdl.Visibility        = 'AllUsers';
        insert cdl;

        // Advance status to Presented only for binding quotes
        if (isNonBinding != true) {
            Quote q = new Quote(Id = quoteId, Status = 'Presented',Quote_Version__c =  (qForName.Quote_Version__c + 1));
            try {
                new DmlHelper().doUpdate(new List<Quote>{ q }); } catch (Exception e) {throw new AuraHandledException(  'Email sent but status could not update to Presented: ' + e.getMessage()
                );
            }
        }
    }

    /**
     * System-context DML helper.
     * Allows updates on approval-locked records (e.g. saving T&C
     * on a Quote currently in an approval process).
     */
    private without sharing class DmlHelper {
        public void doUpdate(List<SObject> records) {
            update records;
        }
    }
}