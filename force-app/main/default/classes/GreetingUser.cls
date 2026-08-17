public class GreetingUser {
    @AuraEnabled(Cacheable = true)
    public static UserLoginWrapper getCurrentUserInfo() {
        UserLoginWrapper instanceUsr = new UserLoginWrapper();

        User usr = [
            SELECT Id, Login_Component_Mode__c, Profile.Name
            FROM User
            WHERE Id = :UserInfo.getUserId()
            LIMIT 1
        ];

        TimeZone tz = UserInfo.getTimeZone();
        DateTime dt = Datetime.now();
        String fomattedDt = '' + dt.addSeconds((tz.getOffset(dt) / 1000));
        String currentTime = fomattedDt.split(' ')[1];
        Integer hrs = Integer.valueOf(currentTime.split(':')[0]);

        if      (hrs >= 0  && hrs < 12) instanceUsr.greeting = 'Morning';
        else if (hrs >= 12 && hrs < 17) instanceUsr.greeting = 'Afternoon';
        else                            instanceUsr.greeting = 'Evening';

        instanceUsr.firstName     = UserInfo.getFirstName();
        instanceUsr.componentMode = usr.Login_Component_Mode__c;
        instanceUsr.profileName   = usr.Profile.Name;          // ← NEW

        System.debug('instanceUsr >> ' + instanceUsr);
        return instanceUsr;
    }

    @AuraEnabled
    public static void updateDarkLightModeForUser(String mode) {
        try {
            User usr = [SELECT Id, Login_Component_Mode__c FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];
            usr.Login_Component_Mode__c = mode;
            UPDATE usr;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    public class UserLoginWrapper {
        @AuraEnabled public String firstName;
        @AuraEnabled public String greeting;
        @AuraEnabled public String componentMode;
        @AuraEnabled public String profileName;               // ← NEW
    }
}