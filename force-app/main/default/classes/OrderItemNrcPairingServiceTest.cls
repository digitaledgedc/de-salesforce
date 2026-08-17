@IsTest
private class OrderItemNrcPairingServiceTest {

    // ─── deriveNrcCode ────────────────────────────────────────────────────────

    @IsTest
    static void deriveNrcCode_standard() {
        System.assertEquals(
            'CAB001.NR',
            OrderItemNrcPairingService.deriveNrcCode('CAB001.RC'),
            'Standard .RC product should map to .NR'
        );
    }

    @IsTest
    static void deriveNrcCode_variantSuffix() {
        System.assertEquals(
            'CAB001.NR',
            OrderItemNrcPairingService.deriveNrcCode('CAB001C.RC'),
            'Single-letter variant suffix should be stripped before .NR appended'
        );
    }

    @IsTest
    static void deriveNrcCode_multiDigitBase() {
        System.assertEquals(
            'CCX012.NR',
            OrderItemNrcPairingService.deriveNrcCode('CCX012.RC'),
            'Multi-digit base code should work correctly'
        );
    }

    @IsTest
    static void deriveNrcCode_nrcCodeReturnsNull() {
        System.assertEquals(
            null,
            OrderItemNrcPairingService.deriveNrcCode('CAB001.NR'),
            'Passing an NRC code should return null'
        );
    }

    @IsTest
    static void deriveNrcCode_nullAndBlank() {
        System.assertEquals(null, OrderItemNrcPairingService.deriveNrcCode(null), 'Null should return null');
        System.assertEquals(null, OrderItemNrcPairingService.deriveNrcCode(''), 'Empty string should return null');
        System.assertEquals(null, OrderItemNrcPairingService.deriveNrcCode('   '), 'Blank string should return null');
    }

    @IsTest
    static void deriveNrcCode_noSuffix() {
        System.assertEquals(
            null,
            OrderItemNrcPairingService.deriveNrcCode('CAB001'),
            'Code without .RC suffix should return null'
        );
    }

    // ─── pairNrcOrderItems — boundary inputs ─────────────────────────────────

    @IsTest
    static void pairNrcOrderItems_nullInput() {
        Test.startTest();
        OrderItemNrcPairingService.pairNrcOrderItems(null);
        Test.stopTest();
        // No exception = pass
    }

    @IsTest
    static void pairNrcOrderItems_emptyList() {
        Test.startTest();
        OrderItemNrcPairingService.pairNrcOrderItems(
            new List<OrderItemNrcPairingService.Request>()
        );
        Test.stopTest();
        // No exception = pass
    }

    @IsTest
    static void pairNrcOrderItems_nullOrderId() {
        OrderItemNrcPairingService.Request req = new OrderItemNrcPairingService.Request();
        req.orderId = null;
        Test.startTest();
        OrderItemNrcPairingService.pairNrcOrderItems(
            new List<OrderItemNrcPairingService.Request>{ req }
        );
        Test.stopTest();
        // No exception = pass
    }

    // ─── pairNrcOrderItems — real order item pairing scenarios ───────────────

    /**
     * Order resolves to a non-empty orderIds set, but the OrderItem query for it
     * comes back empty (order has no line items yet). Exercises the
     * `if (allOIs.isEmpty()) return;` guard.
     */
    @IsTest
    static void pairNrcOrderItems_noOrderItemsOnOrder() {
        Account acc = new Account(Name = 'NRC Pairing Empty Order Acct', Operation_Country__c = 'Singapore');
        insert acc;

        Order ord = new Order(
            AccountId     = acc.Id,
            EffectiveDate = Date.today(),
            Status        = 'Draft',
            Pricebook2Id  = Test.getStandardPricebookId()
        );
        insert ord;

        OrderItemNrcPairingService.Request req = new OrderItemNrcPairingService.Request();
        req.orderId = ord.Id;

        Test.startTest();
        OrderItemNrcPairingService.pairNrcOrderItems(
            new List<OrderItemNrcPairingService.Request>{ req }
        );
        Test.stopTest();
        // Order has zero OrderItems — allOIs query returns empty, method returns early.
        // No exception = pass.
    }

