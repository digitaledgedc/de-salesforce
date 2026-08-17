@IsTest
private class OrderNumberGeneratorTest {

    @TestSetup
    static void setup() {
        Account acct = new Account(Name = 'Test Customer', Operation_Country__c = 'Singapore');
        insert acct;

        // Opportunity trigger assigns Opportunity_Number__c automatically on insert
        Opportunity opp = new Opportunity(
            Name      = 'Test Opp',
            AccountId = acct.Id,
            StageName = '1 - Suspect',
            CloseDate = Date.today().addMonths(3)
        );
        insert opp;
    }

    // ─── helpers ─────────────────────────────────────────────────────────────────

    private static Opportunity getOpp() {
        return [SELECT Id, Opportunity_Number__c FROM Opportunity LIMIT 1];
    }

    private static Account getAcct() {
        return [SELECT Id FROM Account LIMIT 1];
    }

    // ─── tests ───────────────────────────────────────────────────────────────────

    @IsTest
    static void assignNumbers_setsNumberOnFirstOrder() {
        Opportunity opp = getOpp();

        Order ord = new Order(
            AccountId     = getAcct().Id,
            OpportunityId = opp.Id,
            Status        = 'Draft',
            EffectiveDate = Date.today()
        );

        Test.startTest();
        OrderNumberGenerator.assignNumbers(new List<Order>{ ord });
        Test.stopTest();

        System.assertNotEquals(null, ord.Order_Number__c, 'Order_Number__c must be assigned');
        System.assert(
            ord.Order_Number__c.startsWith(opp.Opportunity_Number__c + '-OR-'),
            'Order_Number__c must start with Opportunity_Number__c-OR-'
        );
        System.assertEquals(opp.Opportunity_Number__c + '-OR-1', ord.Order_Number__c,
            'First Order on this Opportunity must be sequence 1');
    }

    @IsTest
    static void assignNumbers_doesNotOverwriteExistingNumber() {
        Opportunity opp = getOpp();

        Order ord = new Order(
            AccountId       = getAcct().Id,
            OpportunityId   = opp.Id,
            Status          = 'Draft',
            EffectiveDate   = Date.today(),
            Order_Number__c = 'MANUAL-001'
        );

        Test.startTest();
        OrderNumberGenerator.assignNumbers(new List<Order>{ ord });
        Test.stopTest();

        System.assertEquals('MANUAL-001', ord.Order_Number__c,
            'Pre-existing Order_Number__c must not be overwritten');
    }

    @IsTest
    static void assignNumbers_sequencesIncrementWithinBatch() {
        Opportunity opp = getOpp();
        Account acct = getAcct();

        List<Order> orders = new List<Order>{
            new Order(AccountId = acct.Id, OpportunityId = opp.Id, Status = 'Draft', EffectiveDate = Date.today()),
            new Order(AccountId = acct.Id, OpportunityId = opp.Id, Status = 'Draft', EffectiveDate = Date.today()),
            new Order(AccountId = acct.Id, OpportunityId = opp.Id, Status = 'Draft', EffectiveDate = Date.today())
        };

        Test.startTest();
        OrderNumberGenerator.assignNumbers(orders);
        Test.stopTest();

        Set<String> numbers = new Set<String>();
        for (Order ord : orders) {
            System.assertNotEquals(null, ord.Order_Number__c, 'Every Order must have a number');
            numbers.add(ord.Order_Number__c);
        }
        System.assertEquals(3, numbers.size(), 'All 3 Orders must have distinct numbers');
        System.assertEquals(opp.Opportunity_Number__c + '-OR-1', orders[0].Order_Number__c);
        System.assertEquals(opp.Opportunity_Number__c + '-OR-2', orders[1].Order_Number__c);
        System.assertEquals(opp.Opportunity_Number__c + '-OR-3', orders[2].Order_Number__c);
    }

    @IsTest
    static void assignNumbers_continuesSequenceAfterExistingOrders() {
        Opportunity opp = getOpp();
        Account acct = getAcct();

        // Pre-set Order_Number__c to simulate an already-numbered existing Order
        // (direct assign simulates what the trigger already set on a prior insert)
        Order existing = new Order(
            AccountId       = acct.Id,
            OpportunityId   = opp.Id,
            Status          = 'Draft',
            EffectiveDate   = Date.today(),
            Order_Number__c = opp.Opportunity_Number__c + '-OR-1'
        );
        insert existing;

        Order newOrd = new Order(
            AccountId     = acct.Id,
            OpportunityId = opp.Id,
            Status        = 'Draft',
            EffectiveDate = Date.today()
        );

        Test.startTest();
        OrderNumberGenerator.assignNumbers(new List<Order>{ newOrd });
        Test.stopTest();

        System.assertEquals(opp.Opportunity_Number__c + '-OR-2', newOrd.Order_Number__c,
            'Second Order on this Opportunity must be sequence 2');
    }

    @IsTest
    static void assignNumbers_skipsOrdersWithoutOpportunity() {
        Order ord = new Order(
            AccountId     = getAcct().Id,
            Status        = 'Draft',
            EffectiveDate = Date.today()
            // OpportunityId intentionally omitted
        );

        Test.startTest();
        OrderNumberGenerator.assignNumbers(new List<Order>{ ord });
        Test.stopTest();

        System.assertEquals(null, ord.Order_Number__c,
            'Orders without an OpportunityId must not have a number assigned');
    }

    @IsTest
    static void assignNumbers_handlesEmptyList() {
        Test.startTest();
        OrderNumberGenerator.assignNumbers(new List<Order>());
        Test.stopTest();
        System.assert(true, 'Empty list call completed without exception');
    }
}