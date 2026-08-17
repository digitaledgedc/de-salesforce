@IsTest
private class UserLanguageControllerTest {

    @IsTest
    static void testGetCurrentLanguage() {
        Test.startTest();
        String lang = UserLanguageController.getCurrentLanguage();
        Test.stopTest();
        System.assertNotEquals(null, lang, 'Should return a language key');
        System.assertEquals(UserInfo.getLanguage(), lang, 'Should match UserInfo language');
    }

    @IsTest
    static void testSetLanguage() {
        String currentLang = UserInfo.getLanguage();
        Test.startTest();
        // Set to same language to avoid side effects
        UserLanguageController.setLanguage(currentLang);
        Test.stopTest();
        // Verify no exception thrown
        System.assertEquals(currentLang, UserInfo.getLanguage(), 'Language should remain unchanged');
    }
}