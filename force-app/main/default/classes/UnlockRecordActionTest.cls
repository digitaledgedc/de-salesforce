/**
 * UnlockRecordActionTest
 *
 * UnlockRecordAction submits a record to a named approval process and then
 * immediately unlocks it so it stays editable while approval is pending.
 *
 * The Quote-side approval processes (SBI_Approval etc.) are inactive in these
 * orgs, so we exercise the invocable against the ACTIVE, object-agnostic
 * BAN_Approval process (BillingAccount__c): entry criteria Status__c='Draft',
 * assigned approver = record Owner (the running user), which makes
 * Approval.process() return isSuccess=true and drives the unlock() branch.
 */
@IsTest
private class UnlockRecordActionTest {

    private static BillingAccount__c newDraftBan() {
        Account cust = new Account(Name = 'URA Customer');
        insert cust;

        Id deEntityRt = Schema.SObjectType.Account
            .getRecordTypeInfosByDeveloperName().get('DE_Entity').getRecordTypeId();
        Account entity = new Account(Name = 'URA Entity Pte Ltd', RecordTypeId = deEntityRt);
        insert entity;

        Contact con = new Contact(AccountId = cust.Id, FirstName = 'URA', LastName = 'Billing');
        insert con;

        BillingAccount__c ban = new BillingAccount__c(
            Account__c = cust.Id, DE_Entity__c = entity.Id,
            Billing_Contact__c = con.Id, Status__c = 'Draft');
        insert ban;
        return ban;
    }

    private static Boolean isLocked(Id recordId) {
        return Approval.isLocked(recordId);
    }

    // Success path WITH a comment → covers setComments() branch + unlock().
    @IsTest
    static void submitAndUnlock_withComment_recordUnlocked() {
        BillingAccount__c ban = newDraftBan();

        UnlockRecordAction.Request req = new UnlockRecordAction.Request();
        req.recordId    = ban.Id;
        req.processName = 'BAN_Approval';
        req.comment     = 'Submitted via automated test';

        Test.startTest();
        UnlockRecordAction.submitAndUnlock(new List<UnlockRecordAction.Request>{ req });
        Test.stopTest();

        // Submitted for approval then explicitly unlocked → must be editable again.
        System.assertEquals(false, isLocked(ban.Id),
            'Record should be unlocked after submit-and-unlock');
    }

    // Success path WITHOUT a comment → covers the isNotBlank == false branch.
    @IsTest
    static void submitAndUnlock_noComment_recordUnlocked() {
        BillingAccount__c ban = newDraftBan();

        UnlockRecordAction.Request req = new UnlockRecordAction.Request();
        req.recordId    = ban.Id;
        req.processName = 'BAN_Approval';
        // comment intentionally left null

        Test.startTest();
        UnlockRecordAction.submitAndUnlock(new List<UnlockRecordAction.Request>{ req });
        Test.stopTest();

        System.assertEquals(false, isLocked(ban.Id),
            'Record should be unlocked even when no comment is supplied');
    }
}