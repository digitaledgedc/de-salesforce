public without sharing class SiteFileUploadController {

    // Grants deletion of record documents uploaded by ANYONE, and stamping the
    // document type on them. Nobody deletes a stored document without it - not
    // even the user who uploaded it. Assign through a permission set so the
    // capability is grantable without an Apex change and survives a profile
    // rename. It replaces a hardcoded profile-name allowlist of which three of
    // four names did not exist in this org at all ('System Admin', 'Finance',
    // 'Regional Manager'); the real finance profile is 'DE Finance', which never
    // matched the literal 'Finance', so finance staff were refused while the
    // error message told them they were allowed.
    @TestVisible
    private static final String MANAGE_ALL_DOCUMENTS_PERMISSION = 'Manage_All_Record_Documents';

    // SFDC-303 follow-up: ceiling on a single uploaded file. lightning-file-upload
    // itself tops out at 2 GB, which is far more than this org wants to accept, so
    // the real limit lives here and is enforced after the bytes land (see 3a).
    // Raising it later is a one-line change: the LWC caption and the rejection
    // message both read this value through getMaxFileBytes().
    private static final Long MAX_FILE_BYTES = 25L * 1024L * 1024L;   // 25 MB

    // Cached per transaction so getSiteDocuments/deleteDocument don't re-check.
    private static Boolean privilegedCache;

    private static Boolean isPrivilegedUser() {
        if (privilegedCache == null) {
            privilegedCache = FeatureManagement.checkPermission(MANAGE_ALL_DOCUMENTS_PERMISSION);
        }
        return privilegedCache;
    }

    @AuraEnabled(cacheable=true)
    public static Boolean canManageDocuments() { return isPrivilegedUser(); }

    @AuraEnabled(cacheable=true)
    public static Long getMaxFileBytes() { return MAX_FILE_BYTES; }

    private static void enforcePrivilegedAccess() {
        if (!isPrivilegedUser()) {
            throw new AuraHandledException(
                'Access denied. This action requires the Manage All Record Documents permission.');
        }
    }

    /* ══════════════════════════════════════════════════════
       INNER CLASSES
    ══════════════════════════════════════════════════════ */

    public class UploadFileItem {
        @AuraEnabled public String fileName    {get;set;}
        @AuraEnabled public String base64Data  {get;set;}
        @AuraEnabled public String contentType {get;set;}
        @AuraEnabled public String docType     {get;set;}
    }

    public class RejectedFile {
        @AuraEnabled public String contentDocumentId {get;set;}
        @AuraEnabled public String fileName          {get;set;}
        @AuraEnabled public Long   fileSizeBytes     {get;set;}
    }

    public class DocTypeAssignment {
        @AuraEnabled public String contentDocumentId {get;set;}
        @AuraEnabled public String docType           {get;set;}
    }

    public class DocTypeOption {
        @AuraEnabled public String masterLabel  {get;set;}
        @AuraEnabled public String documentType {get;set;}
    }

    public class SiteDocument {
        @AuraEnabled public String  contentDocumentId {get;set;}
        @AuraEnabled public String  contentVersionId  {get;set;}
        @AuraEnabled public String  fileName          {get;set;}
        @AuraEnabled public String  docType           {get;set;}
        @AuraEnabled public String  fileExtension     {get;set;}
        @AuraEnabled public Long    fileSizeBytes     {get;set;}
        @AuraEnabled public String  lastModifiedDate  {get;set;}
        @AuraEnabled public String  createdByName     {get;set;}
        @AuraEnabled public String  downloadUrl       {get;set;}
    }

    /* ══════════════════════════════════════════════════════
       1.  GET DOCUMENT TYPES FROM CUSTOM METADATA
    ══════════════════════════════════════════════════════ */
    @AuraEnabled(cacheable=true)
    public static List<DocTypeOption> getSiteDocumentTypes() {
        List<DocTypeOption> results = new List<DocTypeOption>();
        for (Site_Document__mdt r : [
            SELECT MasterLabel, Document_Type__c
            FROM   Site_Document__mdt
            ORDER BY MasterLabel
        ]) {
            DocTypeOption d = new DocTypeOption();
            d.masterLabel  = r.MasterLabel;
            d.documentType = String.isNotBlank(r.Document_Type__c)
                             ? r.Document_Type__c
                             : r.MasterLabel;
            results.add(d);
        }
        return results;
    }

    /* ══════════════════════════════════════════════════════
       2.  GET EXISTING DOCUMENTS LINKED TO A SITE RECORD
           Reads ContentDocumentLink → ContentVersion
           and returns metadata including Document_Type__c
    ══════════════════════════════════════════════════════ */
    @AuraEnabled(cacheable=false)
    public static List<SiteDocument> getSiteDocuments(Id siteId) {
        if (siteId == null) throw new AuraHandledException('Site ID is required.');

        // Collect ContentDocument IDs linked to this record
        List<ContentDocumentLink> links = [
            SELECT ContentDocumentId
            FROM   ContentDocumentLink
            WHERE  LinkedEntityId = :siteId
            ORDER BY SystemModstamp DESC
        ];

        if (links.isEmpty()) return new List<SiteDocument>();

        Set<Id> docIds = new Set<Id>();
        for (ContentDocumentLink l : links) docIds.add(l.ContentDocumentId);

        // Fetch latest published ContentVersion for each document
        List<ContentVersion> versions = [
            SELECT Id,
                   ContentDocumentId,
                   Title,
                   FileExtension,
                   ContentSize,
                   Document_Type__c,
                   LastModifiedDate,
                   CreatedBy.Name,
                   VersionNumber
            FROM   ContentVersion
            WHERE  ContentDocumentId IN :docIds
              AND  IsLatest = true
            ORDER BY LastModifiedDate DESC
        ];

        List<SiteDocument> docs = new List<SiteDocument>();
        for (ContentVersion cv : versions) {
            SiteDocument d         = new SiteDocument();
            d.contentDocumentId   = cv.ContentDocumentId;
            d.contentVersionId    = cv.Id;
            d.fileName            = cv.Title + (String.isNotBlank(cv.FileExtension) ? '.' + cv.FileExtension : '');
            d.docType             = String.isNotBlank(cv.Document_Type__c) ? cv.Document_Type__c : '-';
            d.fileExtension       = cv.FileExtension != null ? cv.FileExtension.toLowerCase() : '';
            d.fileSizeBytes       = cv.ContentSize;
            d.lastModifiedDate    = cv.LastModifiedDate != null ? cv.LastModifiedDate.format('MMM d, yyyy') : '';
            d.createdByName       = cv.CreatedBy != null ? cv.CreatedBy.Name : '';
            d.downloadUrl         = '/sfc/servlet.shepherd/version/download/' + cv.Id;
            docs.add(d);
        }
        return docs;
    }

    /* ══════════════════════════════════════════════════════
       3.  UPLOAD FILES TO SITE__C
    ══════════════════════════════════════════════════════ */
    @AuraEnabled
    public static void uploadFilesToSite(Id siteId, List<UploadFileItem> files) {
        if (siteId == null)          throw new AuraHandledException('Site ID is required.');
        if (files == null || files.isEmpty()) throw new AuraHandledException('No files provided.');

        for (UploadFileItem f : files) {
            if (String.isBlank(f.fileName) || String.isBlank(f.base64Data))  throw new AuraHandledException('FileName or Base64 data is missing.');
            if (String.isBlank(f.docType))
                throw new AuraHandledException('Document Type is required for: ' + f.fileName);
        }

        List<ContentVersion> toInsert = new List<ContentVersion>();
        for (UploadFileItem f : files) {
            ContentVersion cv         = new ContentVersion();
            cv.Title                  = f.fileName.contains('.')  ? f.fileName.substringBeforeLast('.')  : f.fileName;
            cv.PathOnClient           = '/' + f.fileName;
            cv.VersionData            = EncodingUtil.base64Decode(f.base64Data);
            cv.FirstPublishLocationId = siteId;
            cv.Document_Type__c       = f.docType;
            toInsert.add(cv);
        }
        insert toInsert;
    }

    /* ══════════════════════════════════════════════════════
       3a. ENFORCE THE FILE SIZE CEILING
           lightning-file-upload has no max-size attribute and it commits the
           bytes BEFORE onuploadfinished fires, so the cap cannot be applied in
           the browser — by the time anything here runs, the file is already
           stored. The only enforcement point is after the fact: measure what
           landed, delete anything over MAX_FILE_BYTES, and hand the names back
           so the LWC can drop them from the staging modal and tell the user.

           NOT gated on Manage All Record Documents, unlike the delete icon.
           Refusing an upload that breached the cap is not a user deleting a
           stored document - the file was never accepted, no user chose it, and
           only ids actually over MAX_FILE_BYTES are ever touched. Gating it
           would leave the oversized file attached and make the cap advisory
           for everyone without the permission. The class is `without sharing`
           and this DML runs in system mode, so no user permission is involved.

           Cheap on heap: ContentSize is a field read, the file body is never
           loaded into Apex.
    ══════════════════════════════════════════════════════ */
    @AuraEnabled
    public static List<RejectedFile> enforceSizeLimit(List<Id> contentDocumentIds) {
        List<RejectedFile> rejected = new List<RejectedFile>();
        if (contentDocumentIds == null || contentDocumentIds.isEmpty()) return rejected;

        List<ContentVersion> versions = [
            SELECT Id, ContentDocumentId, Title, FileExtension, ContentSize
            FROM   ContentVersion
            WHERE  ContentDocumentId IN :contentDocumentIds
              AND  IsLatest = true
        ];

        List<Id> oversized = new List<Id>();
        for (ContentVersion cv : versions) {
            if (cv.ContentSize == null || cv.ContentSize <= MAX_FILE_BYTES) continue;
            RejectedFile r     = new RejectedFile();
            r.contentDocumentId = cv.ContentDocumentId;
            r.fileName          = String.isBlank(cv.FileExtension)
                                  ? cv.Title
                                  : cv.Title + '.' + cv.FileExtension;
            r.fileSizeBytes     = cv.ContentSize;
            rejected.add(r);
            oversized.add(cv.ContentDocumentId);
        }
        if (oversized.isEmpty()) return rejected;

        // The running user just uploaded these. Note this method is
        // @AuraEnabled and does not re-check that, so a caller who forges an id
        // of someone else's oversized file could have it deleted.
        try {
            delete [SELECT Id FROM ContentDocument WHERE Id IN :oversized];
        } catch (Exception e) {
            throw new AuraHandledException(
                'File exceeded the size limit but could not be removed: ' + e.getMessage());
        }
        return rejected;
    }

    /* ══════════════════════════════════════════════════════
       SHARED GUARD FOR TYPING (not deletion)
           Throws unless the caller owns every document listed, or holds the
           Manage All Record Documents permission. Typing is NOT deletion: a
           user must be able to stamp Document_Type__c on the file they just
           uploaded, otherwise the upload cannot be saved at all. This class is
           `without sharing` and its DML runs in system mode, so this is the
           only real access control.
    ══════════════════════════════════════════════════════ */
    private static void assertCallerMayType(Set<Id> contentDocumentIds) {
        if (isPrivilegedUser()) return;

        Id runningUserId = UserInfo.getUserId();
        for (ContentDocument cd : [
            SELECT Id, OwnerId FROM ContentDocument WHERE Id IN :contentDocumentIds
        ]) {
            if (cd.OwnerId != runningUserId)
                throw new AuraHandledException('You can only set the type on files you uploaded.');
        }
    }

    /* ══════════════════════════════════════════════════════
       3b. STAMP Document_Type__c ON ALREADY-UPLOADED FILES
           SFDC-303: lightning-file-upload stores the bytes and links them to
           the record itself, so Apex never sees the file body and the 6 MB
           synchronous request/heap ceiling no longer applies. All that is left
           is writing the document type the user picked in the staging modal.
    ══════════════════════════════════════════════════════ */
    @AuraEnabled
    public static void setDocumentTypes(List<DocTypeAssignment> assignments) {
        if (assignments == null || assignments.isEmpty())
            throw new AuraHandledException('No document type assignments provided.');

        Map<Id, String> typeByDocId = new Map<Id, String>();
        for (DocTypeAssignment a : assignments) {
            if (String.isBlank(a.contentDocumentId))
                throw new AuraHandledException('Document ID is missing.');
            if (String.isBlank(a.docType))
                throw new AuraHandledException('Document Type is required for every file.');
            typeByDocId.put((Id) a.contentDocumentId, a.docType.trim());
        }

        // The uploader, or a permission holder for anyone's file. Without this
        // the update ran in system mode with no check at all, letting any user
        // re-type a file they could not even see.
        assertCallerMayType(typeByDocId.keySet());

        List<ContentVersion> versions = [
            SELECT Id, ContentDocumentId
            FROM   ContentVersion
            WHERE  ContentDocumentId IN :typeByDocId.keySet()
              AND  IsLatest = true
        ];
        if (versions.isEmpty()) throw new AuraHandledException('Uploaded file(s) not found.');

        for (ContentVersion cv : versions) {
            cv.Document_Type__c = typeByDocId.get(cv.ContentDocumentId);
        }
        try {
            update versions;
        } catch (Exception e) {
            throw new AuraHandledException('Could not save document type: ' + e.getMessage());
        }
    }

    /* ══════════════════════════════════════════════════════
       3c. BULK DELETE (cancel cleanup)
           Cancelling the staging modal has to remove files that
           lightning-file-upload already committed before the modal opened.
           Scoped to the caller's OWN uploads, not gated on Manage All Record
           Documents: abandoning an unsaved upload is not deleting a stored
           document, and gating it would leave untyped files nobody can clear.
           It cannot reach a saved document belonging to anyone else.
           Refuses the whole batch rather than part-succeeding.
    ══════════════════════════════════════════════════════ */
    @AuraEnabled
    public static void deleteDocuments(List<Id> contentDocumentIds) {
        if (contentDocumentIds == null || contentDocumentIds.isEmpty()) return;

        List<ContentDocument> targets = [
            SELECT Id, OwnerId
            FROM   ContentDocument
            WHERE  Id IN :contentDocumentIds
        ];
        if (targets.isEmpty()) return;

        Id runningUserId = UserInfo.getUserId();
        for (ContentDocument cd : targets) {
            if (cd.OwnerId != runningUserId)
                throw new AuraHandledException('You can only cancel uploads you made.');
        }

        try {
            delete targets;
        } catch (Exception e) {
            throw new AuraHandledException('Delete failed: ' + e.getMessage());
        }
    }

    /* ══════════════════════════════════════════════════════
       4.  DELETE A DOCUMENT (ContentDocument)
           Deletes the ContentDocument which cascades to
           all ContentVersions and ContentDocumentLinks.
    ══════════════════════════════════════════════════════ */
    @AuraEnabled
    public static void deleteDocument(Id contentDocumentId) {
        enforcePrivilegedAccess();
        if (contentDocumentId == null) throw new AuraHandledException('Document ID is required.');
        try {
            delete [SELECT Id FROM ContentDocument WHERE Id = :contentDocumentId LIMIT 1];   } catch (Exception e) {  throw new AuraHandledException('Delete failed: ' + e.getMessage());
        }
    }

    /* ══════════════════════════════════════════════════════
       5.  CREATE NEW DOCUMENT TYPE (Metadata API)
    ══════════════════════════════════════════════════════ */
    @AuraEnabled
    public static void createDocumentTypeMetadata(String masterLabel, String developerName) {
        enforcePrivilegedAccess();
        if (String.isBlank(masterLabel) || String.isBlank(developerName))
            throw new AuraHandledException('Name and Developer Name are required.');

        Metadata.CustomMetadata cmdt = new Metadata.CustomMetadata();
        cmdt.fullName = 'Site_Document__mdt.' + developerName.trim();
        cmdt.label    = masterLabel.trim();

        Metadata.CustomMetadataValue fDocType = new Metadata.CustomMetadataValue();
        fDocType.field = 'Document_Type__c';
        fDocType.value = masterLabel.trim();
        cmdt.values.add(fDocType);

        Metadata.DeployContainer container = new Metadata.DeployContainer();
        container.addMetadata(cmdt);
        Metadata.Operations.enqueueDeployment(container, new DeployCallback());
    }

    public class DeployCallback implements Metadata.DeployCallback {
        public void handleResult(Metadata.DeployResult result, Metadata.DeployCallbackContext context) { if (!result.done || result.status != Metadata.DeployStatus.Succeeded) {
                System.debug(LoggingLevel.ERROR, '[SiteFileUploadController] Metadata deploy failed: ' + result);
            }
        }
    }
}