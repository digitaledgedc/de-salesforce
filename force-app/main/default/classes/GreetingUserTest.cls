@IsTest
private class GreetingUserTest {

    /** Mirrors GreetingUser.getCurrentUserInfo()'s time-of-day calculation exactly,
     *  so the test can assert a precise greeting instead of just "some string". */
    private static String expectedGreetingNow() {
        TimeZone tz = UserInfo.getTimeZone();
        DateTime dt = Datetime.now();
        String formattedDt = '' + dt.addSeconds((tz.getOffset(dt) / 1000));
        String currentTime = formattedDt.split(' ')[1];
        Integer hrs = Integer.valueOf(currentTime.split(':')[0]);

        if (hrs >= 0 && hrs < 12) return 'Morning';
        if (hrs >= 12 && hrs < 17) return 'Afternoon';
        return 'Evening';
    }

    // ═══════════════════════════════════════════════════════════════════
    // getCurrentUserInfo
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void getCurrentUserInfo_returnsExpectedGreetingAndProfile() {
        String expectedGreeting = expectedGreetingNow();
        User runningUser = [SELECT Id, FirstName, Profile.Name, Login_Component_Mode__c
                             FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];

        Test.startTest();
        GreetingUser.UserLoginWrapper result = GreetingUser.getCurrentUserInfo();
        Test.stopTest();

        Assert.isNotNull(result, 'Wrapper should never be null');
        Assert.areEqual(expectedGreeting, result.greeting,
            'Greeting should match the time-of-day bucket for the running user\'s timezone');
        Assert.areEqual(UserInfo.getFirstName(), result.firstName, 'First name should be the running user\'s');
        Assert.areEqual(runningUser.Profile.Name, result.profileName, 'Profile name should be the running user\'s');
        Assert.areEqual(runningUser.Login_Component_Mode__c, result.componentMode,
            'Component mode should mirror the User record\'s current value');
    }

    @IsTest
    static void getCurrentUserInfo_greetingIsAlwaysOneOfThreeBuckets() {
        Test.startTest();
        GreetingUser.UserLoginWrapper result = GreetingUser.getCurrentUserInfo();
        Test.stopTest();

        Set<String> validBuckets = new Set<String>{ 'Morning', 'Afternoon', 'Evening' };
        Assert.isTrue(validBuckets.contains(result.greeting),
            'Greeting must be exactly one of Morning/Afternoon/Evening');
    }

    @IsTest
    static void getCurrentUserInfo_reflectsUpdatedComponentMode() {
        GreetingUser.updateDarkLightModeForUser('Dark');

        Test.startTest();
        GreetingUser.UserLoginWrapper result = GreetingUser.getCurrentUserInfo();
        Test.stopTest();

        Assert.areEqual('Dark', result.componentMode,
            'getCurrentUserInfo should reflect the most recently saved component mode');
    }

    // ═══════════════════════════════════════════════════════════════════
    // updateDarkLightModeForUser
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void updateDarkLightModeForUser_updatesToDark() {
        Test.startTest();
        GreetingUser.updateDarkLightModeForUser('Dark');
        Test.stopTest();

        User updated = [SELECT Login_Component_Mode__c FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];
        Assert.areEqual('Dark', updated.Login_Component_Mode__c, 'Mode should be persisted as Dark');
    }

    @IsTest
    static void updateDarkLightModeForUser_updatesToLight() {
        GreetingUser.updateDarkLightModeForUser('Dark');

        Test.startTest();
        GreetingUser.updateDarkLightModeForUser('Light');
        Test.stopTest();

        User updated = [SELECT Login_Component_Mode__c FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];
        Assert.areEqual('Light', updated.Login_Component_Mode__c, 'Mode should be persisted as Light');
    }

    @IsTest
    static void updateDarkLightModeForUser_invalidValueThrowsAuraHandledException() {
        Test.startTest();
        Boolean threw = false;
        String message = '';
        try {
            // Login_Component_Mode__c is a RESTRICTED picklist (Light/Dark only) in de-partial.
            // An invalid value fails DML with INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST, which the
            // method catches and rethrows as AuraHandledException.
            GreetingUser.updateDarkLightModeForUser('Neon');
        } catch (AuraHandledException e) {
            threw = true;
            message = e.getMessage();
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Invalid restricted-picklist value should raise AuraHandledException');
        Assert.isNotNull(message, 'Exception message should be populated from the underlying DML error');
    }

    @IsTest
    static void updateDarkLightModeForUser_nullValueClearsField() {
        GreetingUser.updateDarkLightModeForUser('Dark');

        Test.startTest();
        // Login_Component_Mode__c is nillable, so clearing it to null is a valid DML
        // (unlike an out-of-range restricted-picklist string, which is rejected).
        GreetingUser.updateDarkLightModeForUser(null);
        Test.stopTest();

        User updated = [SELECT Login_Component_Mode__c FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];
        Assert.isNull(updated.Login_Component_Mode__c, 'Null should clear the component mode field');
    }
}