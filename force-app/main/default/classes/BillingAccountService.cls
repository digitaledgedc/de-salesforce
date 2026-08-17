/**
 * BillingAccountService
 *
 * Core business logic for BillingAccount__c.
 * Separated from the trigger handler so logic is reusable and testable in isolation.
 *
 * BAN Auto-Numbering
 * ------------------
 * Generates country-prefixed BAN numbers on before-insert using a BAN_Counter__c
 * row per country prefix locked with SELECT FOR UPDATE to guarantee sequential,
 * race-safe numbering across concurrent transactions.
 *
 * Format: {PREFIX}-{zero-padded-sequence}
 *   SG → SG-00001, SG-00002 …
 *   HK → HK-00001 …
 *   PH → PH-000001 (6-digit padding) …
 *
 * Prefix resolution is driven by the SUBSIDIARY (BillingAccount__c.DE_Entity__c):
 *   1. Optional override — a configured Entity_Fragment__c found within the
 *      subsidiary Account Name (preserves intentional mappings, e.g. CN → "Chuanjun").
 *   2. Primary — the subsidiary Account's Operation_Country__c, mapped to a country
 *      code. The BAN prefix follows the subsidiary country, NEVER the partner/customer
 *      account country.
 *   3. Unresolved — left for manual assignment rather than silently mis-prefixed.
 * BAN_Prefix_Config__mdt is loaded via getAll() (platform-cache read — zero SOQL cost).
 *
 * without sharing — BAN_Counter__c is an internal sequencing object. Counter
 * management must succeed regardless of the running user's CRUD/FLS on counters.
 * Authorization is enforced upstream: only users with BillingAccount__c create
 * access can trigger this code path.
 */
