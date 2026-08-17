/**
 * NrcPairingService
 *
 * When a Cabinet or other DC product QuoteLineItem with a recurring charge
 * (.RC) product code is added to a Quote, automatically creates the paired
 * non-recurring installation charge (.NR) QuoteLineItem if one does not
 * already exist on the Quote.
 *
 * Pairing rule:
 *   Strip ".RC" from ProductCode, append ".NR" → NRC product code
 *   e.g. CAB001.RC → CAB001.NR
 *
 * Called from the QuoteLineItem_AfterSave_PairNrcProduct flow on QLI create.
 * Runs async (AsyncAfterCommit) to keep the MRC insert transaction clean.
 *
 * Bypass: TriggerBypass__mdt record with DeveloperName = 'NrcPairingService'
 * and Is_Active__c = true suppresses all pairing.
 */
public with sharing class NrcPairingService {

    // DML helper — without sharing to bypass Revenue Cloud quote edit restrictions
    // when inserting NRC QLIs (QLI insert triggers implicit Quote total recalc).
    private without sharing class DmlHelper {
        void doInsert(List<SObject> records) { insert records; }
        void doUpdate(List<SObject> records) { update records; } void doDelete(List<SObject> records) { delete records; }
    }

    /**
     * Invocable entry point — called from the QuoteLineItem after-save flow.
     *
     * @param qliIds  List of QuoteLineItem record IDs to process
     */
    @InvocableMethod(
        label='Pair NRC Installation Charge to MRC QLI'
        description='For each .RC QuoteLineItem added to a Quote, inserts the matching .NR installation charge if not already present.'
        category='Quote'
    )
    public static void pairNrcProducts(List<Id> qliIds) {
        TriggerBypass__mdt bypass = TriggerBypass__mdt.getInstance('NrcPairingService');
        if (bypass != null && bypass.Is_Active__c) {   return;  }
        pairNrcToMrc(new Set<Id>(qliIds));
    }

    /**
     * Core pairing logic. For each .RC QLI in the input set, creates the
     * matching .NR QLI if it does not already exist on the same Quote.
     *
     * @param qliIdSet  Set of QuoteLineItem IDs to evaluate
     */
    public static void pairNrcToMrc(Set<Id> qliIdSet) {
        if (qliIdSet == null || qliIdSet.isEmpty()) {
            return;
        }

        // Load MRC QLIs — only .RC products with a Quote and pricebook
        List<QuoteLineItem> mrcQlis = (List<QuoteLineItem>) Security.stripInaccessible(
            AccessType.READABLE,
            [SELECT Id, QuoteId, Product2Id, Product2.ProductCode,
                    Product2.Paired_NRC_Product__c,
                    Product2.Paired_NRC_Product__r.ProductCode,
                    Quote.Pricebook2Id, Quote.CurrencyIsoCode
             FROM QuoteLineItem
             WHERE Id IN :qliIdSet
             AND Change_Type__c = null
               AND (Product2.ProductCode LIKE '%.RC'
                    OR Product2.Paired_NRC_Product__c != null)
               AND Quote.Pricebook2Id != null]
        ).getRecords();

        if (mrcQlis.isEmpty()) {
            return;
        }

        // Collect NRC codes and quote/pricebook context
        Set<Id> quoteIds = new Set<Id>();
        Set<String> allNrcCodes = new Set<String>();
        Set<Id> pricebookIds = new Set<Id>();
        Set<String> quoteCurrencies = new Set<String>();

        for (QuoteLineItem qli : mrcQlis) {
            // Prefer explicit Paired_NRC_Product lookup; fall back to code-based derivation
            String nrcCode = qli.Product2.Paired_NRC_Product__c != null ? qli.Product2.Paired_NRC_Product__r.ProductCode : buildNrcCode(qli.Product2.ProductCode);
            if (String.isBlank(nrcCode)) continue;
            allNrcCodes.add(nrcCode);
            quoteIds.add(qli.QuoteId);
            pricebookIds.add(qli.Quote.Pricebook2Id);
            if (String.isNotBlank(qli.Quote.CurrencyIsoCode)) {
                quoteCurrencies.add(qli.Quote.CurrencyIsoCode);
            }
        }

        if (allNrcCodes.isEmpty()) { return; }

        // Existing NRC QLIs on these quotes — keyed quoteId + '_' + productCode
        Set<String> existingNrcKeys = new Set<String>();
        List<QuoteLineItem> existingNrcList = (List<QuoteLineItem>) Security.stripInaccessible(
            AccessType.READABLE,
            [SELECT QuoteId, Product2.ProductCode
             FROM QuoteLineItem
             WHERE QuoteId IN :quoteIds
               AND Product2.ProductCode IN :allNrcCodes]
        ).getRecords();
        for (QuoteLineItem existing : existingNrcList) {
            existingNrcKeys.add(existing.QuoteId + '_' + existing.Product2.ProductCode);
        }

        // PricebookEntries for NRC products — keyed pricebook2Id + '_' + productCode + '_' + currency
        // Currency filter prevents selecting wrong-currency PBEs in multi-currency orgs
        Map<String, PricebookEntry> pbeByKey = new Map<String, PricebookEntry>();
        List<PricebookEntry> nrcPbes = (List<PricebookEntry>) Security.stripInaccessible(
            AccessType.READABLE,
            [SELECT Id, Product2Id, Product2.ProductCode, Pricebook2Id, UnitPrice, CurrencyIsoCode,
                    Product2.Charge_Frequency__c, Product2.Billing_Charge_Type__c,
                    Product2.Odoo_Product_Id__c
             FROM PricebookEntry
             WHERE Pricebook2Id IN :pricebookIds
               AND Product2.ProductCode IN :allNrcCodes
               AND IsActive = true
               AND CurrencyIsoCode IN :quoteCurrencies]
        ).getRecords();
        for (PricebookEntry pbe : nrcPbes) {
            pbeByKey.put(pbe.Pricebook2Id + '_' + pbe.Product2.ProductCode + '_' + pbe.CurrencyIsoCode, pbe);
        }

        // Build NRC QLIs to insert
        List<QuoteLineItem> nrcToInsert = new List<QuoteLineItem>();

        for (QuoteLineItem qli : mrcQlis) {
            String nrcCode = qli.Product2.Paired_NRC_Product__c != null ? qli.Product2.Paired_NRC_Product__r.ProductCode : buildNrcCode(qli.Product2.ProductCode);
            if (String.isBlank(nrcCode)) continue;

            String existKey = qli.QuoteId + '_' + nrcCode;
            if (existingNrcKeys.contains(existKey)) continue; // already paired

            PricebookEntry pbe = pbeByKey.get(qli.Quote.Pricebook2Id + '_' + nrcCode + '_' + qli.Quote.CurrencyIsoCode);
            if (pbe == null) continue; // no NRC product in this pricebook — skip silently

            QuoteLineItem nrcQli = new QuoteLineItem(
                QuoteId            = qli.QuoteId,
                Product2Id         = pbe.Product2Id,
                PricebookEntryId   = pbe.Id,
                Quantity           = 1,
                UnitPrice          = pbe.UnitPrice,
                List_Price__c      = pbe.UnitPrice,
                Paired_MRC_Line__c = qli.Id,
                Is_Auto_NRC__c     = true,
                Charge_Type__c     = 'NRC',
                Reserved__c        = 'N/A'
            );
            // Copy product-level fields to NRC QLI
            if (String.isNotBlank(pbe.Product2.Charge_Frequency__c)) {  nrcQli.Charge_Frequency__c = pbe.Product2.Charge_Frequency__c;
            }
            if (String.isNotBlank(pbe.Product2.Billing_Charge_Type__c)) {
                String bct = pbe.Product2.Billing_Charge_Type__c.toLowerCase();
                nrcQli.Billing_Mode__c = bct.substring(0, 1).toUpperCase() + bct.substring(1);
            }
            if (pbe.Product2.Odoo_Product_Id__c != null) { nrcQli.Odoo_Product_ID__c = pbe.Product2.Odoo_Product_Id__c;
            }
            nrcToInsert.add(nrcQli);
            existingNrcKeys.add(existKey); // prevent double-insert within the same batch
        }

        if (!nrcToInsert.isEmpty()) {
            new DmlHelper().doInsert(nrcToInsert);
        }
    }

    /**
     * Cascade-deletes auto-generated NRC lines whose paired MRC line is being
     * removed. Called from QuoteLineItemTriggerHandler.beforeDelete to prevent
     * orphaned NRC lines remaining on the Quote after MRC removal.
     *
     * Clears Paired_MRC_Line__c before deleting so VR-QLI-01 (which blocks
     * deletion of paired auto-NRC lines) does not block the cascade.
     *
     * @param mrcLineIds  Set of MRC QuoteLineItem IDs being deleted
     */
    public static void cascadeDeletePairedNrc(Set<Id> mrcLineIds) {
        if (mrcLineIds == null || mrcLineIds.isEmpty()) return;

        List<QuoteLineItem> pairedNrcLines = (List<QuoteLineItem>) Security.stripInaccessible(
            AccessType.READABLE,
            [SELECT Id, Paired_MRC_Line__c FROM QuoteLineItem WHERE Paired_MRC_Line__c IN :mrcLineIds AND Is_Auto_NRC__c = true]).getRecords();

        if (pairedNrcLines.isEmpty()) return;

        // Clear pair reference so VR-QLI-01 re-entry does not block
        for (QuoteLineItem nrc : pairedNrcLines) { nrc.Paired_MRC_Line__c = null;
        }
        new DmlHelper().doUpdate(Security.stripInaccessible(AccessType.UPDATABLE, pairedNrcLines).getRecords()); new DmlHelper().doDelete(pairedNrcLines);
    }

    /**
     * Converts a .RC product code to its .NR counterpart.
     * Returns null if the code does not end with .RC.
     *
     * Handles site-specific variant codes (e.g. CTC-only products) where a
     * single-letter suffix is appended to the base code before .RC
     * (e.g. CAB001C.RC → CAB001.NR, not CAB001C.NR which does not exist).
     * The variant letter is stripped when it immediately follows a digit.
     */
    @TestVisible
    private static String buildNrcCode(String productCode) {
        if (String.isBlank(productCode)) return null;
        if (!productCode.endsWith('.RC')) return null;
        String base = productCode.removeEnd('.RC');
        // Strip single-letter variant suffix preceded by a digit (e.g. CAB001C → CAB001)
        if (Pattern.matches('.*\\d[A-Z]$', base)) { base = base.left(base.length() - 1);
        }
        return base + '.NR';
    }
}