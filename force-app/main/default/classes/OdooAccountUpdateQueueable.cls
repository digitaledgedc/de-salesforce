/**
 * OdooAccountUpdateQueueable
 * SFDC-361: Syncs Account changes (Portal Code, Tax ID, Credit Limit MRC/NRC) to Odoo ("Boss").
 *
 * Same endpoint as NEW-A (OdooBanSyncQueueable.buildNewAPayload): POST /api/v1/create_partner,
 * which per DE Salesforce Odoo Integration Mapping Final.xlsx (NEW-A sheet) "Covers: Create &
 * Update Account" — an update is the same create_partner call with partner_id populated.
 * Kept fully standalone from OdooBanSyncQueueable (duplicates the same payload shape) to avoid
 * touching that production-critical order/BAN provisioning path.
 *
 * Chained from AccountTriggerHandler.handleAfterUpdate when any of Portal_Code__c, Tax_ID__c,
 * Credit_Limit_MRC__c, Credit_Limit_NRC__c, Payment_Terms__c changes to a non-null value. Fires
 * regardless of whether the Account already has an Odoo_Partner_ID__c — when absent, this call
 * effectively performs the same create NEW-A would have; NEW-A's own "skip if Odoo_Partner_ID__c
 * already set" check (OdooBanSyncQueueable lines 156-162) means a later real NEW-A run won't
 * double-create.
 *
 * Payment Terms (property_payment_term_id) is sent as the raw Payment_Terms__c picklist label
 * (e.g. "30 Days"), NOT an integer — the mapping sheet types this field as an Odoo integer id,
 * but there's no label→id mapping yet (unlike Invoice_Frequency__mdt for BAN sync). Sending the
 * label is a deliberate stopgap; switch to a real id lookup once that mapping exists.
 *
 * Every callout stamps Account.Odoo_Sync_Status__c / Odoo_Sync_Error__c / Odoo_Sync_Payload__c
 * (existing fields, same names/picklist as already used elsewhere on Account) so the outcome is
 * visible on the record. Errors are ALSO written to DE_Integration_Error__c with
 * IP_Reference__c = 'ACCT-UPDATE' for the retry queue.
 */
