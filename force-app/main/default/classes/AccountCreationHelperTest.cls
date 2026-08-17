@isTest
private class AccountCreationHelperTest {

    private static AccountCreationHelper.AccountInput buildInput(String name, String parentId) {
        AccountCreationHelper.AccountInput inp = new AccountCreationHelper.AccountInput();
        inp.name = name;
        inp.type = 'Customer';
        inp.status = 'Active';
        inp.kycStatus = 'Approved';
        inp.financeApprovalStatus = 'Approved';
        inp.operationCountry = 'Singapore';
        if (parentId != null) {
            inp.parentId = parentId;
        }
        return inp;
    }

    @isTest
    static void testCreateAccount_singleSuccess() {
        AccountCreationHelper.AccountInput inp = buildInput('AC Helper Success Co', null);
        inp.ownerId = UserInfo.getUserId();

        List<AccountCreationHelper.AccountOutput> outputs =
            AccountCreationHelper.createAccount(new List<AccountCreationHelper.AccountInput>{ inp });

        Assert.areEqual(1, outputs.size(), 'Expected exactly one output for one input');
        AccountCreationHelper.AccountOutput out = outputs[0];
        Assert.isNotNull(out.accountId, 'Successful insert should return an accountId');
        Assert.isNull(out.errorMessage, 'Successful insert should not carry an error message');

        Account created = [
            SELECT Name, Type, Account_Tier__c, Status__c, KYC_Status__c, Operation_Country__c, OwnerId
            FROM Account WHERE Id = :out.accountId
        ];
        Assert.areEqual('AC Helper Success Co', created.Name, 'Name should match input');
        Assert.areEqual('Customer', created.Type, 'Type should be set from input.type');
        Assert.areEqual('Customer', created.Account_Tier__c, 'Account_Tier__c is also set from input.type per current implementation');
        Assert.areEqual('Active', created.Status__c, 'Status__c should be set from input.status');
        Assert.areEqual('Approved', created.KYC_Status__c, 'KYC_Status__c should be set from input.kycStatus');
        Assert.areEqual('Singapore', created.Operation_Country__c, 'Operation_Country__c should be set from input');
        Assert.areEqual(UserInfo.getUserId(), created.OwnerId, 'OwnerId should be set from input.ownerId');
    }

    @isTest
    static void testCreateAccount_bulk200() {
        List<AccountCreationHelper.AccountInput> inputs = new List<AccountCreationHelper.AccountInput>();
        for (Integer i = 0; i < 200; i++) {
            inputs.add(buildInput('AC Helper Bulk Co ' + i, null));
        }

        List<AccountCreationHelper.AccountOutput> outputs = AccountCreationHelper.createAccount(inputs);

        Assert.areEqual(200, outputs.size(), 'Should return one output per input in bulk');
        Integer successCount = 0;
        for (AccountCreationHelper.AccountOutput out : outputs) {
            if (out.accountId != null) {
                successCount++;
            }
        }
        Assert.areEqual(200, successCount, 'All 200 bulk inserts should succeed');

        Integer createdCount = [SELECT COUNT() FROM Account WHERE Name LIKE 'AC Helper Bulk Co %'];
        Assert.areEqual(200, createdCount, 'All 200 Accounts should have been inserted in a single bulk-safe DML');
    }

    @isTest
    static void testCreateAccount_existingAccountFallback() {
        Account existing = new Account(Name = 'AC Helper Fallback Co');
        insert existing;

        // A syntactically valid but non-existent Account Id forces the insert of the
        // *new* Account with this name to fail (invalid cross-reference on ParentId),
        // exercising the "resolve to existing account by name" fallback branch.
        Id fakeParentId = (Id) '001000000000000AAA';
        AccountCreationHelper.AccountInput inp = buildInput('AC Helper Fallback Co', String.valueOf(fakeParentId));

        List<AccountCreationHelper.AccountOutput> outputs =
            AccountCreationHelper.createAccount(new List<AccountCreationHelper.AccountInput>{ inp });

        Assert.areEqual(1, outputs.size(), 'Expected exactly one output');
        AccountCreationHelper.AccountOutput out = outputs[0];
        Assert.areEqual(existing.Id, out.accountId, 'Should fall back to the existing Account with the same Name');
        Assert.isNull(out.errorMessage, 'Fallback-to-existing path should not surface an error message');

        Integer countWithName = [SELECT COUNT() FROM Account WHERE Name = 'AC Helper Fallback Co'];
        Assert.areEqual(1, countWithName, 'No duplicate Account should have been created — the failed insert was not persisted');
    }

    @isTest
    static void testCreateAccount_genuineFailureNoFallback() {
        // No pre-existing Account named this, so the failed insert cannot resolve via fallback.
        Id fakeParentId = (Id) '001000000000000AAA';
        AccountCreationHelper.AccountInput inp = buildInput('AC Helper NoMatch Co', String.valueOf(fakeParentId));

        List<AccountCreationHelper.AccountOutput> outputs =
            AccountCreationHelper.createAccount(new List<AccountCreationHelper.AccountInput>{ inp });

        Assert.areEqual(1, outputs.size(), 'Expected exactly one output');
        AccountCreationHelper.AccountOutput out = outputs[0];
        Assert.isNull(out.accountId, 'No existing Account to fall back to, so accountId should remain null');
        Assert.isNotNull(out.errorMessage, 'Genuine failure should surface an error message');

        Integer countWithName = [SELECT COUNT() FROM Account WHERE Name = 'AC Helper NoMatch Co'];
        Assert.areEqual(0, countWithName, 'Failed insert should not have created any Account');
    }

    @isTest
    static void testCreateAccount_malformedParentIdThrows() {
        AccountCreationHelper.AccountInput inp = buildInput('AC Helper BadFormat Co', 'not-a-real-id');

        Boolean threw = false;
        try {
            AccountCreationHelper.createAccount(new List<AccountCreationHelper.AccountInput>{ inp });
        } catch (Exception e) {
            threw = true;
            Assert.isTrue(
                e.getMessage().contains('Invalid id'),
                'Expected an Id parsing exception, got: ' + e.getMessage()
            );
        }
        Assert.isTrue(threw, 'A malformed parentId string should raise an exception from Id.valueOf');

        Integer countWithName = [SELECT COUNT() FROM Account WHERE Name = 'AC Helper BadFormat Co'];
        Assert.areEqual(0, countWithName, 'Exception should occur before any DML, so no Account is created');
    }
}