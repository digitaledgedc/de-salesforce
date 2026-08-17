/**
 * Tests for the Opportunity SE tag-driven managed share (SE Phase 2).
 * Opportunity OWD = Private. Verifies: grant on insert, move on reassign,
 * and SURGICAL revoke (an unrelated user manual share survives a re-tag).
 */
@isTest
private with sharing class OpportunitySEShareService_Test {

    private static Integer ctr = 0;

    private static User mkUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        ctr++;
        return new User(
            FirstName = 'SE', LastName = 'Probe' + ctr,
            Email = 'seprobe' + ctr + '@de.example.com',
            Username = 'seprobe' + ctr + '.' + System.now().getTime() + '@de.example.com.test',
            Alias = 'sep' + ctr, TimeZoneSidKey = 'Asia/Tokyo', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = p.Id);
    }

    private static Opportunity mkOpp(Id seId) {
        Account a = new Account(Name = 'SE Test Acct', Operation_Country__c = 'Korea');
        insert a;
        Opportunity o = new Opportunity(
            Name = 'SE Test Opp', AccountId = a.Id,
            StageName = '1-Suspect', CloseDate = Date.today().addDays(30),
            Operation_Country__c = 'Korea', Skip_Stage_Gate__c = true,
            CurrencyIsoCode = 'USD', Sales_Engineer__c = seId);
        insert o;
        return o;
    }

    private static Integer shareCount(Id oppId, Id userId) {
        return [SELECT COUNT() FROM OpportunityShare
                WHERE OpportunityId = :oppId AND UserOrGroupId = :userId
                  AND RowCause = 'Manual' AND OpportunityAccessLevel = 'Read'];
    }

    @isTest static void grantsOnInsert() {
        User se = mkUser();
        System.runAs(new User(Id = UserInfo.getUserId())) { insert se; }
        Test.startTest();
        Opportunity o = mkOpp(se.Id);
        Test.stopTest();
        System.assertEquals(1, shareCount(o.Id, se.Id),
            'Tagged SE should receive a Read share on insert');
    }

    @isTest static void reassignMovesShare() {
        User seA = mkUser(); User seB = mkUser();
        System.runAs(new User(Id = UserInfo.getUserId())) { insert new List<User>{ seA, seB }; }
        Opportunity o = mkOpp(seA.Id);
        System.assertEquals(1, shareCount(o.Id, seA.Id), 'A shared after insert');
        Test.startTest();
        o.Sales_Engineer__c = seB.Id; update o;
        Test.stopTest();
        System.assertEquals(0, shareCount(o.Id, seA.Id), 'A share removed on reassign');
        System.assertEquals(1, shareCount(o.Id, seB.Id), 'B share added on reassign');
    }

    @isTest static void surgicalLeavesOtherManualShares() {
        User seA = mkUser(); User seB = mkUser(); User other = mkUser();
        System.runAs(new User(Id = UserInfo.getUserId())) { insert new List<User>{ seA, seB, other }; }
        Opportunity o = mkOpp(seA.Id);
        insert new OpportunityShare(OpportunityId = o.Id, UserOrGroupId = other.Id,
            OpportunityAccessLevel = 'Read', RowCause = 'Manual');
        Test.startTest();
        o.Sales_Engineer__c = seB.Id; update o;
        Test.stopTest();
        System.assertEquals(0, shareCount(o.Id, seA.Id), 'A removed on reassign');
        System.assertEquals(1, shareCount(o.Id, seB.Id), 'B added on reassign');
        System.assertEquals(1, shareCount(o.Id, other.Id),
            'Unrelated manual share SURVIVES the re-tag (surgical revoke)');
    }
}