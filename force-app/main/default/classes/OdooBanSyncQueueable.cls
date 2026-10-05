/**
 * OdooBanSyncQueueable
 * NEW-A + NEW-B: Syncs BillingAccount__c (BAN) records to Odoo.
 * Chained from BillingAccountTriggerHandler when a BAN's Status changes to Active.
 *
 * Sequencing within execute():
 *   NEW-A (POST /api/v1/create_partner) — only for Accounts without Odoo_Partner_ID__c.
 *            One callout per unique Account. Writes Account.Odoo_Partner_ID__c, plus
 *            Odoo_Sync_Status__c/Odoo_Sync_Error__c/Odoo_Sync_Payload__c on every Account that
 *            goes through this callout (SFDC-361) — 'Acknowledged' on success, 'Failed - Manual
 *            Review Required' on any failure/collision, payload always captured.
 *   NEW-B (POST /api/v1/create_ban)     — one callout per BAN.
 *            Writes Odoo_BAN_ID__c, Odoo_Partner_ID__c, Odoo_Invoice_Freq_ID__c on BillingAccount__c.
 *
 * NEW-A payload also carries Portal_Code__c -> ns_portal_code (SFDC-361 — restored; had been
 * dropped from this class, only Account-update-time sync via OdooAccountUpdateQueueable had it),
 * Tax_ID__c -> vat, Credit_Limit_MRC__c -> ns_credit_limit_mrc, Credit_Limit_NRC__c ->
 * ns_credit_limit_nrc, and Payment_Terms__c -> property_payment_term_id — the last one sent as
 * the raw picklist label, not an Odoo integer id (no label->id mapping exists yet for Payment
 * Terms, unlike Invoice_Frequency__mdt for BAN sync).
 *
 * All callouts run before any DML (Apex rule: no DML between callouts).
 * Errors written to DE_Integration_Error__c with IP_Reference__c = 'NEW-A' or 'NEW-B'.
 *
 * Field name source: DE Salesforce Odoo Integration Mapping Final.xlsx (sheets NEW-A Account Sync,
 * NEW-B BAN Sync). Sample payload takes precedence over field mapping table where names differ.
 */
