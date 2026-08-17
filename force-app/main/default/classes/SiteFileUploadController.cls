public without sharing class SiteFileUploadController {

    private static final Set<String> PRIVILEGED_PROFILES = new Set<String>{
        'System Administrator',
        'System Admin',
        'Finance',
        'Regional Manager'
    };

    @AuraEnabled(cacheable=true)
    public static Boolean canManageDocuments() { String profileName = [SELECT Name FROM Profile WHERE Id = :UserInfo.getProfileId() LIMIT 1].Name; return PRIVILEGED_PROFILES.contains(profileName); }

    private static void enforcePrivilegedAccess() {
        String profileName = [SELECT Name FROM Profile WHERE Id = :UserInfo.getProfileId() LIMIT 1].Name;
        if (!PRIVILEGED_PROFILES.contains(profileName)) {throw new AuraHandledException('Access denied. Only Finance, Regional Manager, or System Administrator profiles can perform this action.');
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
            d.docType             = String.isNotBlank(cv.Document_Type__c) ? cv.Document_Type__c : '—';
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