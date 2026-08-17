/**
 * LockOdooSpacesQueueableTest
 *
 * Tests for LockOdooSpacesQueueable (IP-3: lock Space/Breaker inventory in Odoo
 * after New Service order provisioning). All Odoo callouts are mocked — no real
 * callouts are made. Uses the org's existing OdooIntegrationSettings__c hierarchy
 * custom setting default (already provisioned in this org) rather than inserting
 * a new one, since only a single org-default row is permitted.
 */
@IsTest
private class LockOdooSpacesQueueableTest {

    // Generic Odoo callout mock: returns a JSON-RPC "success" body for every
    // endpoint by default; endpoints whose URL contains a configured fragment
    // return a JSON-RPC application-level error instead. Tracks invocation count
    // so tests can assert exactly how many unique callouts were made.
    private class OdooMock implements HttpCalloutMock {
        public Integer callCount = 0;
        public List<String> requestedEndpoints = new List<String>();
        public Set<String> failEndpointsContaining = new Set<String>();

        public HttpResponse respond(HttpRequest req) {
            callCount++;
            requestedEndpoints.add(req.getEndpoint());
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            Boolean shouldFail = false;
            for (String frag : failEndpointsContaining) {
                if (req.getEndpoint().contains(frag)) {
                    shouldFail = true;
                    break;
                }
            }
            if (shouldFail) {
                res.setBody('{"result": {"status": "error", "message": "Simulated Odoo failure"}}');
            } else {
                res.setBody('{"result": {"id": 1}}');
            }
            return res;
        }
    }

    private static Id spaceRecordTypeId() {
        return Schema.SObjectType.Inventory__c.getRecordTypeInfosByDeveloperName()
            .get('Inventory_Space').getRecordTypeId();
    }

    private static Id breakerRecordTypeId() {
        return Schema.SObjectType.Inventory__c.getRecordTypeInfosByDeveloperName()
            .get('Inventory_Breaker').getRecordTypeId();
    }

    private static Site__c makeSite() {
        Site__c site = new Site__c(Name = 'Test Site LOSQ', Site_Code__c = 'TSTLOSQ', Country__c = 'SG');
        insert site;
        return site;
    }

    private static Order makeOrder(Id pricebookId) {
        Account acct = new Account(Name = 'Test Account LOSQ');
        insert acct;
        Order ord = new Order(
            AccountId = acct.Id, Status = 'Draft',
            EffectiveDate = Date.today(), Pricebook2Id = pricebookId
        );
        insert ord;
        return ord;
    }

