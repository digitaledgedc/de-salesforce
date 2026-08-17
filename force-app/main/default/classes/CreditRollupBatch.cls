public without sharing class CreditRollupBatch
        implements Database.Batchable<SObject>, Database.Stateful {

    private static final Set<String> ACTIVE_STATUSES = new Set<String>{
        'Draft', 'In Review', 'Approved', 'Presented'
    };

    private static final Integer MAX_FAILURES_REPORTED = 50;

    private final Date expiryCutoff;

    // Stateful across chunks
    private Integer accountsScanned = 0;
    private Integer accountsUpdated = 0;
    private Integer accountsFailed  = 0;
    private Integer siExpired       = 0;
    private List<String> failures   = new List<String>();

    public CreditRollupBatch() {
        this.expiryCutoff = Date.today();
    }

    @TestVisible
    private CreditRollupBatch(Date cutoff) {
        this.expiryCutoff = cutoff;
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([
            SELECT Id,
                   Total_Active_Quoted_MRC__c, Total_Active_Quoted_NRC__c,
                   Active_Quote_Count__c,
                   Credit_Limit_MRC__c, Credit_Limit_NRC__c, Overdue_90_Days__c
            FROM Account
            ORDER BY Id
        ]);
    }

    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        List<Account> accounts = (List<Account>) scope;
        accountsScanned += accounts.size();

        Map<Id, Account> byId = new Map<Id, Account>(accounts);

      
        Map<String, Decimal> rates = new Map<String, Decimal>();
        for (CurrencyType ct : [
            SELECT IsoCode, ConversionRate FROM CurrencyType WHERE IsActive = true
        ]) {
            rates.put(ct.IsoCode, ct.ConversionRate);
        }

        Map<Id, Decimal> mrcByAcct = new Map<Id, Decimal>();
        Map<Id, Decimal> nrcByAcct = new Map<Id, Decimal>();
        Map<Id, Integer> cntByAcct = new Map<Id, Integer>();
        for (Id aid : byId.keySet()) {
            mrcByAcct.put(aid, 0);
            nrcByAcct.put(aid, 0);
            cntByAcct.put(aid, 0);
        }

        for (Quote q : [
            SELECT AccountId, Total_MRC_2__c, Total_NRC__c, CurrencyIsoCode
            FROM Quote
            WHERE AccountId IN :byId.keySet()
              AND Status IN :ACTIVE_STATUSES
              AND (ExpirationDate = null OR ExpirationDate >= :expiryCutoff)
        ]) {
            Decimal rate = rates.containsKey(q.CurrencyIsoCode)
                           ? rates.get(q.CurrencyIsoCode) : 1;
            if (rate == null || rate == 0) rate = 1; // misconfigured rate guard

            mrcByAcct.put(q.AccountId, mrcByAcct.get(q.AccountId)
                + (q.Total_MRC_2__c != null ? q.Total_MRC_2__c : 0) / rate);
            nrcByAcct.put(q.AccountId, nrcByAcct.get(q.AccountId)
                + (q.Total_NRC__c != null ? q.Total_NRC__c : 0) / rate);
            cntByAcct.put(q.AccountId, cntByAcct.get(q.AccountId) + 1);
        }

        List<Account> updates = new List<Account>();
        for (Account a : accounts) {
            Decimal newMrc = mrcByAcct.get(a.Id).setScale(2, RoundingMode.HALF_UP);
            Decimal newNrc = nrcByAcct.get(a.Id).setScale(2, RoundingMode.HALF_UP);
            Integer newCnt = cntByAcct.get(a.Id);

            Decimal oldMrc = a.Total_Active_Quoted_MRC__c != null ? a.Total_Active_Quoted_MRC__c : 0;
            Decimal oldNrc = a.Total_Active_Quoted_NRC__c != null ? a.Total_Active_Quoted_NRC__c : 0;
            Decimal oldCnt = a.Active_Quote_Count__c      != null ? a.Active_Quote_Count__c      : 0;

            if (oldMrc == newMrc && oldNrc == newNrc && oldCnt == newCnt) continue;

            updates.add(new Account(
                Id                         = a.Id,
                Total_Active_Quoted_MRC__c = newMrc,
                Total_Active_Quoted_NRC__c = newNrc,
                Active_Quote_Count__c      = newCnt
            ));
        }

        Set<Id> committed = new Set<Id>();
        if (!updates.isEmpty()) {
            Database.SaveResult[] results = Database.update(updates, false);
            for (Integer i = 0; i < results.size(); i++) {
                if (results[i].isSuccess()) {
                    accountsUpdated++;
                    committed.add(updates[i].Id);
                } else {
                    accountsFailed++;
                    Database.Error err = results[i].getErrors()[0];
                    String msg = updates[i].Id + ' | ' + err.getStatusCode()
                               + ' | ' + err.getMessage();
                    System.debug(LoggingLevel.ERROR, 'CreditRollupBatch account failure: ' + msg);
                    if (failures.size() < MAX_FAILURES_REPORTED) failures.add(msg);
                }
            }
        }

        expireStaleCreditSIs(committed, mrcByAcct, nrcByAcct, byId);
    }

   
    private void expireStaleCreditSIs(Set<Id> acctIds,
                                      Map<Id, Decimal> mrcByAcct,
                                      Map<Id, Decimal> nrcByAcct,
                                      Map<Id, Account> byId) {
        if (acctIds.isEmpty()) return;

        Set<Id> cleared = new Set<Id>();
        for (Id aid : acctIds) {
            Account a = byId.get(aid);
            if (a == null) continue;

            Decimal limMrc  = a.Credit_Limit_MRC__c != null ? a.Credit_Limit_MRC__c : 0;
            Decimal limNrc  = a.Credit_Limit_NRC__c != null ? a.Credit_Limit_NRC__c : 0;
            Decimal overdue = a.Overdue_90_Days__c  != null ? a.Overdue_90_Days__c  : 0;

            Boolean mrcOk = limMrc == 0 || mrcByAcct.get(aid) <= limMrc;
            Boolean nrcOk = limNrc == 0 || nrcByAcct.get(aid) <= limNrc;

            if (mrcOk && nrcOk && overdue == 0) cleared.add(aid);
        }
        if (cleared.isEmpty()) return;

        List<Special_Instruction__c> toExpire = [
            SELECT Id FROM Special_Instruction__c
            WHERE Account__c IN :cleared
              AND Type__c = 'Credit Limit'
              AND Status__c = 'Pending'
        ];
        if (toExpire.isEmpty()) return;

        for (Special_Instruction__c si : toExpire) {
            si.Status__c = 'Expired';
            si.Resolution_Notes__c = 'Auto-resolved by CreditRollupBatch: '
                + 'credit limit condition cleared after nightly recalculation.';
        }

        Database.SaveResult[] results = Database.update(toExpire, false);
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                siExpired++;
            } else {
                Database.Error err = results[i].getErrors()[0];
                String msg = 'SI ' + toExpire[i].Id + ' | ' + err.getStatusCode()
                           + ' | ' + err.getMessage();
                System.debug(LoggingLevel.ERROR, 'CreditRollupBatch SI failure: ' + msg);
                if (failures.size() < MAX_FAILURES_REPORTED) failures.add(msg);
            }
        }
    }

    public void finish(Database.BatchableContext bc) {
       
    }
}