/**
 * FinanceEmailNotifier
 *
 * Invocable from Flow. Sends a Digital Edge notification email (rendered from a
 * Classic email template) to the country Finance queue for a given record.
 *
 * Used by the custom finance approvals (see docs/Approval_Trigger_Points.md, Part F):
 *   B1 Finance Approval, B2 Billing Mode Change, B3 Different Invoice Currency, B4 Credit Limit.
 *
 * Recipient resolution:
 *   - Queue Developer Name if supplied, otherwise DE_{Country Code}_Country_Finance.
 *   - The queue's active member users' email addresses.
 *
 * After render, button/logo URLs are rewritten with Url.getOrgDomainUrl() so the
 * same Classic templates work in every org without hardcoded sandbox hosts.
 */
public with sharing class FinanceEmailNotifier {

    public class Request {
        @InvocableVariable(required=true label='Record Id' description='Record providing the merge data (Account or Special Instruction).')
        public String recordId;

        @InvocableVariable(required=true label='Template Developer Name' description='DeveloperName of the Classic email template to send.')
        public String templateDeveloperName;

        @InvocableVariable(label='Queue Developer Name' description='Optional. DeveloperName of the target Finance queue. If blank, resolved from Country Code.')
        public String queueDeveloperName;

        @InvocableVariable(label='Country Code' description='Optional. Two-letter country code; used to resolve DE_{code}_Country_Finance when Queue Developer Name is blank.')
        public String countryCode;
    }

    @InvocableMethod(label='Send Finance Notification Email' description='Sends a Digital Edge finance notification email to the country Finance queue.' category='Finance')
    public static void send(List<Request> requests) {
        if (requests == null || requests.isEmpty()) {
            return;
        }
        // Non-blocking: a notification failure must NEVER break the calling flow
        // or roll back the business transaction (record creation, quote update, etc.).
        try {
            List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();
            for (Request req : requests) {
                Messaging.SingleEmailMessage msg = build(req);
                if (msg != null) {
                    emails.add(msg);
                }
            }
            if (!emails.isEmpty()) {
                Messaging.sendEmail(emails, false);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'FinanceEmailNotifier failed (non-blocking): ' + e.getMessage());
        }
    }

    /**
     * Builds one rendered email for the request, or null if the template is
     * missing or no recipients can be resolved.
     */
    @TestVisible
    private static Messaging.SingleEmailMessage build(Request req) {
        List<EmailTemplate> tpls = [
            SELECT Id FROM EmailTemplate WHERE DeveloperName = :req.templateDeveloperName LIMIT 1
        ];
        if (tpls.isEmpty()) {
            return null;
        }
        List<String> toAddresses = resolveRecipients(req);
        if (toAddresses.isEmpty()) {
            return null;
        }
        Messaging.SingleEmailMessage msg =
            Messaging.renderStoredEmailTemplate(tpls[0].Id, null, (Id) req.recordId);
        // Classic templates often use relative /lightning/... links (or leftover sandbox
        // hosts). Rewrite to the current org so buttons work in every environment.
        applyOrgUrls(msg);
        msg.setToAddresses(toAddresses);
        msg.setSaveAsActivity(false);
        return msg;
    }

    /**
     * Makes button (and logo) URLs absolute for the running org via Url.getOrgDomainUrl().
     * Handles relative /lightning paths and known hardcoded partial-sandbox hosts.
     */
    @TestVisible
    private static void applyOrgUrls(Messaging.SingleEmailMessage msg) {
        if (msg == null) {
            return;
        }
        String base = Url.getOrgDomainUrl().toExternalForm();
        if (String.isNotBlank(msg.getHtmlBody())) {
            msg.setHtmlBody(rewriteOrgUrls(msg.getHtmlBody(), base));
        }
        if (String.isNotBlank(msg.getPlainTextBody())) {
            msg.setPlainTextBody(rewriteOrgUrls(msg.getPlainTextBody(), base));
        }
    }

    @TestVisible
    private static String rewriteOrgUrls(String body, String orgBaseUrl) {
        if (String.isBlank(body) || String.isBlank(orgBaseUrl)) {
            return body;
        }
        String out = body;
        // Relative lightning / servlet paths
        out = out.replace('href="/lightning/', 'href="' + orgBaseUrl + '/lightning/');
        out = out.replace('src="/servlet/', 'src="' + orgBaseUrl + '/servlet/');
        // Gmail/email clients sometimes turn relative links into http:///lightning/...
        out = out.replace('href="http:///lightning/', 'href="' + orgBaseUrl + '/lightning/');
        out = out.replace('href="https:///lightning/', 'href="' + orgBaseUrl + '/lightning/');
        // Legacy hardcoded partial sandbox hosts (safe no-op in other orgs)
        out = out.replace('https://digital-edge--partial.sandbox.lightning.force.com', orgBaseUrl);
        out = out.replace('https://digital-edge--partial.sandbox.my.salesforce.com', orgBaseUrl);
        return out;
    }

    /**
     * Returns the addresses the email should go to: members of the resolved
     * Finance queue (by Queue Developer Name or Country Code).
     */
    @TestVisible
    private static List<String> resolveRecipients(Request req) {
        String queueDevName = String.isNotBlank(req.queueDeveloperName)
            ? req.queueDeveloperName
            : (String.isNotBlank(req.countryCode)
                ? 'DE_' + req.countryCode + '_Country_Finance'
                : null);

        if (String.isBlank(queueDevName)) {
            return new List<String>();
        }

        List<Group> queues = [
            SELECT Id FROM Group WHERE DeveloperName = :queueDevName AND Type = 'Queue' LIMIT 1
        ];
        if (queues.isEmpty()) {
            return new List<String>();
        }

        Set<Id> memberIds = new Set<Id>();
        for (GroupMember gm : [SELECT UserOrGroupId FROM GroupMember WHERE GroupId = :queues[0].Id]) {
            memberIds.add(gm.UserOrGroupId);
        }

        List<String> emails = new List<String>();
        if (!memberIds.isEmpty()) {
            for (User u : [SELECT Email FROM User WHERE Id IN :memberIds AND IsActive = true AND Email != null]) {
                emails.add(u.Email);
            }
        }
        return emails;
    }
}