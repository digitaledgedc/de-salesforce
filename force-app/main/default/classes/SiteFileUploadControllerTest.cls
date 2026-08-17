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
        Site__c site = [SELECT Id FROM Site__c WHERE Site_Name__c = 'Upload Test Site' LIMIT 1];

        ContentVersion cv = new ContentVersion(
            Title                 = 'To Delete',
            PathOnClient          = '/to-delete.txt',
            VersionData           = Blob.valueOf('delete me'),
            FirstPublishLocationId = site.Id
        );
        insert cv;

        Id contentDocId = [
            SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id
        ].ContentDocumentId;

        Test.startTest();
        SiteFileUploadController.deleteDocument(contentDocId);
        Test.stopTest();

        List<ContentDocument> remaining = [
            SELECT Id FROM ContentDocument WHERE Id = :contentDocId
        ];
        System.assertEquals(0, remaining.size(), 'Document should be deleted');
    }

    @IsTest
    static void testDeleteDocument_nullId() {
        Test.startTest();
        Boolean caught = false;
        try {
            SiteFileUploadController.deleteDocument(null);
        } catch (AuraHandledException e) {
            caught = true;
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
        Test.startTest();
        try {
            SiteFileUploadController.createDocumentTypeMetadata(
                'Network Diagram', 'Network_Diagram'
            );
        } catch (System.AsyncException e) {
            // Metadata.Operations.enqueueDeployment is not supported in test context
            // — platform limitation. Validates method execution up to the deploy call.
        }
        Test.stopTest();
    }

    @IsTest
    static void testCreateDocumentTypeMetadata_blank() {
        Test.startTest();
        Boolean caught = false;
        try {
            SiteFileUploadController.createDocumentTypeMetadata('', '');
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();

        System.assert(caught, 'Should throw for blank inputs');
    }
}