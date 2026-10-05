@IsTest
private class SiteFileUploadControllerTest {

    @TestSetup
    static void setup() {
        Site__c site = new Site__c(
            Site_Name__c = 'Upload Test Site',
            Site_Code__c = 'TEST01',
            Country__c   = 'SG'
        );
        insert site;
    }

    @IsTest
    static void testGetSiteDocumentTypes() {
        Test.startTest();
        List<SiteFileUploadController.DocTypeOption> types =
            SiteFileUploadController.getSiteDocumentTypes();
        Test.stopTest();

        // CMT records may or may not be deployed — just verify no exception
        System.assertNotEquals(null, types, 'Should return a list (possibly empty)');
    }

    @IsTest
    static void testUploadFilesToSite() {
        Site__c site = [SELECT Id FROM Site__c WHERE Site_Name__c = 'Upload Test Site' LIMIT 1];

        SiteFileUploadController.UploadFileItem file1 = new SiteFileUploadController.UploadFileItem();
        file1.fileName    = 'test-drawing.pdf';
        file1.base64Data  = EncodingUtil.base64Encode(Blob.valueOf('test pdf content'));
        file1.contentType = 'application/pdf';
        file1.docType     = 'Floor Plan';

        Test.startTest();
        SiteFileUploadController.uploadFilesToSite(
            site.Id,
            new List<SiteFileUploadController.UploadFileItem>{ file1 }
        );
        Test.stopTest();

        List<ContentDocumentLink> links = [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :site.Id
        ];
        System.assertEquals(1, links.size(), 'Should have 1 document linked to site');
    }

    @IsTest
    static void testGetSiteDocuments() {
        Site__c site = [SELECT Id FROM Site__c WHERE Site_Name__c = 'Upload Test Site' LIMIT 1];

        // Upload a file first
        ContentVersion cv = new ContentVersion(
            Title                 = 'Existing Doc',
            PathOnClient          = '/existing-doc.pdf',
            VersionData           = Blob.valueOf('existing content'),
            FirstPublishLocationId = site.Id
        );
        insert cv;

        Test.startTest();
        List<SiteFileUploadController.SiteDocument> docs =
            SiteFileUploadController.getSiteDocuments(site.Id);
        Test.stopTest();

        System.assertEquals(1, docs.size(), 'Should find 1 document');
        System.assertEquals('Existing Doc.pdf', docs[0].fileName);
        System.assertNotEquals(null, docs[0].downloadUrl);
    }

    @IsTest
    static void testGetSiteDocuments_empty() {
        Site__c site = [SELECT Id FROM Site__c WHERE Site_Name__c = 'Upload Test Site' LIMIT 1];

        Test.startTest();
        List<SiteFileUploadController.SiteDocument> docs =
            SiteFileUploadController.getSiteDocuments(site.Id);
        Test.stopTest();

        System.assertEquals(0, docs.size(), 'Should return empty list for site with no docs');
    }

