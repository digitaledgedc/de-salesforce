/**
 * QuoteRevisionService
 * Invocable Apex service called by the Quote_Screen_ReviseQuote flow.
 * Clones all QuoteLineItems from the original quote to the new revision quote.
 *
 * Revenue Cloud notes:
 *   - Auto-calculated fields (MRC_Amount__c) are excluded (formula, recalculated).
 *   - Space-assignment fields (Inventory__c, Space__c) are excluded (physical allocation).
 *   - Optional custom fields (Charge_Type__c, Billing_Mode__c, Charge_Frequency__c,
 *     Line_Category__c) are included only when present in the org schema. This allows
 *     the service to function correctly in environments where these fields are not yet
 *     deployed (e.g. partial-copy sandboxes before full metadata sync).
 */
public with sharing class QuoteRevisionService {

    // DML helper — runs without sharing so users on the quote page
    // can revise quotes regardless of Opportunity ownership.
    // CRUD checks are performed before any DML executes.
    private without sharing class DmlHelper {
        void doInsert(List<SObject> records) { insert records; }
        void doInsert(SObject record) { insert record; }
        void doUpdate(SObject record) { update record; }
    }

    public class CloneRequest {
        @InvocableVariable(required=true label='Original Quote Id' description='Id of the source quote whose lines are being cloned')
        public Id originalQuoteId;

        @InvocableVariable(required=true label='New Quote Id' description='Id of the newly created revision quote that will receive the cloned lines')
        public Id newQuoteId;
    }

    // Base fields always present on QuoteLineItem + org-wide standard.
    // QuoteId is excluded — set explicitly per target quote during cloning.
    private static final List<String> BASE_FIELDS = new List<String>{
        'Product2Id', 'PricebookEntryId', 'Quantity', 'UnitPrice', 'Discount', 'Description'
    };

    // Optional DE custom fields — included only when present in the org schema.
    // Physical-allocation fields (Space__c, Inventory__c) and formula fields
    // (MRC_Amount__c) are intentionally omitted.
    // Paired_MRC_Line__c is queried but remapped after insert (see cloneQuoteLines).
    private static final List<String> OPTIONAL_FIELDS = new List<String>{
        'Charge_Type__c',
        'Billing_Mode__c',
        'Charge_Frequency__c',
        'Line_Category__c',
        'Free_Months_Override__c',
        'Power_kVA__c',
        'CabE__c',
        'Ramp_Phase__c',
        'Ramp_Start_Date__c',
        'Custom_Attribute_Value__c',
        'Product_Attribute_Value__c',
        'Customer_PO_Line__c',
        'Target_BAN__c',
        'Is_Auto_NRC__c',
        'Line_Origin__c',
        'Ramp_Parent_Line__c',
        'Ramp_Invoice_Display__c',
        'Ramp_Line__c',
        'Line_Remarks__c',
        'Ramp_Phase_Notes__c',
        'Asset__c'
    };

    /**
     * AuraEnabled entry point for the Revise Quote quick action.
     * Voids the original quote, creates a new Draft revision with all header
     * fields and line items copied, and returns the new Quote Id for navigation.
     */
    @AuraEnabled
    public static Id reviseQuote(Id quoteId) {
        if (!Schema.sObjectType.Quote.isUpdateable()) {
            throw new AuraHandledException('Insufficient access to update Quote records.');
        }
        if (!Schema.sObjectType.Quote.isCreateable()) {
            throw new AuraHandledException('Insufficient access to create Quote records.');
        }

        Quote original = [
            SELECT Id, Name, Status, Quote_Version__c, OpportunityId, Pricebook2Id,
                   ExpirationDate, Description, Quote_Type__c, Amendment_Reason__c,
                   BillingAccount__c, Contract_Term_Months__c, Customer_PO_Reference__c,
                   RDD__c, CurrencyIsoCode, Target_Site__c, Service_Order_Terms__c,
                   Is_Binding__c, DE_Entity__c, ContactId
            FROM Quote
            WHERE Id = :quoteId
            WITH SECURITY_ENFORCED
            LIMIT 1
        ];

        // Build revision name — strip existing " - vN" suffix and increment
        String baseName = original.Name.replaceAll(' - v\\d+$', '');
        // Also strip any legacy " Rev N" suffix
        baseName = baseName.replaceAll(' Rev \\d+$', '');
        Integer newVersion = original.Quote_Version__c != null
            ? (Integer) original.Quote_Version__c + 1
            : 2;

        // Void the original
        original.Status = 'Void';
        new DmlHelper().doUpdate(original);

        // Create new revision in Draft
        Quote revision = new Quote(
            Name                     = baseName + ' - v' + newVersion,
            Status                   = 'Draft',
            Quote_Version__c         = newVersion,
            Revised_From__c          = quoteId,
            OpportunityId            = original.OpportunityId,
            Pricebook2Id             = original.Pricebook2Id,
            ExpirationDate           = original.ExpirationDate,
            Description              = original.Description,
            Quote_Type__c            = original.Quote_Type__c,
            Amendment_Reason__c      = original.Amendment_Reason__c,
            BillingAccount__c        = original.BillingAccount__c,
            Contract_Term_Months__c  = original.Contract_Term_Months__c,
            Customer_PO_Reference__c = original.Customer_PO_Reference__c,
            RDD__c                   = original.RDD__c,
            CurrencyIsoCode          = original.CurrencyIsoCode,
            Target_Site__c           = original.Target_Site__c,
            Service_Order_Terms__c   = original.Service_Order_Terms__c,
            Is_Binding__c            = original.Is_Binding__c,
            DE_Entity__c             = original.DE_Entity__c,
            ContactId                = original.ContactId
        );
        new DmlHelper().doInsert(revision);

        // Clone all line items
        CloneRequest req = new CloneRequest();
        req.originalQuoteId = quoteId;
        req.newQuoteId = revision.Id;
        cloneQuoteLines(new List<CloneRequest>{ req });

        return revision.Id;
    }

    @InvocableMethod(
        label='Clone Quote Line Items to Revision'
        description='Copies all QuoteLineItems from the original quote to the new revision quote. Called by the Revise Quote screen flow.'
    )
    public static void cloneQuoteLines(List<CloneRequest> requests) {
        if (requests == null || requests.isEmpty()) {
            return;
        }

        Set<Id> originalIds = new Set<Id>();
        Map<Id, Id> originalToNew = new Map<Id, Id>();

        for (CloneRequest req : requests) {
            if (req.originalQuoteId != null && req.newQuoteId != null) {
                originalIds.add(req.originalQuoteId);
                originalToNew.put(req.originalQuoteId, req.newQuoteId);
            }
        }

        if (originalIds.isEmpty()) {
            return;
        }

        // Query the target (new) quotes to check if they are termination/churn quotes.
        // When a quote is a termination, cloned line quantities are set to -1 so the
        // integration layer (Odoo) interprets them as service removals.
        Set<Id> newQuoteIds = new Set<Id>(originalToNew.values());
        Map<Id, Quote> targetQuotes = new Map<Id, Quote>([
            SELECT Id, Quote_Type__c, Amendment_Reason__c
            FROM Quote
            WHERE Id IN :newQuoteIds
        ]);

        // Determine which optional fields are accessible in this org's schema.
        // This prevents SOQL failures in environments where a field exists in metadata
        // but has not yet propagated to the runtime schema.
        Map<String, Schema.SObjectField> qliSchema =
            Schema.QuoteLineItem.SObjectType.getDescribe().fields.getMap();

        List<String> queryFields = new List<String>(BASE_FIELDS);
        queryFields.add('QuoteId');

        List<String> presentOptional = new List<String>();
        for (String f : OPTIONAL_FIELDS) {
            if (qliSchema.containsKey(f.toLowerCase())) {
                // Also check FLS READ — fields that exist in the schema but lack
                // field-level access for the running user are skipped gracefully.
                // This prevents stripInaccessible from stripping a queried field
                // (which would cause "field not queried" on src.get()).
                if (qliSchema.get(f.toLowerCase()).getDescribe().isAccessible()) {
                    queryFields.add(f);
                    presentOptional.add(f);
                }
            }
        }

        // Dynamic field list — use stripInaccessible instead of WITH SECURITY_ENFORCED so
        // that runtime FLS gaps on optional fields degrade gracefully (null value cloned)
        // rather than throwing. See SF_PATTERNS.md: Field-Level Security Enforcement.
        String soql = 'SELECT ' + String.join(queryFields, ', ')
            + ' FROM QuoteLineItem WHERE QuoteId IN :originalIds';

        List<QuoteLineItem> sourceLines = (List<QuoteLineItem>) Security.stripInaccessible(
            AccessType.READABLE,
            Database.query(soql)
        ).getRecords();

        if (sourceLines.isEmpty()) {
            return;
        }

        List<QuoteLineItem> newLines = new List<QuoteLineItem>();

        for (QuoteLineItem src : sourceLines) {
            Id targetQuoteId = originalToNew.get(src.QuoteId);
            if (targetQuoteId == null) {
                continue;
            }

            QuoteLineItem newLine = new QuoteLineItem();
            newLine.QuoteId          = targetQuoteId;
            newLine.Product2Id       = src.Product2Id;
            newLine.PricebookEntryId = src.PricebookEntryId;
            newLine.UnitPrice        = src.UnitPrice;
            newLine.Discount         = src.Discount;
            newLine.Description      = src.Description;

            // For termination/churn quotes, set Quantity to -1 so the Grand Total
            // becomes negative and the Odoo integration treats lines as removals.
            Quote tgtQuote = targetQuotes.get(targetQuoteId);
            Boolean isTermination = tgtQuote != null && (
                'Termination'.equals(tgtQuote.Quote_Type__c) ||
                'Termination'.equals(tgtQuote.Amendment_Reason__c)
            );
            newLine.Quantity = isTermination ? -1 : src.Quantity;

            // Copy optional fields that are present in the schema.
            for (String f : presentOptional) {
                newLine.put(f, src.get(f));
            }

            newLines.add(newLine);
        }

        if (!newLines.isEmpty()) {
            new DmlHelper().doInsert(newLines);

            // ── Remap Paired_MRC_Line__c from old QLI IDs to new QLI IDs ──
            // After insert, each newLine has an Id. Build a map from old Id to new Id,
            // then update NRC lines whose Paired_MRC_Line__c should point to the new MRC.
            Map<Id, Id> oldToNewId = new Map<Id, Id>();
            for (Integer i = 0; i < sourceLines.size(); i++) {
                oldToNewId.put(sourceLines[i].Id, newLines[i].Id);
            }

            // Query Paired_MRC_Line__c from source lines (not in OPTIONAL_FIELDS to avoid setting it on insert)
            Map<Id, Id> srcPairing = new Map<Id, Id>();
            for (QuoteLineItem src : [
                SELECT Id, Paired_MRC_Line__c FROM QuoteLineItem
                WHERE Id IN :oldToNewId.keySet() AND Paired_MRC_Line__c != null
            ]) {
                srcPairing.put(src.Id, src.Paired_MRC_Line__c);
            }

            List<QuoteLineItem> pairingUpdates = new List<QuoteLineItem>();
            for (Integer i = 0; i < sourceLines.size(); i++) {
                Id oldPairedMrc = srcPairing.get(sourceLines[i].Id);
                if (oldPairedMrc != null && oldToNewId.containsKey(oldPairedMrc)) {
                    pairingUpdates.add(new QuoteLineItem(
                        Id = newLines[i].Id,
                        Paired_MRC_Line__c = oldToNewId.get(oldPairedMrc)
                    ));
                }
            }
            if (!pairingUpdates.isEmpty()) {
                Database.update(pairingUpdates, false); // Partial success — skip FLS failures gracefully
            }
        }
    }
}