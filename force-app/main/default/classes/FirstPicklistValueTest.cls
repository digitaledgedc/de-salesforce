@IsTest
private class FirstPicklistValueTest {

    private static FirstPicklistValue.Request req(String value) {
        FirstPicklistValue.Request r = new FirstPicklistValue.Request();
        r.picklistValue = value;
        return r;
    }

    // ═══════════════════════════════════════════════════════════════════
    // Blank / null input
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void getFirst_blankValueReturnsNull() {
        List<FirstPicklistValue.Request> requests = new List<FirstPicklistValue.Request>{ req('') };

        Test.startTest();
        List<FirstPicklistValue.Result> results = FirstPicklistValue.getFirst(requests);
        Test.stopTest();

        Assert.areEqual(1, results.size(), 'Should return one result per request');
        Assert.isNull(results[0].firstValue, 'Blank input should yield a null first value');
    }

    @IsTest
    static void getFirst_nullValueReturnsNull() {
        List<FirstPicklistValue.Request> requests = new List<FirstPicklistValue.Request>{ req(null) };

        Test.startTest();
        List<FirstPicklistValue.Result> results = FirstPicklistValue.getFirst(requests);
        Test.stopTest();

        Assert.isNull(results[0].firstValue, 'Null input should yield a null first value');
    }

    @IsTest
    static void getFirst_whitespaceOnlyValueReturnsNull() {
        List<FirstPicklistValue.Request> requests = new List<FirstPicklistValue.Request>{ req('   ') };

        Test.startTest();
        List<FirstPicklistValue.Result> results = FirstPicklistValue.getFirst(requests);
        Test.stopTest();

        Assert.isNull(results[0].firstValue, 'Whitespace-only input should yield a null first value');
    }

    // ═══════════════════════════════════════════════════════════════════
    // Non-country values pass through unchanged
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void getFirst_singleNonCountryValuePassesThrough() {
        List<FirstPicklistValue.Request> requests = new List<FirstPicklistValue.Request>{ req('TypeA') };

        Test.startTest();
        List<FirstPicklistValue.Result> results = FirstPicklistValue.getFirst(requests);
        Test.stopTest();

        Assert.areEqual('TypeA', results[0].firstValue, 'Non-country value should pass through unchanged');
    }

    @IsTest
    static void getFirst_multiSelectNonCountryReturnsFirstTrimmed() {
        List<FirstPicklistValue.Request> requests = new List<FirstPicklistValue.Request>{ req(' TypeA ;TypeB;TypeC') };

        Test.startTest();
        List<FirstPicklistValue.Result> results = FirstPicklistValue.getFirst(requests);
        Test.stopTest();

        Assert.areEqual('TypeA', results[0].firstValue, 'Should return first segment, trimmed of whitespace');
    }

    // ═══════════════════════════════════════════════════════════════════
    // Country name → country code conversion
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void getFirst_countryNameConvertsToCode() {
        List<FirstPicklistValue.Request> requests = new List<FirstPicklistValue.Request>{ req('Japan') };

        Test.startTest();
        List<FirstPicklistValue.Result> results = FirstPicklistValue.getFirst(requests);
        Test.stopTest();

        Assert.areEqual('JP', results[0].firstValue, 'Japan should convert to JP');
    }

    @IsTest
    static void getFirst_multiSelectCountryFirstConvertsToCode() {
        List<FirstPicklistValue.Request> requests = new List<FirstPicklistValue.Request>{ req('Singapore;Thailand;India') };

        Test.startTest();
        List<FirstPicklistValue.Result> results = FirstPicklistValue.getFirst(requests);
        Test.stopTest();

        Assert.areEqual('SG', results[0].firstValue, 'First segment Singapore should convert to SG');
    }

    @IsTest
    static void getFirst_countryNameWithSurroundingWhitespaceConvertsToCode() {
        List<FirstPicklistValue.Request> requests = new List<FirstPicklistValue.Request>{ req('Hong Kong ;Korea') };

        Test.startTest();
        List<FirstPicklistValue.Result> results = FirstPicklistValue.getFirst(requests);
        Test.stopTest();

        Assert.areEqual('HK', results[0].firstValue, 'Hong Kong (trimmed) should convert to HK');
    }

    @IsTest
    static void getFirst_unknownCountryLikeValuePassesThrough() {
        List<FirstPicklistValue.Request> requests = new List<FirstPicklistValue.Request>{ req('Malaysia') };

        Test.startTest();
        List<FirstPicklistValue.Result> results = FirstPicklistValue.getFirst(requests);
        Test.stopTest();

        Assert.areEqual('Malaysia', results[0].firstValue,
            'Country not in the map should pass through unchanged (case-sensitive exact match only)');
    }

    // ═══════════════════════════════════════════════════════════════════
    // Bulk (multiple requests in one invocable call)
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void getFirst_bulkRequestsProcessEachIndependently() {
        List<FirstPicklistValue.Request> requests = new List<FirstPicklistValue.Request>{
            req('China;Indonesia'),
            req(''),
            req('Philippines'),
            req('CustomValue')
        };

        Test.startTest();
        List<FirstPicklistValue.Result> results = FirstPicklistValue.getFirst(requests);
        Test.stopTest();

        Assert.areEqual(4, results.size(), 'Should return one result per request, in order');
        Assert.areEqual('CN', results[0].firstValue, 'First request: China -> CN');
        Assert.isNull(results[1].firstValue, 'Second request: blank -> null');
        Assert.areEqual('PH', results[2].firstValue, 'Third request: Philippines -> PH');
        Assert.areEqual('CustomValue', results[3].firstValue, 'Fourth request: unmapped value passes through');
    }

    @IsTest
    static void getFirst_bulk200RequestsAllCountries() {
        List<FirstPicklistValue.Request> requests = new List<FirstPicklistValue.Request>();
        for (Integer i = 0; i < 200; i++) {
            requests.add(req(Math.mod(i, 2) == 0 ? 'Korea' : 'Batch' + i));
        }

        Test.startTest();
        List<FirstPicklistValue.Result> results = FirstPicklistValue.getFirst(requests);
        Test.stopTest();

        Assert.areEqual(200, results.size(), 'Should process all 200 requests');
        for (Integer i = 0; i < 200; i++) {
            if (Math.mod(i, 2) == 0) {
                Assert.areEqual('KR', results[i].firstValue, 'Even indexes should convert Korea -> KR');
            } else {
                Assert.areEqual('Batch' + i, results[i].firstValue, 'Odd indexes should pass through unchanged');
            }
        }
    }
}