public without sharing class BillingAccountService {

    // ─── Custom exception ─────────────────────────────────────────────────────

    public class BillingAccountException extends Exception {}

    // ─── Generate BAN numbers (called from before-insert handler) ────────────

    /**
     * Assigns BAN_Number__c and Name to records that do not yet have a BAN number.
     * Skips records where BAN_Number__c is already populated (e.g. data migration).
     *
     * Safe to call with an empty list — no DML is issued unless BANs need numbering.
     */
    public static void generateBanNumbers(List<BillingAccount__c> newList) {

        // Filter to records that still need a BAN number
        List<BillingAccount__c> toNumber = new List<BillingAccount__c>();
        for (BillingAccount__c ban : newList) {
            if (String.isBlank(ban.BAN_Number__c)) {
                toNumber.add(ban);
            }
        }
        if (toNumber.isEmpty()) return;

        // Load prefix config from platform cache — no SOQL consumed
        Map<String, BAN_Prefix_Config__mdt> configByCode = new Map<String, BAN_Prefix_Config__mdt>();
        for (BAN_Prefix_Config__mdt cfg : BAN_Prefix_Config__mdt.getAll().values()) {
            if (String.isNotBlank(cfg.Country_Code__c)) {
                configByCode.put(cfg.Country_Code__c.toUpperCase(), cfg);
            }
        }

        // Collect DE_Entity__c (subsidiary) Ids for prefix resolution
        Set<Id> entityIds = new Set<Id>();
        for (BillingAccount__c ban : toNumber) {
            if (ban.DE_Entity__c != null) {
                entityIds.add(ban.DE_Entity__c);
            }
        }

        // Query DE_Entity (subsidiary) Accounts: Name drives the optional fragment
        // override; Operation_Country__c is the primary country source for the prefix.
        Map<Id, Account> entityAccounts = entityIds.isEmpty()
            ? new Map<Id, Account>()
            : new Map<Id, Account>([
                SELECT Id, Name, Operation_Country__c
                FROM Account WHERE Id IN :entityIds
              ]);

        // Resolve the country prefix for each BAN needing a number
        // Group by prefix so we make one counter read per prefix
        Map<String, List<BillingAccount__c>> bansByPrefix = new Map<String, List<BillingAccount__c>>();
        List<BillingAccount__c> unresolved = new List<BillingAccount__c>();

        for (BillingAccount__c ban : toNumber) {
            Account subsidiary = (ban.DE_Entity__c != null)
                ? entityAccounts.get(ban.DE_Entity__c)
                : null;

            // 1. Optional override: a configured fragment within the subsidiary name
            //    (preserves intentional mappings, e.g. CN → "Chuanjun").
            String prefix = resolvePrefix(subsidiary != null ? subsidiary.Name : null, configByCode);

            // 2. Primary: the subsidiary's own Operation_Country__c. The BAN prefix
            //    follows the SUBSIDIARY country, never the partner/customer account.
            if (prefix == null && subsidiary != null) {
                prefix = resolveByCountry(subsidiary.Operation_Country__c, configByCode);
            }

            // 3. Unresolved (no subsidiary, or country not mapped) — leave for manual
            //    assignment rather than silently stamping the wrong country.
            if (prefix == null) {
                unresolved.add(ban);
                continue;
            }
            if (!bansByPrefix.containsKey(prefix)) {
                bansByPrefix.put(prefix, new List<BillingAccount__c>());
            }
            bansByPrefix.get(prefix).add(ban);
        }

        // Leave unresolved records for manual assignment — do not block save
        // (Admins can populate BAN_Number__c manually before finalising)

        if (bansByPrefix.isEmpty()) return;

        // Process each prefix: insert-if-absent, then lock and increment
        for (String prefix : bansByPrefix.keySet()) {
            List<BillingAccount__c> bansForPrefix = bansByPrefix.get(prefix);
            Integer padding = getPadding(prefix, configByCode);
            Integer nextSeq = reserveSequenceBlock(prefix, bansForPrefix.size());

            for (BillingAccount__c ban : bansForPrefix) {
                String banNum = prefix + '-' + String.valueOf(nextSeq).leftPad(padding, '0');
                ban.BAN_Number__c = banNum;
                ban.Name          = banNum;
                nextSeq++;
            }
        }
    }

    // ─── Private helpers ──────────────────────────────────────────────────────

    /**
     * Returns the country prefix for a given DE Entity Account name.
     * Iterates through all CMT records and checks containsIgnoreCase on the
     * entity fragment. First match wins.
     */
    private static String resolvePrefix(
            String contractingEntity,
            Map<String, BAN_Prefix_Config__mdt> configByCode) {

        if (String.isBlank(contractingEntity)) return null;
        String entityLower = contractingEntity.toLowerCase();

        for (BAN_Prefix_Config__mdt cfg : configByCode.values()) {
            if (String.isNotBlank(cfg.Entity_Fragment__c) &&
                entityLower.contains(cfg.Entity_Fragment__c.toLowerCase())) {
                return cfg.Country_Code__c.toUpperCase();
            }
        }
        return null;
    }

    private static final Map<String, String> COUNTRY_TO_CODE = new Map<String, String>{
        'Singapore'   => 'SG',
        'South Korea' => 'KR',
        'Korea'       => 'KR',
        'Japan'       => 'JP',
        'Indonesia'   => 'ID',
        'Philippines' => 'PH',
        'India'       => 'IN',
        'China'       => 'CN',
        'Thailand'    => 'TH',
        'Malaysia'    => 'MY',
        'Hong Kong'   => 'HK'
    };

    private static String resolveByCountry(
            String operationCountry,
            Map<String, BAN_Prefix_Config__mdt> configByCode) {

        if (String.isBlank(operationCountry)) return null;
        String code = COUNTRY_TO_CODE.get(operationCountry);
        if (code != null && configByCode.containsKey(code)) {
            return code;
        }
        return code; // return code even without CMT — counter will use default padding
    }

    /**
     * Returns the sequence padding length configured for this prefix.
     * Defaults to 5 if not set.
     */
    private static Integer getPadding(
            String prefix,
            Map<String, BAN_Prefix_Config__mdt> configByCode) {

        BAN_Prefix_Config__mdt cfg = configByCode.get(prefix);
        if (cfg != null && cfg.Sequence_Padding__c != null) {
            return cfg.Sequence_Padding__c.intValue();
        }
        return 5;
    }

    /**
     * Ensures a BAN_Counter__c row exists for this prefix, then locks it with
     * FOR UPDATE and atomically reserves `count` sequence numbers.
     *
     * Returns the first number in the reserved block (caller increments up to
     * first + count - 1).
     */
    private static Integer reserveSequenceBlock(String prefix, Integer count) {

        // Query-first: check if a counter row already exists for this prefix.
        List<BAN_Counter__c> existing = [
            SELECT Id FROM BAN_Counter__c WHERE Name = :prefix LIMIT 1
        ];

        if (existing.isEmpty()) {
            // First time for this prefix — create the counter and fast-forward
            // past any BANs that were loaded historically.
            Integer maxExisting = 0;
            String likePatternDash = prefix + '-_____';   // e.g. ID-00001 (5 digits)
            String likePatternDash6 = prefix + '-______'; // e.g. JP-000001 (6 digits)
            String likePatternFlat = prefix + '_____';    // e.g. ID00001 (5 digits, legacy)
            String likePatternFlat6 = prefix + '______';  // e.g. JP000001 (6 digits, legacy)
            for (BillingAccount__c ban : [
                SELECT BAN_Number__c FROM BillingAccount__c
                WHERE BAN_Number__c != null
                AND (   BAN_Number__c LIKE :likePatternDash
                     OR BAN_Number__c LIKE :likePatternDash6
                     OR BAN_Number__c LIKE :likePatternFlat
                     OR BAN_Number__c LIKE :likePatternFlat6)
            ]) {
                String banNum = ban.BAN_Number__c;
                String remainder = banNum.substring(prefix.length());
                if (remainder.startsWith('-')) remainder = remainder.substring(1);
                if (remainder.isNumeric()) {
                    Integer seq = Integer.valueOf(remainder);
                    if (seq > maxExisting) maxExisting = seq;
                }
            }

            BAN_Counter__c seed = new BAN_Counter__c(
                Name             = prefix,
                Last_Sequence__c = maxExisting
            );
            insert seed;
        }

        // Lock the row for the duration of this transaction
        BAN_Counter__c locked = [
            SELECT Id, Last_Sequence__c
            FROM BAN_Counter__c
            WHERE Name = :prefix
            LIMIT 1
            FOR UPDATE
        ];

        Integer startAt = locked.Last_Sequence__c.intValue() + 1;
        locked.Last_Sequence__c = locked.Last_Sequence__c + count;
        update locked;

        return startAt;
    }
}