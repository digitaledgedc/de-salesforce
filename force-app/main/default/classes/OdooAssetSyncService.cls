public without sharing class OdooAssetSyncService {

    @future(callout=true)
    public static void fetchAssetDataFromOdoo(List<Id> assetIds) {
        // Fetch Org Default configurations for Odoo API connection
        OdooIntegrationSettings__c settings = OdooIntegrationSettings__c.getOrgDefaults();
        if (settings == null) {
            System.debug('CRITICAL: OdooIntegrationSettings__c configuration defaults are missing.');
            return;
        }

        // Query the core identification assets safely 
        List<Asset> targetAssets = [
            SELECT Id, Name, Service_ID__c, Odoo_IB_ID__c FROM Asset WHERE Id IN :assetIds
        ];

        List<Asset> assetsToUpdate = new List<Asset>();

        for (Asset ass : targetAssets) {
            try {
                // Skip if the External Odoo Install Base ID tracking field is blank
                if (String.isBlank(ass.Odoo_IB_ID__c)) {
                    System.debug('Skipping record ' + ass.Id + ' - Odoo_IB_ID__c is empty.');
                    continue;
                }

                JSONGenerator gen = JSON.createGenerator(false);
                gen.writeStartObject();
                gen.writeFieldName('params');
                gen.writeStartObject();
                
                // Credentials passed at root of parameters matching your JSON requirement spec
                gen.writeStringField('username', settings.Username__c != null ? settings.Username__c : '');
                gen.writeStringField('password', settings.Password__c != null ? settings.Password__c : '');
                gen.writeStringField('asset_id', ass.Odoo_IB_ID__c); 

                gen.writeEndObject(); // end params
                gen.writeEndObject(); // end root
                
                String payload = gen.getAsString();
                System.debug('NEW-C ▶ Dispatching Payload: ' + payload);

                OdooIntegrationSettings__c s = OdooIntegrationSettings__c.getOrgDefaults();

                HttpRequest req = new HttpRequest();
                req.setEndpoint(OdooCalloutService.resolveBaseEndpoint(s) + '/api/v1/get_asset');
                req.setMethod('POST'); // FIXED: Changed from GET to POST for payload compatibility
                req.setHeader('Content-Type', 'application/json');
                req.setHeader('Accept', 'application/json');
                req.setBody(payload);
                req.setTimeout(30000); 

                OdooCalloutService.Response resp = OdooCalloutService.execute(req);
                System.debug('NEW-C ◀ Response state: success=' + resp.isSuccess);

                // FIXED: Changed errorBody verification to rawBody verification
                if (resp.isSuccess && resp.rawBody != null) {
                    Map<String, Object> rootMap = (Map<String, Object>) JSON.deserializeUntyped(resp.rawBody);
                    
                    if (rootMap.containsKey('result')) {
                        Map<String, Object> resultMap = (Map<String, Object>) rootMap.get('result');
                        
                        if (resultMap.containsKey('data') && resultMap.get('data') != null) {
                            // FIXED: Mapped JSON array explicitly as an Object List
                            List<Object> dataList = (List<Object>) resultMap.get('data');
                            
                            if (!dataList.isEmpty()) {
                                // Extract the first record out of the collection array
                                Map<String, Object> dataMap = (Map<String, Object>) dataList[0];
                                
                                // Instantiate update proxy record
                                Asset assetToUpdate = new Asset(Id = ass.Id);
                                
                                // 1. Odoo Service ID string mappings (Cleaned trailing spaces)
                                if (dataMap.get('name') != null) {
                                    assetToUpdate.Name = String.valueOf(dataMap.get('name'));
                                } else if (dataMap.get('x_studio_service_id') != null) {
                                    assetToUpdate.Name = String.valueOf(dataMap.get('x_studio_service_id'));
                                }
                                
                                // 2. Customer Service Reference text fields
                                /*if (dataMap.get('ns_customer_service_reference') != null) {
                                    assetToUpdate.Customer_Service_Reference__c = String.valueOf(dataMap.get('ns_customer_service_reference'));
                                }*/
                                
                                // 3. Status picklists
                                if (dataMap.get('stage_id') != null) {
                                    assetToUpdate.Status = String.valueOf(dataMap.get('stage_id'));
                                }
                                
                                // 4. Date mappings (Parses string date returns e.g., '2026-06-04')
                                if (dataMap.get('x_studio_service_commencement_date') != null) {
                                    try {
                                        assetToUpdate.SCD__c = Date.valueOf(String.valueOf(dataMap.get('x_studio_service_commencement_date')));
                                    } catch(Exception dateEx) {
                                        System.debug('SCD field format variance captured: ' + dateEx.getMessage());
                                    }
                                }
                                
                                // 5. Relational Odoo IDs (FIXED: Saved to Text tracking fields to avoid Lookup validation crashes)
                                // Handle Odoo returning boolean 'false' values for blank fields safely
                                if (dataMap.get('x_studio_space_id') != null && dataMap.get('x_studio_space_id') != false) {
                                    assetToUpdate.Space__c  = getSpacID(String.valueOf(dataMap.get('x_studio_space_id')));
                                }
                                if (dataMap.get('x_studio_breaker_id') != null && dataMap.get('x_studio_breaker_id') != false) {
                                    assetToUpdate.Inventory__c = getInventoryID(String.valueOf(dataMap.get('x_studio_breaker_id')));
                                }
                                if (dataMap.get('ns_a_side_service_id') != null && dataMap.get('ns_a_side_service_id') != false) {
                                    assetToUpdate.A_Side_Asset__c  = getAssetBySideOdooId(String.valueOf(dataMap.get('ns_a_side_service_id')));
                                }
                                if (dataMap.get('ns_z_side_service_id') != null && dataMap.get('ns_z_side_service_id') != false) {
                                    assetToUpdate.Z_Side_Asset__c  = getAssetBySideOdooId(String.valueOf(dataMap.get('ns_z_side_service_id')));
                                }

                                assetsToUpdate.add(assetToUpdate);
                            }
                        }
                    }
                }
            } catch (Exception ex) {
                System.debug('Execution error during asset mapping context process: ' + ex.getMessage());
            }
        }

        // Commit modifications cleanly back into Salesforce context
        if (!assetsToUpdate.isEmpty()) {
            update assetsToUpdate;
        }
    }
    
    public static string getSpacID(String odooId){
        List<Inventory__c> lstSpaceRec = [SELECT ID FRom Inventory__c  where Odoo_Space_ID__c  =: odooId ];
        if(lstSpaceRec.size() > 0){
            return lstSpaceRec[0].Id;
        }
        return null;
        
    }
    
    public static string getInventoryID(String odooId){
        List<Inventory__c> lstInvRec = [SELECT ID FRom Inventory__c  where Odoo_Inventory_Id__c  =: odooId ];
        if(lstInvRec.size() > 0){
            return lstInvRec[0].Id;
        }
        return null;
        
    }
    public Static String getAssetBySideOdooId(String odooId){
        List<Asset> lstAssetRec = [SELECT ID FROM Asset WHERE Odoo_IB_ID__c = :odooId];
        if(lstAssetRec.size() > 0){
            return lstAssetRec[0].Id;
        }
        return null;
    }
    
    public static string getProductID(String odooId){
        List<Inventory__c> lstInvRec = [SELECT ID FRom Inventory__c  where Odoo_Inventory_Id__c  =: odooId ];
        if(lstInvRec.size() > 0){
            return lstInvRec[0].Id;
        }
        return null;
        
    }
}