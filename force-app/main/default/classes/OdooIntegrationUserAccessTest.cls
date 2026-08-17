/**
 * OdooIntegrationUserAccessTest
 *
 * Access-stack coverage for the inbound Odoo REST endpoints. Every handler is
 * invoked while running as a user provisioned exactly like the SFDC Api
 * integration user: Profile 'DE Integration' + Permission Set Group
 * 'DE_PSG_Integration' (which grants object/FLS via DE_Odoo_Integration_Permission
 * and Apex class access via Odoo_Apex_Access).
 *
 * WHAT THIS PROVES — and its limits:
 *  - OdooCrossConnectHandler runs its Account lookup WITH SECURITY_ENFORCED, so
 *    executing it under runAs genuinely validates the integration user's object
 *    read + FLS on Account (Odoo_Partner_ID__c, Name). This is the one real
 *    field-level assertion of the stack.
 *  - The other handlers perform their SOQL/DML in system mode, so runAs here
 *    validates that the user can be provisioned on the DE Integration license
 *    stack and that record VISIBILITY (sharing) is sufficient for the handler to
 *    complete — not field-level security.
 *
 * The integration user is created in @TestSetup (setup sObjects only) so it lives
 * in its own transaction, keeping it clear of MIXED_DML with the business data
 * each test method inserts as the (admin) test-running user before entering runAs.
 */
@IsTest
private class OdooIntegrationUserAccessTest {

    private static final String USER_MARKER = 'OdooIntegAccessTest';

