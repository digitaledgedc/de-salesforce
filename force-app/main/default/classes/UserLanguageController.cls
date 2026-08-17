public with sharing class UserLanguageController {

    @AuraEnabled(cacheable=true)
    public static String getCurrentLanguage() {
        return UserInfo.getLanguage();
    }

    @AuraEnabled
    public static void setLanguage(String languageKey) {
        User u = new User(Id = UserInfo.getUserId(), LanguageLocaleKey = languageKey);
        update u;
    }
}