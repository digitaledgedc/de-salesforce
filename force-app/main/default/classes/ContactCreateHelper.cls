/**
 * ContactCreateHelper
 *
 * Creates a Contact while bypassing duplicate rule alerts.
 * Salesforce duplicate rules set to Allow + Alert still throw
 * DUPLICATES_DETECTED in Flow/Apex DML contexts. This helper
 * uses DuplicateRuleHeader.allowSave to suppress the exception.
 *
 * Called from F-04 Lead Conversion screen flow.
 */
public with sharing class ContactCreateHelper {

    public class CreateRequest {
        @InvocableVariable(label='First Name')
        public String firstName;
        @InvocableVariable(label='Last Name' required=true)
        public String lastName;
        @InvocableVariable(label='Email')
        public String email;
        @InvocableVariable(label='Phone')
        public String phone;
        @InvocableVariable(label='Title')
        public String title;
        @InvocableVariable(label='Account Id' required=true)
        public Id accountId;
    }

    public class CreateResult {
        @InvocableVariable(label='Contact Id')
        public Id contactId;
        @InvocableVariable(label='Success')
        public Boolean success;
        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    @InvocableMethod(label='Create Contact (Allow Duplicates)' description='Creates a Contact with DuplicateRuleHeader.allowSave = true to bypass Allow+Alert duplicate rules in Flow context.')
    public static List<CreateResult> createContact(List<CreateRequest> requests) {
        List<CreateResult> results = new List<CreateResult>();

        for (CreateRequest req : requests) {
            Contact con = new Contact();
            con.FirstName = req.firstName;
            con.LastName = req.lastName;
            con.Email = req.email;
            con.Phone = req.phone;
            con.Title = req.title;
            con.AccountId = req.accountId;

            Database.DMLOptions dml = new Database.DMLOptions();
            dml.DuplicateRuleHeader.allowSave = true;

            Database.SaveResult sr = Database.insert(con, dml);

            CreateResult res = new CreateResult();
            res.success = sr.isSuccess();
            if (sr.isSuccess()) {
                res.contactId = con.Id;
            } else {
                res.errorMessage = sr.getErrors()[0].getMessage();
            }
            results.add(res);
        }
        return results;
    }
}