public without sharing class OdooAccountUpdateQueueable implements Queueable, Database.AllowsCallouts {

    private List<Id> accountIds;
    private Map<Id, Set<String>> changedFieldsByAccountId;

    public OdooAccountUpdateQueueable(List<Id> accountIds) {
        this.accountIds = accountIds;
        this.changedFieldsByAccountId = null;
    }

    /** changedFieldsByAccountId: per-account set of Account field API names that actually
     *  changed in the update that triggered this sync (e.g. 'Portal_Code__c', 'BillingStreet').
     *  buildPartnerPayload only includes a payload field when its source SFDC field is in this
     *  set, so unrelated already-populated fields aren't re-sent on every sync (SFDC-147). A
     *  null value here (or no entry for a given Account) falls back to "include every populated
     *  field", preserving the old behavior for any caller that doesn't track changed fields. */
    public OdooAccountUpdateQueueable(List<Id> accountIds, Map<Id, Set<String>> changedFieldsByAccountId) {
        this.accountIds = accountIds;
        this.changedFieldsByAccountId = changedFieldsByAccountId;
    }

    public void execute(QueueableContext ctx) {
        System.debug('INTEGRATION ▶ OdooAccountUpdateQueueable — START | Accounts: ' + accountIds);
        OdooIntegrationSettings__c settings = OdooIntegrationSettings__c.getOrgDefaults();

        List<Account> accounts = [
            SELECT Id, Name, BillingStreet, BillingCity, BillingCountry, Phone,
                   CurrencyIsoCode, Portal_Code__c, Odoo_Partner_ID__c, Preferred_Language__c,
                   Tax_ID__c, Credit_Limit_MRC__c, Credit_Limit_NRC__c, Payment_Terms__c,
                   DE_Entity__c, Company_Code__c
            FROM Account
            WHERE Id IN :accountIds
        ];

        // Derive company/country from the Account's own DE Subsidiary (DE_Entity__c) via
        // Site__c — NOT from any Order's Operation_Site__c (SFDC-147). Operation_Site__c is
        // a per-order provisioning field that's frequently null at the Account level (no
        // order in progress yet, or an existing Account whose Orders predate that field),
        // so deriving company_id the same way OdooBanSyncQueueable does for a brand-new
        // Order silently produced company_id=false whenever none of an Account's Orders had
        // Operation_Site__c set. Site__c.DE_Entity__c ("DE Subsidiary") is the authoritative
        // link from a physical site to its billing legal entity (per that field's own
        // description) and is confirmed consistent in DE_PROD — every DE_Entity__c maps to
        // exactly one Odoo_Company_ID__c/Odoo_Country_ID__c across all of its Site__c
        // records, so picking any one match is safe.
        Set<Id> entityIds = new Set<Id>();
        for (Account a : accounts) {
            if (a.DE_Entity__c != null) entityIds.add(a.DE_Entity__c);
        }
        Map<Id, Integer> entityCompanyMap = new Map<Id, Integer>();
        Map<Id, Integer> entityCountryMap = new Map<Id, Integer>();
        if (!entityIds.isEmpty()) {
            for (Site__c s : [
                SELECT DE_Entity__c, Odoo_Company_ID__c, Odoo_Country_ID__c
                FROM Site__c
                WHERE DE_Entity__c IN :entityIds AND Odoo_Company_ID__c > 0
            ]) {
                if (!entityCompanyMap.containsKey(s.DE_Entity__c)) {
                    entityCompanyMap.put(s.DE_Entity__c, Integer.valueOf(s.Odoo_Company_ID__c));
                }
                if (s.Odoo_Country_ID__c != null && s.Odoo_Country_ID__c > 0
                        && !entityCountryMap.containsKey(s.DE_Entity__c)) {
                    entityCountryMap.put(s.DE_Entity__c, Integer.valueOf(s.Odoo_Country_ID__c));
                }
            }
        }
        Map<Id, Integer> accountCompanyMap = new Map<Id, Integer>();
        Map<Id, Integer> accountCountryMap = new Map<Id, Integer>();
        for (Account a : accounts) {
            if (a.DE_Entity__c == null) continue;
            if (entityCompanyMap.containsKey(a.DE_Entity__c)) {
                accountCompanyMap.put(a.Id, entityCompanyMap.get(a.DE_Entity__c));
            }
            if (entityCountryMap.containsKey(a.DE_Entity__c)) {
                accountCountryMap.put(a.Id, entityCountryMap.get(a.DE_Entity__c));
            }
        }

        List<Account> accountsToUpdate = new List<Account>();
        List<DE_Integration_Error__c> errors = new List<DE_Integration_Error__c>();

        for (Account acc : accounts) {
            Integer companyId = accountCompanyMap.get(acc.Id);
            Integer countryId = accountCountryMap.get(acc.Id);
            Integer existingPartnerId = (acc.Odoo_Partner_ID__c != null && acc.Odoo_Partner_ID__c > 0)
                ? Integer.valueOf(acc.Odoo_Partner_ID__c) : null;

            // Changed-fields filtering only applies to a genuine UPDATE (existingPartnerId
            // already set). When there's no Odoo_Partner_ID__c yet, this call is effectively
            // a first-time create (per this class's own header comment) — Odoo needs the full
            // profile then, not just whichever field happened to trigger this particular sync,
            // so force changedFields to null (= "include everything populated") in that case.
            Set<String> changedFields = (existingPartnerId != null && changedFieldsByAccountId != null)
                ? changedFieldsByAccountId.get(acc.Id) : null;
            String payload = buildPartnerPayload(acc, companyId, countryId, existingPartnerId, changedFields, settings);
            System.debug('INTEGRATION ▶ ACCT-UPDATE — Calling /api/v1/create_partner for Account: ' + acc.Id
                + ' | partner_id: ' + existingPartnerId);
            System.debug('INTEGRATION ▶ ACCT-UPDATE — Payload: ' + payload);

            OdooCalloutService.Response resp = OdooCalloutService.post('/api/v1/create_partner', payload);
            System.debug('INTEGRATION ▶ ACCT-UPDATE — Response | success: ' + resp.isSuccess
                + ' | rawBody: ' + resp.rawBody + ' | error: ' + resp.errorBody);

            Account accUpdate = new Account(Id = acc.Id);
            accUpdate.Odoo_Sync_Payload__c = payload; // always capture the request payload

            if (resp.isSuccess) {
                Integer partnerId = parseIntFromResult(resp.rawBody, 'partner_id');
                if (partnerId != null && partnerId > 0) {
                    if (existingPartnerId == null || existingPartnerId != partnerId) {
                        accUpdate.Odoo_Partner_ID__c = partnerId;
                    }
                    accUpdate.Odoo_Sync_Status__c = 'Acknowledged';
                    accUpdate.Odoo_Sync_Error__c = null;
                } else {
                    // partner_id = 0: same collision case NEW-A already documents — Odoo silently
                    // rejected creation, most likely the ns_portal_code unique constraint.
                    String sfId = String.valueOf(acc.Id);
                    String sfCode = sfId.length() > 8 ? sfId.substring(sfId.length() - 8) : sfId;
                    String collisionMsg = 'ACCT-UPDATE succeeded but returned partner_id=0. '
                        + 'Search Odoo for res.partner where ns_portal_code = \'' + sfCode + '\', '
                        + 'copy that record\'s ID to Account.Odoo_Partner_ID__c, then re-save Portal Code to retry. '
                        + 'Raw response: ' + resp.rawBody;
                    accUpdate.Odoo_Sync_Status__c = 'Failed - Manual Review Required';
                    accUpdate.Odoo_Sync_Error__c = collisionMsg;
                    errors.add(newError(String.valueOf(acc.Id), collisionMsg, payload));
                }
            } else {
                accUpdate.Odoo_Sync_Status__c = 'Failed - Manual Review Required';
                accUpdate.Odoo_Sync_Error__c = resp.errorBody;
                errors.add(newError(String.valueOf(acc.Id), resp.errorBody, payload));
            }
            accountsToUpdate.add(accUpdate);
        }

        // ── All callouts done — safe to DML ──────────────────────────────────
        if (!errors.isEmpty()) insert errors;
        if (!accountsToUpdate.isEmpty()) update accountsToUpdate;
    }

    // ─── Payload builder ─────────────────────────────────────────────────────
    // Mirrors OdooBanSyncQueueable.buildNewAPayload field-for-field, plus partner_id
    // when this is an update rather than a first-time create.

    /** true when changedFields is null (no change-tracking available — include everything
     *  populated, the old behavior) or actually contains this field's API name. */
    private static Boolean included(Set<String> changedFields, String fieldApiName) {
        return changedFields == null || changedFields.contains(fieldApiName);
    }

    @TestVisible
    private String buildPartnerPayload(Account acc, Integer companyId, Integer countryId,
            Integer partnerId, Set<String> changedFields, OdooIntegrationSettings__c settings) {
        JSONGenerator gen = JSON.createGenerator(false);
        gen.writeStartObject();
        gen.writeFieldName('params');
        gen.writeStartObject();
        gen.writeStringField('username', settings.Username__c != null ? settings.Username__c : '');
        gen.writeStringField('password', settings.Password__c != null ? settings.Password__c : '');
        gen.writeFieldName('data');
        gen.writeStartObject();

        gen.writeStringField('sf_account_id', String.valueOf(acc.Id));
        if (partnerId != null) {
            gen.writeNumberField('partner_id', partnerId);
        }
        gen.writeStringField('name', acc.Name != null ? acc.Name : '');
        gen.writeBooleanField('is_company', true);
        gen.writeBooleanField('ns_finance_approved', true);
        gen.writeStringField('company_type', 'company');
        gen.writeStringField('nrs_company_type', 'company');
        gen.writeBooleanField('ns_is_customer', true);
        gen.writeBooleanField('ns_is_end_customer', false);
        // x_studio_company_code: unique constraint in Odoo, AND Odoo hard-rejects any value
        // over 8 characters ("Company Code must not have more than 8 characters") — confirmed
        // live against DE_PARTIAL. Prefer the Account's own Company_Code__c (Text,
        // unique=true, externalId=true — genuinely enforced unique by SFDC itself) only when
        // it's populated AND fits that 8-char limit (55 of 2,596 populated values in DE_PROD
        // are 9-11 chars, e.g. "KRENDCUST1"/"ZenlayerSH" — truncating those would collide,
        // e.g. "KRENDCUST1"/"KRENDCUST2" both truncate to "KRENDCUS"); fall back to the last
        // 8 chars of the SF Account ID otherwise.
        String companyCode;
        if (String.isNotBlank(acc.Company_Code__c) && acc.Company_Code__c.length() <= 8) {
            companyCode = acc.Company_Code__c;
        } else {
            String sfId = String.valueOf(acc.Id);
            companyCode = sfId.length() > 8 ? sfId.substring(sfId.length() - 8) : sfId;
        }
        gen.writeStringField('x_studio_company_code', companyCode);
        if (companyId != null && companyId > 0) {
            gen.writeNumberField('company_id', companyId);
        } else {
            gen.writeBooleanField('company_id', false);
        }
        gen.writeBooleanField('parent_id', false);
        // Only send these when SFDC actually has a value AND (when change-tracking is
        // available) the field actually changed in this update — writing an explicit ""
        // tells Odoo to blank the field, clobbering whatever value it already has whenever
        // this Account happens to be missing that one field, and re-sending an unchanged
        // value on every sync is exactly the "full payload every time" Darren flagged (SFDC-147).
        if (included(changedFields, 'BillingStreet') && String.isNotBlank(acc.BillingStreet)) {
            gen.writeStringField('street', acc.BillingStreet);
        }
        if (included(changedFields, 'BillingCity') && String.isNotBlank(acc.BillingCity)) {
            gen.writeStringField('city', acc.BillingCity);
        }
        if (included(changedFields, 'BillingCountry') && String.isNotBlank(acc.BillingCountry)) {
            gen.writeStringField('country_name', acc.BillingCountry);
        }
        if (included(changedFields, 'Phone') && String.isNotBlank(acc.Phone)) {
            gen.writeStringField('phone', acc.Phone);
        }
        // email: no source field exists on Account for this yet — omitted rather than sent
        // as a permanent blank that could clobber a real value Odoo already has.
        // Website: send empty string — Azure WAF blocks URLs embedded in POST bodies (SSRF rule),
        // same as buildNewAPayload in OdooBanSyncQueueable. Deliberately always blank, so this
        // one is unaffected by SFDC-147 — left as-is.
        gen.writeStringField('website', '');
        if (included(changedFields, 'Portal_Code__c') && String.isNotBlank(acc.Portal_Code__c)) {
            gen.writeStringField('ns_portal_code', acc.Portal_Code__c);
        }
        if (included(changedFields, 'Tax_ID__c') && String.isNotBlank(acc.Tax_ID__c)) {
            gen.writeStringField('vat', acc.Tax_ID__c);
        }
        if (included(changedFields, 'Credit_Limit_MRC__c') && acc.Credit_Limit_MRC__c != null) {
            gen.writeNumberField('ns_credit_limit_mrc', acc.Credit_Limit_MRC__c);
        }
        if (included(changedFields, 'Credit_Limit_NRC__c') && acc.Credit_Limit_NRC__c != null) {
            gen.writeNumberField('ns_credit_limit_nrc', acc.Credit_Limit_NRC__c);
        }
        // property_payment_term_id is typed as an integer in the mapping sheet, but there's no
        // Payment_Terms__c label -> Odoo id mapping yet (unlike Invoice_Frequency__mdt for BAN
        // sync) — sending the picklist label itself per explicit direction until that mapping exists.
        if (included(changedFields, 'Payment_Terms__c') && acc.Payment_Terms__c != null) {
            gen.writeStringField('property_payment_term_id', acc.Payment_Terms__c);
        }
        gen.writeNumberField('customer_rank', 1);
        gen.writeStringField('currency_id', acc.CurrencyIsoCode != null ? acc.CurrencyIsoCode : 'USD');
        String odooLang = mapPreferredLanguageToOdooLang(acc.Preferred_Language__c);
        if (odooLang != null) {
            gen.writeStringField('lang', odooLang);
        } else {
            gen.writeBooleanField('lang', false);
        }
        gen.writeBooleanField('is_from_sf', true);

        gen.writeEndObject(); // data
        gen.writeEndObject(); // params
        gen.writeEndObject(); // root
        return gen.getAsString();
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    @TestVisible
    private static String mapPreferredLanguageToOdooLang(String sfLabel) {
        if (sfLabel == null || sfLabel == '') return null;
        Map<String, String> langMap = new Map<String, String>{
            'English'  => 'en_US',
            'Chinese'  => 'zh_CN',
            'Japanese' => 'ja_JP',
            'Korean'   => 'ko_KR'
        };
        return langMap.get(sfLabel);
    }

    private static Integer parseIntFromResult(String rawBody, String fieldName) {
        try {
            Map<String,Object> parsed = (Map<String,Object>) JSON.deserializeUntyped(rawBody);
            Map<String,Object> result = (Map<String,Object>) parsed.get('result');
            if (result != null && result.get(fieldName) != null) {
                return Integer.valueOf(result.get(fieldName));
            }
        } catch (Exception e) {
            // fall through — caller logs missing field
        }
        return null;
    }

    private static DE_Integration_Error__c newError(String recordId, String msg, String payload) {
        return new DE_Integration_Error__c(
            Record_Id__c        = recordId,
            IP_Reference__c     = 'ACCT-UPDATE',
            Error_Message__c    = msg,
            Status__c           = 'Open',
            Request_Payload__c  = payload
        );
    }
}