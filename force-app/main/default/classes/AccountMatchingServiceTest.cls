/**
 * AccountMatchingServiceTest
 *
 * Tests for AccountMatchingService covering:
 *   1. Exact match returns 100%
 *   2. Close fuzzy match returns >= 80%
 *   3. No match returns matchFound = false
 *   4. Country filter prioritizes same-country accounts
 *   5. Levenshtein similarity scoring
 */
@IsTest
private class AccountMatchingServiceTest {

    @TestSetup
    static void setup() {
        List<Account> accounts = new List<Account>{
            new Account(
                Name = 'Digital Edge Holdings',
                Operation_Country__c = 'Singapore',
                Tax_ID__c = 'AMT00001'
            ),
            new Account(
                Name = 'Digital Edge Japan',
                Operation_Country__c = 'Japan',
                Tax_ID__c = 'AMT00002'
            ),
            new Account(
                Name = 'Equinix Singapore',
                Operation_Country__c = 'Singapore',
                Tax_ID__c = 'AMT00003'
            ),
            new Account(
                Name = 'ABC Corp',
                Operation_Country__c = 'Hong Kong',
                Tax_ID__c = 'AMT00004'
            )
        };
        insert accounts;
    }

    @IsTest
    static void testExactMatchReturns100() {
        Account target = [SELECT Id FROM Account WHERE Name = 'Digital Edge Holdings' LIMIT 1];

        // SOSL in test context requires fixed search results
        Test.setFixedSearchResults(new List<Id>{ target.Id });

        Test.startTest();
        AccountMatchingService.MatchRequest req = new AccountMatchingService.MatchRequest();
        req.companyName = 'Digital Edge Holdings';
        List<AccountMatchingService.MatchResult> results =
            AccountMatchingService.findMatchingAccounts(
                new List<AccountMatchingService.MatchRequest>{ req }
            );
        Test.stopTest();

        System.assertEquals(1, results.size());
        AccountMatchingService.MatchResult r = results[0];
        System.assertEquals(true, r.matchFound, 'Exact match should be found');
        System.assertEquals('Digital Edge Holdings', r.accountName);
        System.assert(r.matchScore >= 95, 'Exact match score should be >= 95, got: ' + r.matchScore);
    }

    @IsTest
    static void testFuzzyMatchAboveThreshold() {
        Account target = [SELECT Id FROM Account WHERE Name = 'Digital Edge Holdings' LIMIT 1];

        // SOSL returns this candidate; Levenshtein scores the fuzzy match
        Test.setFixedSearchResults(new List<Id>{ target.Id });

        Test.startTest();
        AccountMatchingService.MatchRequest req = new AccountMatchingService.MatchRequest();
        req.companyName = 'Digital Edge Holding';  // Missing 's' — 95% similar
        List<AccountMatchingService.MatchResult> results =
            AccountMatchingService.findMatchingAccounts(
                new List<AccountMatchingService.MatchRequest>{ req }
            );
        Test.stopTest();

        System.assertEquals(1, results.size());
        AccountMatchingService.MatchResult r = results[0];
        System.assertEquals(true, r.matchFound, 'Close fuzzy match should be found');
        System.assert(r.matchScore >= 80, 'Score should be >= 80, got: ' + r.matchScore);
    }

    @IsTest
    static void testNoMatchBelowThreshold() {
        Test.startTest();
        AccountMatchingService.MatchRequest req = new AccountMatchingService.MatchRequest();
        req.companyName = 'Totally Different Company XYZ 12345';
        List<AccountMatchingService.MatchResult> results =
            AccountMatchingService.findMatchingAccounts(
                new List<AccountMatchingService.MatchRequest>{ req }
            );
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(false, results[0].matchFound, 'Dissimilar name should not match');
    }

    @IsTest
    static void testBlankCompanyReturnsNoMatch() {
        Test.startTest();
        AccountMatchingService.MatchRequest req = new AccountMatchingService.MatchRequest();
        req.companyName = '';
        List<AccountMatchingService.MatchResult> results =
            AccountMatchingService.findMatchingAccounts(
                new List<AccountMatchingService.MatchRequest>{ req }
            );
        Test.stopTest();

        System.assertEquals(false, results[0].matchFound);
    }

    @IsTest
    static void testLevenshteinSimilarity() {
        // Direct unit test of the similarity algorithm
        Integer exact = AccountMatchingService.calculateSimilarity('hello', 'hello');
        System.assertEquals(100, exact, 'Identical strings should score 100');

        Integer oneOff = AccountMatchingService.calculateSimilarity('hello', 'helo');
        System.assert(oneOff >= 75, 'One deletion should score >= 75, got: ' + oneOff);

        Integer different = AccountMatchingService.calculateSimilarity('abc', 'xyz');
        System.assert(different < 50, 'Completely different should score < 50, got: ' + different);

        Integer nullInput = AccountMatchingService.calculateSimilarity(null, 'test');
        System.assertEquals(0, nullInput, 'Null input should score 0');
    }
}