    private static PricebookEntry makeStandardPbe() {
        Product2 p = new Product2(Name = 'Test LOSQ Product', IsActive = true, ProductCode = 'LOSQ-PROD');
        insert p;
        Id stdPbId = Test.getStandardPricebookId();
        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = stdPbId, Product2Id = p.Id, UnitPrice = 100, CurrencyIsoCode = 'USD', IsActive = true
        );
        insert pbe;
        return pbe;
    }

    @IsTest
    static void testLockSpaceAndBreakerSuccess() {
        Site__c site = makeSite();
        PricebookEntry pbe = makeStandardPbe();
        Order ord = makeOrder(Test.getStandardPricebookId());

        Inventory__c space1 = new Inventory__c(RecordTypeId = spaceRecordTypeId(), Site_Id__c = site.Id, Odoo_Space_ID__c = 'SPC-1001', Odoo_Inventory_Id__c = 'SPC-1001', Status__c = 'Available');
        Inventory__c breaker1 = new Inventory__c(RecordTypeId = breakerRecordTypeId(), Site_Id__c = site.Id, Odoo_Space_ID__c = 'BRK-2002', Odoo_Inventory_Id__c = 'BRK-2002', Status__c = 'Available');
        Inventory__c space2 = new Inventory__c(RecordTypeId = spaceRecordTypeId(), Site_Id__c = site.Id, Odoo_Space_ID__c = 'SPC-1003', Odoo_Inventory_Id__c = 'SPC-1003', Status__c = 'Available');
        Inventory__c breaker2 = new Inventory__c(RecordTypeId = breakerRecordTypeId(), Site_Id__c = site.Id, Odoo_Space_ID__c = 'BRK-2004', Odoo_Inventory_Id__c = 'BRK-2004', Status__c = 'Available');
        Inventory__c space3 = new Inventory__c(RecordTypeId = spaceRecordTypeId(), Site_Id__c = site.Id, Odoo_Space_ID__c = 'SPC-1005', Odoo_Inventory_Id__c = 'SPC-1005', Status__c = 'Available');
        insert new List<Inventory__c>{ space1, breaker1, space2, breaker2, space3 };

        List<OrderItem> items = new List<OrderItem>{
            new OrderItem(OrderId = ord.Id, Product2Id = pbe.Product2Id, PricebookEntryId = pbe.Id, Quantity = 1, UnitPrice = 100, Is_Active__c = true, Space__c = space1.Id),
            new OrderItem(OrderId = ord.Id, Product2Id = pbe.Product2Id, PricebookEntryId = pbe.Id, Quantity = 1, UnitPrice = 100, Is_Active__c = true, Inventory__c = breaker1.Id),
            // Combined space + breaker on a single order item
            new OrderItem(OrderId = ord.Id, Product2Id = pbe.Product2Id, PricebookEntryId = pbe.Id, Quantity = 1, UnitPrice = 100, Is_Active__c = true, Space__c = space2.Id, Inventory__c = breaker2.Id),
            // Duplicate reference to space1 — should be de-duped, not double-locked
            new OrderItem(OrderId = ord.Id, Product2Id = pbe.Product2Id, PricebookEntryId = pbe.Id, Quantity = 1, UnitPrice = 100, Is_Active__c = true, Space__c = space1.Id),
            // Inactive line referencing space3 — must be excluded entirely
            new OrderItem(OrderId = ord.Id, Product2Id = pbe.Product2Id, PricebookEntryId = pbe.Id, Quantity = 1, UnitPrice = 100, Is_Active__c = false, Space__c = space3.Id)
        };
        insert items;

        OdooMock mock = new OdooMock();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        System.enqueueJob(new LockOdooSpacesQueueable(new List<Id>{ ord.Id }));
        Test.stopTest();

        // Unique units: space1, breaker1, space2, breaker2 = 4 callouts (dup + inactive excluded)
        Assert.areEqual(4, mock.callCount, 'Should make exactly one callout per unique active Space/Breaker');
        Assert.areEqual(0, [SELECT COUNT() FROM DE_Integration_Error__c], 'No errors expected on success');
    }

    @IsTest
    static void testLockFailureCreatesErrorRecord() {
        Site__c site = makeSite();
        PricebookEntry pbe = makeStandardPbe();
        Order ord = makeOrder(Test.getStandardPricebookId());

        Inventory__c space1 = new Inventory__c(RecordTypeId = spaceRecordTypeId(), Site_Id__c = site.Id, Odoo_Space_ID__c = 'SPC-9001', Odoo_Inventory_Id__c = 'SPC-9001', Status__c = 'Available');
        insert space1;

        OrderItem oi = new OrderItem(OrderId = ord.Id, Product2Id = pbe.Product2Id, PricebookEntryId = pbe.Id, Quantity = 1, UnitPrice = 100, Is_Active__c = true, Space__c = space1.Id);
        insert oi;

        OdooMock mock = new OdooMock();
        mock.failEndpointsContaining.add('ns_space/9001');
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        System.enqueueJob(new LockOdooSpacesQueueable(new List<Id>{ ord.Id }));
        Test.stopTest();

        List<DE_Integration_Error__c> errors = [SELECT Error_Message__c, IP_Reference__c, Status__c, Record_Id__c FROM DE_Integration_Error__c];
        Assert.areEqual(1, errors.size(), 'Failed lock should create exactly one error record');
        Assert.isTrue(errors[0].Error_Message__c.contains('Failed to lock Space'), 'Error message should describe the failure: ' + errors[0].Error_Message__c);
        Assert.areEqual('IP-3', errors[0].IP_Reference__c);
        Assert.areEqual('Open', errors[0].Status__c);
        Assert.areEqual(String.valueOf(ord.Id), errors[0].Record_Id__c);
    }

    @IsTest
    static void testNoOrderItemsWithInventoryIsNoOp() {
        PricebookEntry pbe = makeStandardPbe();
        Order ord = makeOrder(Test.getStandardPricebookId());

        // Order item with no Space or Inventory assignment at all
        insert new OrderItem(OrderId = ord.Id, Product2Id = pbe.Product2Id, PricebookEntryId = pbe.Id, Quantity = 1, UnitPrice = 100, Is_Active__c = true);

        OdooMock mock = new OdooMock();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        System.enqueueJob(new LockOdooSpacesQueueable(new List<Id>{ ord.Id }));
        Test.stopTest();

        Assert.areEqual(0, mock.callCount, 'No callouts should be made when no Space/Inventory is assigned');
        Assert.areEqual(0, [SELECT COUNT() FROM DE_Integration_Error__c]);
    }

    @IsTest
    static void testCalloutLimitExceededCreatesErrorRecord() {
        Site__c site = makeSite();
        PricebookEntry pbe = makeStandardPbe();
        Order ord = makeOrder(Test.getStandardPricebookId());

        List<Inventory__c> spaces = new List<Inventory__c>();
        for (Integer i = 0; i < 101; i++) {
            spaces.add(new Inventory__c(
                RecordTypeId = spaceRecordTypeId(), Site_Id__c = site.Id,
                Odoo_Space_ID__c = 'SPC-' + (5000 + i),
                Odoo_Inventory_Id__c = 'SPC-' + (5000 + i), Status__c = 'Available'
            ));
        }
        insert spaces;

        List<OrderItem> items = new List<OrderItem>();
        for (Inventory__c sp : spaces) {
            items.add(new OrderItem(
                OrderId = ord.Id, Product2Id = pbe.Product2Id, PricebookEntryId = pbe.Id,
                Quantity = 1, UnitPrice = 100, Is_Active__c = true, Space__c = sp.Id
            ));
        }
        insert items;

        OdooMock mock = new OdooMock();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        System.enqueueJob(new LockOdooSpacesQueueable(new List<Id>{ ord.Id }));
        Test.stopTest();

        Assert.areEqual(100, mock.callCount, 'Should stop making callouts once the 100-callout governor cap is hit');
        List<DE_Integration_Error__c> errors = [SELECT Error_Message__c FROM DE_Integration_Error__c];
        Assert.areEqual(1, errors.size(), 'The single unit beyond the cap should log exactly one error');
        Assert.isTrue(errors[0].Error_Message__c.contains('Callout limit reached'), 'Error should describe the cap: ' + errors[0].Error_Message__c);
    }

    /**
     * Mirrors testLockFailureCreatesErrorRecord but for the Breaker path
     * (Inventory__c) — covers the "Failed to lock Breaker" error-creation
     * branch (~lines 99-102), which the existing Space-only failure test
     * never reaches.
     */
    @IsTest
    static void testBreakerLockFailureCreatesErrorRecord() {
        Site__c site = makeSite();
        PricebookEntry pbe = makeStandardPbe();
        Order ord = makeOrder(Test.getStandardPricebookId());

        Inventory__c breaker1 = new Inventory__c(RecordTypeId = breakerRecordTypeId(), Site_Id__c = site.Id, Odoo_Space_ID__c = 'BRK-9002', Odoo_Inventory_Id__c = 'BRK-9002', Status__c = 'Available');
        insert breaker1;

        OrderItem oi = new OrderItem(OrderId = ord.Id, Product2Id = pbe.Product2Id, PricebookEntryId = pbe.Id, Quantity = 1, UnitPrice = 100, Is_Active__c = true, Inventory__c = breaker1.Id);
        insert oi;

        OdooMock mock = new OdooMock();
        mock.failEndpointsContaining.add('ns_breaker/9002');
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        System.enqueueJob(new LockOdooSpacesQueueable(new List<Id>{ ord.Id }));
        Test.stopTest();

        List<DE_Integration_Error__c> errors = [SELECT Error_Message__c, IP_Reference__c, Status__c, Record_Id__c FROM DE_Integration_Error__c];
        Assert.areEqual(1, errors.size(), 'Failed breaker lock should create exactly one error record');
        Assert.isTrue(errors[0].Error_Message__c.contains('Failed to lock Breaker'), 'Error message should describe the breaker failure: ' + errors[0].Error_Message__c);
        Assert.areEqual('IP-3', errors[0].IP_Reference__c);
        Assert.areEqual('Open', errors[0].Status__c);
        Assert.areEqual(String.valueOf(ord.Id), errors[0].Record_Id__c);
    }

    /**
     * Mirrors testCalloutLimitExceededCreatesErrorRecord but for the Breaker
     * path — covers the "Callout limit reached (100)" error-creation branch
     * for breakers (~lines 86-91), which the existing Space-only governor-cap
     * test never reaches.
     */
    @IsTest
    static void testBreakerCalloutLimitExceededCreatesErrorRecord() {
        Site__c site = makeSite();
        PricebookEntry pbe = makeStandardPbe();
        Order ord = makeOrder(Test.getStandardPricebookId());

        List<Inventory__c> breakers = new List<Inventory__c>();
        for (Integer i = 0; i < 101; i++) {
            breakers.add(new Inventory__c(
                RecordTypeId = breakerRecordTypeId(), Site_Id__c = site.Id,
                Odoo_Space_ID__c = 'BRK-' + (6000 + i),
                Odoo_Inventory_Id__c = 'BRK-' + (6000 + i), Status__c = 'Available'
            ));
        }
        insert breakers;

        List<OrderItem> items = new List<OrderItem>();
        for (Inventory__c b : breakers) {
            items.add(new OrderItem(
                OrderId = ord.Id, Product2Id = pbe.Product2Id, PricebookEntryId = pbe.Id,
                Quantity = 1, UnitPrice = 100, Is_Active__c = true, Inventory__c = b.Id
            ));
        }
        insert items;

        OdooMock mock = new OdooMock();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        System.enqueueJob(new LockOdooSpacesQueueable(new List<Id>{ ord.Id }));
        Test.stopTest();

        Assert.areEqual(100, mock.callCount, 'Should stop making callouts once the 100-callout governor cap is hit');
        List<DE_Integration_Error__c> errors = [SELECT Error_Message__c FROM DE_Integration_Error__c];
        Assert.areEqual(1, errors.size(), 'The single breaker beyond the cap should log exactly one error');
        Assert.isTrue(errors[0].Error_Message__c.contains('Callout limit reached'), 'Error should describe the cap: ' + errors[0].Error_Message__c);
        Assert.isTrue(errors[0].Error_Message__c.contains('Breaker'), 'Error should mention Breaker: ' + errors[0].Error_Message__c);
    }

    @IsTest
    static void testExtractOdooIntIdVariants() {
        Assert.areEqual('32196', LockOdooSpacesQueueable.extractOdooIntId('SPC-32196'), 'Should strip SPC- prefix');
        Assert.areEqual('3659', LockOdooSpacesQueueable.extractOdooIntId('BRK-3659'), 'Should strip BRK- prefix');
        Assert.areEqual('99', LockOdooSpacesQueueable.extractOdooIntId('AB-CD-99'), 'Should take the segment after the last dash');
        Assert.areEqual('12345', LockOdooSpacesQueueable.extractOdooIntId('12345'), 'Bare integers should pass through unchanged');
        Assert.isNull(LockOdooSpacesQueueable.extractOdooIntId(null), 'Null input should return null');
        Assert.isNull(LockOdooSpacesQueueable.extractOdooIntId(''), 'Blank input should return null');
    }
}