/**
 * QuoteCOAssetPendingChangeTest
 * FB-755: setPendingChange() moves assets linked to a CO quote's original
 * order items to Status = 'Pending Change', skipping assets already in a
 * terminal/blocked state.
 */
@IsTest
private class QuoteCOAssetPendingChangeTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = 'QCOAPC Test Account');
        insert acc;

        Opportunity opp = new Opportunity(
            Name      = 'QCOAPC Test Opp',
            AccountId = acc.Id,
            StageName = '1-Suspect',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;

        Id stdPbId = Test.getStandardPricebookId();
        Product2 prod = new Product2(Name = 'QCOAPC Test Product', IsActive = true);
        insert prod;
        insert new PricebookEntry(Pricebook2Id = stdPbId, Product2Id = prod.Id, UnitPrice = 100, IsActive = true);
        PricebookEntry pbe = [SELECT Id FROM PricebookEntry WHERE Pricebook2Id = :stdPbId AND Product2Id = :prod.Id LIMIT 1];

        Order ord = new Order(
            AccountId         = acc.Id,
            Status            = 'Draft',
            EffectiveDate     = Date.today(),
            Operation_Site__c = 'JKT1',
            Pricebook2Id      = stdPbId,
            Order_Type__c     = 'New Service'
        );
        insert ord;

        // Three order items, each backing an asset in a different starting state.
        List<OrderItem> items = new List<OrderItem>{
            new OrderItem(OrderId = ord.Id, PricebookEntryId = pbe.Id, Quantity = 1, UnitPrice = 100), // -> asset In Service
            new OrderItem(OrderId = ord.Id, PricebookEntryId = pbe.Id, Quantity = 1, UnitPrice = 100), // -> asset Closed (blocked)
            new OrderItem(OrderId = ord.Id, PricebookEntryId = pbe.Id, Quantity = 1, UnitPrice = 100)  // -> not referenced by any quote line
        };
        insert items;

        List<Asset> assets = new List<Asset>{
            new Asset(Name = 'Asset In Service', AccountId = acc.Id, Source_OrderItem__c = items[0].Id, Status = 'In Service'),
            new Asset(Name = 'Asset Closed',      AccountId = acc.Id, Source_OrderItem__c = items[1].Id, Status = 'Closed'),
            new Asset(Name = 'Asset Untouched',    AccountId = acc.Id, Source_OrderItem__c = items[2].Id, Status = 'In Service')
        };
        insert assets;

        Quote q = new Quote(Name = 'QCOAPC CO Quote', OpportunityId = opp.Id, Pricebook2Id = stdPbId, Status = 'Draft');
        insert q;

        // Only the first two order items are referenced by CO quote lines.
        insert new List<QuoteLineItem>{
            new QuoteLineItem(QuoteId = q.Id, Product2Id = prod.Id, PricebookEntryId = pbe.Id,
                               Quantity = 1, UnitPrice = 100, Original_OrderItem__c = items[0].Id),
            new QuoteLineItem(QuoteId = q.Id, Product2Id = prod.Id, PricebookEntryId = pbe.Id,
                               Quantity = 1, UnitPrice = 100, Original_OrderItem__c = items[1].Id)
        };
    }

    @IsTest
    static void testSetPendingChange_UpdatesEligibleAsset_SkipsBlockedAsset() {
        Quote q = [SELECT Id FROM Quote LIMIT 1];
        QuoteCOAssetPendingChange.Request req = new QuoteCOAssetPendingChange.Request();
        req.quoteId = q.Id;

        Test.startTest();
        QuoteCOAssetPendingChange.setPendingChange(new List<QuoteCOAssetPendingChange.Request>{ req });
        Test.stopTest();

        Asset inService = [SELECT Status FROM Asset WHERE Name = 'Asset In Service'];
        System.assertEquals('Pending Change', inService.Status, 'Eligible asset should move to Pending Change');

        Asset closed = [SELECT Status FROM Asset WHERE Name = 'Asset Closed'];
        System.assertEquals('Closed', closed.Status, 'Closed asset is a terminal state and must not be touched');

        Asset untouched = [SELECT Status FROM Asset WHERE Name = 'Asset Untouched'];
        System.assertEquals('In Service', untouched.Status,
            'Asset whose order item is not referenced by any CO quote line must be left alone');
    }

    @IsTest
    static void testSetPendingChange_NullQuoteId_NoOp() {
        QuoteCOAssetPendingChange.Request req = new QuoteCOAssetPendingChange.Request();
        req.quoteId = null;

        Test.startTest();
        QuoteCOAssetPendingChange.setPendingChange(new List<QuoteCOAssetPendingChange.Request>{ req });
        Test.stopTest();

        Asset inService = [SELECT Status FROM Asset WHERE Name = 'Asset In Service'];
        System.assertEquals('In Service', inService.Status, 'A null quoteId should be a no-op');
    }

    @IsTest
    static void testSetPendingChange_EmptyRequestList_NoOp() {
        Test.startTest();
        QuoteCOAssetPendingChange.setPendingChange(new List<QuoteCOAssetPendingChange.Request>());
        Test.stopTest();

        System.assert(true, 'Empty request list should not throw');
    }
}