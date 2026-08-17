/**
 * Temporary utility for inventory data quality analysis.
 * Remove after data remediation is complete.
 */
public without sharing class DataQualityCheck {

    @AuraEnabled
    public static String runInventoryAnalysis() {
        List<String> lines = new List<String>();

        // Total counts
        Integer total = Database.countQuery('SELECT COUNT() FROM Inventory__c');
        Integer withAcct = Database.countQuery('SELECT COUNT() FROM Inventory__c WHERE Account__c != null');
        Integer noAcct = Database.countQuery('SELECT COUNT() FROM Inventory__c WHERE Account__c = null');
        lines.add('TOTAL=' + total + ' | WITH_ACCOUNT=' + withAcct + ' | NO_ACCOUNT=' + noAcct);

        // By record type
        for (AggregateResult ar : Database.query(
            'SELECT RecordType.DeveloperName rt, COUNT(Id) cnt FROM Inventory__c GROUP BY RecordType.DeveloperName'
        )) {
            lines.add('RT: ' + ar.get('rt') + ' => ' + ar.get('cnt'));
        }

        // No-account by status
        for (AggregateResult ar : Database.query(
            'SELECT Status__c s, COUNT(Id) cnt FROM Inventory__c WHERE Account__c = null GROUP BY Status__c ORDER BY COUNT(Id) DESC'
        )) {
            lines.add('NO_ACCT|' + ar.get('s') + ' => ' + ar.get('cnt'));
        }

        // Has-account by status
        for (AggregateResult ar : Database.query(
            'SELECT Status__c s, COUNT(Id) cnt FROM Inventory__c WHERE Account__c != null GROUP BY Status__c ORDER BY COUNT(Id) DESC'
        )) {
            lines.add('HAS_ACCT|' + ar.get('s') + ' => ' + ar.get('cnt'));
        }

        // No-account by site
        for (AggregateResult ar : Database.query(
            'SELECT Site_Id__c site, COUNT(Id) cnt FROM Inventory__c WHERE Account__c = null AND Status__c IN (\'Installed\', \'Sold\', \'Reserved\') GROUP BY Site_Id__c ORDER BY COUNT(Id) DESC LIMIT 20'
        )) {
            lines.add('NO_ACCT_ACTIVE_SITE|' + ar.get('site') + ' => ' + ar.get('cnt'));
        }

        // Assigned_To_Quote__c population
        Integer withQuote = Database.countQuery('SELECT COUNT() FROM Inventory__c WHERE Assigned_To_Quote__c != null');
        lines.add('WITH_QUOTE_ASSIGNMENT=' + withQuote);

        // Missing Space_Type on Space records
        Integer noSpaceType = Database.countQuery(
            'SELECT COUNT() FROM Inventory__c WHERE RecordType.DeveloperName = \'Inventory_Space\' AND Space_Type__c = null'
        );
        lines.add('SPACE_NO_TYPE=' + noSpaceType);

        // Missing Site
        Integer noSite = Database.countQuery('SELECT COUNT() FROM Inventory__c WHERE Site_Id__c = null');
        lines.add('NO_SITE=' + noSite);

        // Orphan floors/halls
        Integer orphanFloors = Database.countQuery('SELECT COUNT() FROM Floor__c WHERE Site__c = null');
        Integer orphanHalls = Database.countQuery('SELECT COUNT() FROM DataHall__c WHERE Site__c = null');
        lines.add('ORPHAN_FLOORS=' + orphanFloors + ' | ORPHAN_HALLS=' + orphanHalls);

        return String.join(lines, '\n');
    }

    @AuraEnabled
    public static String exportBreakerRefs(Integer pageNum) {
        Integer batchSize = 2000;
        Integer offset = pageNum * batchSize;
        List<String> lines = new List<String>();
        for (SObject inv : Database.query(
            'SELECT Id, Unit_Reference__c FROM Inventory__c ' +
            'WHERE RecordType.DeveloperName = \'Inventory_Breaker\' ' +
            'ORDER BY Id LIMIT ' + batchSize + ' OFFSET ' + offset
        )) {
            String ref = (String)inv.get('Unit_Reference__c');
            if (ref != null) {
                lines.add(inv.Id + '|' + ref);
            }
        }
        return String.join(lines, '\n');
    }

    /**
     * Batch update: accepts JSON map of { accountId: [ref1, ref2, ...] }
     * Updates Account__c on matching Inventory records.
     * refField: 'Unit_Reference__c' for breakers, 'Odoo_Space_ID__c' for spaces
     */
    @AuraEnabled
    public static String batchUpdateAccounts(String mappingJson, String refField) {
        if (!Schema.sObjectType.Inventory__c.isUpdateable()) {
            return 'ERROR: No update permission';
        }
        Map<String, Object> mapping = (Map<String, Object>)JSON.deserializeUntyped(mappingJson);
        Integer totalUpdated = 0;
        Integer totalSkipped = 0;
        List<Inventory__c> allUpdates = new List<Inventory__c>();

        for (String accountId : mapping.keySet()) {
            List<Object> refsList = (List<Object>)mapping.get(accountId);
            List<String> refs = new List<String>();
            for (Object r : refsList) {
                refs.add(String.valueOf(r));
            }

            String q = 'SELECT Id FROM Inventory__c WHERE ' + refField +
                ' IN :refs AND Account__c = null';
            List<SObject> records = Database.query(q);

            for (SObject r : records) {
                r.put('Account__c', accountId);
                allUpdates.add((Inventory__c)r);
            }
        }

        if (!allUpdates.isEmpty()) {
            update allUpdates;
            totalUpdated = allUpdates.size();
        }

        return 'UPDATED=' + totalUpdated;
    }

    @AuraEnabled
    public static Integer updateInventoryAccounts(List<String> unitRefs, Id accountId) {
        if (!Schema.sObjectType.Inventory__c.isUpdateable()) {
            return -1;
        }
        List<SObject> records = Database.query(
            'SELECT Id FROM Inventory__c WHERE Unit_Reference__c IN :unitRefs AND Account__c = null'
        );
        if (records.isEmpty()) return 0;
        for (SObject r : records) {
            r.put('Account__c', accountId);
        }
        update records;
        return records.size();
    }

    @AuraEnabled
    public static Integer updateSpaceAccounts(List<String> odooSpaceIds, Id accountId) {
        if (!Schema.sObjectType.Inventory__c.isUpdateable()) {
            return -1;
        }
        List<SObject> records = Database.query(
            'SELECT Id FROM Inventory__c WHERE Odoo_Space_ID__c IN :odooSpaceIds AND Account__c = null'
        );
        if (records.isEmpty()) return 0;
        for (SObject r : records) {
            r.put('Account__c', accountId);
        }
        update records;
        return records.size();
    }

    @AuraEnabled
    public static Id exportAccountsToFile() {
        List<String> lines = new List<String>();
        lines.add('Id,Name');
        for (Account a : [SELECT Id, Name FROM Account ORDER BY Name]) {
            String name = a.Name.replace('"', '""');
            lines.add(a.Id + ',"' + name + '"');
        }
        ContentVersion cv = new ContentVersion(
            Title = 'Accounts_Export',
            PathOnClient = 'Accounts_Export.csv',
            VersionData = Blob.valueOf(String.join(lines, '\n')),
            Origin = 'C'
        );
        insert cv;
        return cv.Id;
    }

    @AuraEnabled
    public static Id exportBreakerRefsToFile() {
        List<String> lines = new List<String>();
        lines.add('Id,Unit_Reference');

        Integer batchSize = 2000;
        Id lastId = null;
        Boolean hasMore = true;

        while (hasMore) {
            String q = 'SELECT Id, Unit_Reference__c FROM Inventory__c ' +
                'WHERE RecordType.DeveloperName = \'Inventory_Breaker\'';
            if (lastId != null) {
                q += ' AND Id > \'' + lastId + '\'';
            }
            q += ' ORDER BY Id LIMIT ' + batchSize;

            List<SObject> batch = Database.query(q);
            for (SObject inv : batch) {
                String ref = (String)inv.get('Unit_Reference__c');
                if (ref != null) {
                    ref = ref.replace('"', '""');
                    lines.add(inv.Id + ',"' + ref + '"');
                }
                lastId = inv.Id;
            }

            hasMore = (batch.size() == batchSize);
        }

        String csvBody = String.join(lines, '\n');
        ContentVersion cv = new ContentVersion(
            Title = 'BreakerRefs_Export',
            PathOnClient = 'BreakerRefs_Export.csv',
            VersionData = Blob.valueOf(csvBody),
            Origin = 'C'
        );
        insert cv;
        return cv.Id;
    }

    @AuraEnabled
    public static String sampleExternalIds() {
        List<String> lines = new List<String>();

        // Space records with Odoo_Space_ID
        for (SObject inv : Database.query(
            'SELECT Odoo_Space_ID__c, Name FROM Inventory__c WHERE RecordType.DeveloperName = \'Inventory_Space\' AND Odoo_Space_ID__c != null ORDER BY Name LIMIT 5'
        )) {
            lines.add('SPACE|' + inv.get('Odoo_Space_ID__c') + '|' + inv.get('Name'));
        }

        // Breaker records
        for (SObject inv : Database.query(
            'SELECT Odoo_Inventory_Id__c, Odoo_Space_ID__c, Name FROM Inventory__c WHERE RecordType.DeveloperName = \'Inventory_Breaker\' AND Odoo_Inventory_Id__c != null ORDER BY Name LIMIT 5'
        )) {
            lines.add('BREAKER|' + inv.get('Odoo_Inventory_Id__c') + '|' + inv.get('Odoo_Space_ID__c') + '|' + inv.get('Name'));
        }

        // Count by external ID presence
        Integer spaceWithId = Database.countQuery('SELECT COUNT() FROM Inventory__c WHERE RecordType.DeveloperName = \'Inventory_Space\' AND Odoo_Space_ID__c != null');
        Integer spaceNoId = Database.countQuery('SELECT COUNT() FROM Inventory__c WHERE RecordType.DeveloperName = \'Inventory_Space\' AND Odoo_Space_ID__c = null');
        Integer breakerWithId = Database.countQuery('SELECT COUNT() FROM Inventory__c WHERE RecordType.DeveloperName = \'Inventory_Breaker\' AND Odoo_Inventory_Id__c != null');
        Integer breakerNoId = Database.countQuery('SELECT COUNT() FROM Inventory__c WHERE RecordType.DeveloperName = \'Inventory_Breaker\' AND Odoo_Inventory_Id__c = null');

        lines.add('SPACE_WITH_ODOO_ID=' + spaceWithId + ' | NO_ID=' + spaceNoId);
        lines.add('BREAKER_WITH_ODOO_ID=' + breakerWithId + ' | NO_ID=' + breakerNoId);

        return String.join(lines, '\n');
    }
}