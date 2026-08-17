/**
 * AccountMatchingService
 *
 * LEAD-005: Fuzzy account matching for Lead conversion.
 * Uses SOSL to find candidate Accounts, then scores results using
 * normalized Levenshtein distance. Returns matches scoring >= threshold.
 *
 * Called from Lead_Screen_ConvertLead flow via @InvocableMethod.
 */
public with sharing class AccountMatchingService {

    private static final Integer DEFAULT_THRESHOLD = 80;
    private static final Integer MAX_RESULTS = 5;

    // ── Invocable entry point ────────────────────────────────────────────────

    public class MatchRequest {
        @InvocableVariable(required=true label='Company Name')
        public String companyName;

        @InvocableVariable(label='Operation Country')
        public String operationCountry;

        @InvocableVariable(label='Match Threshold (default 80)')
        public Integer threshold;
    }

    public class MatchResult {
        @InvocableVariable(label='Best Match Account Id')
        public Id accountId;

        @InvocableVariable(label='Best Match Account Name')
        public String accountName;

        @InvocableVariable(label='Best Match Score (0-100)')
        public Integer matchScore;

        @InvocableVariable(label='Match Found')
        public Boolean matchFound;

        @InvocableVariable(label='Match Country')
        public String matchCountry;
    }

    @InvocableMethod(label='Find Matching Account (Fuzzy)' description='SOSL fuzzy search for existing Account by company name + optional country filter.')
    public static List<MatchResult> findMatchingAccounts(List<MatchRequest> requests) {
        List<MatchResult> results = new List<MatchResult>();
        for (MatchRequest req : requests) {
            results.add(findBestMatch(req));
        }
        return results;
    }

    // ── Core matching logic ──────────────────────────────────────────────────

    private static MatchResult findBestMatch(MatchRequest req) {
        MatchResult result = new MatchResult();
        result.matchFound = false;
        result.matchScore = 0;

        if (String.isBlank(req.companyName)) {
            return result;
        }

        Integer threshold = (req.threshold != null && req.threshold > 0)
            ? req.threshold : DEFAULT_THRESHOLD;

        // SOSL search — inherently fuzzy, handles partial matches
        String searchTerm = String.escapeSingleQuotes(req.companyName.trim());
        if (searchTerm.length() < 2) {  return result;
        }

        List<List<SObject>> soslResults;
        if (String.isNotBlank(req.operationCountry)) {
            soslResults = [ FIND :searchTerm IN NAME FIELDS RETURNING Account( Id, Name, Operation_Country__c, Status__c WHERE Operation_Country__c = :req.operationCountry ORDER BY Name  LIMIT 20 ) ];
        } else {
            soslResults = [
                FIND :searchTerm IN NAME FIELDS
                RETURNING Account(
                    Id, Name, Operation_Country__c, Status__c
                    ORDER BY Name
                    LIMIT 20
                )
            ];
        }

        List<Account> candidates = (List<Account>) soslResults[0];

        // If SOSL returned nothing with country filter, try without
        if (candidates.isEmpty() && String.isNotBlank(req.operationCountry)) {
            soslResults = [  FIND :searchTerm IN NAME FIELDS  RETURNING Account( Id, Name, Operation_Country__c, Status__c ORDER BY Name LIMIT 20 ) ]; candidates = (List<Account>) soslResults[0];
        }

        if (candidates.isEmpty()) {
            return result;
        }

        // Score each candidate with normalized Levenshtein similarity
        String target = req.companyName.trim().toLowerCase();
        Id bestId = null;
        String bestName = null;
        String bestCountry = null;
        Integer bestScore = 0;

        for (Account acct : candidates) {
            String candidateName = acct.Name.toLowerCase();
            Integer score = calculateSimilarity(target, candidateName);

            // Boost score by 5 if country matches
            if (String.isNotBlank(req.operationCountry)  && req.operationCountry.equals(acct.Operation_Country__c)) {  score = Math.min(100, score + 5); }

            if (score > bestScore) {
                bestScore = score;
                bestId = acct.Id;
                bestName = acct.Name;
                bestCountry = acct.Operation_Country__c;
            }
        }

        if (bestScore >= threshold) {
            result.matchFound = true;
            result.accountId = bestId;
            result.accountName = bestName;
            result.matchScore = bestScore;
            result.matchCountry = bestCountry;
        }

        return result;
    }

    // ── String similarity (Levenshtein) ──────────────────────────────────────

    /**
     * Returns similarity score 0-100 between two strings.
     * Uses normalized Levenshtein distance:
     *   score = round((1 - editDistance / maxLength) * 100)
     */
    @TestVisible
    private static Integer calculateSimilarity(String s1, String s2) {
        if (s1 == null || s2 == null) return 0;
        if (s1.equals(s2)) return 100;

        Integer len1 = s1.length();
        Integer len2 = s2.length();

        if (len1 == 0 || len2 == 0) return 0;

        // Levenshtein distance via dynamic programming (two-row optimization)
        List<Integer> prevRow = new List<Integer>();
        List<Integer> currRow = new List<Integer>();

        for (Integer j = 0; j <= len2; j++) {
            prevRow.add(j);
            currRow.add(0);
        }

        for (Integer i = 1; i <= len1; i++) {
            currRow[0] = i;
            for (Integer j = 1; j <= len2; j++) {
                Integer cost = s1.substring(i - 1, i).equals(s2.substring(j - 1, j)) ? 0 : 1;
                currRow[j] = Math.min(
                    Math.min(currRow[j - 1] + 1, prevRow[j] + 1),
                    prevRow[j - 1] + cost
                );
            }
            // Swap rows
            List<Integer> temp = prevRow;
            prevRow = currRow;
            currRow = temp;
        }

        Integer distance = prevRow[len2];
        Integer maxLen = Math.max(len1, len2);
        Decimal similarity = (1.0 - (Decimal.valueOf(distance) / Decimal.valueOf(maxLen))) * 100;
        return similarity.intValue();
    }
}