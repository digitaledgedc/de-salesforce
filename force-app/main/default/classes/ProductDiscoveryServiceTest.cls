/**
 * ProductDiscoveryServiceTest
 *
 * Tests for ProductDiscoveryService — RLM product discovery context builder.
 */
@IsTest
private class ProductDiscoveryServiceTest {

    @IsTest
    static void testBuildContextReturnsCorrectNode() {
        ProductDiscoveryService.BuildContextRequest req = new ProductDiscoveryService.BuildContextRequest();
        req.recordId = 'a0085000001abcdAAA';
        req.objectApiName = 'Quote';

        Test.startTest();
        List<ProductDiscoveryService.BuildContextResult> results =
            ProductDiscoveryService.buildContext(new List<ProductDiscoveryService.BuildContextRequest>{ req });
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Should return one result');
        System.assertEquals(1, results[0].contextDataInputArray.size(), 'Should have one ContextDataInput');
        System.assertEquals('Quote', results[0].contextDataInputArray[0].nodeName, 'nodeName should be Quote');
        System.assertEquals(
            req.recordId,
            (String) results[0].contextDataInputArray[0].nodeData.get('id'),
            'nodeData.id should be recordId'
        );
    }

    @IsTest
    static void testBuildContextDefaultsToQuote() {
        ProductDiscoveryService.BuildContextRequest req = new ProductDiscoveryService.BuildContextRequest();
        req.recordId = 'a0085000001abcdAAA';
        // objectApiName intentionally blank

        Test.startTest();
        List<ProductDiscoveryService.BuildContextResult> results =
            ProductDiscoveryService.buildContext(new List<ProductDiscoveryService.BuildContextRequest>{ req });
        Test.stopTest();

        System.assertEquals('Quote', results[0].contextDataInputArray[0].nodeName,
            'Should default nodeName to Quote when objectApiName is blank');
    }

    @IsTest
    static void testBuildContextBulk() {
        List<ProductDiscoveryService.BuildContextRequest> requests = new List<ProductDiscoveryService.BuildContextRequest>();
        for (Integer i = 0; i < 5; i++) {
            ProductDiscoveryService.BuildContextRequest req = new ProductDiscoveryService.BuildContextRequest();
            req.recordId = 'a008500000' + String.valueOf(i).leftPad(9, '0') + 'AA';
            req.objectApiName = 'Quote';
            requests.add(req);
        }

        Test.startTest();
        List<ProductDiscoveryService.BuildContextResult> results =
            ProductDiscoveryService.buildContext(requests);
        Test.stopTest();

        System.assertEquals(5, results.size(), 'Should handle bulk input');
    }
}