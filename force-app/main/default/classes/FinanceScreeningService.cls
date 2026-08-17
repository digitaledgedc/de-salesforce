/**
 * FinanceScreeningService
 * Invocable Apex for the Finance Approval flow.
 * Searches OpenCorporates (opencorporates.com) to verify the company is registered
 * in its primary market jurisdiction.
 *
 * Free — no API key, no account, no setup required.
 * Covers all Digital Edge APAC markets: HK, SG, JP, IN, ID, PH, KR and 130+ others.
 *
 * Called from Account_Screen_FinanceApproval flow before the D&B Review screen.
 */
public with sharing class FinanceScreeningService {

    // ISO country code → OpenCorporates jurisdiction code
    // Most are identical lowercase. Explicit map handles any edge cases.
    @TestVisible
    static final Map<String, String> JURISDICTION_MAP = new Map<String, String>{
        'HK' => 'hk',
        'SG' => 'sg',
        'JP' => 'jp',
        'IN' => 'in',
        'ID' => 'id',
        'PH' => 'ph',
        'KR' => 'kr',
        'AU' => 'au',
        'MY' => 'my',
        'VN' => 'vn',
        'TW' => 'tw',
        'CN' => 'cn',
        'TH' => 'th',
        'NZ' => 'nz'
    };

    // ─── Input / Output ───────────────────────────────────────────────────────

    public class ScreeningRequest {
        @InvocableVariable(label='Account Name' required=true)
        public String accountName;

        @InvocableVariable(label='Primary Market Country (ISO code, e.g. HK)')
        public String countryCode;
    }

    public class ScreeningResult {
        @InvocableVariable(label='Company Status')
        public String companyStatus;        // Active | Dissolved | NOT_FOUND | UNAVAILABLE

        @InvocableVariable(label='Registered Company Name')
        public String registeredName;

        @InvocableVariable(label='Company Number')
        public String companyNumber;

        @InvocableVariable(label='Incorporation Date')
        public String incorporationDate;

        @InvocableVariable(label='Jurisdiction')
        public String jurisdiction;

        @InvocableVariable(label='Screening Summary')
        public String screeningSummary;
    }

    // ─── Entry point ──────────────────────────────────────────────────────────

    @InvocableMethod(
        label='Run Company Registry Screening'
        description='Searches OpenCorporates to verify the company is registered in its primary market. Free, no API key required. Covers HK, SG, JP, IN, ID, PH, KR and 130+ jurisdictions.'
        callout=true
    )
    public static List<ScreeningResult> runScreening(List<ScreeningRequest> requests) {
        List<ScreeningResult> results = new List<ScreeningResult>();
        for (ScreeningRequest req : requests) {
            results.add(screenCompany(req.accountName, req.countryCode));
        }
        return results;
    }

    // ─── OpenCorporates search ────────────────────────────────────────────────

    @TestVisible
    static ScreeningResult screenCompany(String companyName, String countryCode) {
        ScreeningResult result = new ScreeningResult();

        String jurisdictionCode = resolveJurisdiction(countryCode);

        try {
            String encoded = EncodingUtil.urlEncode(companyName, 'UTF-8');
            String endpoint = System.Label.DE_OpenCorporates_Base_URL + encoded
                + '&per_page=5'
                + (String.isNotBlank(jurisdictionCode) ? '&jurisdiction_code=' + jurisdictionCode : '');

            HttpRequest req = new HttpRequest();
            req.setEndpoint(endpoint);
            req.setMethod('GET');
            req.setHeader('Accept', 'application/json');
            req.setTimeout(10000);

            HttpResponse res = new Http().send(req);

            if (res.getStatusCode() == 200) {
                parseResponse(res.getBody(), companyName, result);
            } else if (res.getStatusCode() == 503 || res.getStatusCode() == 429) {
                result.companyStatus  = 'UNAVAILABLE';
                result.screeningSummary = 'Company registry unavailable — proceed with standard D&B check.';
            } else {
                result.companyStatus  = 'UNAVAILABLE';
                result.screeningSummary = 'Company registry returned error ' + res.getStatusCode() + ' — proceed with standard D&B check.';
            }
        } catch (Exception e) {
            result.companyStatus    = 'UNAVAILABLE';
            result.screeningSummary = 'Company registry check failed — proceed with standard D&B check.';
        }

        return result;
    }

    // ─── Response parsing ─────────────────────────────────────────────────────

    @TestVisible
    static void parseResponse(String body, String searchName, ScreeningResult result) {
        Map<String, Object> root    = (Map<String, Object>) JSON.deserializeUntyped(body);
        Map<String, Object> results = (Map<String, Object>) root.get('results');
        List<Object>        cos     = (List<Object>) results.get('companies');

        if (cos == null || cos.isEmpty()) {
            result.companyStatus    = 'NOT_FOUND';
            result.screeningSummary = 'No company registration found for "' + searchName + '". '
                + 'Verify company name matches registered name before proceeding.';
            return;
        }

        // Use first result — highest relevance match
        Map<String, Object> wrapper = (Map<String, Object>) cos[0];
        Map<String, Object> co      = (Map<String, Object>) wrapper.get('company');

        result.registeredName    = (String)  co.get('name');
        result.companyNumber     = (String)  co.get('company_number');
        result.incorporationDate = (String)  co.get('incorporation_date');
        result.jurisdiction      = (String)  co.get('jurisdiction_code');

        Boolean inactive = co.get('inactive') != null ? (Boolean) co.get('inactive') : false;
        String  status   = co.get('current_status') != null ? (String) co.get('current_status') : (inactive ? 'Inactive' : 'Unknown');

        result.companyStatus = inactive ? 'Dissolved' : 'Active';
        result.screeningSummary = buildSummary(result, status);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    @TestVisible
    static String resolveJurisdiction(String countryCode) {
        if (String.isBlank(countryCode)) return null;
        String upper = countryCode.toUpperCase().trim();
        return JURISDICTION_MAP.containsKey(upper) ? JURISDICTION_MAP.get(upper) : countryCode.toLowerCase().trim();
    }

    private static String buildSummary(ScreeningResult r, String rawStatus) {
        if (r.companyStatus == 'Active') {
            return 'Registry: Active — ' + r.registeredName
                + ' (' + r.jurisdiction.toUpperCase() + ')'
                + (String.isNotBlank(r.companyNumber)     ? ' | Reg: ' + r.companyNumber     : '')
                + (String.isNotBlank(r.incorporationDate) ? ' | Inc: ' + r.incorporationDate  : '');
        }
        if (r.companyStatus == 'Dissolved') {
            return 'Registry: WARNING — ' + r.registeredName + ' is listed as DISSOLVED/INACTIVE (' + rawStatus + '). '
                + 'Do not proceed without compliance sign-off.';
        }
        return 'Registry status unknown (' + rawStatus + ') — verify manually before proceeding.';
    }
}