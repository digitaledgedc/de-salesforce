public without sharing class OdooSyncErrorEmailService {

    public static final String EMAIL_SUBJECT = 'SFDC Odoo Sync Error detected';
    public static final String SUPPORT_EMAIL = 'sfdc-support@digitaledgedc.com';

    private static final String TEST_RECIPIENT_EMAIL = '';


    public static final Integer EMAIL_CHUNK_SIZE = 10;

    @TestVisible
    private static String toAddressOverride;

    @TestVisible
    private static String lastHtmlBody;

    private static final Map<String, String> IP_LABELS = new Map<String, String>{
        'IP-1' => 'New Orders',
        'IP-2' => 'Assets',
        'IP-3' => 'Inventory',
        'IP-4' => 'Change Orders',
        'IP-5' => 'Invoices',
        'NEW-A' => 'BAN / Account',
        'NEW-B' => 'BAN / Account',
        'NEW-C' => 'BAN / Account',
        'ACCT-UPDATE' => 'Account Update'
    };


    public static void notifyAsync(List<Id> errorIds) {
        if (errorIds == null || errorIds.isEmpty()) {
            return;
        }
        if (System.isQueueable()) {
            // Already running inside a Queueable (e.g. OdooBanSyncQueueable inserting this
            // error after its own callouts) — that context allows at most one more chained
            // job, which may already be spent (e.g. on the IP-1/IP-4 order chain). Enqueuing
            // here would risk System.LimitException: Too many queueable jobs added to the
            // queue, killing the whole caller's transaction. Send synchronously instead.
            sendForIds(errorIds);
        } else {
            System.enqueueJob(new EmailQueueable(errorIds));
        }
    }


    public static void handleAfterInsert(List<DE_Integration_Error__c> newRows) {
        if (newRows == null || newRows.isEmpty()) {
            return;
        }
        List<Id> toNotify = new List<Id>();
        for (DE_Integration_Error__c row : newRows) {
            toNotify.add(row.Id);
        }
        notifyAsync(toNotify);
    }

    public static Integer sendForIds(List<Id> errorIds) {
        if (errorIds == null || errorIds.isEmpty()) {
            return 0;
        }

        List<DE_Integration_Error__c> errors = [
            SELECT Id, Name, IP_Reference__c, Error_Message__c, CreatedDate
            FROM DE_Integration_Error__c
            WHERE Id IN :errorIds
        ];
        if (errors.isEmpty()) {
            return 0;
        }

        String baseUrl = Url.getOrgDomainUrl().toExternalForm();
        Id owdId = resolveOrgWideEmailAddressId();
        List<String> toAddresses = resolveToAddresses();

        List<Messaging.SingleEmailMessage> messages = new List<Messaging.SingleEmailMessage>();

        for (DE_Integration_Error__c err : errors) {
            String html = buildHtmlBody(err, baseUrl);
            lastHtmlBody = html;

            Messaging.SingleEmailMessage msg = new Messaging.SingleEmailMessage();
            msg.setToAddresses(toAddresses);
            msg.setSubject(EMAIL_SUBJECT);
            msg.setHtmlBody(html);
            msg.setPlainTextBody(html.stripHtmlTags());
            msg.setSaveAsActivity(false);
            msg.setUseSignature(false);
            if (owdId != null) {
                msg.setOrgWideEmailAddressId(owdId);
            }
            messages.add(msg);
        }

        if (!messages.isEmpty()) {
            Messaging.SendEmailResult[] results = Messaging.sendEmail(messages, false);
            if (results != null) {
                for (Messaging.SendEmailResult r : results) {
                    if (!r.isSuccess() && !r.getErrors().isEmpty()) {
                        System.debug(LoggingLevel.ERROR,
                            'OdooSyncErrorEmailService send failed: ' + r.getErrors()[0].getMessage());
                    }
                }
            }
        }
        return messages.size();
    }

    @TestVisible
    private static String buildHtmlBody(DE_Integration_Error__c err, String baseUrl) {
        String ip = String.isBlank(err.IP_Reference__c) ? 'Unknown' : err.IP_Reference__c;
        String ipLabel = IP_LABELS.containsKey(ip) ? IP_LABELS.get(ip) : ip;
        String errName = String.isBlank(err.Name) ? String.valueOf(err.Id) : err.Name;
        String errUrl = baseUrl + '/lightning/r/DE_Integration_Error__c/' + err.Id + '/view';
        String whenTxt = (err.CreatedDate != null)
            ? err.CreatedDate.format('d MMM yyyy, h:mm a z')
            : Datetime.now().format('d MMM yyyy, h:mm a z');
        String message = String.isBlank(err.Error_Message__c) ? '(No message)' : err.Error_Message__c;
        if (message.length() > 2000) {
            message = message.substring(0, 2000);
        }

        return ''
            + 'Hello Support Team,<br/><br/>'
            + 'Salesforce detected an Odoo sync failure.<br/><br/>'
            + 'Error: <a href="' + errUrl + '">' + escapeHtml(errName) + '</a><br/>'
            + 'Integration Point: ' + escapeHtml(ip) + ' (' + escapeHtml(ipLabel) + ')<br/>'
            + 'Time: ' + escapeHtml(whenTxt) + '<br/><br/>'
            + 'Error message:<br/>'
            + escapeHtml(message).replace('\n', '<br/>') + '<br/><br/>'
            + 'Open error record: <a href="' + errUrl + '">' + escapeHtml(errName) + '</a><br/><br/>'
            + 'This is an automated alert from Salesforce.';
    }

    private static String escapeHtml(String value) {
        if (value == null) {
            return '';
        }
        return value
            .replace('&', '&amp;')
            .replace('<', '&lt;')
            .replace('>', '&gt;')
            .replace('"', '&quot;');
    }

    private static List<String> resolveToAddresses() {
        if (String.isNotBlank(toAddressOverride)) {
            return new List<String>{ toAddressOverride };
        }
        List<String> addrs = new List<String>{ SUPPORT_EMAIL };
        if (String.isNotBlank(TEST_RECIPIENT_EMAIL)
                && !addrs.contains(TEST_RECIPIENT_EMAIL)) {
            addrs.add(TEST_RECIPIENT_EMAIL);
        }
        return addrs;
    }

    private static Id resolveOrgWideEmailAddressId() {
        List<OrgWideEmailAddress> owds = [
            SELECT Id FROM OrgWideEmailAddress WHERE IsVerified = true LIMIT 1
        ];
        return owds.isEmpty() ? null : owds[0].Id;
    }

    /** Processes error Ids in chunks of EMAIL_CHUNK_SIZE; re-enqueues remainder. */
    public without sharing class EmailQueueable implements Queueable {
        private List<Id> errorIds;

        public EmailQueueable(List<Id> errorIds) {
            this.errorIds = (errorIds == null) ? new List<Id>() : new List<Id>(errorIds);
        }

        public void execute(QueueableContext ctx) {
            if (errorIds.isEmpty()) {
                return;
            }
            List<Id> chunk = new List<Id>();
            List<Id> rest = new List<Id>();
            for (Integer i = 0; i < errorIds.size(); i++) {
                if (i < EMAIL_CHUNK_SIZE) {
                    chunk.add(errorIds[i]);
                } else {
                    rest.add(errorIds[i]);
                }
            }
            sendForIds(chunk);
            // Apex caps queueable chaining at depth 1 in test context, so chaining the
            // next chunk throws System.AsyncException: Maximum stack depth has been
            // reached. Only the first chunk is exercised under test; production is
            // unchanged and still chains until every chunk is sent.
            if (!rest.isEmpty() && !Test.isRunningTest()) {
                System.enqueueJob(new EmailQueueable(rest));
            }
        }
    }
}