    @TestSetup
    static void provisionIntegrationUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'DE Integration' LIMIT 1];

        User u = new User(
            Alias             = 'deapi',
            LastName          = USER_MARKER,
            Email             = 'odoo.integ.access@example.com.invalid',
            Username          = 'odoo.integ.access.' + System.now().getTime() + '@example.com.deful',
            EmailEncodingKey  = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey      = 'en_US',
            TimeZoneSidKey    = 'America/Los_Angeles',
            ProfileId         = p.Id
        );
        insert u;

        // The object/FLS permission set is tied to the Salesforce API Integration
        // PSL — assign it before the group so the group's member set is grantable.
        List<PermissionSetLicense> psls = [
            SELECT Id FROM PermissionSetLicense
            WHERE DeveloperName = 'SalesforceAPIIntegrationPsl' LIMIT 1
        ];
        if (!psls.isEmpty()) {
            insert new PermissionSetLicenseAssign(
                AssigneeId = u.Id, PermissionSetLicenseId = psls[0].Id
            );
        }

        PermissionSetGroup psg = [
            SELECT Id FROM PermissionSetGroup
            WHERE DeveloperName = 'DE_PSG_Integration' LIMIT 1
        ];
        insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetGroupId = psg.Id);
    }

    private static User integrationUser() {
        return [SELECT Id FROM User WHERE LastName = :USER_MARKER LIMIT 1];
    }

    private static void call(String uri, String jsonBody) {
        RestRequest req = new RestRequest();
        req.requestURI  = uri;
        req.httpMethod  = 'POST';
        req.requestBody = Blob.valueOf(jsonBody);
        RestContext.request  = req;
        RestContext.response = new RestResponse();
    }

    private static Id accountCustomerRt() {
        return [
            SELECT Id FROM RecordType
            WHERE SObjectType = 'Account' AND DeveloperName = 'Customer' LIMIT 1
        ].Id;
    }

    // ─── IP-6: Cross-connect (FLS-enforced Account read) ────────────────────────

    @IsTest
    static void crossConnect_runsAsIntegrationUser() {
        Account acc = new Account(
            Name                 = 'CC Access Cust',
            BillingCountry       = 'Singapore',
            Operation_Country__c = 'Singapore',
            Odoo_Partner_ID__c   = 7777,
            RecordTypeId         = accountCustomerRt()
        );
        insert acc;

        call('/services/apexrest/de/crossconnect',
            '{"partner_id": 7777, "odoo_order_id": 15800, "site_code": "SIN1",'
            + '"cross_connect_type": "SMF", "mrc": 850.00, "rdd": "2026-07-01"}');

        System.runAs(integrationUser()) {
            Test.startTest();
            OdooCrossConnectHandler.handlePost();
            Test.stopTest();
        }

        System.assertEquals(200, RestContext.response.statusCode,
            'CrossConnect must succeed as the integration user (validates Account read + FLS)');
        System.assert(RestContext.response.responseBody.toString().contains('"order_id"'),
            'An Order should have been created for the matched Account');
        System.assertEquals(1, [SELECT COUNT() FROM Order WHERE AccountId = :acc.Id],
            'Exactly one Order created under the integration user context');
    }

    // ─── IP-2: Order confirm ────────────────────────────────────────────────────

    @IsTest
    static void orderConfirm_runsAsIntegrationUser() {
        Account acc = new Account(Name = 'OC Access Account');
        insert acc;

        Product2 prod = new Product2(Name = 'OC Access Product', IsActive = true);
        insert prod;
        Id stdPbId = Test.getStandardPricebookId();
        insert new PricebookEntry(
            Pricebook2Id = stdPbId, Product2Id = prod.Id, UnitPrice = 100, IsActive = true);
        PricebookEntry pbe = [
            SELECT Id FROM PricebookEntry
            WHERE Pricebook2Id = :stdPbId AND Product2Id = :prod.Id LIMIT 1];

        Order ord = new Order(
            AccountId = acc.Id, Status = 'Draft', EffectiveDate = Date.today(),
            Operation_Site__c = 'JKT1', Pricebook2Id = stdPbId, Order_Type__c = 'New Service');
        insert ord;

        OrderItem oi = new OrderItem(
            OrderId = ord.Id, PricebookEntryId = pbe.Id, Quantity = 1, UnitPrice = 100);
        insert oi;

        call('/services/apexrest/de/orderconfirm',
            '{"sf_order_id": "' + ord.Id + '", "odoo_order_id": 7001, "subscription_id": 8001,'
            + '"lines": [{"sf_orderitem_id": "' + oi.Id + '", "odoo_sub_line_id": 9001,'
            + '"odoo_origin_line_id": 9101}]}');

        System.runAs(integrationUser()) {
            Test.startTest();
            OdooOrderConfirmHandler.handlePost();
            Test.stopTest();
        }

        System.assertEquals(200, RestContext.response.statusCode,
            'OrderConfirm must complete as the integration user: '
            + RestContext.response.responseBody.toString());
    }

    // ─── IP-3: Inventory sync (create space) ────────────────────────────────────

    @IsTest
    static void inventorySync_runsAsIntegrationUser() {
        Site__c site = new Site__c(Site_Code__c = 'TST1', Odoo_Site_ID__c = 42, Country__c = 'JP');
        insert site;
        Floor__c floor = new Floor__c(Name = 'Floor 9', Site__c = site.Id);
        insert floor;
        insert new DataHall__c(Name = 'TST1-09-01', Floor__c = floor.Id, Site__c = site.Id);

        call('/services/apexrest/de/inventory', JSON.serialize(new Map<String, Object>{
            'event_type'        => 'create',
            'model_type'        => 'ns.ns_space',
            'id'                => 99001,
            'ns_name'           => 'JKT2-ACCESS-SPACE-001',
            'ns_stage'          => 'available',
            'capacity_kva'      => 10.5,
            'ns_operation_site' => 42
        }));

        System.runAs(integrationUser()) {
            Test.startTest();
            OdooInventorySyncHandler.handlePost();
            Test.stopTest();
        }

        System.assertEquals(200, RestContext.response.statusCode,
            'InventorySync must complete as the integration user: '
            + RestContext.response.responseBody.toString());
    }

    // ─── IP-5: Invoice sync ─────────────────────────────────────────────────────

    @IsTest
    static void invoiceSync_runsAsIntegrationUser() {
        Account acc = new Account(
            Name = 'IS Access Cust', BillingCountry = 'Singapore',
            Operation_Country__c = 'Singapore', RecordTypeId = accountCustomerRt());
        insert acc;

        Id deEntityRtId = Schema.SObjectType.Account
            .getRecordTypeInfosByDeveloperName().get('DE_Entity').getRecordTypeId();
        Account sgEntity = new Account(Name = 'DE SG Pte Ltd Access', RecordTypeId = deEntityRtId);
        insert sgEntity;

        Contact con = new Contact(
            AccountId = acc.Id, FirstName = 'IS', LastName = 'BillingContact',
            Email = 'is-billing@test.com');
        insert con;

        BillingAccount__c ban = new BillingAccount__c(
            Account__c = acc.Id, DE_Entity__c = sgEntity.Id, Billing_Contact__c = con.Id);
        insert ban;

        Id stdPbId = Test.getStandardPricebookId();
        Order ord = new Order(
            AccountId = acc.Id, BillingAccount__c = ban.Id, Status = 'Draft',
            EffectiveDate = Date.today().addMonths(-3), Operation_Site__c = 'JKT1',
            Pricebook2Id = stdPbId, Order_Type__c = 'New Service', Contract_Term_Months__c = 24);
        insert ord;

        insert new BillingEvent__c(
            Order__c = ord.Id, BAN__c = ban.Id, Odoo_Line_ID__c = '4401',
            External_Invoice_Id__c = 'EXT-ACCESS-001', Status__c = 'Sent to Odoo',
            MRC_Amount__c = 2000.00, Billed_Quantity__c = 1, Original_Quantity__c = 1);

        call('/services/apexrest/de/invoicesync',
            '{"invoices":[{"odoo_line_id": 4401, "invoice_number": "INV-ACCESS-001",'
            + '"invoice_date": "2026-05-01", "invoice_amount": 2000.00, "amount_paid": 2000.00,'
            + '"balance": 0, "due_date": "2026-06-01", "payment_date": "2026-05-20"}]}');

        System.runAs(integrationUser()) {
            Test.startTest();
            OdooInvoiceSyncHandler.handlePost();
            Test.stopTest();
        }

        System.assertEquals(200, RestContext.response.statusCode,
            'InvoiceSync must complete as the integration user');
    }

    // ─── IP-1/status: asset-status endpoint (error path — success path has a
    //     documented pre-existing 500 bug, see OdooStatusSyncHandlerTest) ─────────

    @IsTest
    static void assetStatus_runsAsIntegrationUser() {
        call('/services/apexrest/de/assetstatus', JSON.serialize(new Map<String, Object>{
            'event_type'  => 'unknown_type',
            'odoo_sub_id' => 5003,
            'lines'       => new List<Object>{ new Map<String, Object>{ 'odoo_ib_id' => 5103 } }
        }));

        System.runAs(integrationUser()) {
            Test.startTest();
            OdooAssetStatusHandler.handlePost();
            Test.stopTest();
        }

        System.assertEquals(400, RestContext.response.statusCode,
            'AssetStatus endpoint should parse + reject an unknown event type as the integration user');
    }

    // ─── Legacy status-sync alias (forwards to OdooAssetStatusHandler) ───────────

    @IsTest
    static void statusSync_runsAsIntegrationUser() {
        call('/services/apexrest/odoo/status-sync/v1', JSON.serialize(new Map<String, Object>{
            'event_type'  => 'amendment',
            'odoo_sub_id' => 5002
        }));

        System.runAs(integrationUser()) {
            Test.startTest();
            OdooStatusSyncHandler.handleStatusUpdate();
            Test.stopTest();
        }

        System.assertEquals(400, RestContext.response.statusCode,
            'Legacy status-sync alias should forward and return 400 as the integration user');
    }
}