    /**
     * MRC product has an explicit Paired_NRC_Product__c lookup populated, whose
     * ProductCode deliberately does NOT match what deriveNrcCode() would produce from
     * the MRC code (PAIR001.RC → derived 'PAIR001.NR' vs explicit 'CUSTOM-EXPLICIT-CODE.NR').
     * Pairing only succeeds here if the explicit lookup path (lines 70-72) was used —
     * proving that branch, rather than the code-derivation fallback.
     */
    @IsTest
    static void pairNrcOrderItems_explicitPairedNrcProductLookup() {
        Account acc = new Account(Name = 'NRC Pairing Explicit Lookup Acct', Operation_Country__c = 'Singapore');
        insert acc;

        Product2 nrcProd = new Product2(
            Name = 'Explicit NRC Product', ProductCode = 'CUSTOM-EXPLICIT-CODE.NR',
            IsActive = true, Charge_Type__c = 'NRC'
        );
        insert nrcProd;

        Product2 mrcProd = new Product2(
            Name = 'Explicit MRC Product', ProductCode = 'PAIR001.RC',
            IsActive = true, Charge_Type__c = 'MRC',
            Paired_NRC_Product__c = nrcProd.Id
        );
        insert mrcProd;

        PricebookEntry mrcPbe = new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(), Product2Id = mrcProd.Id,
            UnitPrice = 100, IsActive = true
        );
        PricebookEntry nrcPbe = new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(), Product2Id = nrcProd.Id,
            UnitPrice = 500, IsActive = true
        );
        insert new List<PricebookEntry>{ mrcPbe, nrcPbe };

        Order ord = new Order(
            AccountId     = acc.Id,
            EffectiveDate = Date.today(),
            Status        = 'Draft',
            Pricebook2Id  = Test.getStandardPricebookId()
        );
        insert ord;

        OrderItem mrcOI = new OrderItem(
            OrderId = ord.Id, Product2Id = mrcProd.Id, PricebookEntryId = mrcPbe.Id,
            Quantity = 1, UnitPrice = 100, Charge_Type__c = 'MRC'
        );
        OrderItem nrcOI = new OrderItem(
            OrderId = ord.Id, Product2Id = nrcProd.Id, PricebookEntryId = nrcPbe.Id,
            Quantity = 1, UnitPrice = 500, Charge_Type__c = 'NRC', Is_Auto_NRC__c = true
        );
        insert new List<OrderItem>{ mrcOI, nrcOI };

        OrderItemNrcPairingService.Request req = new OrderItemNrcPairingService.Request();
        req.orderId = ord.Id;

        Test.startTest();
        OrderItemNrcPairingService.pairNrcOrderItems(
            new List<OrderItemNrcPairingService.Request>{ req }
        );
        Test.stopTest();

        OrderItem updatedNrc = [SELECT Paired_MRC_OrderItem__c FROM OrderItem WHERE Id = :nrcOI.Id];
        System.assertEquals(
            mrcOI.Id,
            updatedNrc.Paired_MRC_OrderItem__c,
            'NRC OrderItem should be paired via the explicit Paired_NRC_Product__r lookup, ' +
            'not code-based derivation (the derived code would not have matched).'
        );
    }

    /**
     * Running user's profile has no Update access on OrderItem
     * ('Minimum Access - Salesforce' grants no object permissions on it), so
     * OrderItem.SObjectType.getDescribe().isUpdateable() returns false. Exercises the
     * `if (!...isUpdateable()) return;` guard — pairing is computed but the DML is
     * skipped rather than throwing an insufficient-access exception.
     */
    @IsTest
    static void pairNrcOrderItems_skipsUpdateWhenNotUpdateable() {
        Profile restrictedProfile = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
        User restrictedUser = new User(
            Alias             = 'nrcfls',
            Email             = 'nrc-fls-test@gokarya.test.invalid',
            EmailEncodingKey  = 'UTF-8',
            LastName          = 'NrcFlsTestUser',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey      = 'en_US',
            ProfileId         = restrictedProfile.Id,
            TimeZoneSidKey    = 'America/Los_Angeles',
            UserName          = 'nrc-fls-test@gokarya.test.invalid'
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert restrictedUser;
        }

        Account acc = new Account(Name = 'NRC Pairing FLS Acct', Operation_Country__c = 'Singapore');
        insert acc;

        Product2 mrcProd = new Product2(
            Name = 'FLS MRC Product', ProductCode = 'FLS001.RC', IsActive = true, Charge_Type__c = 'MRC'
        );
        Product2 nrcProd = new Product2(
            Name = 'FLS NRC Product', ProductCode = 'FLS001.NR', IsActive = true, Charge_Type__c = 'NRC'
        );
        insert new List<Product2>{ mrcProd, nrcProd };

        PricebookEntry mrcPbe = new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(), Product2Id = mrcProd.Id,
            UnitPrice = 100, IsActive = true
        );
        PricebookEntry nrcPbe = new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(), Product2Id = nrcProd.Id,
            UnitPrice = 500, IsActive = true
        );
        insert new List<PricebookEntry>{ mrcPbe, nrcPbe };

        Order ord = new Order(
            AccountId     = acc.Id,
            EffectiveDate = Date.today(),
            Status        = 'Draft',
            Pricebook2Id  = Test.getStandardPricebookId()
        );
        insert ord;

        OrderItem mrcOI = new OrderItem(
            OrderId = ord.Id, Product2Id = mrcProd.Id, PricebookEntryId = mrcPbe.Id,
            Quantity = 1, UnitPrice = 100, Charge_Type__c = 'MRC'
        );
        OrderItem nrcOI = new OrderItem(
            OrderId = ord.Id, Product2Id = nrcProd.Id, PricebookEntryId = nrcPbe.Id,
            Quantity = 1, UnitPrice = 500, Charge_Type__c = 'NRC', Is_Auto_NRC__c = true
        );
        insert new List<OrderItem>{ mrcOI, nrcOI };

        OrderItemNrcPairingService.Request req = new OrderItemNrcPairingService.Request();
        req.orderId = ord.Id;

        Test.startTest();
        System.runAs(restrictedUser) {
            OrderItemNrcPairingService.pairNrcOrderItems(
                new List<OrderItemNrcPairingService.Request>{ req }
            );
        }
        Test.stopTest();

        OrderItem afterAttempt = [SELECT Paired_MRC_OrderItem__c FROM OrderItem WHERE Id = :nrcOI.Id];
        System.assertEquals(
            null,
            afterAttempt.Paired_MRC_OrderItem__c,
            'Update should be skipped (not throw) when the running user profile lacks Update ' +
            'access on OrderItem — isUpdateable() is false.'
        );
    }
}