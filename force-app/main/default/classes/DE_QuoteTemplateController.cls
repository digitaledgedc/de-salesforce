public with sharing class DE_QuoteTemplateController {

    // ─── Exposed properties ───────────────────────────────────────────────

    public Quote               q               { get; private set; }
    public String              quoteTitle      { get; private set; }
    public String              contactName     { get; private set; }
    public Boolean             showContactName { get; private set; }
    public String              currencySymbol  { get; private set; }
    // MessageFormat pattern for every money figure on the page. JPY / KRW / IDR are
    // configured with DecimalPlaces = 0 in this org and have no minor unit, so a
    // blanket "#,##0.00" would print ¥ 1,234,567.00 on the ~85% of quotes raised
    // in those currencies. Resolved per quote from CurrencyType.
    public String              moneyPattern    { get; private set; }
    public List<QuoteLineItem> nrcLines        { get; private set; }
    public List<QuoteLineItem> mrcLines        { get; private set; }
    public Decimal             grandTotalNRC   { get; private set; }
    public Decimal             grandTotalMRC   { get; private set; }
    public Boolean             showSpecialNote { get; private set; }
    public String              specialNote     { get; private set; }
    public String              siteName        { get; private set; }
    public String              siteAddress     { get; private set; }
    public Boolean             showDataCenter  { get; private set; }
    public String              endCustomer     { get; private set; }
    public Boolean             showEndCustomer { get; private set; }
    public String              documentLanguage { get; private set; }
    public Map<String, String> pdfLabels        { get; private set; }
    public Map<Id, String>     productNameByLineId { get; private set; }
    // Asset.Name with the trailing ": <Product Name>" suffix stripped — the
    // Product Name is already its own column, so repeating it here is redundant.
    // Mirrors the same trim logic used by the deOrderAssets LWC (Order page).
    public Map<Id, String>     assetDisplayNameByLineId { get; private set; }
    // Attribute column display value: Product_Attribute_Value__c, with
    // Custom_Attribute_Value__c appended when also present (FB-455).
    public Map<Id, String>     attributeDisplayByLineId { get; private set; }
    // SFDC-366: the unit printed in the UoM column. Blank UoM__c inherits the product
    // default, so this map is what the page binds — never li.Product2.QuantityUnitOfMeasure
    // directly, or every pre-SFDC-366 line would print an empty cell.
    public Map<Id, String>     uomByLineId { get; private set; }
    // SFDC-404: the same four column values with HTML break opportunities added,
    // plus the Unit column which the page previously read straight off the
    // record. The page renders these with escape="false"; the plain maps above
    // stay untouched for any non-HTML consumer. See pdfWrapText.
    public Map<Id, String>     productNameHtmlByLineId { get; private set; }
    public Map<Id, String>     assetNameHtmlByLineId { get; private set; }
    public Map<Id, String>     attributeHtmlByLineId { get; private set; }
    public Map<Id, String>     remarksHtmlByLineId { get; private set; }
    public Map<Id, String>     unitHtmlByLineId { get; private set; }
    public String              requestedDeliveryDateStr { get; private set; }
    public String              expirationDateStr { get; private set; }
    public String              initialTermStr  { get; private set; }
    // SFDC-382: drives the Initial Term header row. The page cannot decide this
    // for itself — rendered="{!NOT(ISBLANK(initialTermStr))}" does NOT suppress
    // the row when the string is '', because Visualforce EL treats a non-null
    // Apex String as present no matter how empty it is. That left the label
    // printing with a blank value. An explicit Boolean is unambiguous.
    public Boolean             showInitialTerm { get; private set; }
    public String              termsHeading    { get; private set; }
    public String              termsContent    { get; private set; }

    // China tax (6% VAT, tax-inclusive — China entity only)
    public Boolean             isChinaEntity     { get; private set; }
    public Decimal             chinaTaxTotal     { get; private set; }
    public Decimal             grandTotalInclTax { get; private set; }
    // Per-line computed VAT, keyed by QuoteLineItem Id (China only) — read in VF as {!taxByLineId[li.Id]}
    public Map<Id, Decimal>    taxByLineId       { get; private set; }
    public Map<Id, Decimal>    exclByLineId      { get; private set; }
    // FB: base-table display values per line. For ramp deals the base table shows
    // the aggregated (Lines-view) quantity/price/total, which differ from the stored
    // QuoteLineItem, so they are served from these maps (li.TotalPrice is calculated
    // and cannot be overridden in memory). For non-ramp lines they equal the line's
    // own values, so behaviour is unchanged.
    public Map<Id, Decimal>    displayQtyByLineId      { get; private set; }
    public Map<Id, Decimal>    displayUnitByLineId     { get; private set; }
    public Map<Id, Decimal>    displayDiscByLineId     { get; private set; }
    public Map<Id, Decimal>    displaySubtotalByLineId { get; private set; }

    // Change Order support
    public Boolean             isChangeOrder     { get; private set; }
    public String              amendedOrderNumber { get; private set; }

    // Empty when not a Change Order, single element when it is.
    // Used with <apex:repeat> so conditional table cells emit no hidden
    // placeholder <span> inside a <tr> (which breaks PDF table layout).
    public List<Integer> getServiceIdCol() {
        return (isChangeOrder == true) ? new List<Integer>{ 1 } : new List<Integer>();
    }

    // Same hidden-placeholder-span problem as serviceIdCol above, but for the
    // NRC/MRC section + Grand Total row blocks (each spans multiple <tr>s).
    public List<Integer> getNrcSectionFlag() {
        return (nrcLines != null && !nrcLines.isEmpty()) ? new List<Integer>{ 1 } : new List<Integer>();
    }
    public List<Integer> getMrcSectionFlag() {
        return (mrcLines != null && !mrcLines.isEmpty()) ? new List<Integer>{ 1 } : new List<Integer>();
    }

    // True when at least one line on the quote carries a non-blank Discount
    // (0% or 100%). Drives the conditional "Disc.%" column: empty list -> the
    // <apex:repeat> emits no <col>/<th>/<td>, so the column disappears with no
    // hidden placeholder <span> to break the PDF table grid.
    public Boolean hasAnyDiscount { get; private set; }
    public Boolean hasEpixProduct { get; private set; }
    public List<Integer> getDiscountCol() {
        return (hasAnyDiscount == true) ? new List<Integer>{ 1 } : new List<Integer>();
    }

    // Ramp support
    public Boolean             isRampDeal      { get; private set; }
    public List<RampPhaseWrapper> rampPhases   { get; private set; }

    // Billing address (Quote fields, falling back to Account fields if blank)
    public String              billingName    { get; private set; }
    public String              billingAddress    { get; private set; }
    public String              billingStreet  { get; private set; }
    public String              billingCity    { get; private set; }
    public String              billingState   { get; private set; }
    public String              billingPostal  { get; private set; }
    public String              billingCountry { get; private set; }

    // Binding / signature block
    public String              deEntityName    { get; private set; }
    public String              quoteAccountName { get; private set; }
    public String              issuedDateStr   { get; private set; }

    // ─── China VAT rate (tax-inclusive) ──────────────────────────────────

    private static final Decimal CHINA_TAX_RATE = 6;
    private static final String  EPIX_CODE_PREFIX = 'IXP';
    // SFDC-585: the Indonet logo is for Indonesian entities only
    private static final String  EPIX_LOGO_COUNTRY = 'Indonesia';

    // ─── Inner wrapper for a ramp phase ──────────────────────────────────

    public class RampLineWrapper {
        public QuoteLineItem line        { get; set; }
        public Decimal       rampAdditionalQty { get; set; }
        public String        displayProductName { get; set; }
        // FB: a repricing phase stores one QuoteLineItem per superseded phase, so
        // several rows share the same phase + product and differ only in
        // Ramp_Linked_Phase__c. Those rows are collapsed into ONE wrapper; these
        // two carry the summed Quantity / TotalPrice for the displayed row.
        // Null means "not grouped" — fall back to the line's own value.
        public Decimal       groupedQuantity   { get; set; }
        public Decimal       groupedTotalPrice { get; set; }

        // SFDC-143: inputs for the Additional Qty second pass below. Additional
        // quantity is a property of the phase SERIES, not of one line, so it
        // cannot be computed while the lines are still being read — these carry
        // what the pass needs and are not bound by the page.
        //   rampGroupKey  identifies the series: charge type + ramp group
        //   rampPhaseNum  orders the series
        //   isAggregate   Quantity holds a RUNNING TOTAL, not a per-phase delta
        //   runningQty    the cell's running total (max, so a fan-out cell does
        //                 not multiply it the way groupedQuantity's sum would)
        //   unlinkedQty   summed quantity of the cell's non-repricing lines
        public String        rampGroupKey { get; set; }
        public Integer       rampPhaseNum { get; set; }
        public Boolean       isAggregate  { get; set; }
        public Decimal       runningQty   { get; set; }
        public Decimal       unlinkedQty  { get; set; }

        // Delegate common QuoteLineItem fields so VF can use {!rl.Product2.Name} etc.
        public Product2         Product2                { get { return line.Product2; } }
        public String           Product_Attribute_Value { get { return combineAttributeDisplay(line.Product_Attribute_Value__c, line.Custom_Attribute_Value__c); } }
        public Decimal          Quantity                { get { return groupedQuantity   != null ? groupedQuantity   : line.Quantity;   } }
        public Decimal          UnitPrice               { get { return line.UnitPrice; } }
        public Decimal          Discount                { get { return line.Discount; } }
        public Decimal          TotalPrice              { get { return groupedTotalPrice != null ? groupedTotalPrice : line.TotalPrice; } }
        public String           Description             { get { return line.Line_Remarks__c; } }
        public String           Notes                   { get { return line.Line_Remarks__c; } }
        // SFDC-404: HTML variants for the ramp grid's free-text columns. See
        // pdfWrapText — the page renders these with escape="false".
        public String           displayProductNameHtml  { get { return pdfWrapText(displayProductName); } }
        public String           ProductAttributeHtml    { get { return pdfWrapText(Product_Attribute_Value); } }
        // SFDC-366: the line's own unit wins; blank inherits the product default.
        public String           UnitHtml                { get { return pdfWrapText(String.isNotBlank(line.UoM__c) ? line.UoM__c : (line.Product2 != null ? line.Product2.QuantityUnitOfMeasure : null)); } }
        public String           NotesHtml               { get { return pdfWrapText(line.Line_Remarks__c); } }
    }

    public class RampPhaseWrapper {
        public String                  label          { get; set; }
        public String                  phaseNumber    { get; set; }
        public String                  phaseAttribute { get; set; }
        public Date                    startDate      { get; set; }
        public String                  startDateStr   { get; set; }
        public List<RampLineWrapper>   nrcLines       { get; set; }
        public List<RampLineWrapper>   mrcLines       { get; set; }
        public Decimal                 subtotalNRC    { get; set; }
        public Decimal                 subtotalMRC    { get; set; }
        // True when the phase adds no new quantity and only reprices — i.e. it has
        // at least one MRC line and EVERY MRC line carries Ramp_Linked_Phase__c.
        // Drives the "All Phases Linked" marker on the phase header row.
        public Boolean                 isAllPhasesLinked { get; set; }
        // Tallies behind isAllPhasesLinked, filled while the phase is being built.
        public Boolean                 hasMrcLine         { get; set; }
        public Boolean                 hasUnlinkedMrcLine { get; set; }
        // SFDC-370: phase remark; stored per line in Ramp_Phase_Notes__c, same text on every line of the phase.
        public String                  phaseNote          { get; set; }
        public String                  notesHtml          { get { return pdfWrapText(phaseNote); } }

        public RampPhaseWrapper() {
            nrcLines       = new List<RampLineWrapper>();
            mrcLines       = new List<RampLineWrapper>();
            subtotalNRC    = 0;
            subtotalMRC    = 0;
            phaseAttribute = '';
            isAllPhasesLinked  = false;
            hasMrcLine         = false;
            hasUnlinkedMrcLine = false;
        }
    }

    // ─── Currency symbol map ──────────────────────────────────────────────

    private static final Map<String, String> CURR_SYMBOL = new Map<String, String>{
        'IDR' => 'Rp',   'USD' => '$',    'SGD' => 'S$',   'AUD' => 'A$',
        'JPY' => '¥',    'HKD' => 'HK$',  'KRW' => '₩',   'PHP' => '₱',
        'CNY' => '¥',    'MYR' => 'RM',   'THB' => '฿',   'EUR' => '€',
        'GBP' => '£'
    };

    // ─── DE Entity display names ──────────────────────────────────────────

    private static final Map<String, String> DE_ENTITY_NAMES = new Map<String, String>{
        'Digital Edge (Japan) G.K.'       => 'Digital Edge (Japan) G.K.',
        'PT Ekagrata Data Gemilang'        => 'PT Ekagrata Data Gemilang',
        'Digital Edge (Korea) Co., Ltd.'   => 'Digital Edge (Korea) Co., Ltd.',
        'Digital Edge (Singapore) Pte Ltd' => 'Digital Edge (Singapore) Pte Ltd',
        '川隽信息技术（上海）有限公司'          => '川隽信息技术（上海）有限公司'
    };

    // ─── Entity → IANA timezone ───────────────────────────────────────────

    private static final Map<String, String> ENTITY_TIMEZONE = new Map<String, String>{
        'Japan'        => 'Asia/Tokyo',
        'Korea'        => 'Asia/Seoul',
        'South Korea'  => 'Asia/Seoul',
        'Singapore'    => 'Asia/Singapore',
        'Indonesia'    => 'Asia/Jakarta',
        'China'        => 'Asia/Shanghai',
        'India'        => 'Asia/Kolkata',
        'Thailand'     => 'Asia/Bangkok',
        'Malaysia'     => 'Asia/Kuala_Lumpur',
        'Philippines'  => 'Asia/Manila'
    };

    // ─── Constructor ─────────────────────────────────────────────────────

    public DE_QuoteTemplateController(ApexPages.StandardController sc) {
        documentLanguage = DE_QuotePDFLocalization.normalizeLanguage(
            ApexPages.currentPage().getParameters().get('lang')
        );
        pdfLabels = DE_QuotePDFLocalization.labels(documentLanguage);
        productNameByLineId = new Map<Id, String>();

        Id quoteId = sc.getId();
        if (quoteId == null) {
            initDefaults();
            return;
        }

        List<Quote> quotes = [
            SELECT Id, Name, Quote_Number__c, Quote_Type__c, Quote_Version__c,
                   Opportunity.Opportunity_Number__c,
                   ExpirationDate, CurrencyIsoCode,
                   Contract_Term_Months__c,
                   Target_Site__c, RDD__c,
                   BillingName, BillingStreet, BillingCity, BillingState,
                   BillingPostalCode, BillingCountry,Account.Local_Registered_Office_Address__c,
                   Account.Name, Account.Local_Entity_Name__c, Account.Translated_Name__c,
                   Account.Preferred_Language__c, Account.BillingStreet, Account.BillingCity, Account.Local_Language__c,
                   Account.BillingState, Account.BillingPostalCode, Account.BillingCountry,
                   ContactId, Contact.Name, Contact.Translated_Name__c, Contact.Language_Preference__c,
                   Special_Notes__c,Account.Registered_Address__c,
                   Is_Binding__c, Ramp_Schedule__c,
                   Service_Order_Terms__c,
                   SBI_Flag__c, SBI_Notes__c,
                   Customer_PO_Reference__c, End_Customer__c,
                   QuoteAccountId, QuoteAccount.Name, QuoteAccount.Translated_Name__c,
                   QuoteAccount.Preferred_Language__c,
                   QuoteAccount.Local_Entity_Name__c, QuoteAccount.Local_Language__c,
                   Original_Order__c, Original_Order__r.Order_Number__c,
                   DE_Entity__c, DE_Entity__r.Name, DE_Entity__r.Translated_Name__c,
                   DE_Entity__r.Preferred_Language__c, DE_Entity__r.Operation_Country__c,
                   Total_NRC__c, Total_MRC_2__c
            FROM Quote WHERE Id = :quoteId LIMIT 1
        ];

        if (quotes.isEmpty()) {
            initDefaults();
            return;
        }
        q = quotes[0];

        // ── Billing address: Quote fields first, fall back to Account ────
        Boolean useTranslatedAccount = q.Account != null
            && DE_QuotePDFLocalization.preferenceMatches(q.Account.Preferred_Language__c, documentLanguage)
            && String.isNotBlank(q.Account.Translated_Name__c);
        Boolean useLegacyLocalAccountName = documentLanguage != 'en_US'
            && q.Account != null
            && q.Account.Local_Language__c == true
            && String.isNotBlank(q.Account.Local_Entity_Name__c);
        String accountDisplayName = useTranslatedAccount
            ? q.Account.Translated_Name__c
            : (useLegacyLocalAccountName
                ? q.Account.Local_Entity_Name__c
                : (q.Account?.Name ?? ''));
        billingName = useTranslatedAccount || useLegacyLocalAccountName
            ? accountDisplayName
            : (String.isNotBlank(q.BillingName) ? q.BillingName : accountDisplayName);
        /*billingStreet  = String.isNotBlank(q.BillingStreet)     ? q.BillingStreet     : (q.Account?.BillingStreet     ?? '');
        billingCity    = String.isNotBlank(q.BillingCity)       ? q.BillingCity       : (q.Account?.BillingCity       ?? '');
        billingState   = String.isNotBlank(q.BillingState)      ? q.BillingState      : (q.Account?.BillingState      ?? '');
        billingPostal  = String.isNotBlank(q.BillingPostalCode) ? q.BillingPostalCode : (q.Account?.BillingPostalCode ?? '');
        billingCountry = String.isNotBlank(q.BillingCountry)    ? q.BillingCountry    : (q.Account?.BillingCountry    ?? '');*/
        Boolean useLocalAddress = documentLanguage != 'en_US'
            && q.Account != null
            && q.Account.Local_Language__c == true
            && String.isNotBlank(q.Account.Local_Registered_Office_Address__c);
		billingAddress = useLocalAddress
            ? q.Account.Local_Registered_Office_Address__c
            : q.Account?.Registered_Address__c;
        // ── Title ────────────────────────────────────────────────────────
        isChangeOrder = (q.Quote_Type__c == 'Amendment' || q.Quote_Type__c == 'Change Order');
        Boolean isBinding = (q.Is_Binding__c == true);
        quoteTitle = DE_QuotePDFLocalization.quoteTitle(
            isChangeOrder, isBinding, documentLanguage
        );
        termsHeading = isBinding
            ? pdfLabels.get('Heading_Terms_Binding')
            : pdfLabels.get('Heading_Terms_NonBinding');
        termsContent = insertCjkSoftBreaks(q.Service_Order_Terms__c);

        // ── Amended-from order number ────────────────────────────────────
        amendedOrderNumber = isChangeOrder && q.Original_Order__r != null
            ? q.Original_Order__r.Order_Number__c
            : '';

        // ── Misc header fields ───────────────────────────────────────────
        showSpecialNote = (q.Special_Notes__c != null ? TRUE :FALSE) ;
        specialNote     = q.Special_Notes__c;
        endCustomer     = q.End_Customer__c;
        showEndCustomer = String.isNotBlank(q.End_Customer__c);
        Boolean useTranslatedContact = q.Contact != null
            && DE_QuotePDFLocalization.preferenceMatches(q.Contact.Language_Preference__c, documentLanguage)
            && String.isNotBlank(q.Contact.Translated_Name__c);
        contactName = q.Contact == null
            ? ''
            : (useTranslatedContact ? q.Contact.Translated_Name__c : q.Contact.Name);
        // VF ISBLANK() on an Apex String only tests null, not '', so the page
        // needs an explicit Boolean or the "Attn:" label renders with no name.
        showContactName = String.isNotBlank(contactName);
        String code     = String.isNotBlank(q.CurrencyIsoCode) ? q.CurrencyIsoCode : 'USD';
        currencySymbol  = CURR_SYMBOL.containsKey(code) ? CURR_SYMBOL.get(code) : code;
        moneyPattern    = '{0,number,#,##0' + (currencyDecimals(code) == 0 ? '' : '.00') + '}';

        // ── DE contracting entity display name ───────────────────────────
        Boolean useTranslatedEntity = q.DE_Entity__r != null
            && DE_QuotePDFLocalization.preferenceMatches(q.DE_Entity__r.Preferred_Language__c, documentLanguage)
            && String.isNotBlank(q.DE_Entity__r.Translated_Name__c);
        deEntityName = q.DE_Entity__r == null
            ? 'Digital Edge'
            : (useTranslatedEntity ? q.DE_Entity__r.Translated_Name__c : q.DE_Entity__r.Name);

        // ── Account for Quote (signature block, left side) ───────────────
        // Mirror the billing-name fallback chain so the customer signatory
        // renders in the local language: Translated_Name__c (when the account's
        // preferred language matches the document) → Local_Entity_Name__c (legacy
        // local-language name) → English Name.
        Boolean useTranslatedQuoteAccount = q.QuoteAccount != null
            && DE_QuotePDFLocalization.preferenceMatches(q.QuoteAccount.Preferred_Language__c, documentLanguage)
            && String.isNotBlank(q.QuoteAccount.Translated_Name__c);
        Boolean useLegacyLocalQuoteAccountName = documentLanguage != 'en_US'
            && q.QuoteAccount != null
            && q.QuoteAccount.Local_Language__c == true
            && String.isNotBlank(q.QuoteAccount.Local_Entity_Name__c);
        quoteAccountName = q.QuoteAccount == null
            ? ''
            : (useTranslatedQuoteAccount
                ? q.QuoteAccount.Translated_Name__c
                : (useLegacyLocalQuoteAccountName
                    ? q.QuoteAccount.Local_Entity_Name__c
                    : q.QuoteAccount.Name));

        // ── China entity? (drives the 6% VAT columns on the PDF) ─────────
        isChinaEntity = (q.DE_Entity__r != null && q.DE_Entity__r.Operation_Country__c == 'China');

        // ── Issued date formatted in entity's local timezone ─────────────
        String entityTz = (q.DE_Entity__r != null)
            ? ENTITY_TIMEZONE.get(q.DE_Entity__r.Operation_Country__c) : null;
        issuedDateStr = DE_QuotePDFLocalization.formatDateTime(
            System.now(), entityTz != null ? entityTz : 'UTC', documentLanguage
        );
        requestedDeliveryDateStr = DE_QuotePDFLocalization.formatDate(q.RDD__c, documentLanguage);
        expirationDateStr = DE_QuotePDFLocalization.formatDate(q.ExpirationDate, documentLanguage);
        // SFDC-382: the Initial Term header belongs on New and Renewal orders
        // only. A Change Order (Quote_Type__c = Amendment) and a Termination
        // both inherit Contract_Term_Months__c from the order they act on, but
        // neither document re-sets the contract term — printing it there reads
        // as a term being agreed and misrepresents the document. Whitelist the
        // two types that do set a term rather than blacklisting the others, so
        // a future quote type stays silent until it is deliberately added.
        Boolean setsContractTerm =
            (q.Quote_Type__c == 'New' || q.Quote_Type__c == 'Renewal');
        showInitialTerm = setsContractTerm && q.Contract_Term_Months__c != null;
        initialTermStr = showInitialTerm
            ? formatInitialTerm(q.Contract_Term_Months__c)
            : '';

        // ── Site lookup ──────────────────────────────────────────────────
        if (q.Target_Site__c != null) {
            List<Site__c> sites = [SELECT Name, Address__c, Local_Address__c FROM Site__c WHERE Id = :q.Target_Site__c LIMIT 1];
            if (!sites.isEmpty()) {
                siteName = sites[0].Name;
                List<String> addrParts = new List<String>();
                try {
                    // Compound address field → full state/country names via JSON
                    Object addrObj = sites[0].get('Address__c');
                    if (addrObj != null) {
                        Map<String, Object> addrMap = (Map<String, Object>) JSON.deserializeUntyped(JSON.serialize(addrObj));
                        String street  = (String) addrMap.get('street');
                        String city    = (String) addrMap.get('city');
                        String state   = (String) addrMap.get('state');
                        String country = (String) addrMap.get('country');
                        String postal  = (String) addrMap.get('postalCode');
                        if (String.isNotBlank(street))  addrParts.add(street);
                        if (String.isNotBlank(city))    addrParts.add(city);
                        if (String.isNotBlank(state))   addrParts.add(state);
                        if (String.isNotBlank(country)) addrParts.add(country);
                        if (String.isNotBlank(postal))  addrParts.add(postal);
                    }
                } catch (Exception e) {
                    System.debug('Site address parse error: ' + e.getMessage());
                }
                siteAddress = addrParts.isEmpty()
                    ? siteName
                    : String.join(addrParts, ', ');
                // Non-English documents show the site's local-language address
                // (Local_Address__c) when populated; otherwise fall back to the
                // English compound address assembled above.
                if (documentLanguage != 'en_US' && String.isNotBlank(sites[0].Local_Address__c)) {
                    siteAddress = sites[0].Local_Address__c;
                }
            } else {
                siteName    = '';
                siteAddress = '';
            }
        } else {
            siteName    = '';
            siteAddress = '';
        }
        showDataCenter = String.isNotBlank(siteName) || String.isNotBlank(siteAddress);

        // ── Load all line items ──────────────────────────────────────────
        List<QuoteLineItem> lines = [
            SELECT Id, Product2Id, Product2.Name, Product2.ProductCode, Product2.QuantityUnitOfMeasure,
                   UoM__c,
                   Product_Attribute_Value__c, Custom_Attribute_Value__c, Charge_Type__c, BillingFrequency,
                   Quantity, ListPrice, UnitPrice, Discount, TotalPrice,
                   Description, SortOrder, Line_Remarks__c, Ramp_Phase_Notes__c,
                   Line_Origin__c, Ramp_Phase__c, Ramp_Step_Number__c,
                   Ramp_Start_Date__c, SegmentName,
                   StartQuantity, EndQuantity,
                   Ramp_Parent_Line__c, Ramp_Linked_Phase__c,
                   Merge_IB_Task__c, Product2.Merge_IB_Task__c,
                   Asset__c, Asset__r.Name
            FROM QuoteLineItem WHERE QuoteId = :quoteId
            ORDER BY SortOrder ASC NULLS LAST, Ramp_Phase__c ASC NULLS LAST
        ];

        Set<Id> productIds = new Set<Id>();
        hasAnyDiscount = false;
        hasEpixProduct = false;
        Boolean isEpixLogoEntity = q.DE_Entity__r != null
            && q.DE_Entity__r.Operation_Country__c == EPIX_LOGO_COUNTRY;
        for (QuoteLineItem li : lines) {
            if (li.Product2Id != null) productIds.add(li.Product2Id);
            if (li.Discount != null) hasAnyDiscount = true;
            if (isEpixLogoEntity && li.Product2 != null && li.Product2.ProductCode != null
                && li.Product2.ProductCode.startsWith(EPIX_CODE_PREFIX)) hasEpixProduct = true;
        }
        Map<Id, String> translatedProductNames = new Map<Id, String>();
        if (documentLanguage != 'en_US' && !productIds.isEmpty()) {
            for (Product2DataTranslation translation : [
                SELECT ParentId, Name
                FROM Product2DataTranslation
                WHERE ParentId IN :productIds
                AND Language = :documentLanguage
                AND IsOutOfDate = false
            ]) {
                translatedProductNames.put(translation.ParentId, translation.Name);
            }
        }
        for (QuoteLineItem li : lines) {
            productNameByLineId.put(
                li.Id,
                translatedProductNames.containsKey(li.Product2Id)
                    ? translatedProductNames.get(li.Product2Id)
                    : li.Product2.Name
            );
        }

        // ── Service ID column display value (Asset.Name, product suffix stripped) ─
        assetDisplayNameByLineId = new Map<Id, String>();
        for (QuoteLineItem li : lines) {
            // Visualforce's map[key] EL syntax treats a null value the same as a
            // missing key ("Map key ... not found in map") — default to '' instead.
            String assetName = (li.Asset__r != null && li.Asset__r.Name != null) ? li.Asset__r.Name : '';
            assetDisplayNameByLineId.put(
                li.Id,
                stripProductSuffix(assetName, li.Product2?.Name)
            );
        }

        // ── Attribute column display value (attribute + custom, when present) ──
        attributeDisplayByLineId = new Map<Id, String>();
        for (QuoteLineItem li : lines) {
            attributeDisplayByLineId.put(li.Id, combineAttributeDisplay(li.Product_Attribute_Value__c, li.Custom_Attribute_Value__c));
        }

        // ── SFDC-366: UoM column — the line's own unit, falling back to the product ──
        uomByLineId = new Map<Id, String>();
        for (QuoteLineItem li : lines) {
            uomByLineId.put(li.Id, String.isNotBlank(li.UoM__c)
                ? li.UoM__c
                : (li.Product2 != null ? li.Product2.QuantityUnitOfMeasure : null));
        }

        // ── SFDC-404: HTML variants of every free-text column in the line grids ─
        productNameHtmlByLineId = new Map<Id, String>();
        assetNameHtmlByLineId   = new Map<Id, String>();
        attributeHtmlByLineId   = new Map<Id, String>();
        remarksHtmlByLineId     = new Map<Id, String>();
        unitHtmlByLineId        = new Map<Id, String>();
        for (QuoteLineItem li : lines) {
            productNameHtmlByLineId.put(li.Id, pdfWrapText(productNameByLineId.get(li.Id)));
            assetNameHtmlByLineId.put(  li.Id, pdfWrapText(assetDisplayNameByLineId.get(li.Id)));
            attributeHtmlByLineId.put(  li.Id, pdfWrapText(attributeDisplayByLineId.get(li.Id)));
            remarksHtmlByLineId.put(    li.Id, pdfWrapText(li.Line_Remarks__c));
            // SFDC-366: same coalesce as uomByLineId above
            unitHtmlByLineId.put(       li.Id, pdfWrapText(uomByLineId.get(li.Id)));
        }

        // ── Separate base lines from ramp lines ──────────────────────────
        // Is_Ramp_Deal__c removed from Quote — derive ramp status from Ramp_Schedule__c
        // or from the QLIs themselves (any Ramp_Line__c = true).
        isRampDeal  = (q.Ramp_Schedule__c == true);
        if (!isRampDeal) {
            for (QuoteLineItem li : lines) {
                if (li.Line_Origin__c == 'Ramp') { isRampDeal = true; break; }
            }
        }
        nrcLines    = new List<QuoteLineItem>();
        mrcLines    = new List<QuoteLineItem>();
        grandTotalNRC = 0;
        grandTotalMRC = 0;
        chinaTaxTotal = 0;
        taxByLineId  = new Map<Id, Decimal>();
        exclByLineId = new Map<Id, Decimal>();
        displayQtyByLineId      = new Map<Id, Decimal>();
        displayUnitByLineId     = new Map<Id, Decimal>();
        displayDiscByLineId     = new Map<Id, Decimal>();
        displaySubtotalByLineId = new Map<Id, Decimal>();

        // Ramp: map phase number -> wrapper
        Map<Integer, RampPhaseWrapper> phaseMap = new Map<Integer, RampPhaseWrapper>();
        List<Integer>                  phaseOrder = new List<Integer>();
        // FB: one displayed ramp row per (phase, NRC/MRC, product group). Key is
        // phase|NRC-or-MRC|Ramp_Parent_Line__c (falling back to the line's own Id
        // for a phase-1 anchor, which has no parent).
        Map<String, RampLineWrapper>   rampLineByKey = new Map<String, RampLineWrapper>();

        // FB: ramp PDF layout —
        //   First table  = aggregated "Lines view" (built post-loop from group anchors).
        //   Next tables  = one per ramp phase (Ramp-1, Ramp-2, ...), EVERY phase incl. 1.
        // Group anchors + their cross-phase siblings (linked via Ramp_Parent_Line__c)
        // feed the aggregation below.
        List<QuoteLineItem>              groupAnchors     = new List<QuoteLineItem>();
        Map<Id, List<QuoteLineItem>>     siblingsByAnchor = new Map<Id, List<QuoteLineItem>>();

        for (QuoteLineItem li : lines) {
            Boolean isRampLine = (li.Line_Origin__c == 'Ramp');
            Boolean isNRC      = isNrcLine(li);

            if (isRampLine && isRampDeal) {
                Integer phaseNum = li.Ramp_Phase__c != null ? Integer.valueOf(li.Ramp_Phase__c) : 1;
                if (phaseNum < 1) phaseNum = 1;

                // (1) Every ramp phase (including Phase 1) gets a ramp-schedule table
                if (!phaseMap.containsKey(phaseNum)) {
                    RampPhaseWrapper pw = new RampPhaseWrapper();
                    String segName = String.isNotBlank(li.SegmentName) ? li.SegmentName.trim() : 'Ramp-' + phaseNum;
                    String pNum  = 'Ramp-' + phaseNum;
                    String pAttr = '';
                    if (segName.startsWithIgnoreCase('Ramp-')) {
                        Integer spaceIdx = segName.indexOf(' ');
                        if (spaceIdx > 0) {
                            pNum  = segName.substring(0, spaceIdx);
                            pAttr = segName.substring(spaceIdx + 1).trim();
                        } else {
                            pNum  = segName;
                        }
                    } else {
                        pAttr = segName;
                    }
                    pw.label          = segName;
                    pw.phaseNumber    = pNum;
                    pw.phaseAttribute = pAttr;
                    pw.startDate      = li.Ramp_Start_Date__c;
                    pw.startDateStr   = DE_QuotePDFLocalization.formatDate(
                        li.Ramp_Start_Date__c, documentLanguage
                    );
                    phaseMap.put(phaseNum, pw);
                    phaseOrder.add(phaseNum);
                }
                RampPhaseWrapper pw = phaseMap.get(phaseNum);
                // SFDC-370: phase remark for the phase header row — first line of the phase that carries one
                if (String.isBlank(pw.phaseNote)) pw.phaseNote = li.Ramp_Phase_Notes__c;

                // (1a) Collapse the QuoteLineItems a repricing phase saves per
                // superseded phase into ONE displayed row. They share phase +
                // product (same Ramp_Parent_Line__c) and differ only in
                // Ramp_Linked_Phase__c, so printing one <tr> each duplicated the
                // product. Quantity / additional qty / total are summed; unit price,
                // attribute and description come from the first line (identical by
                // construction). Subtotals below still sum every line, so they are
                // untouched by the grouping.
                Id     groupKey   = (li.Ramp_Parent_Line__c != null) ? li.Ramp_Parent_Line__c : li.Id;
                String wrapperKey = phaseNum + '|' + (isNRC ? 'NRC' : 'MRC') + '|' + groupKey;
                // SFDC-143: additional quantity used to be EndQuantity - StartQuantity.
                // StartQuantity is never populated (0 of 390 ramp lines in de-prod carry
                // one), so that expression collapsed to EndQuantity and the column printed
                // each phase's TOTAL instead of its increment. It is now derived per phase
                // series in the second pass below; only the inputs are collected here.
                Boolean lineIsAgg = (li.Merge_IB_Task__c == true)
                                    || (li.Product2 != null && li.Product2.Merge_IB_Task__c == true);
                Decimal lineQty   = (li.Quantity   != null ? li.Quantity   : 0);
                // A linked line reprices quantity an earlier phase already delivered, so
                // it contributes no additional quantity — whether it supersedes one phase
                // or all of them. Only non-aggregate products need this: on an aggregate
                // product a repricing phase repeats the previous running total, so the
                // subtraction already yields 0.
                Decimal unlinkedQ = (li.Ramp_Linked_Phase__c != null) ? 0 : lineQty;
                Decimal lineTotal = (li.TotalPrice != null ? li.TotalPrice : 0);

                RampLineWrapper rlw = rampLineByKey.get(wrapperKey);
                if (rlw == null) {
                    rlw = new RampLineWrapper();
                    rlw.line = li;
                    rlw.displayProductName = productNameByLineId.get(li.Id);
                    rlw.groupedQuantity    = lineQty;
                    rlw.groupedTotalPrice  = lineTotal;
                    // SFDC-143: series inputs; rampAdditionalQty is set by the pass below
                    rlw.rampGroupKey       = (isNRC ? 'NRC' : 'MRC') + '|' + groupKey;
                    rlw.rampPhaseNum       = phaseNum;
                    rlw.isAggregate        = lineIsAgg;
                    rlw.runningQty         = lineQty;
                    rlw.unlinkedQty        = unlinkedQ;
                    rlw.rampAdditionalQty  = 0;
                    rampLineByKey.put(wrapperKey, rlw);
                    if (isNRC) { pw.nrcLines.add(rlw); } else { pw.mrcLines.add(rlw); }
                } else {
                    // Same phase + product but a different unit price means the line
                    // was edited outside the ramp editor. Keep the first price (never
                    // average) and make the discrepancy visible in the debug log.
                    if (rlw.line.UnitPrice != li.UnitPrice) {
                        System.debug(LoggingLevel.WARN,
                            'DE_QuoteTemplateController: ramp phase ' + phaseNum +
                            ' group ' + groupKey + ' has mixed unit prices (' +
                            rlw.line.UnitPrice + ' on ' + rlw.line.Id + ' vs ' +
                            li.UnitPrice + ' on ' + li.Id +
                            ') — keeping the first for display.');
                    }
                    rlw.groupedQuantity   += lineQty;
                    rlw.groupedTotalPrice += lineTotal;
                    // SFDC-143: a fan-out cell repeats the same running total on every
                    // line, so take the max rather than summing it the way the displayed
                    // Quantity does. unlinkedQty does sum — each unlinked line is real
                    // new quantity on a non-aggregate product.
                    rlw.isAggregate        = rlw.isAggregate || lineIsAgg;
                    if (lineQty > rlw.runningQty) rlw.runningQty = lineQty;
                    rlw.unlinkedQty       += unlinkedQ;
                }

                if (isNRC) {
                    pw.subtotalNRC += lineTotal;
                } else {
                    pw.subtotalMRC += lineTotal;
                    // (1b) "All Phases Linked": every MRC line in the phase reprices
                    // an earlier phase, so the phase adds no new quantity.
                    pw.hasMrcLine = true;
                    if (li.Ramp_Linked_Phase__c == null) pw.hasUnlinkedMrcLine = true;
                }

                // (2) Collect anchors and siblings. The anchor of a ramp group is the
                // line with no Ramp_Parent_Line__c — the same convention groupKey above
                // already uses. It is NOT necessarily a phase-1 line: a space that only
                // comes online partway through the ramp anchors at phase 2, 3 or 4.
                // Keying on "phase <= 1" dropped those groups from the aggregated table
                // entirely (SFDC-349: 48,000 of 60,000 kVA missing from the first table).
                if (li.Ramp_Parent_Line__c == null) {
                    groupAnchors.add(li);
                    if (!siblingsByAnchor.containsKey(li.Id)) siblingsByAnchor.put(li.Id, new List<QuoteLineItem>());
                    siblingsByAnchor.get(li.Id).add(li);
                } else {
                    if (!siblingsByAnchor.containsKey(li.Ramp_Parent_Line__c)) {
                        siblingsByAnchor.put(li.Ramp_Parent_Line__c, new List<QuoteLineItem>());
                    }
                    siblingsByAnchor.get(li.Ramp_Parent_Line__c).add(li);
                }
            } else {
                // Non-ramp base line — unchanged
                addBaseLine(li, isNRC);
            }
        }

        // A sibling group whose parent line is not in this quote has no anchor and
        // would silently vanish from the table — the same failure mode as above.
        // Promote its earliest-phase member so the row is still rendered.
        Set<Id> anchorIds = new Set<Id>();
        for (QuoteLineItem a : groupAnchors) anchorIds.add(a.Id);
        for (Id parentId : siblingsByAnchor.keySet()) {
            if (anchorIds.contains(parentId)) continue;
            QuoteLineItem earliest = null;
            Integer earliestPhase = null;
            for (QuoteLineItem s2 : siblingsByAnchor.get(parentId)) {
                Integer sp = (s2.Ramp_Phase__c != null) ? Integer.valueOf(s2.Ramp_Phase__c) : 0;
                if (earliest == null || sp < earliestPhase) {
                    earliest = s2;
                    earliestPhase = sp;
                }
            }
            if (earliest != null) {
                System.debug(LoggingLevel.WARN,
                    'DE_QuoteTemplateController: ramp group ' + parentId +
                    ' has no anchor line in this quote — promoting ' + earliest.Id +
                    ' (phase ' + earliest.Ramp_Phase__c + ') so the row still renders.');
                groupAnchors.add(earliest);
            }
        }

        // ── SFDC-143: Additional Qty per phase ───────────────────────────────
        // "Additional Qty should be = Current Total Qty - Last Phase Total Qty"
        // (Henry Wang, SFDC-143). That is only true for an AGGREGATE product,
        // where Quantity holds the running total — the same Merge_IB_Task__c
        // distinction the aggregated first table below already makes. On a
        // non-aggregate product Quantity is ALREADY the per-phase increment (the
        // first table sums it), so subtracting would understate every phase; the
        // additional quantity there is the quantity itself.
        //
        // Walking the series needs every phase of the group in hand, so it runs
        // here rather than inside the line loop above. A group whose anchor lives
        // on another quote simply starts at the earliest phase present, which
        // then prints its full running total.
        Map<String, Map<Integer, RampLineWrapper>> rampSeries =
            new Map<String, Map<Integer, RampLineWrapper>>();
        for (RampLineWrapper rlw : rampLineByKey.values()) {
            Map<Integer, RampLineWrapper> byPhase = rampSeries.get(rlw.rampGroupKey);
            if (byPhase == null) {
                byPhase = new Map<Integer, RampLineWrapper>();
                rampSeries.put(rlw.rampGroupKey, byPhase);
            }
            byPhase.put(rlw.rampPhaseNum, rlw);
        }
        for (Map<Integer, RampLineWrapper> byPhase : rampSeries.values()) {
            List<Integer> seriesPhases = new List<Integer>(byPhase.keySet());
            seriesPhases.sort();
            Decimal prevRunning = 0;
            for (Integer sp : seriesPhases) {
                RampLineWrapper rlw = byPhase.get(sp);
                if (rlw.isAggregate == true) {
                    // First phase of the series has no predecessor, so prevRunning
                    // is 0 and the whole quantity reads as additional. That keeps the
                    // column summing to the aggregate total shown in the first table.
                    rlw.rampAdditionalQty = rlw.runningQty - prevRunning;
                    prevRunning = rlw.runningQty;
                } else {
                    rlw.rampAdditionalQty = rlw.unlinkedQty;
                }
            }
        }

        // Build the aggregated first table from the group anchors (mirrors the LWC
        // Lines tab: aggregate products show running/last-phase qty; everything else
        // sums the "new" phases, skipping "price change" phases (Ramp_Linked_Phase__c)).
        for (QuoteLineItem anchor : groupAnchors) {
            List<QuoteLineItem> sibs = siblingsByAnchor.get(anchor.Id);
            if ((sibs == null || sibs.isEmpty()) && anchor.Ramp_Parent_Line__c != null) {
                sibs = siblingsByAnchor.get(anchor.Ramp_Parent_Line__c);
            }
            if (sibs == null || sibs.isEmpty()) sibs = new List<QuoteLineItem>{ anchor };
            Boolean isNRC = isNrcLine(anchor);
            Boolean isAgg = (anchor.Merge_IB_Task__c == true)
                || (anchor.Product2 != null && anchor.Product2.Merge_IB_Task__c == true);

            QuoteLineItem lastSib = anchor;
            for (QuoteLineItem s : sibs) {
                Integer sp = (s.Ramp_Phase__c != null) ? Integer.valueOf(s.Ramp_Phase__c) : 0;
                Integer lp = (lastSib.Ramp_Phase__c != null) ? Integer.valueOf(lastSib.Ramp_Phase__c) : 0;
                if (sp > lp) lastSib = s;
            }

            // SFDC-275: the first table prints the FIRST phase price. Later phases carry
            // escalations that belong only in the Ramp-Up Orders tables below.
            QuoteLineItem firstSib = anchor;
            for (QuoteLineItem s : sibs) {
                Integer sp = (s.Ramp_Phase__c != null) ? Integer.valueOf(s.Ramp_Phase__c) : 0;
                Integer fp = (firstSib.Ramp_Phase__c != null) ? Integer.valueOf(firstSib.Ramp_Phase__c) : 0;
                if (sp < fp) firstSib = s;
            }

            Decimal aggQty;
            if (isAgg) {
                aggQty = (lastSib.Quantity != null) ? lastSib.Quantity : 0;
            } else {
                aggQty = 0;
                for (QuoteLineItem s : sibs) {
                    if (s.Ramp_Linked_Phase__c == null) aggQty += (s.Quantity != null ? s.Quantity : 0);
                }
            }
            Decimal unit = (firstSib.UnitPrice != null) ? firstSib.UnitPrice : 0;
            Decimal disc = (firstSib.Discount  != null) ? firstSib.Discount  : 0;
            Decimal total = aggQty * unit * (1 - disc / 100);

            // Keep the original anchor object (Product2 etc. stay resolvable and the
            // per-phase ramp tables are unaffected); serve the aggregated display
            // values via the display*ByLineId maps.
            addAggregatedBaseLine(anchor, isNRC, aggQty, unit, disc, total);
        }

        // Build ordered phase list. Every ramp phase gets a schedule table now
        // (phase 1 included — the base table is the aggregated Lines view instead).
        // Renumber the displayed schedule sequentially so it always starts at
        // "Ramp-1" regardless of the internal phase number. Only the displayed
        // number is overridden — the attribute (e.g. "15kVA") and start date
        // parsed from SegmentName are preserved.
        phaseOrder.sort();
        rampPhases = new List<RampPhaseWrapper>();
        Integer displayNum = 1;
        for (Integer pn : phaseOrder) {
            RampPhaseWrapper pw = phaseMap.get(pn);
            pw.phaseNumber = 'Ramp-' + displayNum;
            // A phase with no MRC line at all is never marked (the flag would be
            // vacuously true); a phase mixing linked and unlinked MRC lines adds
            // new quantity, so it is not marked either.
            pw.isAllPhasesLinked = (pw.hasMrcLine == true && pw.hasUnlinkedMrcLine == false);
            rampPhases.add(pw);
            displayNum++;
        }

        // ── China combined total (tax-inclusive), shown on the total side ─
        grandTotalInclTax = grandTotalNRC + grandTotalMRC;
    }

    // ─── Helper: decimal places configured for a currency ──────────────
    // Read from CurrencyType so the PDF follows org currency setup rather than a
    // hard-coded list. Non-multi-currency orgs and unknown codes fall back to 2.

    private static Map<String, Integer> decimalsByIso;

    private static Integer currencyDecimals(String isoCode) {
        if (decimalsByIso == null) {
            decimalsByIso = new Map<String, Integer>();
            if (UserInfo.isMultiCurrencyOrganization()) {
                for (SObject ct : Database.query(
                        'SELECT IsoCode, DecimalPlaces FROM CurrencyType')) {
                    decimalsByIso.put(
                        String.valueOf(ct.get('IsoCode')),
                        Integer.valueOf(ct.get('DecimalPlaces'))
                    );
                }
            }
        }
        Integer d = decimalsByIso.get(isoCode);
        return (d == null) ? 2 : d;
    }

    // ─── Helper: strip the trailing ": <Product Name>" suffix Odoo appends ─
    // to Asset.Name (e.g. "ggVAiAAM-IB-000325315: 19\" Cabinet" → "ggVAiAAM-IB-000325315").
    // Mirrors deOrderAssets.js's displayName trim so the Service ID column
    // doesn't repeat what the Product Name column already shows.

    private static String stripProductSuffix(String assetName, String productName) {
        if (String.isBlank(assetName) || String.isBlank(productName)) {
            return assetName;
        }
        String suffix = ': ' + productName;
        Integer idx = assetName.indexOf(suffix);
        if (idx >= 0) {
            return assetName.substring(0, idx);
        }
        if (assetName.endsWith(productName)) {
            String trimmed = assetName.substring(0, assetName.length() - productName.length());
            return trimmed.replaceAll('[:\\s-]+$', '');
        }
        return assetName;
    }

    // ─── Helper: Attribute column display (attribute + custom value) ─────
    // FB-455: Custom_Attribute_Value__c shown alongside Product_Attribute_Value__c
    // when present — the two are typically mutually exclusive per product
    // (Product2.Show_Custom_Attribute_Value__c), but combine defensively.

    // ── SFDC-404: line-break opportunities for the PDF renderer ──────────────
    // The PDF renderer breaks a line only at whitespace. Japanese, Chinese and
    // Korean are written without spaces, so a whole phrase is a single
    // unbreakable token: it overflows its fixed-width column (the line grids
    // are table-layout:fixed), paints straight over the neighbouring cells, and
    // is finally cut off at the page margin. In the Remarks column — the last
    // one — that reads as the truncation reported in SFDC-404; in the Product
    // Name or Attribute column the same overflow silently overprints Qty and
    // Unit, so the numbers are still on the page but unreadable.
    //
    // CSS cannot fix it. Measured against the live renderer on 31-Aug-2026:
    // word-wrap:break-word, word-break:break-all and a U+200B zero-width space
    // are all ignored; &shy; works but prints visible hyphens; table-layout:auto
    // works but resizes every column. A <wbr/> element IS honoured, so the text
    // is HTML-escaped here and <wbr/> inserted at each legal break point. The
    // page renders the result with escape="false" — escaping happens first, so
    // customer text containing & or < stays literal.
    private static final String NO_LINE_START =
        '、。，．）」』】〕〉》”’!?:;,.)]}%％‰・ーぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮヵヶ';
    // A non-CJK run only needs breaking once it is long enough to overflow a
    // column on its own; normal prose has spaces well before this.
    private static final Integer LONG_RUN_START = 20;
    private static final Integer LONG_RUN_EVERY = 10;

    @TestVisible
    private static String pdfWrapText(String raw) {
        // Visualforce's map[key] EL treats a null value the same as a missing
        // key ("Map key ... not found in map") — never return null.
        if (String.isBlank(raw)) return '';
        List<String> out = new List<String>();
        Integer runLen = 0;
        Integer len = raw.length();
        for (Integer i = 0; i < len; i++) {
            String  ch     = raw.substring(i, i + 1);
            Integer code   = raw.charAt(i);
            Boolean isLast = (i == len - 1);
            String  nextCh = isLast ? null : raw.substring(i + 1, i + 2);

            out.add(escapeForPdf(ch));

            if (isCjkChar(code)) {
                runLen = 0;
                // Kinsoku: a line must not begin with closing punctuation.
                if (!isLast && !NO_LINE_START.contains(nextCh)) out.add('<wbr/>');
            } else if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
                runLen = 0;
            } else {
                runLen++;
                if (runLen >= LONG_RUN_START
                    && Math.mod(runLen, LONG_RUN_EVERY) == 0
                    && !isLast
                    && nextCh != ' ') {
                    out.add('<wbr/>');
                }
            }
        }
        return String.join(out, '');
    }

    private static Boolean isCjkChar(Integer c) {
        // Apex has no hex literals, so the ranges are decimal; the U+ form is in
        // the comment.
        return (c >= 12288 && c <= 12351)    // U+3000-303F CJK symbols and punctuation
            || (c >= 12352 && c <= 12447)    // U+3040-309F hiragana
            || (c >= 12448 && c <= 12543)    // U+30A0-30FF katakana
            || (c >= 12592 && c <= 12687)    // U+3130-318F hangul compatibility jamo
            || (c >= 19968 && c <= 40959)    // U+4E00-9FFF CJK unified ideographs
            || (c >= 44032 && c <= 55215)    // U+AC00-D7AF hangul syllables
            || (c >= 63744 && c <= 64255)    // U+F900-FAFF CJK compatibility ideographs
            || (c >= 65280 && c <= 65519);   // U+FF00-FFEF full-width and half-width forms
    }

    private static String escapeForPdf(String ch) {
        if (ch == '&') return '&amp;';
        if (ch == '<') return '&lt;';
        if (ch == '>') return '&gt;';
        if (ch == '"') return '&quot;';
        return ch;
    }

    private static String combineAttributeDisplay(String attributeValue, Object customRaw) {
        // Custom_Attribute_Value__c is Text in some orgs and Number in others;
        // accept it as Object and normalize to String so this compiles against
        // either schema.
        String customValue = (customRaw == null) ? null : String.valueOf(customRaw);
        // SFDEV-5: a zero custom value means "not entered" — quoteLineEditor
        // already shows it blank, so the PDF must not print 0.00 either.
        if (isZeroNumber(customValue)) customValue = null;
        // Visualforce's map[key] EL syntax treats a null value the same as a
        // missing key ("Map key ... not found in map") — never return null.
        if (String.isBlank(customValue)) {
            return attributeValue != null ? attributeValue : '';
        }
        return String.isBlank(attributeValue) ? customValue : (attributeValue + ' / ' + customValue);
    }

    private static Boolean isZeroNumber(String value) {
        if (String.isBlank(value)) return false;
        try {
            return Decimal.valueOf(value.trim()) == 0;
        } catch (TypeException e) {
            return false;
        }
    }

    // ─── Helper: determine if a line is NRC ──────────────────────────────

    private static Boolean isNrcLine(QuoteLineItem li) {
        String prodCode = (li.Product2?.ProductCode != null ? li.Product2.ProductCode : '').toUpperCase();
        String freq     = (li.BillingFrequency != null ? li.BillingFrequency : '').toLowerCase();
        return prodCode.endsWith('.NR')
            || freq.contains('one')
            || freq == 'nrc'
            || li.Charge_Type__c == 'NRC';
    }

    // ─── Helper: soft line-break points for unspaced CJK terms text ───────
    // The PDF render engine only wraps at literal space characters — it does
    // not implement CJK (UAX#14) line-breaking, so a long run of Japanese/
    // Chinese text with no spaces overflows the page instead of wrapping.
    // Insert a real space after common CJK punctuation (never mid-word) so
    // the renderer has periodic, natural-looking break opportunities.
    private static final String CJK_BREAK_CHARS = '、。）」』】，．；：';

    private static String insertCjkSoftBreaks(String html) {
        if (String.isBlank(html)) return html;
        return html.replaceAll('([' + CJK_BREAK_CHARS + '])(?!\\s)', '$1 ');
    }

    private String formatInitialTerm(Decimal months) {
        String value = String.valueOf(months.intValue());
        if (documentLanguage == 'ja') return value + 'か月';
        if (documentLanguage == 'ko') return value + '개월';
        if (documentLanguage == 'zh_CN' || documentLanguage == 'zh_TW') return value + '个月';
        return value + ' Months';
    }

    // ─── Helper: add a base (non-ramp / phase-1) line, computing China VAT ─

    private void addBaseLine(QuoteLineItem li, Boolean isNRC) {
        Decimal total = (li.TotalPrice != null) ? li.TotalPrice : 0;
        Decimal tax   = 0;
        Decimal excl  = total;
        if (isChinaEntity && total != 0) {
            // Tax-inclusive: back the 6% VAT out of the line total
            tax  = (total * CHINA_TAX_RATE / (100 + CHINA_TAX_RATE)).setScale(2, System.RoundingMode.HALF_UP);
            excl = total - tax;
        }
        taxByLineId.put(li.Id, tax);
        exclByLineId.put(li.Id, excl);
        // SFDC-256: Visualforce's map[key] EL treats a null VALUE as a missing key
        // ("Map key 0QL... not found in map"), which aborts the whole PDF render —
        // preview and Send Quote both fail. A QuoteLineItem can legitimately carry a
        // null Quantity/UnitPrice/Discount, so never store null here.
        displayQtyByLineId.put(li.Id, li.Quantity  != null ? li.Quantity  : 0);
        displayUnitByLineId.put(li.Id, li.UnitPrice != null ? li.UnitPrice : 0);
        displayDiscByLineId.put(li.Id, li.Discount  != null ? li.Discount  : 0);
        displaySubtotalByLineId.put(li.Id, total);
        if (isNRC) {
            nrcLines.add(li);
            grandTotalNRC += total;
        } else {
            mrcLines.add(li);
            grandTotalMRC += total;
        }
        chinaTaxTotal += tax;
    }

    // FB: base-table line whose DISPLAYED qty/price/total differ from the stored
    // QuoteLineItem (ramp aggregated "Lines view"). The original line object is kept
    // (so li.Product2 etc. still resolve and the per-phase ramp tables are unaffected);
    // the aggregated values are served via the display*ByLineId maps.
    private void addAggregatedBaseLine(QuoteLineItem li, Boolean isNRC,
                                       Decimal qty, Decimal unit, Decimal disc, Decimal total) {
        if (total == null) total = 0;
        Decimal tax  = 0;
        Decimal excl = total;
        if (isChinaEntity && total != 0) {
            tax  = (total * CHINA_TAX_RATE / (100 + CHINA_TAX_RATE)).setScale(2, System.RoundingMode.HALF_UP);
            excl = total - tax;
        }
        taxByLineId.put(li.Id, tax);
        exclByLineId.put(li.Id, excl);
        // SFDC-256: same null-value/missing-key rule as addBaseLine above.
        displayQtyByLineId.put(li.Id, qty  != null ? qty  : 0);
        displayUnitByLineId.put(li.Id, unit != null ? unit : 0);
        displayDiscByLineId.put(li.Id, disc != null ? disc : 0);
        displaySubtotalByLineId.put(li.Id, total);
        if (isNRC) {
            nrcLines.add(li);
            grandTotalNRC += total;
        } else {
            mrcLines.add(li);
            grandTotalMRC += total;
        }
        chinaTaxTotal += tax;
    }

    // ─── Defaults when no record context ─────────────────────────────────

    private void initDefaults() {
        quoteTitle         = pdfLabels.get('PDF_Title_New_NonBinding');
        showSpecialNote    = false;
        specialNote        = '';
        contactName        = '';
        showContactName    = false;
        currencySymbol     = '$';
        moneyPattern       = '{0,number,#,##0.00}';
        nrcLines           = new List<QuoteLineItem>();
        mrcLines           = new List<QuoteLineItem>();
        grandTotalNRC      = 0;
        grandTotalMRC      = 0;
        chinaTaxTotal      = 0;
        grandTotalInclTax  = 0;
        isChinaEntity      = false;
        taxByLineId        = new Map<Id, Decimal>();
        exclByLineId       = new Map<Id, Decimal>();
        displayQtyByLineId      = new Map<Id, Decimal>();
        displayUnitByLineId     = new Map<Id, Decimal>();
        displayDiscByLineId     = new Map<Id, Decimal>();
        displaySubtotalByLineId = new Map<Id, Decimal>();
        siteName           = '';
        siteAddress        = '';
        showDataCenter     = false;
        endCustomer        = '';
        showEndCustomer    = false;
        isChangeOrder      = false;
        amendedOrderNumber = '';
        hasAnyDiscount     = false;
        hasEpixProduct     = false;
        isRampDeal         = false;
        rampPhases         = new List<RampPhaseWrapper>();
        deEntityName       = 'Digital Edge';
        quoteAccountName   = '';
        billingName        = '';
        billingStreet      = '';
        billingCity        = '';
        billingState       = '';
        billingPostal      = '';
        billingCountry     = '';
        requestedDeliveryDateStr = '';
        expirationDateStr  = '';
        initialTermStr     = '';
        showInitialTerm    = false;
        termsHeading       = pdfLabels.get('Heading_Terms_NonBinding');
    }
}