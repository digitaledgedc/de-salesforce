/**
 * OdooBanSyncQueueable
 * NEW-A + NEW-B: Syncs BillingAccount__c (BAN) records to Odoo.
 * Chained from BillingAccountTriggerHandler when a BAN's Status changes to Active.
 *
 * Sequencing within execute():
 *   NEW-A (POST /api/v1/create_partner) — only for Accounts without Odoo_Partner_ID__c.
 *            One callout per unique Account. Writes Account.Odoo_Partner_ID__c.
 *   NEW-B (POST /api/v1/create_ban)     — one callout per BAN.
 *            Writes Odoo_BAN_ID__c, Odoo_Partner_ID__c, Odoo_Invoice_Freq_ID__c on BillingAccount__c.
 *
 * All callouts run before any DML (Apex rule: no DML between callouts).
 * Errors written to DE_Integration_Error__c with IP_Reference__c = 'NEW-A' or 'NEW-B'.
 *
 * Field name source: DE Salesforce Odoo Integration Mapping Final.xlsx (sheets NEW-A Account Sync,
 * NEW-B BAN Sync). Sample payload takes precedence over field mapping table where names differ.
 */
public without sharing class OdooBanSyncQueueable implements Queueable, Database.AllowsCallouts {

    private List<Id> banIds;
    private List<Id> chainOrderIds;
    private String   chainTarget;  // 'IP-1' (default) or 'IP-4'

    public OdooBanSyncQueueable(List<Id> banIds) {
        this.banIds = banIds;
        this.chainOrderIds = new List<Id>();
        this.chainTarget = 'IP-1';
    }

    /** Chaining constructor: after BAN sync, enqueue SendNewOrdersQueueable (IP-1) for these Order IDs. */
    public OdooBanSyncQueueable(List<Id> banIds, List<Id> chainOrderIds) {
        this.banIds = banIds;
        this.chainOrderIds = chainOrderIds != null ? chainOrderIds : new List<Id>();
        this.chainTarget = 'IP-1';
    }

    /** Chaining constructor with explicit target: 'IP-1' → SendNewOrdersQueueable,
     *  'IP-4' → SendChangeOrdersQueueable. */
    public OdooBanSyncQueueable(List<Id> banIds, List<Id> chainOrderIds, String chainTarget) {
        this.banIds = banIds;
        this.chainOrderIds = chainOrderIds != null ? chainOrderIds : new List<Id>();
        this.chainTarget = chainTarget != null ? chainTarget : 'IP-1';
    }

    public void execute(QueueableContext ctx) {
        System.debug('INTEGRATION ▶ OdooBanSyncQueueable — START | BANs: ' + banIds
            + ' | chainOrderIds: ' + chainOrderIds);
        OdooIntegrationSettings__c settings = OdooIntegrationSettings__c.getOrgDefaults();
        System.debug('INTEGRATION ▶ OdooBanSyncQueueable — Settings | IP1_Enabled: ' + settings.IP1_Enabled__c
            + ' | Base_URL: ' + settings.Base_URL__c);

        // Invoice Frequency CMT — maps picklist label to Odoo integer ID
        Map<String, Integer> freqMap = new Map<String, Integer>();
        for (Invoice_Frequency__mdt f : Invoice_Frequency__mdt.getAll().values()) {
            if (f.SF_Frequency__c != null && f.Odoo_Frequency_Id__c != null
                    && f.Odoo_Frequency_Id__c > 0) {
                freqMap.put(f.SF_Frequency__c, Integer.valueOf(f.Odoo_Frequency_Id__c));
            }
        }
        System.debug('INTEGRATION ▶ OdooBanSyncQueueable — FreqMap: ' + freqMap);

        // Site → Company ID + Country ID maps
        Map<String, Integer> siteCompanyMap = new Map<String, Integer>();
        Map<String, Integer> siteCountryMap = new Map<String, Integer>();
        for (Odoo_Site__mdt s : [
            SELECT Odoo_Site_Code__c, Odoo_Company_ID__c, Odoo_Country_ID__c
            FROM Odoo_Site__mdt
            WHERE Is_Active__c = true AND Odoo_Company_ID__c > 0
        ]) {
            siteCompanyMap.put(s.Odoo_Site_Code__c, Integer.valueOf(s.Odoo_Company_ID__c));
            if (s.Odoo_Country_ID__c != null && s.Odoo_Country_ID__c > 0) {
                siteCountryMap.put(s.Odoo_Site_Code__c, Integer.valueOf(s.Odoo_Country_ID__c));
            }
        }

        List<BillingAccount__c> bans = [
            SELECT Id, Name,
                   Account__c,
                   Account__r.Name,
                   Account__r.BillingStreet,
                   Account__r.BillingCity,
                   Account__r.Phone,
                   Account__r.Website,
                   Account__r.CurrencyIsoCode,
                   Account__r.Odoo_Partner_ID__c,BAN_ID_INV_Label__c,BAN_ID_Reference__c,
                   Odoo_Partner_ID__c,
                   Odoo_BAN_ID__c,CurrencyISOCode,
                   Alias__c,Invoice_Currency__c,Billing_Contact__c, Billing_Contact__r.Name,Billing_Contact__r.Email,
            	   Billing_Contact__r.Phone,Billing_Contact__r.Odoo_Partner_ID__c,Billing_Contact__r.CurrencyISOCode,
                   Invoice_Presentment__c,Different_Invoice_Currency__c,
                   Charge_Period_Presentment__c,
                   Additional_Invoice_Email__c,
                   Invoice_Frequency__c,
                   InvoiceDeliveryMode__c
            FROM BillingAccount__c
            WHERE Id IN :banIds
              AND Odoo_BAN_ID__c = null
        ];

        System.debug('INTEGRATION ▶ OdooBanSyncQueueable — BANs needing sync: ' + bans.size());
        if (bans.isEmpty()) {
            System.debug('INTEGRATION ▶ OdooBanSyncQueueable — No BANs need sync, skipping to chain');
            chainIfNeeded();
            return;
        }

        // ── Derive company ID + country ID from first order on each BAN ──
        Set<Id> banIdSet = new Map<Id, BillingAccount__c>(bans).keySet();
        Map<Id, Integer> banCompanyMap = new Map<Id, Integer>();
        Map<Id, Integer> banCountryMap = new Map<Id, Integer>();
        // Also track Account → company/country for NEW-A payload
        Map<Id, Integer> accountCompanyMap = new Map<Id, Integer>();
        Map<Id, Integer> accountCountryMap = new Map<Id, Integer>();
        for (Order o : [
            SELECT BillingAccount__c, BillingAccount__r.Account__c, Operation_Site__c,BillingAccount__r.Billing_Contact__c
            FROM Order
            WHERE BillingAccount__c IN :banIdSet
              AND Operation_Site__c != null
            ORDER BY CreatedDate ASC
        ]) {
            if (!banCompanyMap.containsKey(o.BillingAccount__c)
                    && siteCompanyMap.containsKey(o.Operation_Site__c)) {
                banCompanyMap.put(o.BillingAccount__c, siteCompanyMap.get(o.Operation_Site__c));
            }
            if (!banCountryMap.containsKey(o.BillingAccount__c)
                    && siteCountryMap.containsKey(o.Operation_Site__c)) {
                banCountryMap.put(o.BillingAccount__c, siteCountryMap.get(o.Operation_Site__c));
            }
            // Derive per-account from the first BAN's order
            Id acctId = o.BillingAccount__r.Account__c;
            if (acctId != null && !accountCompanyMap.containsKey(acctId)
                    && siteCompanyMap.containsKey(o.Operation_Site__c)) {
                accountCompanyMap.put(acctId, siteCompanyMap.get(o.Operation_Site__c));
            }
            if (acctId != null && !accountCountryMap.containsKey(acctId)
                    && siteCountryMap.containsKey(o.Operation_Site__c)) {
                accountCountryMap.put(acctId, siteCountryMap.get(o.Operation_Site__c));
            }
        }

        // ── Step 1: Collect unique Accounts that need NEW-A ───────────────────
        // Priority: Account.Odoo_Partner_ID__c → BAN.Odoo_Partner_ID__c (historical migration) → NEW-A callout
        // Historical BANs already have Odoo_Partner_ID__c loaded from the BAN export (the Account's Odoo
        // res.partner ID). Use that directly so NEW-A is only called for genuinely new accounts.
        Map<Id, Integer> partnerIdByAccount = new Map<Id, Integer>();
        Set<Id> accountsNeedingNewA = new Set<Id>();
        Map<Id, Integer> oddoIdByContact = new Map<Id, Integer>();
		Set<Id> billingContactNeedingNewB = new Set<Id>();
        for (BillingAccount__c ban : bans) {
            System.debug('INTEGRATION ▶ OdooBanSyncQueueable — Evaluating BAN: ' + ban.Id
                + ' (' + ban.Name + ') | Account: ' + ban.Account__c
                + ' | Acct Odoo_Partner_ID: ' + ban.Account__r.Odoo_Partner_ID__c
                + ' | BAN Odoo_Partner_ID: ' + ban.Odoo_Partner_ID__c
                + ' | BAN Odoo_BAN_ID: ' + ban.Odoo_BAN_ID__c);
            if (ban.Account__c == null && ban.Billing_Contact__c == null) continue;
            if (!partnerIdByAccount.containsKey(ban.Account__c)) {
                if (ban.Account__r.Odoo_Partner_ID__c != null
                        && ban.Account__r.Odoo_Partner_ID__c > 0) {
                    // Account already synced (NEW-A previously ran or field was set manually)
                    // Guard > 0: a value of 0 means a previous run received a bad response from Odoo
                    // and must not be reused — treat as unsynced and re-run NEW-A.
                    partnerIdByAccount.put(ban.Account__c, Integer.valueOf(ban.Account__r.Odoo_Partner_ID__c));
                } else if (ban.Odoo_Partner_ID__c != null
                        && ban.Odoo_Partner_ID__c != '0') {
                    // Historical BAN: partner ID loaded from Odoo export — use it directly, skip NEW-A
                    partnerIdByAccount.put(ban.Account__c, Integer.valueOf(ban.Odoo_Partner_ID__c));
                } else {
                    accountsNeedingNewA.add(ban.Account__c);
                }
            }
            
            if (!oddoIdByContact.containsKey(ban.Billing_Contact__c)) {
                if (ban.Billing_Contact__r.Odoo_Partner_ID__c != null
                        && ban.Billing_Contact__r.Odoo_Partner_ID__c > 0) {
                    // Account already synced (NEW-A previously ran or field was set manually)
                    // Guard > 0: a value of 0 means a previous run received a bad response from Odoo
                    // and must not be reused — treat as unsynced and re-run NEW-B.
                    oddoIdByContact.put(ban.Billing_Contact__c, Integer.valueOf(ban.Billing_Contact__r.Odoo_Partner_ID__c));
                }else {
                    billingContactNeedingNewB.add(ban.Billing_Contact__c );
                }
            }
        }

        // ── Step 2: Build Account objects for NEW-A payload ───────────────────
        // Pull Name/address from the first BAN relationship we saw per Account
        Map<Id, BillingAccount__c> firstBanByAccount = new Map<Id, BillingAccount__c>();
        Map<Id, BillingAccount__c> firstBanByContact = new Map<Id, BillingAccount__c>();
        for (BillingAccount__c ban : bans) {
            if (ban.Account__c != null && accountsNeedingNewA.contains(ban.Account__c)
                    && !firstBanByAccount.containsKey(ban.Account__c)) {
                firstBanByAccount.put(ban.Account__c, ban);
            }
            if (ban.Billing_Contact__c != null && billingContactNeedingNewB.contains(ban.Billing_Contact__c)
                    && !firstBanByContact.containsKey(ban.Billing_Contact__c)) {
                firstBanByContact.put(ban.Billing_Contact__c, ban);
            }
        }

        // ── Collect for DML after all callouts ───────────────────────────────
        List<Account>            accountsToUpdate = new List<Account>();
        List<Contact>            contactsToUpdate = new List<Contact>();
        List<BillingAccount__c>  bansToUpdate     = new List<BillingAccount__c>();
        List<DE_Integration_Error__c> errors      = new List<DE_Integration_Error__c>();

        // ── Step 3: NEW-A callouts — one per unsynced Account ─────────────────
        System.debug('INTEGRATION ▶ OdooBanSyncQueueable — Accounts needing NEW-A: ' + accountsNeedingNewA);
        System.debug('INTEGRATION ▶ OdooBanSyncQueueable — Accounts with existing partner_id: ' + partnerIdByAccount);
        for (Id accountId : accountsNeedingNewA) {
            BillingAccount__c sample = firstBanByAccount.get(accountId);
            Integer acctCompanyId = accountCompanyMap.get(accountId);
            Integer acctCountryId = accountCountryMap.get(accountId);
            String currCode = sample.Account__r.CurrencyIsoCode;
            String payload = buildNewAPayload(accountId, sample, acctCompanyId, acctCountryId, currCode, settings);
            System.debug('INTEGRATION ▶ NEW-A — Calling /api/v1/create_partner for Account: ' + accountId
                + ' (' + sample.Account__r.Name + ')');
            System.debug('INTEGRATION ▶ NEW-A — Payload: ' + payload);

            OdooCalloutService.Response resp =
                OdooCalloutService.post('/api/v1/create_partner', payload);

            System.debug('INTEGRATION ▶ NEW-A — Response | success: ' + resp.isSuccess
                + ' | rawBody: ' + resp.rawBody + ' | error: ' + resp.errorBody);
            if (resp.isSuccess) {
                Integer partnerId = parseIntFromResult(resp.rawBody, 'partner_id');
                System.debug('INTEGRATION ▶ NEW-A — Parsed partner_id: ' + partnerId);
                if (partnerId != null && partnerId > 0) {
                    partnerIdByAccount.put(accountId, partnerId);
                    accountsToUpdate.add(new Account(Id = accountId, Odoo_Partner_ID__c = partnerId));
                } else {
                    // partner_id = 0: Odoo silently rejected creation — most likely the
                    // ns_portal_code unique constraint was violated by a previous run that
                    // created the partner without writing the ID back to Salesforce.
                    // Resolution: find the partner in Odoo by searching ns_portal_code = '<code>'
                    // (the last 8 chars of the SF Account ID), then set Account.Odoo_Partner_ID__c
                    // to that integer ID and re-run this queueable — NEW-A will be skipped and
                    // NEW-B will proceed with the correct partner_id.
                    String sfId = String.valueOf(accountId);
                    String sfCode = sfId.length() > 8 ? sfId.substring(sfId.length() - 8) : sfId;
                    errors.add(newError(String.valueOf(accountId), 'NEW-A',
                        'NEW-A succeeded but returned partner_id=0. '
                        + 'Search Odoo for res.partner where ns_portal_code = \'' + sfCode + '\', '
                        + 'copy that record\'s ID to Account.Odoo_Partner_ID__c, then re-run. '
                        + 'Raw response: ' + resp.rawBody));
                }
            } else {
                errors.add(newError(String.valueOf(accountId), 'NEW-A', resp.errorBody, payload));
            }
        }
        
		 for (Id conId : billingContactNeedingNewB) {
            BillingAccount__c sample = firstBanByContact.get(conId);
            String payload = buildNewCPayload(conId, sample, settings);
            System.debug('INTEGRATION ▶ NEW-C — Calling /api/v1/create_partner for Contact: ' + conId
                + ' (' + sample.Account__r.Name + ')');
            System.debug('INTEGRATION ▶ NEW-C — Payload: ' + payload);

            OdooCalloutService.Response resp =
                OdooCalloutService.post('/api/v1/create_partner', payload);

            System.debug('INTEGRATION ▶ NEW-C — Response | success: ' + resp.isSuccess
                + ' | rawBody: ' + resp.rawBody + ' | error: ' + resp.errorBody);
            if (resp.isSuccess) {
                Integer partnerId = parseIntFromResult(resp.rawBody, 'partner_id');
                System.debug('INTEGRATION ▶ NEW-C — Parsed partner_id: ' + partnerId);
                if (partnerId != null && partnerId > 0) {
                    oddoIdByContact.put(conId, partnerId);
                    contactsToUpdate.add(new Contact(Id = conId, Odoo_Partner_ID__c = partnerId));
                } else {
                    // partner_id = 0: Odoo silently rejected creation — most likely the
                    // ns_portal_code unique constraint was violated by a previous run that
                    // created the partner without writing the ID back to Salesforce.
                    // Resolution: find the partner in Odoo by searching ns_portal_code = '<code>'
                    // (the last 8 chars of the SF Account ID), then set Account.Odoo_Partner_ID__c
                    // to that integer ID and re-run this queueable — NEW-A will be skipped and
                    // NEW-B will proceed with the correct partner_id.
                    String sfId = String.valueOf(conId);
                    String sfCode = sfId.length() > 8 ? sfId.substring(sfId.length() - 8) : sfId;
                    errors.add(newError(String.valueOf(conId), 'NEW-A',
                        'NEW-C succeeded but returned partner_id=0. '
                        + 'Search Odoo for res.partner where ns_portal_code = \'' + sfCode + '\', '
                        + 'copy that record\'s ID to Contact.Odoo_Partner_ID__c, then re-run. '
                        + 'Raw response: ' + resp.rawBody));
                }
            } else {
                errors.add(newError(String.valueOf(conId), 'NEW-C', resp.errorBody, payload));
            }
        }
        // ── Step 4: NEW-B callouts — one per BAN ─────────────────────────────
        System.debug('INTEGRATION ▶ OdooBanSyncQueueable — Starting NEW-B for ' + bans.size() + ' BANs');
        for (BillingAccount__c ban : bans) {
            Integer partnerId = partnerIdByAccount.get(ban.Account__c);
            Integer contactId = oddoIdByContact.get(ban.Billing_Contact__c);
            System.debug('INTEGRATION ▶ NEW-B — BAN: ' + ban.Id + ' (' + ban.Name
                + ') | partner_id: ' + partnerId);
            if (partnerId == null || partnerId <= 0 ) {
                // Account partner not available — NEW-A either failed or returned 0
                String skipMsg = 'NEW-B skipped — Account Odoo partner_id unavailable or zero. '
                    + (ban.Account__c == null
                        ? 'BAN has no Account.'
                        : 'Check NEW-A error for Account ' + ban.Account__c + '.');
                errors.add(newError(String.valueOf(ban.Id), 'NEW-B', skipMsg));
                bansToUpdate.add(new BillingAccount__c(
                    Id = ban.Id,
                    Odoo_Sync_Status__c = 'Sync Failed',
                    Odoo_Sync_Error__c  = skipMsg
                ));
                continue;
            }

            // Guard: BAN name must contain a hyphen — Odoo's _compute_next_ban_id
            // splits on '-' and crashes with "list index out of range" if absent.
            if (ban.Name == null || !ban.Name.contains('-')) {
                String skipMsg = 'BAN name "' + ban.Name + '" has no hyphen — Odoo requires PREFIX-NNNNN format. '
                    + 'Fix BAN_Number__c before retrying.';
                errors.add(newError(String.valueOf(ban.Id), 'NEW-B', skipMsg));
                bansToUpdate.add(new BillingAccount__c(
                    Id = ban.Id,
                    Odoo_Sync_Status__c = 'Sync Failed',
                    Odoo_Sync_Error__c  = skipMsg
                ));
                continue;
            }

            Integer deCompanyId = banCompanyMap.containsKey(ban.Id)
                ? banCompanyMap.get(ban.Id)
                : null;
            String payload = buildNewBPayload(ban, partnerId, deCompanyId,contactId, freqMap, settings);
            System.debug('INTEGRATION ▶ NEW-B — Calling /api/v1/create_ban for BAN: ' + ban.Id
                + ' | deCompanyId: ' + deCompanyId + ' | freqLabel: ' + ban.Invoice_Frequency__c);
            System.debug('INTEGRATION ▶ NEW-B — Payload: ' + payload);

            OdooCalloutService.Response resp =
                OdooCalloutService.post('/api/v1/create_ban', payload);

            System.debug('INTEGRATION ▶ NEW-B — Response | success: ' + resp.isSuccess
                + ' | rawBody: ' + resp.rawBody + ' | error: ' + resp.errorBody);

            BillingAccount__c banUpdate = new BillingAccount__c(Id = ban.Id);
            banUpdate.Odoo_Sync_Payload__c = payload; // always capture the request payload

            if (resp.isSuccess) {
                Integer banId     = parseIntFromResult(resp.rawBody, 'ban_id');
                Integer bPartner  = parseIntFromResult(resp.rawBody, 'partner_id');
                Integer freqId    = parseIntFromResult(resp.rawBody, 'invoice_frequency_id');
                System.debug('INTEGRATION ▶ NEW-B — Parsed | ban_id: ' + banId
                    + ' | partner_id: ' + bPartner + ' | freq_id: ' + freqId);

                if (banId != null) banUpdate.Odoo_BAN_ID__c             = banId;
                if (bPartner != null) banUpdate.Odoo_Partner_ID__c      = String.valueOf(bPartner);
                if (freqId != null) banUpdate.Odoo_Invoice_Freq_ID__c   = freqId;

                if (banId == null) {
                    String noIdMsg = 'NEW-B succeeded but ban_id missing from response: ' + resp.rawBody;
                    errors.add(newError(String.valueOf(ban.Id), 'NEW-B', noIdMsg));
                    banUpdate.Odoo_Sync_Status__c = 'Sync Failed';
                    banUpdate.Odoo_Sync_Error__c  = noIdMsg;
                } else {
                    banUpdate.Odoo_Sync_Status__c = 'Synced';
                    banUpdate.Odoo_Sync_Error__c  = null;
                }
            } else {
                errors.add(newError(String.valueOf(ban.Id), 'NEW-B', resp.errorBody, payload));
                banUpdate.Odoo_Sync_Status__c = 'Sync Failed';
                banUpdate.Odoo_Sync_Error__c  = resp.errorBody;
            }
            bansToUpdate.add(banUpdate);
        }

        // ── All callouts done — safe to DML ──────────────────────────────────
        System.debug('INTEGRATION ▶ OdooBanSyncQueueable — DML summary | errors: ' + errors.size()
            + ' | accountsToUpdate: ' + accountsToUpdate.size()
            + ' | bansToUpdate: ' + bansToUpdate.size());
        if (!errors.isEmpty())        insert errors;
        if (!accountsToUpdate.isEmpty()) update accountsToUpdate;
        if (!contactsToUpdate.isEmpty()) update contactsToUpdate;
        if (!bansToUpdate.isEmpty())  update bansToUpdate;

        chainIfNeeded();
    }

    /** Chain to the target Queueable (IP-1 or IP-4) after BAN sync completes. */
    private void chainIfNeeded() {
        if (chainOrderIds == null || chainOrderIds.isEmpty()) {
            System.debug('INTEGRATION ▶ OdooBanSyncQueueable — No chain orders, done');
            return;
        }
        OdooIntegrationSettings__c s = OdooIntegrationSettings__c.getOrgDefaults();
        if (!s.IP1_Enabled__c) {
            System.debug('INTEGRATION ▶ OdooBanSyncQueueable — IP1_Enabled is false, skipping chain');
            return;
        }
        if (chainTarget == 'IP-4') {
            System.debug('INTEGRATION ▶ OdooBanSyncQueueable — CHAINING → SendChangeOrdersQueueable (IP-4) | Orders: ' + chainOrderIds);
            System.enqueueJob(new SendChangeOrdersQueueable(chainOrderIds));
        } else {
            System.debug('INTEGRATION ▶ OdooBanSyncQueueable — CHAINING → SendNewOrdersQueueable (IP-1) | Orders: ' + chainOrderIds);
            System.enqueueJob(new SendNewOrdersQueueable(chainOrderIds));
        }
    }

    // ─── Payload builders ────────────────────────────────────────────────────

    @TestVisible
    private String buildNewAPayload(Id accountId, BillingAccount__c sample,
            Integer companyId, Integer countryId, String currencyCode, OdooIntegrationSettings__c settings) {
        JSONGenerator gen = JSON.createGenerator(false);
        gen.writeStartObject();
        gen.writeFieldName('params');
        gen.writeStartObject();
        gen.writeStringField('username', settings.Username__c != null ? settings.Username__c : '');
        gen.writeStringField('password', settings.Password__c != null ? settings.Password__c : '');
        gen.writeFieldName('data');
        gen.writeStartObject();

        gen.writeStringField('sf_account_id', String.valueOf(accountId));
        gen.writeStringField('name', sample.Account__r.Name != null ? sample.Account__r.Name : '');
        gen.writeBooleanField('is_company', true);
        gen.writeBooleanField('ns_finance_approved', true);        
        gen.writeStringField('company_type', 'company');
        gen.writeStringField('nrs_company_type', 'company');
        gen.writeBooleanField('ns_is_customer', true);
        gen.writeBooleanField('ns_is_end_customer', false);
        // x_studio_company_code: unique constraint in Odoo, use last 8 chars of SF Account ID
        String sfId = String.valueOf(accountId);
        String sfCode = sfId.length() > 8 ? sfId.substring(sfId.length() - 8) : sfId;
        gen.writeStringField('x_studio_company_code', sfCode);
        if (companyId != null && companyId > 0) {
            gen.writeNumberField('company_id', companyId);
        } else {
            gen.writeBooleanField('company_id', false);
        }
        gen.writeBooleanField('parent_id', false);
        gen.writeStringField('street',
            sample.Account__r.BillingStreet != null ? sample.Account__r.BillingStreet : '');
        gen.writeStringField('city',
            sample.Account__r.BillingCity != null ? sample.Account__r.BillingCity : '');
        if (countryId != null && countryId > 0) {
            gen.writeNumberField('country_id', countryId);
        }
        gen.writeStringField('phone',
            sample.Account__r.Phone != null ? sample.Account__r.Phone : '');
        gen.writeStringField('email', '');
        // Website: send empty string — Azure WAF blocks URLs embedded in POST bodies (SSRF rule).
        // The Odoo team must add a WAF exclusion for /api/v1/* before real website values can be sent.
        gen.writeStringField('website', '');
        // Required per field mapping
        gen.writeNumberField('customer_rank', 1);
        gen.writeStringField('currency_id', currencyCode != null ? currencyCode : 'USD');
        gen.writeBooleanField('is_from_sf', true);

        gen.writeEndObject(); // data
        gen.writeEndObject(); // params
        gen.writeEndObject(); // root
        return gen.getAsString();
    }

    @TestVisible
    private String buildNewBPayload(BillingAccount__c ban, Integer partnerId,
            Integer deCompanyId,Integer contactId, Map<String, Integer> freqMap,
            OdooIntegrationSettings__c settings) {
        JSONGenerator gen = JSON.createGenerator(false);
        gen.writeStartObject();
        gen.writeFieldName('params');
        gen.writeStartObject();
        gen.writeStringField('username', settings.Username__c != null ? settings.Username__c : '');
        gen.writeStringField('password', settings.Password__c != null ? settings.Password__c : '');
        gen.writeFieldName('data');
        gen.writeStartObject();

        // Required fields
        gen.writeStringField('sf_ban_id', String.valueOf(ban.Id));
        gen.writeStringField('sf_account_id', String.valueOf(ban.Account__c));
        gen.writeNumberField('partner_id', partnerId);
        gen.writeStringField('name', ban.Name != null ? ban.Name : '');
        // Invoice frequency — Odoo requires both ns_invoice_frequency_id AND invoice_frequency
        String freqLabel = ban.Invoice_Frequency__c != null ? ban.Invoice_Frequency__c : 'Monthly';
        Integer freqId = freqMap.get(freqLabel);
        if (freqId != null && freqId > 0) {
            gen.writeNumberField('ns_invoice_frequency_id', freqId);
            gen.writeNumberField('invoice_frequency', freqId);
        } else {
            gen.writeBooleanField('ns_invoice_frequency_id', false);
            gen.writeBooleanField('invoice_frequency', false);
        }
        gen.writeStringField('ns_approval_status', 'approved');
        String invoiceDeliv = ban.InvoiceDeliveryMode__c;
        String mappedDelivery = mapInvoiceDeliveryMode(invoiceDeliv);
        if (mappedDelivery != null) {
            gen.writeStringField('ns_invoice_delivery', mappedDelivery);
        } else {
            // Unmapped value — send false so Odoo uses its default
            gen.writeBooleanField('ns_invoice_delivery', false);
        }
        gen.writeStringField('additional_email', normalizeAdditionalEmails(ban.Additional_Invoice_Email__c));
        
        if (deCompanyId != null && deCompanyId > 0) {
            gen.writeNumberField('ns_de_company_id', deCompanyId);
        } else {
            gen.writeBooleanField('ns_de_company_id', false);
        }
        // charge_period_presentment — Odoo reads both ns_ and bare field names
        String chargePres = ban.Charge_Period_Presentment__c;
        if (chargePres != null && chargePres != '') {
            String cpVal = chargePres.toLowerCase().replace(' ', '_');
            gen.writeStringField('ns_charge_period_presentment', cpVal);
            gen.writeStringField('charge_period_presentment', cpVal);
        } else {
            gen.writeBooleanField('ns_charge_period_presentment', false);
            gen.writeBooleanField('charge_period_presentment', false);
        }
        // invoice_presentment — Odoo reads both ns_ and bare field names
        // Send false when blank or unmapped — Odoo uses its default
        String invoicePres = ban.Invoice_Presentment__c;
        if (invoicePres != null && invoicePres != '') {
            String ipVal = invoicePres.toLowerCase().replace(' ', '_');
            gen.writeStringField('ns_invoice_presentment', ipVal);
            gen.writeStringField('invoice_presentment', ipVal);
        } else {
            gen.writeBooleanField('ns_invoice_presentment', false);
            gen.writeBooleanField('invoice_presentment', false);
        }
        // ns_billing_address
        String billingAddr = '';
        if (ban.Account__r.BillingStreet != null) billingAddr += ban.Account__r.BillingStreet;
        if (ban.Account__r.BillingCity != null) {
            billingAddr += (billingAddr != '' ? ', ' : '') + ban.Account__r.BillingCity;
        }
        gen.writeStringField('ns_billing_address', billingAddr);
        gen.writeStringField('ns_inv_report_label', ban.BAN_ID_INV_Label__c != null ?ban.BAN_ID_INV_Label__c : '' );
        gen.writeStringField('ns_inv_report_value', ban.BAN_ID_Reference__c!= null ? ban.BAN_ID_Reference__c : '');    
        gen.writeStringField('ns_currency_id', ban.CurrencyISOCode);
        gen.writeBooleanField('ns_different_invoice_currency', ban.Different_Invoice_Currency__c);
        gen.writeStringField('ns_invoice_currency', ban.Invoice_Currency__c);  
                
        // ns_billing_contact
        if(contactId != null){
            gen.writeNumberField('ns_billing_contact', contactId);
        }
        else{
            gen.writeBooleanField('ns_billing_contact', false);
        }
        gen.writeEndObject(); // data
        gen.writeEndObject(); // params
        gen.writeEndObject(); // root
        return gen.getAsString();
    }

    @TestVisible
    private String buildNewCPayload(Id accountId, BillingAccount__c sample, OdooIntegrationSettings__c settings) {
        JSONGenerator gen = JSON.createGenerator(false);
        gen.writeStartObject();
        gen.writeFieldName('params');
        gen.writeStartObject();
        gen.writeStringField('username', settings.Username__c != null ? settings.Username__c : '');
        gen.writeStringField('password', settings.Password__c != null ? settings.Password__c : '');
        gen.writeFieldName('data');
        gen.writeStartObject();

        gen.writeStringField('sf_account_id', String.valueOf(sample.Billing_Contact__c));
        gen.writeStringField('name', sample.Billing_Contact__r.Name != null ? sample.Billing_Contact__r.Name : '');
        gen.writeBooleanField('is_company', false);
        gen.writeStringField('company_type', 'person');
        gen.writeBooleanField('parent_id', false);
        gen.writeStringField('currency_id', sample.Billing_Contact__r.CurrencyISOCode);
        gen.writeBooleanField('company_id', false);
        gen.writeNumberField('customer_rank', 1);
        gen.writeBooleanField('is_from_sf', true);
        gen.writeStringField('phone',sample.Billing_Contact__r.Phone != null ? sample.Billing_Contact__r.Phone : '');
        gen.writeStringField('email', sample.Billing_Contact__r.email != null ? sample.Billing_Contact__r.email : '');
        gen.writeEndObject(); // data
        gen.writeEndObject(); // params
        gen.writeEndObject(); // root
        return gen.getAsString();
    }
    
    // ─── Helpers ─────────────────────────────────────────────────────────────

    /**
     * Converts a display label to an Odoo selection field technical key.
     * Odoo selection fields store lowercase, underscore-separated technical keys
     * (e.g. 'EDGE Default' → 'edge_default', 'Customer Remarks' → 'customer_remarks').
     */
    @TestVisible
    private static String toSelectionKey(String label) {
        if (label == null || label.trim() == '') return '';
        return label.trim().toLowerCase().replace(' ', '_');
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

    /**
     * Normalizes Additional_Invoice_Email__c into a comma-delimited string before it's sent
     * to Odoo. VR_BAN_09_AdditionalEmailFmt historically allowed a bare space or newline
     * between the two addresses (in addition to a comma), so existing records may hold
     * space- or newline-separated values. Odoo/BOSS expects a standard comma-delimited
     * address list — a plain space isn't a recognized separator there — so this collapses
     * any run of whitespace and/or commas into ", " regardless of what was typed in SF.
     */
    @TestVisible
    private static String normalizeAdditionalEmails(String raw) {
        if (String.isBlank(raw)) return '';
        List<String> parts = new List<String>();
        for (String part : raw.trim().split('[\\s,]+')) {
            if (String.isNotBlank(part)) parts.add(part);
        }
        return String.join(parts, ', ');
    }

    /**
     * Maps SF InvoiceDeliveryMode__c picklist labels to Odoo selection field technical keys.
     * Odoo's res.partner.ban ns_invoice_delivery accepts only lowercase technical keys.
     * SF labels like "Email (PDF attachment)" cannot be lowercased directly — Odoo rejects them.
     */
    @TestVisible
    private static String mapInvoiceDeliveryMode(String sfLabel) {
        if (sfLabel == null || sfLabel == '') return null;
        // Exact match map — add entries as Darren confirms valid Odoo selection keys.
        // Staging only has 'online'. Production values TBD — update this map once confirmed.
        Map<String, String> deliveryMap = new Map<String, String>{
            'Online' => 'online'
        };
        if (deliveryMap.containsKey(sfLabel)) return deliveryMap.get(sfLabel);
        // Unrecognized value — return null so caller sends false (Odoo default)
        return null;
    }

    private static DE_Integration_Error__c newError(String recordId, String ipRef, String msg) {
        return newError(recordId, ipRef, msg, null);
    }

    private static DE_Integration_Error__c newError(String recordId, String ipRef, String msg, String payload) {
        DE_Integration_Error__c err = new DE_Integration_Error__c(
            Record_Id__c     = recordId,
            IP_Reference__c  = ipRef,
            Error_Message__c = msg,
            Status__c        = 'Open'
        );
        if (payload != null) err.Request_Payload__c = payload;
        return err;
    }
}