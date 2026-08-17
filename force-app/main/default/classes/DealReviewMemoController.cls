public with sharing class DealReviewMemoController {

    /**
     * Resolves an Opportunity ID from either an Opportunity ID or a Quote ID.
     * Allows the Deal Review Memo LWC to be launched from both the
     * Opportunity page and the Quote page via quick actions.
     */
    private static Id resolveOppId(Id recordId) {
        if (recordId == null) return null;
        // Quote key prefix is 0Q0
        if (String.valueOf(recordId).startsWith('0Q0')) {
            List<Quote> quotes = [SELECT OpportunityId FROM Quote WHERE Id = :recordId LIMIT 1];
            if (quotes.isEmpty() || quotes[0].OpportunityId == null) {
                throw new AuraHandledException('Could not find the linked Opportunity for this Quote.');
            }
            return quotes[0].OpportunityId;
        }
        return recordId;
    }

    @AuraEnabled
    public static MemoData getMemoData(Id oppId) {
        oppId = resolveOppId(oppId);
        List<Opportunity> opps = [
            SELECT Id, Name, CurrencyIsoCode, StageName, OwnerId, Owner.Name,
                   AccountId, Account.Name, Account.Status__c, Account.Operation_Country__c,
                   Account.KYC_Status__c, Account.Credit_Block__c,
                   Account.Legal_Entity_Name__c, Account.Customer_ID__c,
                   Operation_Country__c, Target_Site__c, Target_Site__r.Name,
                   Customer_Type__c, DE_Entity__c, DE_Entity__r.Name,
                   Power_kW__c, Power_Density__c, Cabinets_Required__c,
                   Capacity_kW__c, Target_Data_Hall__c, Target_Data_Hall__r.Name, Target_Floor__c, Target_Floor__r.Name,
                   Product_Interest__c, GoLive_Target_Date__c,
                   Contract_Term_Months__c, Renewal_Type__c, Free_Months__c,
                   Is_Ramp_Deal__c, Ramp_Phases__c,
                   MRC__c, Total_Deal_MRC__c, NRC__c, NRC_Budget_Approved__c, NRC_Actual_Cost__c,
                   Quote_MRC__c, Quote_NRC__c,
                   API__c, PUE__c, Metered_Power_Charges__c, Reservation_ROFR_kW__c,
                   Description,
                   DR_Required__c, DR_Status__c, DR_Requested_Date__c,
                   DR_Approved_Date__c, DR_Notes__c,
                   DR_Market_Benchmark__c, DR_Pricing_Justification__c,
                   DR_NRC_Scope__c, DR_NRC_Justification__c, DR_Other_Considerations__c,
                   FX_Billing_Flag__c, FX_Rate_Model__c
            FROM Opportunity
            WHERE Id = :oppId
            LIMIT 1
        ];

        if (opps.isEmpty()) {
            throw new AuraHandledException('Opportunity not found or you do not have access.');
        }
        // Keep the raw Opportunity for system operations (getMissingFields)
        // before stripping inaccessible fields for the LWC return value.
        Opportunity rawOpp = opps[0];
        Opportunity opp = (Opportunity) Security.stripInaccessible(
            AccessType.READABLE, opps
        ).getRecords()[0];

        MemoData data = new MemoData();
        data.opp = opp;

        List<Quote> activeQuotes = [
            SELECT Id, Name, QuoteNumber, Status
            FROM Quote
            WHERE OpportunityId = :oppId
              AND Status IN ('Draft', 'In Review', 'Approved')
            ORDER BY LastModifiedDate DESC
        ];
        data.availableQuotes = new List<QuoteOption>();
        for (Quote q : activeQuotes) {
            data.availableQuotes.add(new QuoteOption(q.Id, q.Name, q.QuoteNumber, q.Status));
        }

        data.missingFields = getMissingFields(rawOpp);
        return data;
    }

    @AuraEnabled
    public static Id generateMemo(Id oppId) {
        oppId = resolveOppId(oppId);
        List<Opportunity> opps = [
            SELECT Id, Name, CurrencyIsoCode, StageName, Owner.Name,
                   AccountId, Account.Name, Account.Status__c, Account.Operation_Country__c,
                   Account.KYC_Status__c, Account.Credit_Block__c,
                   Account.Legal_Entity_Name__c,
                   Operation_Country__c, Target_Site__c, Target_Site__r.Name,
                   Customer_Type__c, DE_Entity__c, DE_Entity__r.Name,
                   Power_kW__c, Power_Density__c, Cabinets_Required__c,
                   Capacity_kW__c, Target_Data_Hall__c, Target_Data_Hall__r.Name, Target_Floor__c, Target_Floor__r.Name,
                   Product_Interest__c, GoLive_Target_Date__c,
                   Contract_Term_Months__c, Renewal_Type__c, Free_Months__c,
                   Is_Ramp_Deal__c, Ramp_Phases__c,
                   MRC__c, Total_Deal_MRC__c, NRC__c, NRC_Budget_Approved__c, NRC_Actual_Cost__c,
                   Quote_MRC__c, Quote_NRC__c,
                   API__c, PUE__c, Metered_Power_Charges__c, Reservation_ROFR_kW__c,
                   Description,
                   DR_Required__c, DR_Status__c, DR_Requested_Date__c, DR_Notes__c,
                   DR_Market_Benchmark__c, DR_Pricing_Justification__c,
                   DR_NRC_Scope__c, DR_NRC_Justification__c, DR_Other_Considerations__c,
                   FX_Billing_Flag__c, FX_Rate_Model__c
            FROM Opportunity
            WHERE Id = :oppId
            LIMIT 1
        ];

        if (opps.isEmpty()) {
            throw new AuraHandledException('Opportunity not found or you do not have access.');
        }
        Opportunity opp = opps[0];

        PageReference pdfPage = Page.DealReviewMemoPDF;
        pdfPage.getParameters().put('id', oppId);
        Blob pdfBlob;
        if (Test.isRunningTest()) {
            pdfBlob = Blob.valueOf('Test PDF');
        } else {
            pdfBlob = pdfPage.getContentAsPDF();
        }

        String fileName = 'Deal Review Memo - ' + opp.Name + ' - ' + Date.today().format() + '.pdf';

        ContentVersion cv = new ContentVersion();
        cv.Title = fileName;
        cv.PathOnClient = fileName;
        cv.VersionData = pdfBlob;
        cv.FirstPublishLocationId = oppId;
        insert cv;

        if (opp.DR_Status__c != 'Approved') {
            opp.DR_Status__c = 'DR Required';
            opp.DR_Required__c = true;
            if (opp.DR_Requested_Date__c == null) {
                opp.DR_Requested_Date__c = Date.today();
            }
            update opp;
        }

        return cv.Id;
    }

    @AuraEnabled
    public static void saveDraftFields(Id oppId, String fieldsJson) {
        oppId = resolveOppId(oppId);
        Map<String, Object> fields = (Map<String, Object>) JSON.deserializeUntyped(fieldsJson);
        Opportunity opp = new Opportunity(Id = oppId);

        if (fields.containsKey('DR_Notes__c')) {
            opp.DR_Notes__c = (String) fields.get('DR_Notes__c');
        }
        if (fields.containsKey('DR_Market_Benchmark__c')) {
            opp.DR_Market_Benchmark__c = (String) fields.get('DR_Market_Benchmark__c');
        }
        if (fields.containsKey('DR_Pricing_Justification__c')) {
            opp.DR_Pricing_Justification__c = (String) fields.get('DR_Pricing_Justification__c');
        }
        if (fields.containsKey('DR_NRC_Scope__c')) {
            opp.DR_NRC_Scope__c = (String) fields.get('DR_NRC_Scope__c');
        }
        if (fields.containsKey('DR_NRC_Justification__c')) {
            opp.DR_NRC_Justification__c = (String) fields.get('DR_NRC_Justification__c');
        }
        if (fields.containsKey('DR_Other_Considerations__c')) {
            opp.DR_Other_Considerations__c = (String) fields.get('DR_Other_Considerations__c');
        }
        if (fields.containsKey('API__c')) {
            opp.API__c = (String) fields.get('API__c');
        }
        if (fields.containsKey('PUE__c') && fields.get('PUE__c') != null) {
            opp.PUE__c = Decimal.valueOf(String.valueOf(fields.get('PUE__c')));
        }
        if (fields.containsKey('Metered_Power_Charges__c')) {
            opp.Metered_Power_Charges__c = (String) fields.get('Metered_Power_Charges__c');
        }
        if (fields.containsKey('Reservation_ROFR_kW__c') && fields.get('Reservation_ROFR_kW__c') != null) {
            opp.Reservation_ROFR_kW__c = Decimal.valueOf(String.valueOf(fields.get('Reservation_ROFR_kW__c')));
        }

        update opp;
    }

    private static List<String> getMissingFields(Opportunity opp) {
        List<String> missing = new List<String>();
        if (opp.AccountId == null) missing.add('Account');
        if (opp.Operation_Country__c == null) missing.add('Country');
        if (opp.Target_Site__c == null) missing.add('Site');
        if (opp.Power_kW__c == null) missing.add('Power (kW)');
        if (opp.Contract_Term_Months__c == null) missing.add('Contract Tenure');
        if (String.isBlank(opp.DR_Notes__c)) missing.add('Deal Review Summary');
        return missing;
    }

    @AuraEnabled
    public static List<QuoteLineItem> getQuoteLines(Id quoteId) {
        return [
            SELECT Id, Product2.Name, Product2.Family, Product2.ProductCode,
                   Quantity, UnitPrice, TotalPrice, ListPrice,
                   Charge_Type__c,
                   QuoteId, Quote.CurrencyIsoCode
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
            ORDER BY Product2.Family, Product2.Name
        ];
    }

    public class MemoData {
        @AuraEnabled public Opportunity opp { get; set; }
        @AuraEnabled public List<QuoteOption> availableQuotes { get; set; }
        @AuraEnabled public List<String> missingFields { get; set; }
    }

    public class QuoteOption {
        @AuraEnabled public String quoteId { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String quoteName { get; set; }
        @AuraEnabled public String status { get; set; }
        public QuoteOption(Id qId, String name, String number_x, String sts) {
            this.quoteId = qId;
            this.label = name + ' (' + sts + ')';
            this.quoteName = name;
            this.status = sts;
        }
    }
}