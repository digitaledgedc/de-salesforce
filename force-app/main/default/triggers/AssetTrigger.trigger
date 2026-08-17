trigger AssetTrigger on Asset (after update,after insert) {
	if (Trigger.isAfter && (Trigger.isUpdate ||Trigger.isInsert) ) {
        // Collect newly inserted Asset IDs to process asynchronously
        List<Id> assetIds = new List<Id>();
        for (Asset ass : Trigger.new) {
            if(ass.Name == 'Asset'){
              assetIds.add(ass.Id);  
            }  
        }
        
        if (!assetIds.isEmpty()) {
            // Hand off to our @future method to handle HTTP Callouts safely
            OdooAssetSyncService.fetchAssetDataFromOdoo(assetIds);
        }
    }
}