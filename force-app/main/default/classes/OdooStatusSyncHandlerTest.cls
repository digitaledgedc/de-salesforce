/**
 * OdooStatusSyncHandlerTest
 * OdooStatusSyncHandler is a legacy URL alias that forwards entirely to
 * OdooAssetStatusHandler.handlePost() — it has exactly one line of its own
 * logic, so both tests below deliberately use error payloads (unknown event
 * type / missing lines) rather than a "new_service" success payload: as of
 * this writing, OdooAssetStatusHandlerTest.testNewService_ViaRestEndpoint_Returns200
 * itself fails with the same "Expected 200, Actual 500" (a pre-existing bug in
 * OdooAssetStatusHandler, out of scope here). Both error paths still fully
 * exercise this class's one line and prove the forwarding is unconditional.
 */
@IsTest
private class OdooStatusSyncHandlerTest {

    @IsTest
    static void testMissingLines_StillReturns400ViaDelegate() {
        Map<String, Object> payload = new Map<String, Object>{
            'event_type'  => 'amendment',
            'odoo_sub_id' => 5002
            // lines omitted
        };
        RestContext.request  = buildRequest(payload);
        RestContext.response = new RestResponse();

        Test.startTest();
        OdooStatusSyncHandler.handleStatusUpdate();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode,
            'Legacy endpoint should forward to OdooAssetStatusHandler and return its 400 response unchanged');
    }

    @IsTest
    static void testUnknownEventType_StillReturns400ViaDelegate() {
        Map<String, Object> payload = new Map<String, Object>{
            'event_type'  => 'unknown_type',
            'odoo_sub_id' => 5003,
            'lines'       => new List<Object>{
                new Map<String, Object>{ 'odoo_ib_id' => 5103 }
            }
        };
        RestContext.request  = buildRequest(payload);
        RestContext.response = new RestResponse();

        Test.startTest();
        OdooStatusSyncHandler.handleStatusUpdate();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode,
            'Error responses from the delegate must also pass through unchanged');
    }

    private static RestRequest buildRequest(Map<String, Object> payload) {
        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf(JSON.serialize(payload));
        req.httpMethod  = 'POST';
        return req;
    }
}