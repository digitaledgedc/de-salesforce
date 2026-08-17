/**
 * OdooCalloutServiceTest
 * Direct coverage for the shared Odoo HTTP utility — success, JSON-RPC error,
 * application error, HTTP 403/404/500/other branches, endpoint resolution, logError.
 */
@IsTest
private class OdooCalloutServiceTest {

    @TestSetup
    static void setup() {
        OdooIntegrationSettings__c s = OdooIntegrationSettings__c.getOrgDefaults();
        s.Environment__c = 'Sandbox';
        s.Base_URL__c    = 'https://test.odoo.example.com';
        s.Username__c    = 'u';
        s.Password__c    = 'p';
        upsert s;
    }

    @IsTest
    static void post_success_parsesOdooId() {
        Test.setMock(HttpCalloutMock.class, new MockOdooCallout(200, '{"result":{"order_id":4321,"name":"SO-1"}}'));
        Test.startTest();
        OdooCalloutService.Response r = OdooCalloutService.post('/api/v1/create_sale_order', '{}');
        Test.stopTest();
        System.assertEquals(true, r.isSuccess, 'HTTP 200 with result → success');
        System.assertEquals(4321, r.odooId, 'order_id should be parsed');
    }

    @IsTest
    static void post_jsonRpcError() {
        Test.setMock(HttpCalloutMock.class, new MockOdooCallout(200, '{"error":{"message":"auth failed"}}'));
        Test.startTest();
        OdooCalloutService.Response r = OdooCalloutService.post('/x', '{}');
        Test.stopTest();
        System.assertEquals(false, r.isSuccess, 'Top-level error key → failure');
        System.assertNotEquals(null, r.errorBody, 'Error body should be captured');
    }

    @IsTest
    static void post_applicationError() {
        Test.setMock(HttpCalloutMock.class, new MockOdooCallout(200, '{"result":{"status":"error","message":"bad data"}}'));
        Test.startTest();
        OdooCalloutService.Response r = OdooCalloutService.post('/x', '{}');
        Test.stopTest();
        System.assertEquals(false, r.isSuccess, 'result.status=error → failure');
        System.assertEquals('bad data', r.errorBody, 'Application error message surfaced');
    }

    @IsTest
    static void get_http404() {
        Test.setMock(HttpCalloutMock.class, new MockOdooCallout(404, 'Not Found'));
        Test.startTest();
        OdooCalloutService.Response r = OdooCalloutService.get('/api/v1/thing');
        Test.stopTest();
        System.assertEquals(false, r.isSuccess, '404 → failure');
        System.assert(r.errorBody.contains('404'), 'Error should mention 404');
    }

    @IsTest
    static void patch_http403() {
        Test.setMock(HttpCalloutMock.class, new MockOdooCallout(403, 'Forbidden'));
        Test.startTest();
        OdooCalloutService.Response r = OdooCalloutService.patch('/api/v1/thing', '{}');
        Test.stopTest();
        System.assertEquals(false, r.isSuccess, '403 → failure');
        System.assert(r.errorBody.contains('403'), 'Error should mention 403');
    }

    @IsTest
    static void post_http500_andGeneric() {
        Test.setMock(HttpCalloutMock.class, new MockOdooCallout(500, 'Server boom'));
        Test.startTest();
        OdooCalloutService.Response r = OdooCalloutService.post('/x', '{}');
        Test.stopTest();
        System.assertEquals(false, r.isSuccess, '500 → failure');
        System.assert(r.errorBody.contains('500'), 'Error should mention 500');
    }

    @IsTest
    static void resolveBaseEndpoint_fallbackToNamedCredential() {
        OdooIntegrationSettings__c s = OdooIntegrationSettings__c.getOrgDefaults();
        s.Base_URL__c = null;               // force the callout: named-credential fallback
        s.Environment__c = 'Sandbox';
        upsert s;
        String ep = OdooCalloutService.resolveBaseEndpoint(s);
        System.assertEquals('callout:DigitalEdge_Odoo_Sandbox', ep,
            'Null Base_URL should resolve to the environment-named credential');
    }

    @IsTest
    static void logError_insertsRecord() {
        Test.startTest();
        OdooCalloutService.logError(null, 'IP-9', 'unit test error');
        Test.stopTest();
        System.assertEquals(1,
            [SELECT COUNT() FROM DE_Integration_Error__c WHERE IP_Reference__c = 'IP-9'],
            'logError should insert a DE_Integration_Error__c');
    }
}