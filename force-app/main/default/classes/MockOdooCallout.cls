/**
 * MockOdooCallout
 * HttpCalloutMock implementation for all Odoo callout tests.
 * Used across OrderTriggerTest, AssetSyncBatchTest, BillingEventRetryTest.
 * Set via Test.setMock(HttpCalloutMock.class, MockOdooCallout.success(12345));
 */
@IsTest
public class MockOdooCallout implements HttpCalloutMock {

    private Integer statusCode;
    private String  responseBody;

    public MockOdooCallout(Integer statusCode, String responseBody) {
        this.statusCode   = statusCode;
        this.responseBody = responseBody;
    }

    public HTTPResponse respond(HTTPRequest req) {
        HttpResponse res = new HttpResponse();
        res.setStatusCode(statusCode);
        res.setBody(responseBody);
        return res;
    }

    // Convenience factories
    public static MockOdooCallout success(Integer odooId) {
        return new MockOdooCallout(200,
            '{"result": {"id": ' + odooId + ', "name": "SO-001"}}');
    }

    public static MockOdooCallout odooError() {
        return new MockOdooCallout(200,
            '{"error": {"message": "Validation error", "code": 200}}');
    }

    public static MockOdooCallout httpError() {
        return new MockOdooCallout(500, 'Internal Server Error');
    }

    public static MockOdooCallout patchSuccess() {
        return new MockOdooCallout(200, '{"result": true}');
    }
}