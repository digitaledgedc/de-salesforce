/**
 * FinanceEmailNotifierTest
 *
 * SeeAllData=true: the class renders a stored Classic email template and resolves
 * real Finance queues (DE_{country}_Country_Finance). EmailTemplate records and
 * existing queues/accounts are only visible with SeeAllData, so the render and
 * queue-resolution paths cannot be covered otherwise.
 */
@IsTest(SeeAllData=true)
private class FinanceEmailNotifierTest {

    private static final String REAL_TEMPLATE = 'DE_Finance_Review_Notification';
    private static final String REAL_QUEUE    = 'DE_KR_Country_Finance';

    // Any existing Account — used only as a generic recordId for requests that
    // never reach the merge-field render step (template-not-found / no-recipients
    // / queue-not-found all return before touching recordId at all). Unlike
    // Special_Instruction__c, at least one Account can be relied on to exist in
    // any populated org, so these tests no longer need to skip.
    private static Id anyRecordId() {
        List<Account> accs = [SELECT Id FROM Account LIMIT 1];
        return accs.isEmpty() ? null : accs[0].Id;
    }

    // Ensures the running user is a member of the given queue for the duration of
    // a test, so the "found queue -> resolve member emails" path gets real
    // coverage even in orgs where Finance queue memberships are currently empty.
    // Never touches a genuinely pre-existing membership: checks first, and only
    // inserts (and later removes) a GroupMember it created itself. Returns the
    // GroupMember Id to clean up, or null if the user was already a member (in
    // which case there is nothing for the caller to delete).
    private static Id ensureTempMembership(String queueDevName) {
        List<Group> queues = [SELECT Id FROM Group WHERE DeveloperName = :queueDevName AND Type = 'Queue' LIMIT 1];
        if (queues.isEmpty()) return null;
        Id queueId = queues[0].Id;
        Id userId = UserInfo.getUserId();
        List<GroupMember> existing = [
            SELECT Id FROM GroupMember WHERE GroupId = :queueId AND UserOrGroupId = :userId LIMIT 1
        ];
        if (!existing.isEmpty()) return null; // already a real member — nothing to clean up
        GroupMember gm = new GroupMember(GroupId = queueId, UserOrGroupId = userId);
        insert gm;
        return gm.Id;
    }

    private static FinanceEmailNotifier.Request req(Id recId, String tpl, String queue, String country) {
        FinanceEmailNotifier.Request r = new FinanceEmailNotifier.Request();
        r.recordId = recId;
        r.templateDeveloperName = tpl;
        r.queueDeveloperName = queue;
        r.countryCode = country;
        return r;
    }

    // Queue path via explicit queue developer name -> resolves member emails and
    // sends. Temporarily ensures the running user is a member of the real Finance
    // queue for the duration of this test (see ensureTempMembership) so the full
    // render/send path gets real coverage, then removes only what it added.
    @IsTest
    static void queuePath_byQueueDeveloperName() {
        Id rec = anyRecordId();
        if (rec == null) {
            System.debug('Environment gap: no Account exists in this org — skipping.');
            return;
        }
        Id tempMembershipId = ensureTempMembership(REAL_QUEUE);
        try {
            Test.startTest();
            FinanceEmailNotifier.send(new List<FinanceEmailNotifier.Request>{
                req(rec, REAL_TEMPLATE, REAL_QUEUE, null)
            });
            Test.stopTest();

            List<String> to = FinanceEmailNotifier.resolveRecipients(req(rec, REAL_TEMPLATE, REAL_QUEUE, null));
            System.assert(!to.isEmpty(), 'Real Finance queue should resolve to member email addresses');
        } finally {
            if (tempMembershipId != null) delete new GroupMember(Id = tempMembershipId);
        }
    }

