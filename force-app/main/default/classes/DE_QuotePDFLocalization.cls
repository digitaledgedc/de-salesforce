public without sharing class DE_QuotePDFLocalization {
    public static final String DEFAULT_LANGUAGE = 'en_US';
    public static final Set<String> SUPPORTED_LANGUAGES = new Set<String>{
        'en_US', 'ja', 'ko', 'zh_CN', 'zh_TW'
    };

    public static String normalizeLanguage(String languageCode) {
        return SUPPORTED_LANGUAGES.contains(languageCode) ? languageCode : DEFAULT_LANGUAGE;
    }

    public static String languageFromAccountPreference(String preference) {
        if (preference == 'Japanese') return 'ja';
        if (preference == 'Korean')   return 'ko';
        if (preference == 'Chinese')  return 'zh_CN';
        return DEFAULT_LANGUAGE;
    }

    public static Boolean preferenceMatches(String preference, String languageCode) {
        String lang = normalizeLanguage(languageCode);
        if (preference == 'English')  return lang == 'en_US';
        if (preference == 'Japanese') return lang == 'ja';
        if (preference == 'Korean')   return lang == 'ko';
        if (preference == 'Chinese')  return lang == 'zh_CN' || lang == 'zh_TW';
        if (preference == 'Simplified Chinese')  return lang == 'zh_CN';
        if (preference == 'Traditional Chinese') return lang == 'zh_TW';
        return false;
    }

    public static String label(String labelName, String languageCode) {
        String lang = normalizeLanguage(languageCode);
        if (lang != DEFAULT_LANGUAGE && Label.translationExists('', labelName, lang)) {
            return System.Label.get('', labelName, lang);
        }
        return System.Label.get('', labelName, DEFAULT_LANGUAGE);
    }

    public static Map<String, String> labels(String languageCode) {
        List<String> names = new List<String>{
            'PDF_Title_New_NonBinding', 'PDF_Title_New_Binding',
            'PDF_Title_Change_NonBinding', 'PDF_Title_Change_Binding',
            'Header_Order_Number', 'Header_Quote_Number', 'Header_Issued_Date', 'Header_Currency',
            'Header_Initial_Term', 'Header_Expiration', 'Header_Attention',
            'Header_Data_Center', 'Header_Amended_Order',
            'Header_Requested_Delivery_Date', 'Header_End_Customer_Name',
            'Header_Customer_PO_Reference', 'Header_Contracting_Entity',
            'Table_Product_Name', 'Table_Product_Attribute',
            'Table_Original_Product_Attribute', 'Table_Quantity',
            'Table_Additional_Quantity', 'Table_Unit', 'Table_Original_Price',
            'Table_Unit_Cost', 'Table_Unit_Charge', 'Table_Discount_Percent',
            'Table_Tax_Rate', 'Table_Tax_Amount', 'Table_Amount_Excluding_Tax',
            'Table_Subtotal', 'Table_Total', 'Table_Service_ID', 'Table_Remarks',
            'Section_Non_Recurring_Charges', 'Section_Monthly_Recurring_Charges',
            'Section_Ramp_Up_Orders', 'Section_Ramp_All_Phases_Linked',
            'Total_Grand_NRC', 'Total_Grand_MRC',
            'Total_Subtotal_NRC', 'Total_Subtotal_MRC', 'Total_Subtotal',
            'Total_Tax', 'Total_Grand_Total', 'Heading_Terms_NonBinding',
            'Heading_Terms_Binding', 'Heading_Special_Note',
            'Heading_Scope_Of_Work', 'Heading_Project_Overview',
            'Heading_Network_Accessories', 'Signature_Accepted_And_Agreed',
            'Signature_Authorized_Signatory', 'Signature_Name',
            'Signature_Title', 'Signature_Date', 'Footer_Page',
            'PDF_NonBinding_Term_1', 'PDF_NonBinding_Term_2',
            'PDF_NonBinding_Term_3', 'PDF_NonBinding_Term_4'
        };
        Map<String, String> result = new Map<String, String>();
        for (String name : names) {
            result.put(name, label(name, languageCode));
        }
        return result;
    }

    public static String buildNonBindingTermsHtml(String languageCode) {
        List<String> clauses = new List<String>();
        for (Integer i = 1; i <= 4; i++) {
            clauses.add('<li>' + label('PDF_NonBinding_Term_' + i, languageCode).escapeHtml4() + '</li>');
        }
        return '<ol style="padding-left:18px;margin:4px 0 0 0;">' +
            String.join(clauses, '') + '</ol>';
    }

    public static String quoteTitle(
        Boolean isChangeOrder,
        Boolean isBinding,
        String languageCode
    ) {
        String labelName;
        if (isChangeOrder == true) {
            labelName = isBinding == true
                ? 'PDF_Title_Change_Binding'
                : 'PDF_Title_Change_NonBinding';
        } else {
            labelName = isBinding == true
                ? 'PDF_Title_New_Binding'
                : 'PDF_Title_New_NonBinding';
        }
        return label(labelName, languageCode);
    }

    public static Blob renderQuotePdf(Id quoteId, String languageCode) {
        PageReference pageReference = Page.DE_QuoteTemplate;
        pageReference.getParameters().put('id', String.valueOf(quoteId));
        pageReference.getParameters().put('lang', normalizeLanguage(languageCode));
        return Test.isRunningTest()
            ? Blob.valueOf('PDF_STUB')
            : pageReference.getContentAsPDF();
    }

    public static String formatDate(Date value, String languageCode) {
        if (value == null) return '';
        return formatParts(value.year(), value.month(), value.day(), null, languageCode);
    }

    public static String formatDateTime(Datetime value, String timezoneName, String languageCode) {
        if (value == null) return '';
        String numeric = value.format('yyyy|M|d|HH|mm', String.isBlank(timezoneName) ? 'UTC' : timezoneName);
        List<String> parts = numeric.split('\\|');
        return formatParts(
            Integer.valueOf(parts[0]), Integer.valueOf(parts[1]), Integer.valueOf(parts[2]),
            parts[3] + ':' + parts[4], languageCode
        );
    }

    private static String formatParts(
        Integer year, Integer month, Integer day, String timeValue, String languageCode
    ) {
        String lang = normalizeLanguage(languageCode);
        String dateValue;
        if (lang == 'ja' || lang == 'zh_CN' || lang == 'zh_TW') {
            dateValue = year + '年' + month + '月' + day + '日';
        } else if (lang == 'ko') {
            dateValue = year + '년 ' + month + '월 ' + day + '일';
        } else {
            List<String> months = new List<String>{
                'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
            };
            String dayValue = day < 10 ? '0' + day : String.valueOf(day);
            dateValue = dayValue + '-' + months[month - 1] + '-' + year;
        }
        return String.isBlank(timeValue) ? dateValue : dateValue + ' ' + timeValue;
    }
}