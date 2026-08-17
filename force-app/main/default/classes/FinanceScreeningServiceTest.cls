@IsTest
private class FinanceScreeningServiceTest {

    // ─── Mocks ────────────────────────────────────────────────────────────────

    private class FoundActiveMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"results":{"companies":[{"company":{"name":"FIBERSTAR LIMITED","company_number":"12345678",'
                + '"jurisdiction_code":"hk","incorporation_date":"2010-03-15","dissolution_date":null,'
                + '"current_status":"Live","inactive":false}}],"total_count":1,"page":1,"per_page":5}}');
            return res;
        }
    }

    private class FoundDissolveMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"results":{"companies":[{"company":{"name":"OLDCO LIMITED","company_number":"99999999",'
                + '"jurisdiction_code":"sg","incorporation_date":"2000-01-01","dissolution_date":"2020-06-30",'
                + '"current_status":"Dissolved","inactive":true}}],"total_count":1,"page":1,"per_page":5}}');
            return res;
        }
    }

    private class NotFoundMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"results":{"companies":[],"total_count":0,"page":1,"per_page":5}}');
            return res;
        }
    }

    private class UnavailableMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(503);
            return res;
        }
    }

    // ─── Tests ────────────────────────────────────────────────────────────────

    @IsTest
    static void testActiveCompany() {
        Test.setMock(HttpCalloutMock.class, new FoundActiveMock());
        Test.startTest();
        FinanceScreeningService.ScreeningRequest req = new FinanceScreeningService.ScreeningRequest();
        req.accountName = 'Fiberstar';
        req.countryCode = 'HK';
        List<FinanceScreeningService.ScreeningResult> results = FinanceScreeningService.runScreening(
            new List<FinanceScreeningService.ScreeningRequest>{ req }
        );
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals('Active', results[0].companyStatus);
        System.assertEquals('FIBERSTAR LIMITED', results[0].registeredName);
        System.assertEquals('12345678', results[0].companyNumber);
        System.assertEquals('hk', results[0].jurisdiction);
        System.assert(results[0].screeningSummary.contains('Active'));
    }

    @IsTest
    static void testDissolvedCompany() {
        Test.setMock(HttpCalloutMock.class, new FoundDissolveMock());
        Test.startTest();
        FinanceScreeningService.ScreeningRequest req = new FinanceScreeningService.ScreeningRequest();
        req.accountName = 'OldCo';
        req.countryCode = 'SG';
        List<FinanceScreeningService.ScreeningResult> results = FinanceScreeningService.runScreening(
            new List<FinanceScreeningService.ScreeningRequest>{ req }
        );
        Test.stopTest();

        System.assertEquals('Dissolved', results[0].companyStatus);
        System.assert(results[0].screeningSummary.contains('DISSOLVED'));
    }

    @IsTest
    static void testNotFound() {
        Test.setMock(HttpCalloutMock.class, new NotFoundMock());
        Test.startTest();
        FinanceScreeningService.ScreeningRequest req = new FinanceScreeningService.ScreeningRequest();
        req.accountName = 'Unknown Corp XYZ';
        req.countryCode = 'JP';
        List<FinanceScreeningService.ScreeningResult> results = FinanceScreeningService.runScreening(
            new List<FinanceScreeningService.ScreeningRequest>{ req }
        );
        Test.stopTest();

        System.assertEquals('NOT_FOUND', results[0].companyStatus);
        System.assert(results[0].screeningSummary.contains('No company registration found'));
    }

    @IsTest
    static void testUnavailable() {
        Test.setMock(HttpCalloutMock.class, new UnavailableMock());
        Test.startTest();
        FinanceScreeningService.ScreeningRequest req = new FinanceScreeningService.ScreeningRequest();
        req.accountName = 'Any Company';
        req.countryCode = 'IN';
        List<FinanceScreeningService.ScreeningResult> results = FinanceScreeningService.runScreening(
            new List<FinanceScreeningService.ScreeningRequest>{ req }
        );
        Test.stopTest();

        System.assertEquals('UNAVAILABLE', results[0].companyStatus);
    }

    @IsTest
    static void testJurisdictionMapping() {
        System.assertEquals('hk', FinanceScreeningService.resolveJurisdiction('HK'));
        System.assertEquals('sg', FinanceScreeningService.resolveJurisdiction('SG'));
        System.assertEquals('jp', FinanceScreeningService.resolveJurisdiction('JP'));
        System.assertEquals('id', FinanceScreeningService.resolveJurisdiction('ID'));
        System.assertEquals('ph', FinanceScreeningService.resolveJurisdiction('PH'));
        System.assertEquals('kr', FinanceScreeningService.resolveJurisdiction('KR'));
        System.assertNotEquals(null, FinanceScreeningService.resolveJurisdiction('AU'));
        System.assertEquals(null,   FinanceScreeningService.resolveJurisdiction(null));
        System.assertEquals(null,   FinanceScreeningService.resolveJurisdiction(''));
    }

    @IsTest
    static void testNoCountryCode() {
        Test.setMock(HttpCalloutMock.class, new FoundActiveMock());
        Test.startTest();
        FinanceScreeningService.ScreeningRequest req = new FinanceScreeningService.ScreeningRequest();
        req.accountName = 'Fiberstar';
        req.countryCode = null; // no country — searches all jurisdictions
        List<FinanceScreeningService.ScreeningResult> results = FinanceScreeningService.runScreening(
            new List<FinanceScreeningService.ScreeningRequest>{ req }
        );
        Test.stopTest();

        System.assertNotEquals(null, results[0]);
    }
}