public without sharing class OdooBanSyncQueueable implements Queueable, Database.AllowsCallouts {

    private List<Id> banIds;
    private List<Id> ip1OrderIds;  // chain to SendNewOrdersQueueable after BAN sync
    private List<Id> ip4OrderIds;  // chain to SendChangeOrdersQueueable after BAN sync

    public OdooBanSyncQueueable(List<Id> banIds) {
        this.banIds = banIds;
        this.ip1OrderIds = new List<Id>();
        this.ip4OrderIds = new List<Id>();
    }

    /** Chaining constructor: after BAN sync, send these Orders via IP-1 (New Service/Renewal). */
    public OdooBanSyncQueueable(List<Id> banIds, List<Id> chainOrderIds) {
        this.banIds = banIds;
        this.ip1OrderIds = chainOrderIds != null ? chainOrderIds : new List<Id>();
        this.ip4OrderIds = new List<Id>();
    }

    /** Chaining constructor with explicit target: 'IP-1' → SendNewOrdersQueueable,
     *  'IP-4' → SendChangeOrdersQueueable. Kept for backward compatibility — prefer the
     *  (banIds, ip1OrderIds, ip4OrderIds) constructor below when both targets are needed. */
    public OdooBanSyncQueueable(List<Id> banIds, List<Id> chainOrderIds, String chainTarget) {
        this.banIds = banIds;
        List<Id> ids = chainOrderIds != null ? chainOrderIds : new List<Id>();
        if (chainTarget == 'IP-4') {
            this.ip1OrderIds = new List<Id>();
            this.ip4OrderIds = ids;
        } else {
            this.ip1OrderIds = ids;
            this.ip4OrderIds = new List<Id>();
        }
    }

    /**
     * Combined chaining constructor: after BAN sync, send ip1OrderIds via IP-1 (New Service/
     * Renewal) AND ip4OrderIds via IP-4 (Change Orders) — both from this single job. Lets
     * OrderTriggerHandler enqueue exactly one job per trigger invocation even when a batch of
     * activated Orders mixes both types, instead of the previous approach of enqueueing one
     * OdooBanSyncQueueable per order type (which could total 2 System.enqueueJob() calls in one
     * trigger execution and fail with "Too many queueable jobs added to the queue" whenever that
     * trigger fired from inside an already-executing async job).
     */
    public OdooBanSyncQueueable(List<Id> banIds, List<Id> ip1OrderIds, List<Id> ip4OrderIds) {
        this.banIds = banIds;
        this.ip1OrderIds = ip1OrderIds != null ? ip1OrderIds : new List<Id>();
        this.ip4OrderIds = ip4OrderIds != null ? ip4OrderIds : new List<Id>();
    }

    public void execute(QueueableContext ctx) {
        System.debug('INTEGRATION ▶ OdooBanSyncQueueable — START | BANs: ' + banIds
            + ' | ip1OrderIds: ' + ip1OrderIds + ' | ip4OrderIds: ' + ip4OrderIds);
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
                   Account__r.BillingCountry,Account__r.Preferred_Language__c,
                   Account__r.Portal_Code__c,
                   Account__r.Tax_ID__c,Account__r.Credit_Limit_MRC__c,Account__r.Credit_Limit_NRC__c,
                   Account__r.Payment_Terms__c,
                   Account__r.Odoo_Partner_ID__c,Account__r.DE_Entity__c,Account__r.Company_Code__c,BAN_ID_INV_Label__c,BAN_ID_Reference__c,
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

        // ── Collect for DML after all callouts ───────────────────────────────
        List<Account>            accountsToUpdate = new List<Account>();
        List<Contact>            contactsToUpdate = new List<Contact>();
        List<BillingAccount__c>  bansToUpdate     = new List<BillingAccount__c>();
        List<DE_Integration_Error__c> errors      = new List<DE_Integration_Error__c>();

        // NEW-C (Quote-role contacts): sync Quote Contact, Ops Contact (Opportunity_Contact__c),
        // and Order Contact (Order_Contact__c) — sourced from the Quote linked to each Order being
        // chained to SendNewOrdersQueueable/SendChangeOrdersQueueable. Runs regardless of whether
        // the BAN itself needs (re)sync, since a repeat order on an already-active BAN can still
        // reference a contact never synced to Odoo before. oddoIdByContact is seeded here so the
        // Billing Contact sync below (Step 1) reuses any partner already created for the same
        // person instead of double-creating it.
        List<Id> allChainOrderIds = new List<Id>();
        allChainOrderIds.addAll(ip1OrderIds);
        allChainOrderIds.addAll(ip4OrderIds);
        Map<Id, Integer> oddoIdByContact = new Map<Id, Integer>();
        syncQuoteRoleContacts(allChainOrderIds, settings, oddoIdByContact, contactsToUpdate, errors);

        if (bans.isEmpty()) {
            System.debug('INTEGRATION ▶ OdooBanSyncQueueable — No BANs need sync, skipping to chain');
            // Chain (its own callouts) BEFORE any DML — see sendChainedOrders() doc.
            ChainResult chained = sendChainedOrders(new Map<Id, BillingAccount__c>(), oddoIdByContact);
            errors.addAll(chained.errors);
            if (!errors.isEmpty())          insert errors;
            if (!contactsToUpdate.isEmpty()) update contactsToUpdate;
            if (!chained.ordersToUpdate.isEmpty()) update chained.ordersToUpdate;
            return;
        }

        // ── Derive company ID + country ID from first order on each BAN ──
        // (NEW-B's ns_de_company_id stays keyed off the BAN's own first Order/Operation_Site__c
        // below, unchanged — that's a distinct field from NEW-A's company_id below and wasn't
        // part of the confirmed SFDC-147 bug.)
        Set<Id> banIdSet = new Map<Id, BillingAccount__c>(bans).keySet();
        Map<Id, Integer> banCompanyMap = new Map<Id, Integer>();
        Map<Id, Integer> banCountryMap = new Map<Id, Integer>();
        for (Order o : [
            SELECT BillingAccount__c, Operation_Site__c
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
        }

        // ── Account → company/country for NEW-A payload, derived from the Account's own
        // DE Subsidiary (DE_Entity__c) via Site__c — NOT from any Order's Operation_Site__c
        // (SFDC-147). Operation_Site__c is a per-order provisioning field that can be null
        // (no order yet, or an Account whose Orders predate that field), which was silently
        // producing company_id=false for NEW-A. Site__c.DE_Entity__c is the authoritative
        // link from a physical site to its billing legal entity and is confirmed consistent
        // in DE_PROD — every DE_Entity__c maps to exactly one Odoo_Company_ID__c/
        // Odoo_Country_ID__c across all of its Site__c records, so picking any one match is safe.
        Set<Id> entityIds = new Set<Id>();
        for (BillingAccount__c ban : bans) {
            if (ban.Account__r.DE_Entity__c != null) entityIds.add(ban.Account__r.DE_Entity__c);
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
        for (BillingAccount__c ban : bans) {
            Id acctId = ban.Account__c;
            Id entityId = ban.Account__r.DE_Entity__c;
            if (acctId == null || entityId == null) continue;
            if (!accountCompanyMap.containsKey(acctId) && entityCompanyMap.containsKey(entityId)) {
                accountCompanyMap.put(acctId, entityCompanyMap.get(entityId));
            }
            if (!accountCountryMap.containsKey(acctId) && entityCountryMap.containsKey(entityId)) {
                accountCountryMap.put(acctId, entityCountryMap.get(entityId));
            }
        }

        // ── Step 1: Collect unique Accounts that need NEW-A ───────────────────
        // Priority: Account.Odoo_Partner_ID__c → BAN.Odoo_Partner_ID__c (historical migration) → NEW-A callout
        // Historical BANs already have Odoo_Partner_ID__c loaded from the BAN export (the Account's Odoo
        // res.partner ID). Use that directly so NEW-A is only called for genuinely new accounts.
        Map<Id, Integer> partnerIdByAccount = new Map<Id, Integer>();
        Set<Id> accountsNeedingNewA = new Set<Id>();
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

            Account acctUpdate = new Account(Id = accountId);
            acctUpdate.Odoo_Sync_Payload__c = payload; // always capture the request payload

            if (resp.isSuccess) {
                Integer partnerId = parseIntFromResult(resp.rawBody, 'partner_id');
                System.debug('INTEGRATION ▶ NEW-A — Parsed partner_id: ' + partnerId);
                if (partnerId != null && partnerId > 0) {
                    partnerIdByAccount.put(accountId, partnerId);
                    acctUpdate.Odoo_Partner_ID__c = partnerId;
                    acctUpdate.Odoo_Sync_Status__c = 'Acknowledged';
                    acctUpdate.Odoo_Sync_Error__c = null;
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
                    String collisionMsg = 'NEW-A succeeded but returned partner_id=0. '
                        + 'Search Odoo for res.partner where ns_portal_code = \'' + sfCode + '\', '
                        + 'copy that record\'s ID to Account.Odoo_Partner_ID__c, then re-run. '
                        + 'Raw response: ' + resp.rawBody;
                    acctUpdate.Odoo_Sync_Status__c = 'Failed - Manual Review Required';
                    acctUpdate.Odoo_Sync_Error__c = collisionMsg;
                    errors.add(newError(String.valueOf(accountId), 'NEW-A', collisionMsg));
                }
            } else {
                acctUpdate.Odoo_Sync_Status__c = 'Failed - Manual Review Required';
                acctUpdate.Odoo_Sync_Error__c = resp.errorBody;
                errors.add(newError(String.valueOf(accountId), 'NEW-A', resp.errorBody, payload));
            }
            accountsToUpdate.add(acctUpdate);
        }
        
		 for (Id conId : billingContactNeedingNewB) {
            BillingAccount__c sample = firstBanByContact.get(conId);
            String payload = buildNewCPayload(conId, sample.Billing_Contact__r, settings);
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

        // ── Chain BEFORE any DML — IP-1/IP-4 make their own callouts too, and Salesforce throws
        // "You have uncommitted work pending" on ANY callout that follows ANY DML in one
        // transaction. This ordering (not just passing banOverrides/contactPartnerIdOverrides) is
        // what actually prevents that error — the override maps alone only fixed stale/uncommitted
        // data being read; they don't change when the callout happens relative to this class's own
        // DML. See sendChainedOrders() doc. Fix: 2026-09-28.
        Map<Id, BillingAccount__c> banOverridesByBanId = new Map<Id, BillingAccount__c>(bansToUpdate);
        ChainResult chained = sendChainedOrders(banOverridesByBanId, oddoIdByContact);
        errors.addAll(chained.errors);

        // ── All callouts done (this class's own NEW-A/B/C + any chained IP-1/IP-4 sends) —
        // only now is it safe to DML, exactly once, for everything. ──────────────────────────
        System.debug('INTEGRATION ▶ OdooBanSyncQueueable — DML summary | errors: ' + errors.size()
            + ' | accountsToUpdate: ' + accountsToUpdate.size()
            + ' | bansToUpdate: ' + bansToUpdate.size()
            + ' | chainedOrdersToUpdate: ' + chained.ordersToUpdate.size());
        if (!errors.isEmpty())        insert errors;
        if (!accountsToUpdate.isEmpty()) update accountsToUpdate;
        if (!contactsToUpdate.isEmpty()) update contactsToUpdate;
        if (!bansToUpdate.isEmpty())  update bansToUpdate;
        if (!chained.ordersToUpdate.isEmpty()) update chained.ordersToUpdate;
    }

    /** Return shape for sendChainedOrders() — the Order updates and integration errors the chained
     *  sends would have written, handed back instead of committed so the caller can fold them into
     *  its own single end-of-transaction DML. */
    private class ChainResult {
        List<Order> ordersToUpdate = new List<Order>();
        List<DE_Integration_Error__c> errors = new List<DE_Integration_Error__c>();
    }

    /**
     * Runs both chained order sends (IP-1/IP-4) after BAN sync's own callouts, and BEFORE any DML
     * anywhere in this transaction. Calls SendNewOrdersQueueable/SendChangeOrdersQueueable's
     * deferred entry points (sendOrdersDeferred(...)) DIRECTLY rather than via
     * System.enqueueJob() — this method already runs inside an executing Queueable
     * (OdooBanSyncQueueable itself), which Salesforce caps at exactly one additional
     * System.enqueueJob() call; a plain method call carries no such limit. The only
     * System.enqueueJob() left in this whole chain is SendNewOrdersQueueable's own IP-3
     * (LockOdooSpacesQueueable) capacity chain, fired at most once — see SendNewOrdersQueueable.
     *
     * Deferred (not committed here) is the key word: sendOrdersDeferred performs its own Odoo
     * callouts but does NOT do its own DML, returning it instead via SendResult so the caller
     * (this class's execute()) can commit it together with its own pending DML, once, after every
     * callout in the whole chain has run. banOverrides/contactPartnerIdOverrides carry the
     * BAN/Contact Odoo ids this run just computed, still uncommitted at this point.
     */
    private ChainResult sendChainedOrders(Map<Id, BillingAccount__c> banOverrides,
            Map<Id, Integer> contactPartnerIdOverrides) {
        ChainResult result = new ChainResult();
        if ((ip1OrderIds == null || ip1OrderIds.isEmpty())
                && (ip4OrderIds == null || ip4OrderIds.isEmpty())) {
            System.debug('INTEGRATION ▶ OdooBanSyncQueueable — No chain orders, done');
            return result;
        }
        OdooIntegrationSettings__c s = OdooIntegrationSettings__c.getOrgDefaults();
        if (!s.IP1_Enabled__c) {
            System.debug('INTEGRATION ▶ OdooBanSyncQueueable — IP1_Enabled is false, skipping chain');
            return result;
        }
        if (ip1OrderIds != null && !ip1OrderIds.isEmpty()) {
            System.debug('INTEGRATION ▶ OdooBanSyncQueueable — CHAINING → SendNewOrdersQueueable (IP-1) | Orders: ' + ip1OrderIds);
            SendNewOrdersQueueable.SendResult r1 =
                SendNewOrdersQueueable.sendOrdersDeferred(ip1OrderIds, banOverrides, contactPartnerIdOverrides);
            result.ordersToUpdate.addAll(r1.pendingUpdates);
            result.errors.addAll(r1.pendingErrors);
        }
        if (ip4OrderIds != null && !ip4OrderIds.isEmpty()) {
            System.debug('INTEGRATION ▶ OdooBanSyncQueueable — CHAINING → SendChangeOrdersQueueable (IP-4) | Orders: ' + ip4OrderIds);
            SendChangeOrdersQueueable.SendResult r2 =
                SendChangeOrdersQueueable.sendOrdersDeferred(ip4OrderIds, banOverrides);
            result.ordersToUpdate.addAll(r2.pendingUpdates);
            result.errors.addAll(r2.pendingErrors);
        }
        return result;
    }

    /**
     * NEW-C (Quote-role contacts): syncs the three contact roles carried on the Quote linked to
     * each Order in orderIds — Quote Contact (Quote.ContactId), Ops Contact
     * (Quote.Opportunity_Contact__c), and Order Contact (Quote.Order_Contact__c). Any of these
     * without an existing Odoo_Partner_ID__c gets a res.partner created via
     * /api/v1/create_partner; results are appended to the caller's oddoIdByContact map and
     * contactsToUpdate/errors lists (all callouts must finish before any DML in this class, so
     * this must be called before the caller does any update/insert).
     */
    private void syncQuoteRoleContacts(List<Id> orderIds, OdooIntegrationSettings__c settings,
            Map<Id, Integer> oddoIdByContact, List<Contact> contactsToUpdate,
            List<DE_Integration_Error__c> errors) {
        if (orderIds == null || orderIds.isEmpty()) return;

        Map<Id, Contact> contactsById = new Map<Id, Contact>();
        for (Order o : [
            SELECT Quote__r.ContactId, Quote__r.Contact.Name, Quote__r.Contact.Email,
                   Quote__r.Contact.Phone, Quote__r.Contact.Odoo_Partner_ID__c, Quote__r.Contact.CurrencyISOCode,
                   Quote__r.Ops_Contact__c, Quote__r.Ops_Contact__r.Name,
                   Quote__r.Ops_Contact__r.Email, Quote__r.Ops_Contact__r.Phone,
                   Quote__r.Ops_Contact__r.Odoo_Partner_ID__c, Quote__r.Ops_Contact__r.CurrencyISOCode,
                   Quote__r.Order_Contact__c, Quote__r.Order_Contact__r.Name,
                   Quote__r.Order_Contact__r.Email, Quote__r.Order_Contact__r.Phone,
                   Quote__r.Order_Contact__r.Odoo_Partner_ID__c, Quote__r.Order_Contact__r.CurrencyISOCode
            FROM Order
            WHERE Id IN :orderIds AND Quote__c != null
        ]) {
            if (o.Quote__r.ContactId != null) contactsById.put(o.Quote__r.ContactId, o.Quote__r.Contact);
            if (o.Quote__r.Ops_Contact__c != null) contactsById.put(o.Quote__r.Ops_Contact__c, o.Quote__r.Ops_Contact__r);
            if (o.Quote__r.Order_Contact__c != null) contactsById.put(o.Quote__r.Order_Contact__c, o.Quote__r.Order_Contact__r);
        }

        for (Id conId : contactsById.keySet()) {
            Contact con = contactsById.get(conId);
            if (con.Odoo_Partner_ID__c != null && con.Odoo_Partner_ID__c > 0) {
                oddoIdByContact.put(conId, Integer.valueOf(con.Odoo_Partner_ID__c));
                continue;
            }

            String payload = buildNewCPayload(conId, con, settings);
            System.debug('INTEGRATION ▶ NEW-C (Quote role) — Calling /api/v1/create_partner for Contact: ' + conId);
            System.debug('INTEGRATION ▶ NEW-C (Quote role) — Payload: ' + payload);

            OdooCalloutService.Response resp =
                OdooCalloutService.post('/api/v1/create_partner', payload);

            System.debug('INTEGRATION ▶ NEW-C (Quote role) — Response | success: ' + resp.isSuccess
                + ' | rawBody: ' + resp.rawBody + ' | error: ' + resp.errorBody);
            if (resp.isSuccess) {
                Integer partnerId = parseIntFromResult(resp.rawBody, 'partner_id');
                if (partnerId != null && partnerId > 0) {
                    oddoIdByContact.put(conId, partnerId);
                    contactsToUpdate.add(new Contact(Id = conId, Odoo_Partner_ID__c = partnerId));
                } else {
                    String sfId = String.valueOf(conId);
                    String sfCode = sfId.length() > 8 ? sfId.substring(sfId.length() - 8) : sfId;
                    errors.add(newError(String.valueOf(conId), 'NEW-C',
                        'NEW-C (Quote role) succeeded but returned partner_id=0. '
                        + 'Search Odoo for res.partner where ns_portal_code = \'' + sfCode + '\', '
                        + 'copy that record\'s ID to Contact.Odoo_Partner_ID__c, then re-run. '
                        + 'Raw response: ' + resp.rawBody));
                }
            } else {
                errors.add(newError(String.valueOf(conId), 'NEW-C', resp.errorBody, payload));
            }
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
        // x_studio_company_code: unique constraint in Odoo, AND Odoo hard-rejects any value
        // over 8 characters ("Company Code must not have more than 8 characters") — confirmed
        // live against DE_PARTIAL. Prefer the Account's own Company_Code__c (Text,
        // unique=true, externalId=true — genuinely enforced unique by SFDC itself) only when
        // it's populated AND fits that 8-char limit (55 of 2,596 populated values in DE_PROD
        // are 9-11 chars, e.g. "KRENDCUST1"/"ZenlayerSH" — truncating those would collide,
        // e.g. "KRENDCUST1"/"KRENDCUST2" both truncate to "KRENDCUS"); fall back to the last
        // 8 chars of the SF Account ID otherwise.
        String companyCode;
        if (String.isNotBlank(sample.Account__r.Company_Code__c)
                && sample.Account__r.Company_Code__c.length() <= 8) {
            companyCode = sample.Account__r.Company_Code__c;
        } else {
            String sfId = String.valueOf(accountId);
            companyCode = sfId.length() > 8 ? sfId.substring(sfId.length() - 8) : sfId;
        }
        gen.writeStringField('x_studio_company_code', companyCode);
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
        gen.writeStringField('country_name',
            sample.Account__r.BillingCountry != null ? sample.Account__r.BillingCountry : '');
        gen.writeStringField('phone',
            sample.Account__r.Phone != null ? sample.Account__r.Phone : '');
        gen.writeStringField('email', '');
        // Website: send empty string — Azure WAF blocks URLs embedded in POST bodies (SSRF rule).
        // The Odoo team must add a WAF exclusion for /api/v1/* before real website values can be sent.
        gen.writeStringField('website', '');
        gen.writeStringField('ns_portal_code', sample.Account__r.Portal_Code__c != null ? sample.Account__r.Portal_Code__c : '');
        gen.writeStringField('vat', sample.Account__r.Tax_ID__c != null ? sample.Account__r.Tax_ID__c : '');
        if (sample.Account__r.Credit_Limit_MRC__c != null) {
            gen.writeNumberField('ns_credit_limit_mrc', sample.Account__r.Credit_Limit_MRC__c);
        }
        if (sample.Account__r.Credit_Limit_NRC__c != null) {
            gen.writeNumberField('ns_credit_limit_nrc', sample.Account__r.Credit_Limit_NRC__c);
        }
        // property_payment_term_id is typed as an integer in the mapping sheet, but there's no
        // Payment_Terms__c label -> Odoo id mapping yet (unlike Invoice_Frequency__mdt for BAN
        // sync) — sending the picklist label itself per explicit direction until that mapping exists.
        if (sample.Account__r.Payment_Terms__c != null) {
            gen.writeStringField('property_payment_term_id', sample.Account__r.Payment_Terms__c);
        }
        // Required per field mapping
        gen.writeNumberField('customer_rank', 1);
        gen.writeStringField('currency_id', currencyCode != null ? currencyCode : 'USD');
        String odooLang = mapPreferredLanguageToOdooLang(sample.Account__r.Preferred_Language__c);
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

    /** Builds the /api/v1/create_partner payload for a person-type Contact — shared by the
     *  Billing Contact sync (Step 1/NEW-B) and the Quote-role contact sync (syncQuoteRoleContacts). */
    @TestVisible
    private String buildNewCPayload(Id contactId, Contact con, OdooIntegrationSettings__c settings) {
        JSONGenerator gen = JSON.createGenerator(false);
        gen.writeStartObject();
        gen.writeFieldName('params');
        gen.writeStartObject();
        gen.writeStringField('username', settings.Username__c != null ? settings.Username__c : '');
        gen.writeStringField('password', settings.Password__c != null ? settings.Password__c : '');
        gen.writeFieldName('data');
        gen.writeStartObject();

        gen.writeStringField('sf_account_id', String.valueOf(contactId));
        gen.writeStringField('name', con.Name != null ? con.Name : '');
        gen.writeBooleanField('is_company', false);
        gen.writeStringField('company_type', 'person');
        gen.writeBooleanField('parent_id', false);
        gen.writeStringField('currency_id', con.CurrencyISOCode);
        gen.writeBooleanField('company_id', false);
        gen.writeNumberField('customer_rank', 1);
        gen.writeBooleanField('is_from_sf', true);
        gen.writeStringField('phone', con.Phone != null ? con.Phone : '');
        gen.writeStringField('email', con.Email != null ? con.Email : '');
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