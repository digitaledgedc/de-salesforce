@IsTest
private class SplitStringActionTest {

    @IsTest
    static void testSplitMultipleCountries() {
        // Simulates a multi-select picklist with 3 country values
        SplitStringAction.SplitRequest req = new SplitStringAction.SplitRequest();
        req.inputString = 'JP;SG;HK';
        req.delimiter   = ';';

        Test.startTest();
        List<List<String>> results = SplitStringAction.split(
            new List<SplitStringAction.SplitRequest>{ req }
        );
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Should return one result list');
        List<String> countries = results[0];
        System.assertEquals(3, countries.size(), 'Should have 3 countries');
        System.assertEquals('JP', countries[0], 'First country should be JP');
        System.assertEquals('SG', countries[1], 'Second country should be SG');
        System.assertEquals('HK', countries[2], 'Third country should be HK');
    }

    @IsTest
    static void testSplitSingleCountry() {
        // Simulates a single-country lead (no semicolon)
        SplitStringAction.SplitRequest req = new SplitStringAction.SplitRequest();
        req.inputString = 'JP';
        req.delimiter   = ';';

        Test.startTest();
        List<List<String>> results = SplitStringAction.split(
            new List<SplitStringAction.SplitRequest>{ req }
        );
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(1, results[0].size(), 'Should have exactly 1 country');
        System.assertEquals('JP', results[0][0]);
    }

    @IsTest
    static void testSplitBlankInput() {
        // Empty string should return an empty list — no Opportunity created
        SplitStringAction.SplitRequest req = new SplitStringAction.SplitRequest();
        req.inputString = '';
        req.delimiter   = ';';

        Test.startTest();
        List<List<String>> results = SplitStringAction.split(
            new List<SplitStringAction.SplitRequest>{ req }
        );
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(0, results[0].size(), 'Blank input should return empty list');
    }

    @IsTest
    static void testSplitNullInput() {
        // Null string should not throw — returns empty list
        SplitStringAction.SplitRequest req = new SplitStringAction.SplitRequest();
        req.inputString = null;
        req.delimiter   = ';';

        Test.startTest();
        List<List<String>> results = SplitStringAction.split(
            new List<SplitStringAction.SplitRequest>{ req }
        );
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(0, results[0].size(), 'Null input should return empty list');
    }

    @IsTest
    static void testSplitAllNineCountries() {
        // Full multi-country scenario — all 9 DE markets
        SplitStringAction.SplitRequest req = new SplitStringAction.SplitRequest();
        req.inputString = 'JP;KR;ID;SG;HK;PH;CN;IN;TH';
        req.delimiter   = ';';

        Test.startTest();
        List<List<String>> results = SplitStringAction.split(
            new List<SplitStringAction.SplitRequest>{ req }
        );
        Test.stopTest();

        System.assertEquals(9, results[0].size(), 'All 9 countries should be parsed');
        System.assertEquals('JP', results[0][0]);
        System.assertEquals('TH', results[0][8]);
    }

    @IsTest
    static void testSplitBulkRequests() {
        // Multiple requests in one invocation (bulk pattern)
        List<SplitStringAction.SplitRequest> requests = new List<SplitStringAction.SplitRequest>();

        SplitStringAction.SplitRequest r1 = new SplitStringAction.SplitRequest();
        r1.inputString = 'JP;SG';
        r1.delimiter   = ';';
        requests.add(r1);

        SplitStringAction.SplitRequest r2 = new SplitStringAction.SplitRequest();
        r2.inputString = 'KR';
        r2.delimiter   = ';';
        requests.add(r2);

        Test.startTest();
        List<List<String>> results = SplitStringAction.split(requests);
        Test.stopTest();

        System.assertEquals(2, results.size(), 'Should return 2 result lists');
        System.assertEquals(2, results[0].size(), 'First request: JP;SG = 2 values');
        System.assertEquals(1, results[1].size(), 'Second request: KR = 1 value');
    }
}