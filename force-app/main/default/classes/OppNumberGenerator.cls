/**
 * OppNumberGenerator — generates Opportunity_Number__c values for new Opportunities.
 *
 * Format: YY + zero-padded 4-digit sequence (e.g. 260156, 260157), restarting at
 * 0001 every calendar year (e.g. 269999 → 270001).
 *
 * Sequence logic (bulkified):
 *   1. Year rollover check: for any year AFTER the launch year (LAUNCH_YEAR_SUFFIX,
 *      currently '26'), if Opportunities have been numbered before but none yet
 *      carry the current year's prefix, this is the first number requested since
 *      the calendar rolled over — return 1 immediately, ignoring the Custom Label
 *      entirely (see isYearRollover below). The launch year itself is exempt: 2026
 *      always defers to the Custom Label floor below, even if it happens to be the
 *      first "26"-prefixed Opportunity in a given org (e.g. right after a sandbox
 *      refresh that carried over prior-year data but nothing yet this year).
 *   2. Otherwise, build the "floor" number from Custom Label OppNumber_StartingSequence:
 *      floor = YY + leftPad(label + 1, 4).  e.g. label=155 → floor="260156".
 *   3. Check if that floor number already exists on any Opportunity.
 *      - If NO  → start from the floor (label is the authoritative starting point).
 *      - If YES → find the current DB max and continue from there.
 *
 * This means:
 *   - Set label to 155 on a brand new org (no Opportunities numbered yet) → first
 *     Opp = 260156. This is a ONE-TIME starting point (e.g. continuing after an
 *     Odoo data import at go-live) — it is never used to reset the count within
 *     a year that already has numbered Opportunities.
 *   - Once 260156 is taken, subsequent Opps increment from the DB max automatically.
 *   - Changing the label to a higher value (e.g. 5000) resets the floor to 265001
 *     as long as 265001 has never been used (mid-year override).
 *   - When the calendar rolls to a new year, numbering restarts at 0001
 *     automatically — the label is not consulted for this, so a stale label
 *     value left over from a prior year can never leak into the new year.
 *
 * Design decisions:
 *   - without sharing: must read all Opps regardless of ownership.
 *   - Gaps OK: deletes leave gaps in the sequence.
 *   - Bulkified: a small, fixed number of SOQLs regardless of batch size; in-memory
 *     increment handles multiple Opps in one trigger batch.
 *
 * Called from OpportunityTriggerHandler.beforeInsert() (Phase 3, item 3.C1).
 */
public without sharing class OppNumberGenerator {

    public class OppNumberGeneratorException extends Exception {}

    private static final Integer SEQUENCE_DIGITS = 4;

    // The launch year — Custom Label always governs its starting point, regardless
    // of whether any records exist yet with that year's prefix. Only years AFTER
    // this one get the automatic year-rollover restart-to-1 behavior. Update this
    // if go-live slips to a different year.
    private static final String LAUNCH_YEAR_SUFFIX = '26';

    /**
     * Assigns Opportunity_Number__c to all Opportunities in the list that do not
     * already have a number. Safe to call in before-insert context.
     */
    public static void assignNumbers(List<Opportunity> opps) {
        if (opps == null || opps.isEmpty()) {
            return;
        }

        List<Opportunity> needsNumber = new List<Opportunity>();
        for (Opportunity opp : opps) {
            if (String.isBlank(opp.Opportunity_Number__c)) {
                needsNumber.add(opp);
            }
        }
        if (needsNumber.isEmpty()) {
            return;
        }

        String yearPrefix = String.valueOf(Date.today().year()).right(2);
        Integer nextSeq   = getNextSequence(yearPrefix);

        for (Opportunity opp : needsNumber) {
            opp.Opportunity_Number__c = yearPrefix + String.valueOf(nextSeq).leftPad(SEQUENCE_DIGITS, '0');
            nextSeq++;
        }
    }

    // ─── private helpers ────────────────────────────────────────────────────────

    private static Integer getNextSequence(String yearPrefix) {
        // ── Step 0: genuine year rollover — restart at 1, ignore the label ────────
        if (isYearRollover(yearPrefix)) {
            return 1;
        }

        // ── Step 1: derive floor from Custom Label ───────────────────────────────
        Integer floorSeq;
        try {
            floorSeq = Integer.valueOf(System.Label.OppNumber_StartingSequence) + 1;
        } catch (Exception e) {
            floorSeq = 1;
        }
        String floorNumber = yearPrefix + String.valueOf(floorSeq).leftPad(SEQUENCE_DIGITS, '0');

        // ── Step 2: check if floor number has ever been used ─────────────────────
        Integer floorCount = [
            SELECT COUNT() FROM Opportunity
            WHERE Opportunity_Number__c = :floorNumber
        ];

        if (floorCount == 0) {
            // Floor number not yet taken — start from here.
            return floorSeq;
        }

        // ── Step 3: floor is taken — find current DB max and continue ─────────────
        // Use '_' wildcards (exact length match) to skip old-format numbers with a
        // different digit width that would text-sort incorrectly against this year's.
        List<Opportunity> recent = [
            SELECT Opportunity_Number__c
            FROM Opportunity
            WHERE Opportunity_Number__c LIKE :buildYearMask(yearPrefix)
            ORDER BY Opportunity_Number__c DESC
            LIMIT 1
        ];

        if (recent.isEmpty()) {
            return floorSeq;
        }

        String lastNumber = recent[0].Opportunity_Number__c;
        String seqStr     = lastNumber.substring(yearPrefix.length());
        try {
            return Integer.valueOf(seqStr) + 1;
        } catch (TypeException e) {
            return floorSeq;
        }
    }

    /**
     * True when Opportunities have been numbered before (any year) but none yet
     * carry the current year's prefix — i.e. this is the first number requested
     * since the calendar rolled over, not a fresh org's very first number ever.
     * A fresh org (no numbered Opportunities at all) returns false so the Custom
     * Label can still set its documented one-time starting point.
     *
     * The launch year (LAUNCH_YEAR_SUFFIX) is always exempt: it must defer to the
     * Custom Label floor / DB-max logic regardless of whether any "26"-prefixed
     * Opportunity exists yet, since 2026 is the one-time cutover year, not a
     * rollover from a prior year of this same numbering scheme.
     */
    @TestVisible
    private static Boolean isYearRollover(String yearPrefix) {
        if (yearPrefix == LAUNCH_YEAR_SUFFIX) {
            return false;
        }

        Integer everNumberedCount = [
            SELECT COUNT() FROM Opportunity WHERE Opportunity_Number__c != null
        ];
        if (everNumberedCount == 0) {
            return false;
        }

        Integer thisYearCount = [
            SELECT COUNT() FROM Opportunity
            WHERE Opportunity_Number__c LIKE :buildYearMask(yearPrefix)
        ];
        return thisYearCount == 0;
    }

    /** Exact-length LIKE mask for the given year prefix, e.g. "26" -> "26____". */
    private static String buildYearMask(String yearPrefix) {
        String seqMask = '';
        for (Integer i = 0; i < SEQUENCE_DIGITS; i++) {
            seqMask += '_';
        }
        return yearPrefix + seqMask;
    }
}