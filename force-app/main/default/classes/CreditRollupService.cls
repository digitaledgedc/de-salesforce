/**
 * CreditRollupService
 *
 * Replaces the flow-based Quote_AfterSave_CreditRollup loop that blindly sums
 * Quote.Total_MRC_2__c / Total_NRC__c across currencies.  This service converts
 * every quote's totals to the org's corporate currency (via CurrencyType
 * conversion rates) before summing, so the comparison against
 * Account.Credit_Limit_MRC__c is valid even when quotes use different currencies.
 *
 * Called as an Invocable Action from the Quote_AfterSave_CreditRollup flow.
 *
 * WITHOUT SHARING — must see all quotes for the Account regardless of the
 * triggering user's sharing rules (mirrors the flow's SystemModeWithoutSharing).
 */
public without sharing class CreditRollupService {

    // Reference date for the quote-expiration cutoff. Only overridden in tests,
    // because VR_QUOTE_23 forbids inserting a quote with a past ExpirationDate.
    @TestVisible
    private static Date expiryCutoff = Date.today();

    @InvocableMethod(label='Rollup Quote Totals (Currency-Converted)' description='Sums active-quote MRC/NRC into corporate currency and writes to Account.')
    public static void rollupForAccounts(List<Id> accountIds) {
        if (accountIds == null || accountIds.isEmpty()) return;

        Set<Id> acctIdSet = new Set<Id>(accountIds);
        acctIdSet.remove(null);
        if (acctIdSet.isEmpty()) return;

        // Exchange rates relative to corporate currency (ConversionRate = 1 corporate unit in local)
        Map<String, Decimal> rates = new Map<String, Decimal>();
        for (CurrencyType ct : [SELECT IsoCode, ConversionRate FROM CurrencyType WHERE IsActive = true]) {
            rates.put(ct.IsoCode, ct.ConversionRate);
        }

        // Active quotes with currency
        List<Quote> quotes = [
            SELECT AccountId, Total_MRC_2__c, Total_NRC__c, CurrencyIsoCode
            FROM Quote
            WHERE AccountId IN :acctIdSet
              AND Status IN ('Draft', 'In Review', 'Approved', 'Presented')
              AND (ExpirationDate = null OR ExpirationDate >= :expiryCutoff)
        ];

        // Initialise accumulators
        Map<Id, Decimal> mrcByAcct = new Map<Id, Decimal>();
        Map<Id, Decimal> nrcByAcct = new Map<Id, Decimal>();
        Map<Id, Integer> cntByAcct = new Map<Id, Integer>();
        for (Id aid : acctIdSet) {
            mrcByAcct.put(aid, 0);
            nrcByAcct.put(aid, 0);
            cntByAcct.put(aid, 0);
        }

        // Convert each quote's totals to corporate currency and accumulate
        for (Quote q : quotes) {
            Decimal rate = rates.containsKey(q.CurrencyIsoCode) ? rates.get(q.CurrencyIsoCode) : 1;
            if (rate == 0) rate = 1; // safety — avoid divide-by-zero on misconfigured rates
            Decimal mrc = (q.Total_MRC_2__c != null ? q.Total_MRC_2__c : 0) / rate;
            Decimal nrc = (q.Total_NRC__c != null ? q.Total_NRC__c : 0) / rate;
            mrcByAcct.put(q.AccountId, mrcByAcct.get(q.AccountId) + mrc);
            nrcByAcct.put(q.AccountId, nrcByAcct.get(q.AccountId) + nrc);
            cntByAcct.put(q.AccountId, cntByAcct.get(q.AccountId) + 1);
        }

        // Update accounts
        List<Account> updates = new List<Account>();
        for (Id aid : acctIdSet) {
            updates.add(new Account(
                Id = aid,
                Total_Active_Quoted_MRC__c = mrcByAcct.get(aid).setScale(2, RoundingMode.HALF_UP),
                Total_Active_Quoted_NRC__c = nrcByAcct.get(aid).setScale(2, RoundingMode.HALF_UP),
                Active_Quote_Count__c = cntByAcct.get(aid)
            ));
        }
        if (!updates.isEmpty()) {
            update updates;
        }

        // Auto-expire stale Credit Limit SIs whose condition has cleared
        expireStaleCreditSIs(acctIdSet, mrcByAcct, nrcByAcct);
    }

    /**
     * After the rollup completes, check if any Pending Credit Limit SIs on these
     * accounts are now stale (cumulative totals no longer exceed limits).
     * If so, mark them Expired with a resolution note.
     */
    private static void expireStaleCreditSIs(Set<Id> acctIds,
                                              Map<Id, Decimal> mrcByAcct,
                                              Map<Id, Decimal> nrcByAcct) {
        // Get accounts with their credit limits
        Map<Id, Account> acctMap = new Map<Id, Account>([
            SELECT Id, Credit_Limit_MRC__c, Credit_Limit_NRC__c, Overdue_90_Days__c
            FROM Account
            WHERE Id IN :acctIds
        ]);

        // Find accounts where the condition has cleared
        Set<Id> clearedAcctIds = new Set<Id>();
        for (Id aid : acctIds) {
            Account a = acctMap.get(aid);
            if (a == null) continue;

            Decimal totalMrc = mrcByAcct.containsKey(aid) ? mrcByAcct.get(aid) : 0;
            Decimal totalNrc = nrcByAcct.containsKey(aid) ? nrcByAcct.get(aid) : 0;
            Decimal limitMrc = a.Credit_Limit_MRC__c != null ? a.Credit_Limit_MRC__c : 0;
            Decimal limitNrc = a.Credit_Limit_NRC__c != null ? a.Credit_Limit_NRC__c : 0;
            Decimal overdue  = a.Overdue_90_Days__c != null ? a.Overdue_90_Days__c : 0;

            Boolean mrcOk = limitMrc == 0 || totalMrc <= limitMrc;
            Boolean nrcOk = limitNrc == 0 || totalNrc <= limitNrc;
            Boolean overdueOk = overdue == 0;

            if (mrcOk && nrcOk && overdueOk) {
                clearedAcctIds.add(aid);
            }
        }

        if (clearedAcctIds.isEmpty()) return;

        // Expire pending Credit Limit SIs on cleared accounts
        List<Special_Instruction__c> toExpire = [
            SELECT Id FROM Special_Instruction__c
            WHERE Account__c IN :clearedAcctIds
              AND Type__c = 'Credit Limit'
              AND Status__c = 'Pending'
        ];

        if (!toExpire.isEmpty()) {
            for (Special_Instruction__c si : toExpire) {
                si.Status__c = 'Expired';
                si.Resolution_Notes__c = 'Auto-resolved: credit limit condition cleared after quote totals recalculated.';
            }
            update toExpire;
        }
    }
}