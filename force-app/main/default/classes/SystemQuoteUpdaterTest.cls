/**
 * SystemQuoteUpdaterTest
 * unlockUpdateRelock() calls Approval.unlock/lock around a field update so
 * finance users can edit records normally locked by an active approval
 * process. Both overloads are tested against an ordinary, unlocked Quote —
 * Approval.unlock/lock on an already-unlocked record is a documented no-op,
 * so this exercises the real code path without needing to drive a record
 * through an actual approval process first.
 */
@IsTest
private class SystemQuoteUpdaterTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = 'SQU Test Account');
        insert acc;

        Opportunity opp = new Opportunity(
            Name = 'SQU Test Opp', AccountId = acc.Id,
            StageName = '1-Suspect', CloseDate = Date.today().addDays(30)
        );
        insert opp;

        insert new Quote(
            Name = 'SQU Test Quote', OpportunityId = opp.Id,
            Pricebook2Id = Test.getStandardPricebookId(), Status = 'Draft',
            ExpirationDate = Date.today().addDays(30)
        );
    }

    @IsTest
    static void testUnlockUpdateRelock_ByIdAndFieldName_UpdatesField() {
        Quote q = [SELECT Id FROM Quote LIMIT 1];

        Test.startTest();
        SystemQuoteUpdater.unlockUpdateRelock(q.Id, 'Status', 'Approved');
        Test.stopTest();

        Quote updated = [SELECT Status FROM Quote WHERE Id = :q.Id];
        System.assertEquals('Approved', updated.Status, 'Field should be updated via the unlock/update/relock pattern');
    }

    @IsTest
    static void testUnlockUpdateRelock_BySObject_UpdatesField() {
        Quote q = [SELECT Id FROM Quote LIMIT 1];
        Quote toUpdate = new Quote(Id = q.Id, Status = 'Presented');

        Test.startTest();
        SystemQuoteUpdater.unlockUpdateRelock(toUpdate);
        Test.stopTest();

        Quote updated = [SELECT Status FROM Quote WHERE Id = :q.Id];
        System.assertEquals('Presented', updated.Status, 'Field should be updated via the SObject overload');
    }
}