    @IsTest
    static void testGetSiteDocuments_nullId() {
        Test.startTest();
        Boolean caught = false;
        try {
            SiteFileUploadController.getSiteDocuments(null);
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();

        System.assert(caught, 'Should throw for null site ID');
    }

    @IsTest
    static void testDeleteDocument() {
        // Was written when System Administrator was implicitly privileged. The
        // gate is now the custom permission, which no profile carries, so the
        // caller has to be granted it explicitly.
        User privileged = makePrivilegedUser();
        if (privileged == null) return;

        Site__c site = [SELECT Id FROM Site__c WHERE Site_Name__c = 'Upload Test Site' LIMIT 1];
        Id contentDocId = newFileOnSite(site.Id, 'To Delete');

        Test.startTest();
        System.runAs(privileged) {
            SiteFileUploadController.deleteDocument(contentDocId);
        }
        Test.stopTest();

        System.assertEquals(false, docExists(contentDocId), 'Document should be deleted');
    }

    @IsTest
    static void testDeleteDocument_nullId() {
        // Run privileged so the null-id branch is what throws, not the gate.
        User privileged = makePrivilegedUser();
        if (privileged == null) return;

        Test.startTest();
        Boolean caught = false;
        System.runAs(privileged) {
            try {
                SiteFileUploadController.deleteDocument(null);
            } catch (AuraHandledException e) {
                caught = true;
            }
        }
        Test.stopTest();

        System.assert(caught, 'Should throw for null document ID');
    }

    @IsTest
    static void testUploadFilesToSite_nullSiteId() {
        SiteFileUploadController.UploadFileItem file1 = new SiteFileUploadController.UploadFileItem();
        file1.fileName   = 'test.pdf';
        file1.base64Data = EncodingUtil.base64Encode(Blob.valueOf('data'));
        file1.docType    = 'Floor Plan';

        Test.startTest();
        Boolean caught = false;
        try {
            SiteFileUploadController.uploadFilesToSite(
                null,
                new List<SiteFileUploadController.UploadFileItem>{ file1 }
            );
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();

        System.assert(caught, 'Should throw for null site ID');
    }

    @IsTest
    static void testUploadFilesToSite_missingDocType() {
        Site__c site = [SELECT Id FROM Site__c WHERE Site_Name__c = 'Upload Test Site' LIMIT 1];

        SiteFileUploadController.UploadFileItem file1 = new SiteFileUploadController.UploadFileItem();
        file1.fileName   = 'test.pdf';
        file1.base64Data = EncodingUtil.base64Encode(Blob.valueOf('data'));
        file1.docType    = '';

        Test.startTest();
        Boolean caught = false;
        try {
            SiteFileUploadController.uploadFilesToSite(
                site.Id,
                new List<SiteFileUploadController.UploadFileItem>{ file1 }
            );
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();

        System.assert(caught, 'Should throw for missing doc type');
    }

    @IsTest
    static void testUploadFilesToSite_emptyList() {
        Site__c site = [SELECT Id FROM Site__c WHERE Site_Name__c = 'Upload Test Site' LIMIT 1];

        Test.startTest();
        Boolean caught = false;
        try {
            SiteFileUploadController.uploadFilesToSite(
                site.Id,
                new List<SiteFileUploadController.UploadFileItem>()
            );
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();

        System.assert(caught, 'Should throw for empty file list');
    }

    @IsTest
    static void testCreateDocumentTypeMetadata() {
        User privileged = makePrivilegedUser();
        if (privileged == null) return;
        Test.startTest();
        System.runAs(privileged) {
            try {
                SiteFileUploadController.createDocumentTypeMetadata(
                    'Network Diagram', 'Network_Diagram'
                );
            } catch (System.AsyncException e) {
                // Metadata.Operations.enqueueDeployment is not supported in test
                // context — platform limitation. Validates method execution up to
                // the deploy call.
            }
        }
        Test.stopTest();
    }

    @IsTest
    static void testCreateDocumentTypeMetadata_blank() {
        User privileged = makePrivilegedUser();
        if (privileged == null) return;
        Test.startTest();
        Boolean caught = false;
        System.runAs(privileged) {
            try {
                SiteFileUploadController.createDocumentTypeMetadata('', '');
            } catch (AuraHandledException e) {
                caught = true;
            }
        }
        Test.stopTest();

        System.assert(caught, 'Should throw for blank inputs');
    }

    /* ══════════════════════════════════════════════════════════════════════
       SFDC-303 ADDITIONS

       THE AUTHORISATION POLICY UNDER TEST — deletion is a single capability:
         (a) DELETING A STORED DOCUMENT (the delete icon) always requires
             Manage_All_Record_Documents. The uploader has no standing to
             delete their own file. This is the deliberate difference from
             de-partial, where the owner may always delete;
         (b) TYPING (setDocumentTypes) allows the owner OR a permission holder,
             because a user must be able to type the file they just uploaded or
             the upload cannot be saved at all;
         (b2) REJECTING AN UPLOAD is not deletion and is not gated at all:
             enforceSizeLimit (over the cap) runs for anyone, and
             deleteDocuments (cancel) runs for the uploader's own files. Neither
             can reach a saved document belonging to someone else;
         (c) a holder of the Manage_All_Record_Documents custom permission may
             manage files uploaded by ANYONE.
       Profile name is irrelevant. isPrivilegedUser() is now a single
       FeatureManagement.checkPermission call, so these tests grant the
       capability through a PermissionSet + SetupEntityAccess +
       PermissionSetAssignment rather than by picking a profile.

       IMPORTANT TEST-DESIGN CONSTRAINT
       SiteFileUploadController caches the privilege verdict in a private
       static (privilegedCache) for the whole transaction. System.runAs does
       NOT reset statics, so a single test method may only ever let ONE user
       reach isPrivilegedUser(). Every method below therefore makes its first
       privilege-touching controller call inside the runAs block for the user
       under test, and never switches user for a second such call.
    ══════════════════════════════════════════════════════════════════════ */

    private static Integer userSeq = 0;

    // An ordinary business profile in this org. Since privilege is now a custom
    // permission, the profile a test user sits on carries no authority at all —
    // this is just "some real profile a user can be created on".
    private static final String PROFILE_ORDINARY = 'DE Sales';

    // The profile that used to be hardcoded as privileged. Kept deliberately so
    // testCanManageDocuments_systemAdministratorWithoutPermissionIsFalse can
    // prove the profile allowlist is really gone.
    private static final String PROFILE_FORMERLY_PRIVILEGED = 'System Administrator';

    /**
     * Creates a test user on the named profile.
     * Returns null when the profile does not exist in this org so callers can
     * skip gracefully. Both profiles used below ('DE Sales' and
     * 'System Administrator') do exist in de-partial, so in practice nothing
     * skips any more — the old three-profiles-missing failure mode disappeared
     * with the profile allowlist.
     */
    private static User makeUser(String profileName) {
        List<Profile> profiles = [SELECT Id FROM Profile WHERE Name = :profileName LIMIT 1];
        if (profiles.isEmpty()) return null;   // profile absent -> caller returns early

        userSeq++;
        String seed = 'sfdc303u' + userSeq + 'x' + String.valueOf(Datetime.now().getTime());
        User u = new User(
            FirstName         = 'SFDC303',
            LastName          = 'Tester' + userSeq,
            Alias             = ('t' + userSeq + '303').left(8),
            Email             = 'sfdc303.tester' + userSeq + '@example.invalid',
            Username          = seed + '@sfdc303.example.invalid',
            ProfileId         = profiles[0].Id,
            EmailEncodingKey  = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey      = 'en_US',
            TimeZoneSidKey    = 'Asia/Singapore'
        );
        // runAs wrapper lets this setup-object DML sit alongside the
        // non-setup DML (ContentVersion / Site__c / Site__Share) the tests need.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
        }
        return u;
    }

    /** Standalone file (no ContentDocumentLink). Owner = whoever is running. */
    private static Id newFile(String title) {
        ContentVersion cv = new ContentVersion(
            Title        = title,
            PathOnClient = '/' + title.replace(' ', '-') + '.txt',
            VersionData  = Blob.valueOf('body of ' + title)
        );
        insert cv;
        return [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id LIMIT 1].ContentDocumentId;
    }

    /** File published to a record. Owner = whoever is running. */
    private static Id newFileOnSite(Id siteId, String title) {
        ContentVersion cv = new ContentVersion(
            Title                  = title,
            PathOnClient           = '/' + title.replace(' ', '-') + '.txt',
            VersionData            = Blob.valueOf('body of ' + title),
            FirstPublishLocationId = siteId
        );
        insert cv;
        return [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id LIMIT 1].ContentDocumentId;
    }

    private static Boolean docExists(Id contentDocumentId) {
        return ![SELECT Id FROM ContentDocument WHERE Id = :contentDocumentId].isEmpty();
    }

    /** Site__c OWD is Private, so a non-owner needs an explicit share to upload. */
    private static void grantSiteAccess(Id siteId, Id userId) {
        insert new Site__Share(
            ParentId      = siteId,
            UserOrGroupId = userId,
            AccessLevel   = 'Edit',
            RowCause      = 'Manual'
        );
    }

    private static SiteFileUploadController.DocTypeAssignment assign(String docId, String docType) {
        SiteFileUploadController.DocTypeAssignment a = new SiteFileUploadController.DocTypeAssignment();
        a.contentDocumentId = docId;
        a.docType           = docType;
        return a;
    }

    private static Map<Id, String> docTypes(Set<Id> docIds) {
        Map<Id, String> out = new Map<Id, String>();
        for (ContentVersion cv : [
            SELECT ContentDocumentId, Document_Type__c
            FROM   ContentVersion
            WHERE  ContentDocumentId IN :docIds AND IsLatest = true
        ]) {
            out.put(cv.ContentDocumentId, cv.Document_Type__c);
        }
        return out;
    }

    /**
     * Sets Document_Type__c straight on the latest ContentVersion, bypassing the
     * controller. Use this for arranging state whenever the test's assertion is
     * about a DIFFERENT user's privilege verdict - going through
     * setDocumentTypes would prime privilegedCache with the test runner's
     * verdict and invalidate the runAs that follows.
     */
    private static void stampDocTypeDirectly(Id contentDocumentId, String docType) {
        ContentVersion cv = [
            SELECT Id, Document_Type__c
            FROM   ContentVersion
            WHERE  ContentDocumentId = :contentDocumentId AND IsLatest = true
            LIMIT 1
        ];
        cv.Document_Type__c = docType;
        update cv;
    }

    /** A genuine, well-formed ContentDocument Id that no longer exists. */
    private static Id deadDocId() {
        Id cdId = newFile('Doomed');
        delete [SELECT Id FROM ContentDocument WHERE Id = :cdId];
        return cdId;
    }

    /**
     * Grants Manage_All_Record_Documents to a user via a fresh PermissionSet.
     * All four objects touched here (PermissionSet, SetupEntityAccess,
     * PermissionSetAssignment, User) are setup objects, so the whole thing sits
     * inside a runAs(current user) wrapper to keep it away from the
     * ContentVersion / Site__c DML the tests also need. Must be called BEFORE
     * entering runAs(target user): you cannot grant yourself a permission while
     * already impersonating, and the grant has to be committed before
     * FeatureManagement.checkPermission is first evaluated.
     */
    private static void grantManageAllDocuments(User u) {
        List<CustomPermission> perms = [
            SELECT Id FROM CustomPermission
            WHERE  DeveloperName = :SiteFileUploadController.MANAGE_ALL_DOCUMENTS_PERMISSION
            LIMIT 1
        ];
        System.assertEquals(1, perms.size(),
            'CustomPermission ' + SiteFileUploadController.MANAGE_ALL_DOCUMENTS_PERMISSION +
            ' must be deployed for the privileged path to be testable');

        System.runAs(new User(Id = UserInfo.getUserId())) {
            permSetSeq++;
            PermissionSet ps = new PermissionSet(
                Name  = 'SFDC303_ManageAllDocs_' + permSetSeq,
                Label = 'SFDC303 Manage All Docs ' + permSetSeq
            );
            insert ps;

            // SetupEntityType is NOT createable on this object (describe says
            // createable=false); the platform derives it from the SetupEntityId
            // key prefix (0CP = CustomPermission). Setting it explicitly fails
            // with a field-not-writeable error.
            insert new SetupEntityAccess(
                ParentId      = ps.Id,
                SetupEntityId = perms[0].Id
            );

            insert new PermissionSetAssignment(
                AssigneeId      = u.Id,
                PermissionSetId = ps.Id
            );
        }
    }

    private static Integer permSetSeq = 0;

    /** Convenience: an ordinary-profile user who holds the custom permission. */
    private static User makePrivilegedUser() {
        User u = makeUser(PROFILE_ORDINARY);
        if (u == null) return null;
        grantManageAllDocuments(u);
        return u;
    }

    /**
     * VERIFIED ON THIS ORG (API 62): AuraHandledException does NOT expose its
     * client-facing message to Apex - getMessage() returns the generic
     * 'Script-thrown exception'. The friendly strings the controller passes to
     * the constructor reach the LWC but are unreadable from a test, so the only
     * assertable facts are (a) that an AuraHandledException was raised and
     * (b) the resulting data state. Pinned here so nobody later writes an
     * assertion on the message text and wonders why it fails.
     */
    private static void assertAuraMessageIsOpaque(String msg) {
        System.assertEquals('Script-thrown exception', msg,
            'AuraHandledException message text is not readable from Apex');
    }

    /* ─────────────────────────────────────────────────────────────
       A.  deleteDocument  —  single-file authorisation
    ───────────────────────────────────────────────────────────── */

    @IsTest
    static void testDeleteDocument_ownerWithoutPermissionIsRejected() {
        // The rule this org asked for: nobody deletes a stored document without
        // the permission, not even the person who uploaded it. de-partial does
        // the opposite (owner may always delete their own), so this assertion is
        // the single clearest marker of the difference between the two orgs.
        User owner = makeUser(PROFILE_ORDINARY);
        if (owner == null) return;   // profile absent in this org

        Id cdId;
        System.runAs(owner) { cdId = newFile('Owned By Plain User'); }

        Test.startTest();
        Boolean caught = false;
        String  msg    = null;
        System.runAs(owner) {
            try {
                SiteFileUploadController.deleteDocument(cdId);
            } catch (AuraHandledException e) {
                caught = true;
                msg    = e.getMessage();
            }
        }
        Test.stopTest();

        System.assert(caught, 'The uploader must be refused without the permission');
        System.assertEquals(true, docExists(cdId),
            'The file the caller uploaded themselves must survive the refusal');
        assertAuraMessageIsOpaque(msg);
    }

    @IsTest
    static void testDeleteDocument_nonOwnerWithoutPermissionIsRejected() {
        User owner   = makeUser(PROFILE_ORDINARY);
        User intruder = makeUser(PROFILE_ORDINARY);
        if (owner == null || intruder == null) return;

        Id cdId;
        System.runAs(owner) { cdId = newFile('Not Yours'); }

        Test.startTest();
        Boolean caught = false;
        String  msg    = null;
        System.runAs(intruder) {
            try {
                SiteFileUploadController.deleteDocument(cdId);
            } catch (AuraHandledException e) {
                caught = true;
                msg    = e.getMessage();
            }
        }
        Test.stopTest();

        System.assert(caught, 'A non-owner without the permission must be rejected');
        System.assertEquals(true, docExists(cdId), 'Rejected delete must leave the file in place');
        assertAuraMessageIsOpaque(msg);
    }

    @IsTest
    static void testDeleteDocument_permissionHolderCanDeleteSomeoneElsesFile() {
        User owner      = makeUser(PROFILE_ORDINARY);
        User privileged = makePrivilegedUser();   // ordinary profile + custom permission
        if (owner == null || privileged == null) return;

        Id cdId;
        System.runAs(owner) { cdId = newFile('Owned By Someone Else'); }

        Test.startTest();
        System.runAs(privileged) {
            SiteFileUploadController.deleteDocument(cdId);
        }
        Test.stopTest();

        System.assertEquals(false, docExists(cdId),
            'A Manage_All_Record_Documents holder must be able to delete another user\'s file');
    }

    @IsTest
    static void testDeleteDocument_systemAdministratorWithoutPermissionIsRejected() {
        // Replaces the old 'DE Finance is not in PRIVILEGED_PROFILES' test.
        // Profile no longer grants anything, so the sharpest regression test is
        // the inverse: the profile that USED to be hardcoded as privileged now
        // gets refused unless it actually holds the custom permission. If
        // anyone reintroduces a profile-name shortcut, this fails.
        User admin = makeUser(PROFILE_FORMERLY_PRIVILEGED);   // NO permission granted
        if (admin == null) return;

        Id cdId = newFile('Owned By Test Runner');   // plain DML: no privilege evaluation yet

        Test.startTest();
        Boolean caught = false;
        System.runAs(admin) {
            try {
                SiteFileUploadController.deleteDocument(cdId);
            } catch (AuraHandledException e) {
                caught = true;
            }
        }
        Test.stopTest();

        System.assert(caught,
            'System Administrator without Manage_All_Record_Documents must be refused');
        System.assertEquals(true, docExists(cdId), 'File must survive the rejected delete');
    }

    @IsTest
    static void testDeleteDocument_unknownIdSilentlyDeletesNothing() {
        // DIVERGENCE FROM de-partial, deliberate. There, deleteDocument queries
        // the row first and throws 'Document not found.' for a dead id. This org
        // keeps its original one-liner - `delete [SELECT ... LIMIT 1]` - which
        // matches zero rows and returns quietly. Not changed here because the
        // brief was the permission gate, not deleteDocument's shape. Pinned so
        // the difference is a recorded fact rather than a surprise.
        User privileged = makePrivilegedUser();
        if (privileged == null) return;

        Id dead = deadDocId();

        Test.startTest();
        Boolean caught = false;
        System.runAs(privileged) {
            try {
                SiteFileUploadController.deleteDocument(dead);
            } catch (AuraHandledException e) {
                caught = true;
            }
        }
        Test.stopTest();

        System.assertEquals(false, caught,
            'An id with no live ContentDocument is a silent no-op on this org');
    }

    /* ─────────────────────────────────────────────────────────────
       B.  deleteDocuments  —  bulk cancel-cleanup semantics
    ───────────────────────────────────────────────────────────── */

    @IsTest
    static void testDeleteDocuments_ownerCleansUpOwnCancelledUpload() {
        // Cancel cleanup is NOT gated on the permission. Abandoning an unsaved
        // upload is not deleting a stored document, and gating it would strand
        // untyped files that the uploader cannot clear. Scoped to own files.
        User owner = makeUser(PROFILE_ORDINARY);
        if (owner == null) return;

        List<Id> ids = new List<Id>();
        System.runAs(owner) {
            ids.add(newFile('Bulk One'));
            ids.add(newFile('Bulk Two'));
            ids.add(newFile('Bulk Three'));
        }

        Test.startTest();
        System.runAs(owner) {
            SiteFileUploadController.deleteDocuments(ids);
        }
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM ContentDocument WHERE Id IN :ids],
            'The uploader clears their own cancelled upload with no permission');
    }

    @IsTest
    static void testDeleteDocuments_cannotReachAnotherUsersFile() {
        // The two entry points answer differently ON PURPOSE. deleteDocuments is
        // cancel cleanup, so it allows the caller's own file and refuses anyone
        // else's. deleteDocument is the delete icon, so it refuses even the
        // caller's own file without the permission. This test pins both.
        User owner = makeUser(PROFILE_ORDINARY);
        if (owner == null) return;

        Id foreignDoc = newFile('Owned By Test Runner');
        Id ownDoc;
        System.runAs(owner) { ownDoc = newFile('Owned By Caller'); }

        Test.startTest();
        Boolean bulkThrew   = false;
        Boolean singleThrew = false;
        System.runAs(owner) {
            try {
                SiteFileUploadController.deleteDocuments(new List<Id>{ ownDoc, foreignDoc });
            } catch (AuraHandledException e) {
                bulkThrew = true;
            }
            try {
                SiteFileUploadController.deleteDocument(ownDoc);
            } catch (AuraHandledException e) {
                singleThrew = true;
            }
        }
        Test.stopTest();

        System.assertEquals(true, bulkThrew,
            'A batch containing someone else\'s file is refused outright');
        System.assertEquals(true, docExists(ownDoc),
            'Nothing is deleted when the batch is refused - not even the owned file');
        System.assertEquals(true, docExists(foreignDoc),
            'The other user\'s file is untouched');
        System.assertEquals(true, singleThrew,
            'The delete ICON still refuses the caller\'s own file without the permission');
    }

    @IsTest
    static void testDeleteDocuments_noneOwnedThrowsAndDeletesNothing() {
        User outsider = makeUser(PROFILE_ORDINARY);
        if (outsider == null) return;

        List<Id> ids = new List<Id>{ newFile('Runner File A'), newFile('Runner File B') };

        Test.startTest();
        Boolean caught = false;
        String  msg    = null;
        System.runAs(outsider) {
            try {
                SiteFileUploadController.deleteDocuments(ids);
            } catch (AuraHandledException e) {
                caught = true;
                msg    = e.getMessage();
            }
        }
        Test.stopTest();

        System.assert(caught, 'A caller who owns none of the ids is refused');
        System.assertEquals(2, [SELECT COUNT() FROM ContentDocument WHERE Id IN :ids],
            'Nothing should be deleted');
        assertAuraMessageIsOpaque(msg);   // intended: 'You can only cancel uploads you made.'
    }

    @IsTest
    static void testDeleteDocuments_permissionDoesNotWidenCancelCleanup() {
        // Cancel cleanup is ownership-scoped and the permission does NOT bypass
        // it, so this endpoint can never be used to clear another user's stored
        // file. Deleting someone else's document goes through deleteDocument.
        User privileged = makePrivilegedUser();
        if (privileged == null) return;

        Id foreignDoc = newFile('Runner Owned Bulk');

        Test.startTest();
        Boolean caught = false;
        System.runAs(privileged) {
            try {
                SiteFileUploadController.deleteDocuments(new List<Id>{ foreignDoc });
            } catch (AuraHandledException e) {
                caught = true;
            }
            // ...but the delete icon path does let them remove it.
            SiteFileUploadController.deleteDocument(foreignDoc);
        }
        Test.stopTest();

        System.assertEquals(true, caught,
            'Even a permission holder cannot cancel-clean a file they do not own');
        System.assertEquals(false, docExists(foreignDoc),
            'deleteDocument is the path that removes another user\'s file');
    }

    @IsTest
    static void testDeleteDocuments_nullListIsSilentNoOp() {
        // Divergence: deleteDocument(null) throws 'Document ID is required.'
        Test.startTest();
        Boolean threw = false;
        try {
            SiteFileUploadController.deleteDocuments(null);
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(false, threw, 'deleteDocuments(null) returns silently instead of throwing');
    }

    @IsTest
    static void testDeleteDocuments_emptyListIsSilentNoOp() {
        Test.startTest();
        Boolean threw = false;
        try {
            SiteFileUploadController.deleteDocuments(new List<Id>());
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(false, threw, 'deleteDocuments([]) returns silently instead of throwing');
    }

    @IsTest
    static void testDeleteDocuments_unknownIdsAreSilentNoOp() {
        Id dead = deadDocId();

        Test.startTest();
        Boolean threw = false;
        try {
            SiteFileUploadController.deleteDocuments(new List<Id>{ dead });
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(false, threw,
            'An id that does not resolve is dropped by the SOQL before any check runs');
    }

    /* ─────────────────────────────────────────────────────────────
       C.  setDocumentTypes
    ───────────────────────────────────────────────────────────── */

    @IsTest
    static void testSetDocumentTypes_happyPath() {
        Site__c site = [SELECT Id FROM Site__c WHERE Site_Name__c = 'Upload Test Site' LIMIT 1];
        Id cdId = newFileOnSite(site.Id, 'Needs A Type');

        Test.startTest();
        SiteFileUploadController.setDocumentTypes(
            new List<SiteFileUploadController.DocTypeAssignment>{ assign(cdId, 'Floor Plan') }
        );
        Test.stopTest();

        System.assertEquals('Floor Plan', docTypes(new Set<Id>{ cdId }).get(cdId),
            'Document_Type__c should be stamped on the latest ContentVersion');
    }

    @IsTest
    static void testSetDocumentTypes_bulkStampsEachFileIndependently() {
        Site__c site = [SELECT Id FROM Site__c WHERE Site_Name__c = 'Upload Test Site' LIMIT 1];
        Id a = newFileOnSite(site.Id, 'Bulk Type A');
        Id b = newFileOnSite(site.Id, 'Bulk Type B');
        Id c = newFileOnSite(site.Id, 'Bulk Type C');

        Test.startTest();
        SiteFileUploadController.setDocumentTypes(
            new List<SiteFileUploadController.DocTypeAssignment>{
                assign(a, 'Floor Plan'),
                assign(b, 'Network Diagram'),
                assign(c, 'Site Survey')
            }
        );
        Test.stopTest();

        Map<Id, String> got = docTypes(new Set<Id>{ a, b, c });
        System.assertEquals('Floor Plan',      got.get(a));
        System.assertEquals('Network Diagram', got.get(b));
        System.assertEquals('Site Survey',     got.get(c));
    }

    @IsTest
    static void testSetDocumentTypes_trimsSurroundingWhitespace() {
        Id cdId = newFile('Padded Type');

        Test.startTest();
        SiteFileUploadController.setDocumentTypes(
            new List<SiteFileUploadController.DocTypeAssignment>{ assign(cdId, '   Floor Plan   ') }
        );
        Test.stopTest();

        System.assertEquals('Floor Plan', docTypes(new Set<Id>{ cdId }).get(cdId),
            'docType is trimmed before it is stored');
    }

    @IsTest
    static void testSetDocumentTypes_blankDocTypeRejected() {
        Id cdId = newFile('Blank Type');

        Test.startTest();
        Boolean caught = false;
        String  msg    = null;
        try {
            SiteFileUploadController.setDocumentTypes(
                new List<SiteFileUploadController.DocTypeAssignment>{ assign(cdId, '') }
            );
        } catch (AuraHandledException e) {
            caught = true;
            msg    = e.getMessage();
        }
        Test.stopTest();

        System.assert(caught, 'Blank docType must be rejected');
        System.assertEquals(null, docTypes(new Set<Id>{ cdId }).get(cdId),
            'Nothing should have been stamped');
        assertAuraMessageIsOpaque(msg);   // intended: 'Document Type is required for every file.'
    }

    @IsTest
    static void testSetDocumentTypes_whitespaceOnlyDocTypeRejected() {
        Id cdId = newFile('Whitespace Type');

        Test.startTest();
        Boolean caught = false;
        try {
            SiteFileUploadController.setDocumentTypes(
                new List<SiteFileUploadController.DocTypeAssignment>{ assign(cdId, '   ') }
            );
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();

        System.assert(caught, 'String.isBlank also catches a whitespace-only docType');
    }

    @IsTest
    static void testSetDocumentTypes_nullDocTypeRejected() {
        Id cdId = newFile('Null Type');

        Test.startTest();
        Boolean caught = false;
        try {
            SiteFileUploadController.setDocumentTypes(
                new List<SiteFileUploadController.DocTypeAssignment>{ assign(cdId, null) }
            );
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();

        System.assert(caught, 'Null docType must be rejected');
    }

    @IsTest
    static void testSetDocumentTypes_blankContentDocumentIdRejected() {
        Test.startTest();
        Boolean caught = false;
        String  msg    = null;
        try {
            SiteFileUploadController.setDocumentTypes(
                new List<SiteFileUploadController.DocTypeAssignment>{ assign('', 'Floor Plan') }
            );
        } catch (AuraHandledException e) {
            caught = true;
            msg    = e.getMessage();
        }
        Test.stopTest();

        System.assert(caught, 'Blank contentDocumentId must be rejected');
        assertAuraMessageIsOpaque(msg);   // intended text: 'Document ID is missing.'
    }

    @IsTest
    static void testSetDocumentTypes_absentContentDocumentIdRejected() {
        Test.startTest();
        Boolean caught = false;
        String  msg    = null;
        try {
            SiteFileUploadController.setDocumentTypes(
                new List<SiteFileUploadController.DocTypeAssignment>{ assign(null, 'Floor Plan') }
            );
        } catch (AuraHandledException e) {
            caught = true;
            msg    = e.getMessage();
        }
        Test.stopTest();

        System.assert(caught, 'Absent contentDocumentId must be rejected');
        assertAuraMessageIsOpaque(msg);   // intended text: 'Document ID is missing.'
    }

    @IsTest
    static void testSetDocumentTypes_nullListRejected() {
        Test.startTest();
        Boolean caught = false;
        String  msg    = null;
        try {
            SiteFileUploadController.setDocumentTypes(null);
        } catch (AuraHandledException e) {
            caught = true;
            msg    = e.getMessage();
        }
        Test.stopTest();

        System.assert(caught, 'Null assignment list must be rejected');
        assertAuraMessageIsOpaque(msg);   // intended: 'No document type assignments provided.'
    }

    @IsTest
    static void testSetDocumentTypes_emptyListRejected() {
        Test.startTest();
        Boolean caught = false;
        try {
            SiteFileUploadController.setDocumentTypes(
                new List<SiteFileUploadController.DocTypeAssignment>()
            );
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();

        System.assert(caught, 'Empty assignment list must be rejected');
    }

    @IsTest
    static void testSetDocumentTypes_unknownIdYieldsNotFound() {
        Id dead = deadDocId();

        Test.startTest();
        Boolean caught = false;
        String  msg    = null;
        try {
            SiteFileUploadController.setDocumentTypes(
                new List<SiteFileUploadController.DocTypeAssignment>{ assign(dead, 'Floor Plan') }
            );
        } catch (AuraHandledException e) {
            caught = true;
            msg    = e.getMessage();
        }
        Test.stopTest();

        System.assert(caught, 'An id with no live ContentVersion must be reported');
        assertAuraMessageIsOpaque(msg);   // intended text: 'Uploaded file(s) not found.'
    }

    @IsTest
    static void testSetDocumentTypes_partiallyUnknownIdsStampSilently() {
        // 'Uploaded file(s) not found.' only fires when NO id resolves. A batch
        // holding one good and one bad id stamps the good one and says nothing
        // about the bad one.
        Id live = newFile('Live One');
        Id dead = deadDocId();

        Test.startTest();
        Boolean threw = false;
        try {
            SiteFileUploadController.setDocumentTypes(
                new List<SiteFileUploadController.DocTypeAssignment>{
                    assign(live, 'Floor Plan'),
                    assign(dead, 'Network Diagram')
                }
            );
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(false, threw, 'A partially resolvable batch does not raise an error');
        System.assertEquals('Floor Plan', docTypes(new Set<Id>{ live }).get(live),
            'The resolvable id is still stamped');
    }

    @IsTest
    static void testSetDocumentTypes_duplicateIdLastAssignmentWins() {
        Id cdId = newFile('Duplicated');

        Test.startTest();
        SiteFileUploadController.setDocumentTypes(
            new List<SiteFileUploadController.DocTypeAssignment>{
                assign(cdId, 'Floor Plan'),
                assign(cdId, 'Network Diagram')
            }
        );
        Test.stopTest();

        System.assertEquals('Network Diagram', docTypes(new Set<Id>{ cdId }).get(cdId),
            'Assignments are collapsed into a Map, so the last docType for an id wins');
    }

    @IsTest
    static void testSetDocumentTypes_nonOwnerWithoutPermissionIsRejected() {
        // INVERTED. This test previously documented an authorisation hole: any
        // user could relabel any file in the org because setDocumentTypes ran in
        // system mode with no check. It now routes through
        // assertCallerMayManage, so a non-owner without the custom permission is
        // refused and the existing document type must be left untouched.
        User outsider = makeUser(PROFILE_ORDINARY);
        if (outsider == null) return;

        Id foreignDoc = newFile('Runner Owned Label Target');
        // Stamp a known value first so 'unchanged' is a real assertion, not just
        // null - but do it with PLAIN DML, never through the controller. Calling
        // setDocumentTypes here would evaluate isPrivilegedUser() as the test
        // RUNNER, and the runner holds Manage_All_Record_Documents in this org
        // (via the DE Admin permission set), so privilegedCache would latch to
        // true and the outsider below would inherit it and not be refused. That
        // is exactly the transaction-static trap described in the section header,
        // and it produced a false pass on the first run of this test.
        stampDocTypeDirectly(foreignDoc, 'Original Type');

        Test.startTest();
        Boolean caught = false;
        String  msg    = null;
        System.runAs(outsider) {
            try {
                SiteFileUploadController.setDocumentTypes(
                    new List<SiteFileUploadController.DocTypeAssignment>{
                        assign(foreignDoc, 'Relabelled By Outsider')
                    }
                );
            } catch (AuraHandledException e) {
                caught = true;
                msg    = e.getMessage();
            }
        }
        Test.stopTest();

        System.assert(caught,
            'A non-owner without Manage_All_Record_Documents must be refused');
        System.assertEquals('Original Type', docTypes(new Set<Id>{ foreignDoc }).get(foreignDoc),
            'The refused call must leave Document_Type__c exactly as it was');
        assertAuraMessageIsOpaque(msg);   // intended: 'You can only manage files you uploaded.'
    }

    @IsTest
    static void testSetDocumentTypes_ownerWithoutPermissionMayTypeOwnFile() {
        // Path (a) of the policy: your own uploads need no permission at all.
        User owner = makeUser(PROFILE_ORDINARY);
        if (owner == null) return;

        Id ownDoc;
        System.runAs(owner) { ownDoc = newFile('Owner Types Own File'); }

        Test.startTest();
        Boolean threw = false;
        System.runAs(owner) {
            try {
                SiteFileUploadController.setDocumentTypes(
                    new List<SiteFileUploadController.DocTypeAssignment>{ assign(ownDoc, 'Floor Plan') }
                );
            } catch (Exception e) {
                threw = true;
            }
        }
        Test.stopTest();

        System.assertEquals(false, threw, 'The owner needs no permission to type their own upload');
        System.assertEquals('Floor Plan', docTypes(new Set<Id>{ ownDoc }).get(ownDoc));
    }

    @IsTest
    static void testSetDocumentTypes_permissionHolderMayTypeSomeoneElsesFile() {
        // Path (b) of the policy: the custom permission reaches anyone's file.
        User privileged = makePrivilegedUser();
        if (privileged == null) return;

        Id foreignDoc = newFile('Runner Owned, Typed By Permission Holder');

        Test.startTest();
        Boolean threw = false;
        System.runAs(privileged) {
            try {
                SiteFileUploadController.setDocumentTypes(
                    new List<SiteFileUploadController.DocTypeAssignment>{
                        assign(foreignDoc, 'Network Diagram')
                    }
                );
            } catch (Exception e) {
                threw = true;
            }
        }
        Test.stopTest();

        System.assertEquals(false, threw,
            'Manage_All_Record_Documents must allow typing a file owned by someone else');
        System.assertEquals('Network Diagram', docTypes(new Set<Id>{ foreignDoc }).get(foreignDoc));
    }

    @IsTest
    static void testSetDocumentTypes_mixedOwnershipRefusesWholeBatch() {
        // assertCallerMayManage throws on the first foreign document, so a batch
        // mixing your own file with someone else's stamps nothing - consistent
        // with the all-or-nothing rule deleteDocuments now follows.
        User owner = makeUser(PROFILE_ORDINARY);
        if (owner == null) return;

        Id foreignDoc = newFile('Runner Owned In Mixed Batch');
        Id ownDoc;
        System.runAs(owner) { ownDoc = newFile('Caller Owned In Mixed Batch'); }

        Test.startTest();
        Boolean caught = false;
        System.runAs(owner) {
            try {
                SiteFileUploadController.setDocumentTypes(
                    new List<SiteFileUploadController.DocTypeAssignment>{
                        assign(ownDoc, 'Floor Plan'),
                        assign(foreignDoc, 'Floor Plan')
                    }
                );
            } catch (AuraHandledException e) {
                caught = true;
            }
        }
        Test.stopTest();

        System.assert(caught, 'A mixed-ownership batch must be refused');
        Map<Id, String> got = docTypes(new Set<Id>{ ownDoc, foreignDoc });
        System.assertEquals(null, got.get(ownDoc),
            'Nothing is stamped when the batch is refused - not even the owned file');
        System.assertEquals(null, got.get(foreignDoc), 'The foreign file is untouched');
    }

    /* ─────────────────────────────────────────────────────────────
       D.  canManageDocuments  (one user per method: static cache)
    ───────────────────────────────────────────────────────────── */

    @IsTest
    static void testCanManageDocuments_permissionHolderIsTrue() {
        User privileged = makePrivilegedUser();
        if (privileged == null) return;

        Test.startTest();
        Boolean result;
        System.runAs(privileged) { result = SiteFileUploadController.canManageDocuments(); }
        Test.stopTest();

        System.assertEquals(true, result,
            'Manage_All_Record_Documents, granted via permission set, must read as privileged');
    }

    @IsTest
    static void testCanManageDocuments_userWithoutPermissionIsFalse() {
        User plain = makeUser(PROFILE_ORDINARY);
        if (plain == null) return;

        Test.startTest();
        Boolean result;
        System.runAs(plain) { result = SiteFileUploadController.canManageDocuments(); }
        Test.stopTest();

        System.assertEquals(false, result, 'No permission means no privilege');
    }

    @IsTest
    static void testCanManageDocuments_systemAdministratorWithoutPermissionIsFalse() {
        // Replaces the old 'DE Finance is not Finance' test. Profile name no
        // longer participates in the decision at all, so the meaningful check is
        // that even the formerly-hardcoded 'System Administrator' reads as
        // unprivileged without the permission. Guards against a regression to
        // profile-name matching.
        User admin = makeUser(PROFILE_FORMERLY_PRIVILEGED);   // NO permission granted
        if (admin == null) return;

        Test.startTest();
        Boolean result;
        System.runAs(admin) { result = SiteFileUploadController.canManageDocuments(); }
        Test.stopTest();

        System.assertEquals(false, result,
            'Profile is irrelevant now - System Administrator alone grants nothing');
    }

    /* ─────────────────────────────────────────────────────────────
       E.  getSiteDocuments

       There is no per-row canDelete flag on this org. Deletion is a single
       org-wide capability, so the LWC gates the icon on canManageDocuments and
       every row answers the same way. de-partial's per-row tests were dropped
       rather than ported - the field they assert does not exist here.
    ───────────────────────────────────────────────────────────── */

    @IsTest
    static void testGetSiteDocuments_leaksFilesToUserWithNoAccessToParentRecord() {
        // getSiteDocuments does no CRUD/sharing check on siteId, and the class is
        // `without sharing`, so ContentDocumentLink/ContentVersion are read in
        // system mode. This user gets NO Site__Share (Site__c OWD is Private) and
        // owns nothing, yet still receives the row - including downloadUrl.
        User outsider = makeUser(PROFILE_ORDINARY);
        if (outsider == null) return;

        Site__c site = [SELECT Id FROM Site__c WHERE Site_Name__c = 'Upload Test Site' LIMIT 1];
        Id foreignDoc = newFileOnSite(site.Id, 'Confidential Runner File');

        Test.startTest();
        List<SiteFileUploadController.SiteDocument> docs;
        System.runAs(outsider) { docs = SiteFileUploadController.getSiteDocuments(site.Id); }
        Test.stopTest();

        System.assertEquals(1, docs.size(),
            'A user with no access to the Site record still receives its file metadata');
        System.assertEquals(String.valueOf(foreignDoc), docs[0].contentDocumentId,
            'The disclosed row is the runner-owned file the outsider must not see');
        System.assert(String.isNotBlank(docs[0].downloadUrl),
            'A download URL is handed to a user who cannot see the parent record');
    }

    /* ─────────────────────────────────────────────────────────────
       F.  deleteDocuments  —  remaining leniency
    ───────────────────────────────────────────────────────────── */

    @IsTest
    static void testDeleteDocuments_unknownIdInBatchIsIgnoredAndTheRestDeleted() {
        // Looser than deleteDocument: an id that does not resolve is dropped by
        // the SOQL before the ownership loop runs, so the batch succeeds and the
        // caller is never told one id went nowhere.
        User owner = makeUser(PROFILE_ORDINARY);
        if (owner == null) return;

        Id dead = deadDocId();
        Id ownDoc;
        System.runAs(owner) { ownDoc = newFile('Alive Alongside A Dead Id'); }

        Test.startTest();
        Boolean threw = false;
        System.runAs(owner) {
            try {
                SiteFileUploadController.deleteDocuments(new List<Id>{ ownDoc, dead });
            } catch (Exception e) {
                threw = true;
            }
        }
        Test.stopTest();

        System.assertEquals(false, threw, 'An unresolvable id is silently dropped');
        System.assertEquals(false, docExists(ownDoc), 'The resolvable owned id is still deleted');
    }

    /* ─────────────────────────────────────────────────────────────
       G.  enforceSizeLimit / getMaxFileBytes  (commit 780e353)

       COVERAGE LIMIT — the oversized branch is NOT reachable from Apex.
       MAX_FILE_BYTES is 25 MB and is a private static final with no
       @TestVisible, so it cannot be lowered for a test. ContentVersion.
       ContentSize is describe-confirmed createable=false / updateable=false —
       the platform derives it from VersionData, so it cannot be faked, and an
       in-memory sObject built by JSON.deserialize is no use because
       enforceSizeLimit re-queries the database. Producing a genuinely >25 MB
       ContentVersion would need a 25 MB Blob, far past the 6 MB synchronous
       Apex heap ceiling. So the rejection path (RejectedFile construction and
       the oversized delete) stays uncovered by design rather than by omission.
       Making it testable needs one of: @TestVisible on MAX_FILE_BYTES, or the
       ceiling moved into custom metadata.

       enforceSizeLimit is deliberately NOT permission-gated: rejecting a file
       that breached the cap is not a user deleting a stored document, and
       gating it would leave the oversized file attached for everyone without
       the permission. Verify the oversized path by hand with a >25 MB upload.
    ───────────────────────────────────────────────────────────── */

    @IsTest
    static void testGetMaxFileBytes_isTwentyFiveMegabytes() {
        Test.startTest();
        Long max = SiteFileUploadController.getMaxFileBytes();
        Test.stopTest();

        System.assertEquals(25L * 1024L * 1024L, max, 'The advertised ceiling is 25 MB');
        System.assertEquals(26214400L, max, 'Pinned as a literal so a silent change is caught');
    }

    @IsTest
    static void testEnforceSizeLimit_nullListReturnsEmpty() {
        Test.startTest();
        List<SiteFileUploadController.RejectedFile> rejected =
            SiteFileUploadController.enforceSizeLimit(null);
        Test.stopTest();

        System.assertNotEquals(null, rejected, 'Always returns a list, never null');
        System.assertEquals(0, rejected.size(), 'Nothing to reject');
    }

    @IsTest
    static void testEnforceSizeLimit_emptyListReturnsEmpty() {
        Test.startTest();
        List<SiteFileUploadController.RejectedFile> rejected =
            SiteFileUploadController.enforceSizeLimit(new List<Id>());
        Test.stopTest();

        System.assertEquals(0, rejected.size(), 'Nothing to reject');
    }

    @IsTest
    static void testEnforceSizeLimit_fileUnderTheCapSurvives() {
        Id cdId = newFile('Small Enough');

        Test.startTest();
        List<SiteFileUploadController.RejectedFile> rejected =
            SiteFileUploadController.enforceSizeLimit(new List<Id>{ cdId });
        Test.stopTest();

        System.assertEquals(0, rejected.size(), 'A file under 25 MB must not be rejected');
        System.assertEquals(true, docExists(cdId), 'A file under 25 MB must not be deleted');
    }

    @IsTest
    static void testEnforceSizeLimit_bulkUnderCapAllSurvive() {
        List<Id> ids = new List<Id>{
            newFile('Small One'), newFile('Small Two'), newFile('Small Three')
        };

        Test.startTest();
        List<SiteFileUploadController.RejectedFile> rejected =
            SiteFileUploadController.enforceSizeLimit(ids);
        Test.stopTest();

        System.assertEquals(0, rejected.size(), 'None of the three exceeds the cap');
        System.assertEquals(3, [SELECT COUNT() FROM ContentDocument WHERE Id IN :ids],
            'All three survive');
    }

    @IsTest
    static void testEnforceSizeLimit_unknownIdIsIgnored() {
        Id dead = deadDocId();

        Test.startTest();
        Boolean threw = false;
        List<SiteFileUploadController.RejectedFile> rejected = null;
        try {
            rejected = SiteFileUploadController.enforceSizeLimit(new List<Id>{ dead });
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(false, threw, 'An id with no live ContentVersion is simply skipped');
        System.assertEquals(0, rejected.size(), 'Nothing to reject');
    }

    @IsTest
    static void testEnforceSizeLimit_foreignIdRaisesNoAuthorisationError() {
        // enforceSizeLimit is @AuraEnabled and still performs no ownership check
        // on the ids it is handed. What has changed is the consequence: the
        // delete itself is now behind the permission, so a caller without it can
        // no longer remove anything through this method. Passing a foreign id
        // remains silently accepted, which is the observable half of the gap.
        User outsider = makeUser(PROFILE_ORDINARY);
        if (outsider == null) return;

        Id foreignDoc = newFile('Runner Owned, Size-Checked By Outsider');

        Test.startTest();
        Boolean caught = false;
        System.runAs(outsider) {
            try {
                SiteFileUploadController.enforceSizeLimit(new List<Id>{ foreignDoc });
            } catch (AuraHandledException e) {
                caught = true;
            }
        }
        Test.stopTest();

        System.assertEquals(false, caught,
            'enforceSizeLimit raises no authorisation error - there is no guard on entry');
        System.assertEquals(true, docExists(foreignDoc),
            'Under the cap it is left alone regardless');
    }

    @IsTest
    static void testEnforceSizeLimit_isNotGatedOnThePermission() {
        // The cap must hold for every user, so enforceSizeLimit performs no
        // permission check at all. Proven on the under-cap path: an ordinary
        // user calls it without being refused. The oversized delete itself is
        // unreachable from Apex for the heap reason documented above.
        User plain = makeUser(PROFILE_ORDINARY);
        if (plain == null) return;

        Id cdId;
        System.runAs(plain) { cdId = newFile('Small, Checked By Plain User'); }

        Test.startTest();
        Boolean caught = false;
        List<SiteFileUploadController.RejectedFile> rejected = null;
        System.runAs(plain) {
            try {
                rejected = SiteFileUploadController.enforceSizeLimit(new List<Id>{ cdId });
            } catch (AuraHandledException e) {
                caught = true;
            }
        }
        Test.stopTest();

        System.assertEquals(false, caught,
            'A user with no permission must still be able to run the size check');
        System.assertEquals(0, rejected.size(), 'Nothing under the cap is reported');
        System.assertEquals(true, docExists(cdId), 'And nothing under the cap is deleted');
    }
}