    // Queue path via country code -> builds DE_{code}_Country_Finance. Same
    // temporary-membership approach as queuePath_byQueueDeveloperName, applied to
    // the queue that 'KR' resolves to.
    @IsTest
    static void queuePath_byCountryCode() {
        Id rec = anyRecordId();
        if (rec == null) {
            System.debug('Environment gap: no Account exists in this org — skipping.');
            return;
        }
        Id tempMembershipId = ensureTempMembership(REAL_QUEUE);
        try {
            Test.startTest();
            FinanceEmailNotifier.send(new List<FinanceEmailNotifier.Request>{
                req(rec, REAL_TEMPLATE, null, 'KR')
            });
            Test.stopTest();

            List<String> to = FinanceEmailNotifier.resolveRecipients(req(rec, REAL_TEMPLATE, null, 'KR'));
            System.assert(!to.isEmpty(), 'Country code KR should resolve the KR Finance queue members');
        } finally {
            if (tempMembershipId != null) delete new GroupMember(Id = tempMembershipId);
        }
    }

    // Template not found -> build returns null, nothing sent, no exception.
    // recordId is never touched on this path, so any existing record Id is fine.
    @IsTest
    static void templateNotFound_skips() {
        Id rec = anyRecordId();

        Test.startTest();
        FinanceEmailNotifier.send(new List<FinanceEmailNotifier.Request>{
            req(rec, 'THIS_TEMPLATE_DOES_NOT_EXIST_XYZ', REAL_QUEUE, null)
        });
        Test.stopTest();

        Messaging.SingleEmailMessage msg =
            FinanceEmailNotifier.build(req(rec, 'THIS_TEMPLATE_DOES_NOT_EXIST_XYZ', REAL_QUEUE, null));
        System.assertEquals(null, msg, 'No message should be built when the template is missing');
    }

    // No queue and no country -> no recipients, nothing sent. recordId is never
    // touched on this path (resolveRecipients short-circuits before any render).
    @IsTest
    static void noRecipients_skips() {
        Id rec = anyRecordId();

        Test.startTest();
        FinanceEmailNotifier.send(new List<FinanceEmailNotifier.Request>{
            req(rec, REAL_TEMPLATE, null, null)
        });
        Test.stopTest();

        List<String> to = FinanceEmailNotifier.resolveRecipients(req(rec, REAL_TEMPLATE, null, null));
        System.assert(to.isEmpty(), 'No queue and no country should resolve to no recipients');
    }

    // Nonexistent country queue -> empty recipients. recordId is unused here too.
    @IsTest
    static void queueNotFound_returnsEmpty() {
        Id rec = anyRecordId();
        List<String> to = FinanceEmailNotifier.resolveRecipients(req(rec, REAL_TEMPLATE, null, 'ZZ'));
        System.assert(to.isEmpty(), 'Nonexistent country queue should resolve to no recipients');
    }

    // Null and empty input lists are handled without error.
    @IsTest
    static void nullAndEmptyInput_handled() {
        Test.startTest();
        FinanceEmailNotifier.send(null);
        FinanceEmailNotifier.send(new List<FinanceEmailNotifier.Request>());
        Test.stopTest();
        System.assert(true, 'Null / empty input should be a no-op');
    }

    // Org URL rewrite: relative lightning links become absolute for the running org.
    @IsTest
    static void rewriteOrgUrls_makesLightningLinksAbsolute() {
        String base = Url.getOrgDomainUrl().toExternalForm();
        String html = '<a href="/lightning/r/Account/001xx/view">Open</a>'
            + '<img src="/servlet/servlet.ImageServer?id=015"/>'
            + '<a href="https://digital-edge--partial.sandbox.lightning.force.com/lightning/r/Quote/0Q0xx/view">Q</a>';
        String out = FinanceEmailNotifier.rewriteOrgUrls(html, base);
        System.assert(out.contains('href="' + base + '/lightning/r/Account/001xx/view'),
            'Relative lightning href should be prefixed with org base');
        System.assert(out.contains('src="' + base + '/servlet/servlet.ImageServer?id=015'),
            'Relative servlet src should be prefixed with org base');
        System.assert(!out.contains('digital-edge--partial.sandbox.lightning.force.com'),
            'Hardcoded partial host should be replaced');
        System.assert(out.contains('href="' + base + '/lightning/r/Quote/0Q0xx/view'),
            'Hardcoded partial lightning host should become org base');
    }
}