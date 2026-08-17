/**
 * SendNewOrdersQueueable
 * IP-1: Sends New Service and Renewal Orders to Odoo via /api/v1/create_sale_order.
 * Chains LockOdooSpacesQueueable (IP-3) on success for Orders with capacity assignments.
 */
public without sharing class SendNewOrdersQueueable implements Queueable, Database.AllowsCallouts {

    private static final Integer BATCH_SIZE = 10; // Process 10 orders at a time to avoid callout limits
    private List<Id> orderIds;

    public SendNewOrdersQueueable(List<Id> orderIds) {
        System.debug('🔵 IP-1 INIT: Creating Queueable with ' + orderIds.size() + ' Order IDs');
        this.orderIds = orderIds;
    }

    public void execute(QueueableContext ctx) {
        System.debug('🔵 IP-1 EXECUTE: Starting execution with ' + orderIds.size() + ' orders');
        System.debug('🔵 IP-1 EXECUTE: Order IDs: ' + orderIds);
        
        // Process in smaller batches if too many orders
        if (orderIds.size() > BATCH_SIZE) {
            System.debug('⚠️ IP-1 BATCHING: ' + orderIds.size() + ' orders exceeds batch size of ' + BATCH_SIZE);
            List<Id> currentBatch = new List<Id>();
            List<Id> remainingBatch = new List<Id>();
            
            for (Integer i = 0; i < orderIds.size(); i++) {
                if (i < BATCH_SIZE) {
                    currentBatch.add(orderIds[i]);
                } else {
                    remainingBatch.add(orderIds[i]);
                }
            }
            
            System.debug('📦 IP-1 BATCH: Processing ' + currentBatch.size() + ' orders in current batch');
            System.debug('📦 IP-1 BATCH: ' + remainingBatch.size() + ' orders remaining for next batch');
            
            // Process current batch
            processOrders(currentBatch);
            
            // Queue next batch
            if (!remainingBatch.isEmpty()) {
                System.debug('🔄 IP-1 QUEUE: Enqueuing next batch with ' + remainingBatch.size() + ' orders');
                System.enqueueJob(new SendNewOrdersQueueable(remainingBatch));
            } else {
                System.debug('✅ IP-1 COMPLETE: All batches processed');
            }
        } else {
            System.debug('📦 IP-1 DIRECT: Processing all ' + orderIds.size() + ' orders in single batch');
            processOrders(orderIds);
        }
    }
    
    private void processOrders(List<Id> batchOrderIds) {
        System.debug('🔵 IP-1 PROCESS ORDERS: Starting batch processing for ' + batchOrderIds.size() + ' orders');
        
        OdooIntegrationSettings__c settings = OdooIntegrationSettings__c.getOrgDefaults();
        System.debug('⚙️ IP-1 SETTINGS: Username=' + settings.Username__c + ', Environment=' + settings.Environment__c);

        // Query Site__c once outside the loop
        System.debug('🔍 IP-1 QUERY: Fetching Site__c records');
        Map<String, Site__c> siteMap = new Map<String, Site__c>();
        for (Site__c s : [
            SELECT Name, Odoo_Company_ID__c, Odoo_Country_ID__c,Odoo_Site_ID__c,Odoo_Metro_ID__c
            FROM Site__c
            WHERE Odoo_Site_ID__c > 0
        ]) {
            siteMap.put(s.Name, s);
        }
        
        System.debug('📍 IP-1 SITES: Found ' + siteMap.size() + ' active Odoo sites');

        // Optimized query - only get necessary fields
        System.debug('🔍 IP-1 QUERY: Fetching Orders with OrderItems for IDs: ' + batchOrderIds);
        List<Order> orders = [
            SELECT Id, OrderNumber, EffectiveDate, Contract_Term_Months__c,
                   Customer_PO_Reference__c, RDD__c, Operation_Site__c,
                   Target_Site__c, Target_Site__r.Site_Code__c, Order_Number__c,
                   Order_Type__c, FX_Billing_Flag__c, FX_Rate_Model__c, FX_Rate_Terms__c,
                   Is_Ramp_Deal__c, Original_Order__c,
                   BillingAccount__c,CurrencyIsoCode,
                   BillingAccount__r.Odoo_Partner_ID__c,
                   BillingAccount__r.Odoo_BAN_ID__c,
                   BillingAccount__r.Odoo_Invoice_Freq_ID__c,
                   BillingAccount__r.Invoice_Presentment__c,
                   BillingAccount__r.Charge_Period_Presentment__c,
                   BillingAccount__r.Additional_Invoice_Email__c,
                   (SELECT Id, Product2.Name, Product2.Merge_IB_Task__c,
                           Odoo_Product_ID__c, Odoo_Attribute_Value_ID__c,Product_Attribute_Value__c,
                           Description, Quantity, UnitPrice, Billing_Mode__c,
                           Charge_Type__c, Is_Auto_NRC__c,
                           CabE__c, Custom_Attribute_Value__c, Line_Remarks__c,
                           A_Side_Service_ID__c, Z_Side_Service_ID__c,
                           Target_BAN__r.Odoo_BAN_ID__c,
                           QuoteLineItemId, ns_change_type__c,
                           Ramp_Identifier__c, Ramp_Linked_Phase__c,
                           Original_OrderItem__c,
                           Original_OrderItem__r.Odoo_Origin_Line_ID__c,
                           Original_OrderItem__r.Odoo_Sub_Line_ID__c
                    FROM OrderItems
                    WHERE Is_Active__c = true)
            FROM Order 
            WHERE Id IN :batchOrderIds
        ];
        System.debug('📋 IP-1 ORDERS: Retrieved ' + orders.size() + ' orders');

        // ─── NEW: Query to trace back to the original order for aggregate products ───
        // For aggregate products (Merge_IB_Task__c = TRUE), we need the sf_originitem_id
        // to point to the VERY FIRST order, not just the previous phase.
        Set<Id> allOrderIds = new Set<Id>();
        for (Order o : orders) {
            allOrderIds.add(o.Id);
            if (o.Original_Order__c != null) {  Id currentId = o.Original_Order__c; Boolean foundOriginal = false; Integer maxDepth = 10; Integer depth = 0;
                
                while (!foundOriginal && depth < maxDepth) {
                    allOrderIds.add(currentId);
                    // Check if this order has an Original_Order__c
                    List<Order> parentOrders = [SELECT Id, Original_Order__c FROM Order WHERE Id = :currentId LIMIT 1];
                    if (!parentOrders.isEmpty()) {
                        if (parentOrders[0].Original_Order__c != null) {  currentId = parentOrders[0].Original_Order__c;  depth++;
                        } else { foundOriginal = true;
                        }
                    } else { foundOriginal = true;
                    }
                }
            }
        }
        
        // ─── Build maps for previous phase items ───
        Map<Id, Map<String, OrderItem>> prevPhaseItemMap = new Map<Id, Map<String, OrderItem>>();
        if (!allOrderIds.isEmpty()) {
            // Query all OrderItems from all orders in the chain
            for (OrderItem poi : [
                SELECT Id, OrderId, Odoo_Product_ID__c, Odoo_Attribute_Value_ID__c, UnitPrice,
                       Product2.Merge_IB_Task__c
                FROM OrderItem
                WHERE OrderId IN :allOrderIds AND Is_Active__c = true
                ORDER BY OrderId ASC
            ]) {
                if (!prevPhaseItemMap.containsKey(poi.OrderId)) {
                    prevPhaseItemMap.put(poi.OrderId, new Map<String, OrderItem>());
                }
                String prevKey = String.valueOf(poi.Odoo_Product_ID__c) + '_' + String.valueOf(poi.Odoo_Attribute_Value_ID__c);
                prevPhaseItemMap.get(poi.OrderId).put(prevKey, poi);
            }
        }

        // ─── NEW: Build map to trace original order for each order ───
        Map<Id, Id> orderToOriginalMap = new Map<Id, Id>();
        for (Order o : orders) {
            if (o.Original_Order__c != null) {
                // Find the ultimate original order
                Id currentId = o.Original_Order__c; Boolean foundOriginal = false; Integer maxDepth = 10; Integer depth = 0;
                
                while (!foundOriginal && depth < maxDepth) {
                    List<Order> parentOrders = [SELECT Id, Original_Order__c FROM Order WHERE Id = :currentId LIMIT 1];
                    if (!parentOrders.isEmpty()) {
                        if (parentOrders[0].Original_Order__c != null) { currentId = parentOrders[0].Original_Order__c; depth++; } else { foundOriginal = true;  orderToOriginalMap.put(o.Id, currentId);  }
                    } else {  foundOriginal = true; orderToOriginalMap.put(o.Id, currentId);
                    }
                } if (!orderToOriginalMap.containsKey(o.Id)) {  orderToOriginalMap.put(o.Id, currentId);
                }
            }
        }

        // Single optimized query for all Inventory records
        Set<Id> quoteLineIds = new Set<Id>();
        Integer totalOrderItems = 0;
        for (Order orderRec : orders) {
            totalOrderItems += orderRec.OrderItems.size();
            for (OrderItem orderItemRec : orderRec.OrderItems) {
                if (orderItemRec.QuoteLineItemId != null) {  quoteLineIds.add(orderItemRec.QuoteLineItemId);
                }
            }
        }
        System.debug('📊 IP-1 STATS: Total OrderItems=' + totalOrderItems + ', Unique QuoteLineIds=' + quoteLineIds.size());
        
        // Single query to get all inventory records
        Map<Id, List<Inventory__c>> mapLineItemWithSpaceId = new Map<Id, List<Inventory__c>>();
        Map<Id, List<Inventory__c>> mapLineItemWithBreakerId = new Map<Id, List<Inventory__c>>();
        
        if (!quoteLineIds.isEmpty()) {
            System.debug('🔍 IP-1 QUERY: Fetching Inventory records for ' + quoteLineIds.size() + ' QuoteLine IDs');
            for (Inventory__c invRec : [SELECT Id, Order_Item__c, Odoo_Space_ID__c, Odoo_Inventory_Id__c, Quote_Line__c, Order__c, Assigned_To_Order__c, RecordType.DeveloperName FROM Inventory__c WHERE Quote_Line__c IN :quoteLineIds ORDER BY Order_Item__c DESC]) {
                if (invRec.RecordType.DeveloperName == 'Inventory_Space') { if (!mapLineItemWithSpaceId.containsKey(invRec.Quote_Line__c)) {   mapLineItemWithSpaceId.put(invRec.Quote_Line__c, new List<Inventory__c>()); }
                    mapLineItemWithSpaceId.get(invRec.Quote_Line__c).add(invRec);
				 } else {  if (!mapLineItemWithBreakerId.containsKey(invRec.Quote_Line__c)) { mapLineItemWithBreakerId.put(invRec.Quote_Line__c, new List<Inventory__c>()); }  mapLineItemWithBreakerId.get(invRec.Quote_Line__c).add(invRec);
                }
            }
            System.debug('🗄️ IP-1 INVENTORY: Space records found for ' + mapLineItemWithSpaceId.keySet().size() + ' QuoteLines');
            System.debug('🗄️ IP-1 INVENTORY: Breaker records found for ' + mapLineItemWithBreakerId.keySet().size() + ' QuoteLines');
        } else {
            System.debug('⚠️ IP-1 INVENTORY: No QuoteLine IDs found, skipping inventory query');
        }
        
        List<Order> toUpdate = new List<Order>();
        List<Id> successOrderIds = new List<Id>();
        List<DE_Integration_Error__c> errorsToInsert = new List<DE_Integration_Error__c>();
        
        // Validate all orders first to avoid partial processing
        System.debug('🔍 IP-1 VALIDATION: Starting order validation');
        List<Order> validOrders = new List<Order>();
        Integer validationFailures = 0;
        
        for (Order o : orders) {
            System.debug('🔍 IP-1 VALIDATE: Order ' + o.Order_Number__c + ' (' + o.Id + ')');
            if (!validateOrder(o, siteMap, settings, errorsToInsert, toUpdate)) {
                validationFailures++;
                System.debug('❌ IP-1 VALIDATION FAILED: Order ' + o.Order_Number__c);
                continue;
            }
            validOrders.add(o);
            System.debug('✅ IP-1 VALIDATION PASSED: Order ' + o.Order_Number__c);
        }
        System.debug('📊 IP-1 VALIDATION: ' + validOrders.size() + ' valid orders, ' + validationFailures + ' failures');
        
        // Process callouts for valid orders
        System.debug('🌐 IP-1 CALLOUTS: Starting API calls for ' + validOrders.size() + ' orders');
        Integer calloutSuccess = 0;
        Integer calloutFailure = 0;
        
        for (Order o : validOrders) {
            System.debug('📤 IP-1 PROCESSING: Order ' + o.Order_Number__c + ' (' + o.Id + '), Type: ' + o.Order_Type__c);
            
            String siteCode = (o.Target_Site__c != null && o.Target_Site__r.Site_Code__c != null)
                ? o.Target_Site__r.Site_Code__c : o.Operation_Site__c;
            System.debug('📍 IP-1 SITE: Order ' + o.Order_Number__c + ' using site code: ' + siteCode);
            
            Site__c site = siteMap.get(siteCode);
            
            String payload = buildIP1Payload(o, site, settings, mapLineItemWithSpaceId, mapLineItemWithBreakerId, 
                                              prevPhaseItemMap, orderToOriginalMap);
            System.debug('📦 IP-1 PAYLOAD for ' + o.Order_Number__c + ': ' + payload);
            
            System.debug('🚀 IP-1 CALLOUT: Sending request to Odoo for Order ' + o.Order_Number__c);
            OdooCalloutService.Response resp = OdooCalloutService.post('/api/v1/create_sale_order', payload);
            
            System.debug('📥 IP-1 RESPONSE for ' + o.Order_Number__c + ':');
            System.debug('   - Success: ' + resp.isSuccess);
            System.debug('   - Odoo ID: ' + resp.odooId);
            System.debug('   - Error: ' + resp.errorBody);
            o.Odoo_Sync_Payload__c = payload;
            if (resp.isSuccess) {
                o.Odoo_Order_ID__c = String.valueOf(resp.odooId);
                o.Integration_Status__c = 'Synced';
                successOrderIds.add(o.Id);
                calloutSuccess++;
                System.debug('✅ IP-1 SUCCESS: Order ' + o.Order_Number__c + ' synced with Odoo ID: ' + resp.odooId);
            } else {
                o.Integration_Status__c = 'Failed';
                o.Integration_Error__c = resp.errorBody;
                errorsToInsert.add(new DE_Integration_Error__c(
                    Record_Id__c = String.valueOf(o.Id), 
                    IP_Reference__c = 'IP-1',
                    Error_Message__c = resp.errorBody, 
                    Status__c = 'Open',
                    Request_Payload__c = payload));
                calloutFailure++;
                System.debug('❌ IP-1 FAILURE: Order ' + o.Order_Number__c + ' failed with error: ' + resp.errorBody);
            }
            toUpdate.add(o);
        }
        
        System.debug('📊 IP-1 CALLOUT SUMMARY: ' + calloutSuccess + ' succeeded, ' + calloutFailure + ' failed');
        
        // DML operations
        if (!errorsToInsert.isEmpty()) {
            System.debug('💾 IP-1 DML: Inserting ' + errorsToInsert.size() + ' error records');
            insert errorsToInsert;
        }
        
        if (!toUpdate.isEmpty()) {
            System.debug('💾 IP-1 DML: Updating ' + toUpdate.size() + ' orders');
            update toUpdate;
        }
        
        // Chain IP-3 for Orders with capacity assignments
        if (!successOrderIds.isEmpty()) {
            System.debug('🔗 IP-1 CHAINING: Checking ' + successOrderIds.size() + ' successful orders for capacity assignments');
            List<Id> spaceLockIds = getOrdersWithCapacity(successOrderIds);
            if (!spaceLockIds.isEmpty()) {
                System.debug('🔒 IP-1 CHAINING: Found ' + spaceLockIds.size() + ' orders with capacity, enqueuing LockOdooSpacesQueueable');  System.enqueueJob(new LockOdooSpacesQueueable(spaceLockIds));
            } else {
                System.debug('ℹ️ IP-1 CHAINING: No capacity assignments found, skipping IP-3');
            }
        }
        
        System.debug('✅ IP-1 PROCESS ORDERS COMPLETE: Batch finished');
    }
    
    private Boolean validateOrder(Order o, Map<String, Site__c> siteMap, 
                                   OdooIntegrationSettings__c settings,
                                   List<DE_Integration_Error__c> errorsToInsert, 
                                   List<Order> toUpdate) {
        
        System.debug('🔍 IP-1 VALIDATE ORDER: Starting validation for Order ' + o.Order_Number__c);
        
        String siteCode = (o.Target_Site__c != null && o.Target_Site__r.Site_Code__c != null)
            ? o.Target_Site__r.Site_Code__c : o.Operation_Site__c;
        System.debug('   - Site Code: ' + siteCode);
        
        Site__c site = siteMap.get(siteCode);
        if (site == null) {
            String errMsg = 'No Site__c record found for site code: ' + siteCode;
            System.debug('❌ IP-1 VALIDATION ERROR: ' + errMsg);
            addError(o, errMsg, errorsToInsert, toUpdate);
            return false;
        }
        System.debug('   - Site Found: ' + site.Name);
        
        if (o.BillingAccount__c == null) { String errMsg = 'Order has no BillingAccount (BAN) — IP-1 requires partner_id, ban_id, and invoice_frequency_id from the BAN'; System.debug('❌ IP-1 VALIDATION ERROR: ' + errMsg); addError(o, errMsg, errorsToInsert, toUpdate); return false;
        }
        System.debug('   - BillingAccount: ' + o.BillingAccount__c);
        
        if (o.BillingAccount__r.Odoo_Partner_ID__c == null ||
            o.BillingAccount__r.Odoo_BAN_ID__c == null ||
            o.BillingAccount__r.Odoo_Invoice_Freq_ID__c == null) {
            String errMsg = 'BAN is missing required Odoo IDs (Odoo_Partner_ID__c, Odoo_BAN_ID__c, or Odoo_Invoice_Freq_ID__c). '
                + 'Ensure the BAN has been synced to Odoo before activating this order.';
            System.debug('❌ IP-1 VALIDATION ERROR: ' + errMsg);
            System.debug('   - Partner ID: ' + o.BillingAccount__r.Odoo_Partner_ID__c);
            System.debug('   - BAN ID: ' + o.BillingAccount__r.Odoo_BAN_ID__c);
            System.debug('   - Invoice Freq ID: ' + o.BillingAccount__r.Odoo_Invoice_Freq_ID__c);
            addError(o, errMsg, errorsToInsert, toUpdate);
            return false;
        }
        System.debug('   - Odoo Partner ID: ' + o.BillingAccount__r.Odoo_Partner_ID__c);
        System.debug('   - Odoo BAN ID: ' + o.BillingAccount__r.Odoo_BAN_ID__c);
        
        // Validate OrderItems
        Integer itemCount = 0;
        Integer missingProductCount = 0;
        for (OrderItem oi : o.OrderItems) {
            itemCount++;
            if (oi.Odoo_Product_ID__c == null) {
                missingProductCount++;
                System.debug('⚠️ IP-1 VALIDATION: OrderItem ' + oi.Id + ' missing Odoo_Product_ID__c');
            }
        }
        
        if (missingProductCount > 0) {
            String errMsg = missingProductCount + ' Order Item(s) are missing Odoo_Product_ID__c. '
                + 'Ensure the product catalog has been synced to Odoo and Odoo_Product_ID__c is set on all active Order Items before confirming.';
            System.debug('❌ IP-1 VALIDATION ERROR: ' + errMsg);
            addError(o, errMsg, errorsToInsert, toUpdate);
            return false;
        }
        
        System.debug('✅ IP-1 VALIDATION: Order ' + o.Order_Number__c + ' passed validation (' + itemCount + ' items)');
        return true;
    }
    
    private void addError(Order o, String errMsg, List<DE_Integration_Error__c> errorsToInsert, List<Order> toUpdate) {
        System.debug('❌ IP-1 ADD ERROR: Order ' + o.Order_Number__c + ' - ' + errMsg);
        o.Integration_Status__c = 'Failed';
        o.Integration_Error__c = errMsg;
        errorsToInsert.add(new DE_Integration_Error__c(
            Record_Id__c = String.valueOf(o.Id), 
            IP_Reference__c = 'IP-1',
            Error_Message__c = errMsg, 
            Status__c = 'Open'));
        toUpdate.add(o);
    }

    @TestVisible
    private String buildIP1Payload(Order o, Site__c site, OdooIntegrationSettings__c settings,
                                    Map<Id, List<Inventory__c>> mapLineItemWithSpaceId,
                                    Map<Id, List<Inventory__c>> mapLineItemWithBreakerId,
                                    Map<Id, Map<String, OrderItem>> prevPhaseItemMap,
                                    Map<Id, Id> orderToOriginalMap) {
        
        System.debug('🔨 IP-1 BUILD PAYLOAD: Creating payload for Order ' + o.Order_Number__c);
        
        JSONGenerator gen = JSON.createGenerator(false);
        
        gen.writeStartObject();
        gen.writeFieldName('params');
        gen.writeStartObject();
        
        gen.writeStringField('username', settings.Username__c != null ? settings.Username__c : '');
        gen.writeStringField('password', settings.Password__c != null ? settings.Password__c : '');
        
        gen.writeFieldName('data');
        gen.writeStartObject();
        
        gen.writeStringField('name', o.Order_Number__c);
        gen.writeBooleanField('is_from_sf', true);
        gen.writeStringField('sf_order_id', o.Id);
        if (o.Original_Order__c != null) {
            gen.writeStringField('sf_origin_id', o.Original_Order__c);
        }
        
        Boolean isPhase2Plus = (o.Original_Order__c != null);
        String subMgmt = 'Renewal'.equals(o.Order_Type__c) ? 'renewal' : (isPhase2Plus ? 'change_order' : 'create');
        gen.writeStringField('subscription_management', subMgmt);
        System.debug('   - Subscription Management: ' + subMgmt);
        
        gen.writeNumberField('company_id', Integer.valueOf(site.Odoo_Company_ID__c));
        gen.writeStringField('date_order', formatDateTime(o.EffectiveDate));
        gen.writeNumberField('partner_id', Integer.valueOf(o.BillingAccount__r.Odoo_Partner_ID__c));
        gen.writeStringField('picking_policy', 'direct');
        
        String clientOrderRef = (o.Customer_PO_Reference__c != null && o.Customer_PO_Reference__c != '')
            ? o.Customer_PO_Reference__c : '';
        gen.writeStringField('client_order_ref', clientOrderRef);
        
        gen.writeNumberField('x_studio_operation_country', Integer.valueOf(site.Odoo_Country_ID__c));
        gen.writeNumberField('x_studio_operation_metro', Integer.valueOf(site.Odoo_Metro_ID__c));
        gen.writeNumberField('x_studio_operation_site', Integer.valueOf(site.Odoo_Site_ID__c));
        gen.writeStringField('x_studio_service_request_date',
            o.RDD__c != null ? formatDate(o.RDD__c) : formatDate(o.EffectiveDate));
        gen.writeNumberField('x_contract_term', o.Contract_Term_Months__c != null ? Integer.valueOf(o.Contract_Term_Months__c) : 12);
        gen.writeNumberField('ns_invoice_frequency_id', Integer.valueOf(o.BillingAccount__r.Odoo_Invoice_Freq_ID__c));
        gen.writeNumberField('ns_ban_id', Integer.valueOf(o.BillingAccount__r.Odoo_BAN_ID__c));
        gen.writeStringField('currency_id', String.valueOf(o.CurrencyIsoCode));
        if (o.EffectiveDate != null && o.Contract_Term_Months__c != null) {
            Date validityDate = o.EffectiveDate.addMonths(Integer.valueOf(o.Contract_Term_Months__c));
            gen.writeStringField('validity_date', String.valueOf(validityDate));
        }
        
        if (o.FX_Billing_Flag__c) {
            gen.writeStringField('x_studio_fx_rate_model', o.FX_Rate_Model__c != null ? o.FX_Rate_Model__c : '');
            gen.writeStringField('x_studio_fx_rate_terms', o.FX_Rate_Terms__c != null ? o.FX_Rate_Terms__c : '');
            System.debug('   - FX Billing: Enabled');
        }
        
        if (o.Is_Ramp_Deal__c) {
            //gen.writeBooleanField('ns_is_ramp_up', true);
            gen.writeBooleanField('ns_from_ramp_up', true);
            System.debug('   - Ramp Deal: Enabled');
        }
        
        gen.writeFieldName('order_lines');
        gen.writeStartArray();
        
        Integer lineCount = 0;
        for (OrderItem oi : o.OrderItems) {
            lineCount++;
            System.debug('   📝 Building line ' + lineCount + ': Product ID=' + oi.Odoo_Product_ID__c + ', Qty=' + oi.Quantity);
            
            gen.writeStartObject();
            gen.writeStringField('sf_orderitem_id', oi.Id);
            gen.writeNumberField('product_id', Integer.valueOf(oi.Odoo_Product_ID__c));
            gen.writeStringField('name', oi.Description != null ? oi.Description : (oi.Product2 != null ? oi.Product2.Name : 'Service'));
            
            if (oi.Product_Attribute_Value__c != null) {
                gen.writeStringField('ns_product_attribute_value', oi.Product_Attribute_Value__c);
            }
            
            gen.writeNumberField('product_uom_qty', oi.Quantity);
            gen.writeNumberField('price_unit', oi.UnitPrice);
            gen.writeBooleanField('ns_usage_data', true);

            // ─── NEW LOGIC FOR sf_originitem_id ───
            // For aggregate products (Merge_IB_Task__c = TRUE), we want to point to the
            // ORIGINAL/STARTING order, not just the previous phase.
            Boolean isAggregate = (oi.Product2 != null && oi.Product2.Merge_IB_Task__c == true);

            // ns_change_type calculation
            String nsChangeType;
            if (!isPhase2Plus) {
                nsChangeType = 'add';
            } else if (isAggregate) {
                // For aggregate products, compare price with previous phase
                Map<String, OrderItem> prevItems = prevPhaseItemMap.get(o.Original_Order__c);
                String prevKey = String.valueOf(oi.Odoo_Product_ID__c) + '_' + String.valueOf(oi.Odoo_Attribute_Value_ID__c);
                OrderItem prevItem = (prevItems != null) ? prevItems.get(prevKey) : null;
                nsChangeType = (prevItem != null && prevItem.UnitPrice != oi.UnitPrice) ? 'price_change' : 'change';
            } else {
                nsChangeType = getRampChangeType(oi.Ramp_Identifier__c);
            }
            gen.writeStringField('ns_change_type', nsChangeType);

            // ─── sf_originitem_id calculation ───
            if (isPhase2Plus) {
                Boolean needsOriginItem = isAggregate || oi.Ramp_Linked_Phase__c != null
                    || 'Price_Change'.equals(oi.Ramp_Identifier__c) || 'Change'.equals(oi.Ramp_Identifier__c);
                
                if (needsOriginItem) {
                    String originItemId = null;
                    
                    if (isAggregate) {
                        // ─── AGGREGATE PRODUCT: Find the original (first) order's item ───
                        // Get the original order ID for this order
                        Id originalOrderId = orderToOriginalMap.get(o.Id);
                        
                        if (originalOrderId != null && prevPhaseItemMap.containsKey(originalOrderId)) {
                            // Look for the matching product in the original order
                            String prevKey = String.valueOf(oi.Odoo_Product_ID__c) + '_' + String.valueOf(oi.Odoo_Attribute_Value_ID__c);
                            Map<String, OrderItem> originalItems = prevPhaseItemMap.get(originalOrderId);
                            OrderItem originalItem = originalItems != null ? originalItems.get(prevKey) : null;
                            
                            if (originalItem != null) {
                                originItemId = originalItem.Id;
                                System.debug('      - AGGREGATE: Using original order item ' + originItemId + ' from order ' + originalOrderId);
                            } else {
                                System.debug('      - AGGREGATE: No matching item found in original order ' + originalOrderId);
                            }
                        } else {
                            // Fallback: use previous phase if original order not found
                            Map<String, OrderItem> prevItems = prevPhaseItemMap.get(o.Original_Order__c);  String prevKey = String.valueOf(oi.Odoo_Product_ID__c) + '_' + String.valueOf(oi.Odoo_Attribute_Value_ID__c); OrderItem prevItem = (prevItems != null) ? prevItems.get(prevKey) : null;
                            if (prevItem != null) { originItemId = prevItem.Id;
                                System.debug('      - AGGREGATE FALLBACK: Using previous phase item ' + originItemId);
                            }
                        }
                    } else {
                        // ─── NON-AGGREGATE PRODUCT: Use previous phase (existing logic) ───
                        Map<String, OrderItem> prevItems = prevPhaseItemMap.get(o.Original_Order__c);
                        String prevKey = String.valueOf(oi.Odoo_Product_ID__c) + '_' + String.valueOf(oi.Odoo_Attribute_Value_ID__c);
                        OrderItem prevItem = (prevItems != null) ? prevItems.get(prevKey) : null;
                        if (prevItem != null) {  originItemId = prevItem.Id;
                            System.debug('      - NON-AGGREGATE: Using previous phase item ' + originItemId);
                        }
                    }
                    
                    if (originItemId != null) {
                        gen.writeStringField('sf_originitem_id', originItemId);
                    }
                }
            }

            // Subscription line IDs for phase 2+ existing lines — uncomment when confirmed by client
            // if (oi.Original_OrderItem__c != null) {
            //     if (oi.Original_OrderItem__r.Odoo_Origin_Line_ID__c != null) {
            //         gen.writeNumberField('ns_origin_sale_line_id', Integer.valueOf(oi.Original_OrderItem__r.Odoo_Origin_Line_ID__c));
            //     }
            //     if (oi.Original_OrderItem__r.Odoo_Sub_Line_ID__c != null) {
            //         gen.writeNumberField('ns_subscription_line_id', Integer.valueOf(oi.Original_OrderItem__r.Odoo_Sub_Line_ID__c));
            //     }
            // }

            gen.writeStringField('ns_charge_type', oi.Billing_Mode__c != null ? oi.Billing_Mode__c.toLowerCase() : 'arrear');
            gen.writeStringField('x_studio_remarks', (oi.Line_Remarks__c != null && oi.Line_Remarks__c != '') ? oi.Line_Remarks__c : '-');
            
            if (oi.Odoo_Attribute_Value_ID__c != null) {
                gen.writeNumberField('ns_product_attribute', 1);
            }
            
            if (oi.CabE__c != null && oi.CabE__c != 0) {
                gen.writeNumberField('ns_cabe', oi.CabE__c);
            }
            
            if (oi.Custom_Attribute_Value__c != null && oi.Custom_Attribute_Value__c != '') {
                try {
                    gen.writeNumberField('ns_custom_attribute_value', Decimal.valueOf(oi.Custom_Attribute_Value__c));
                } catch (TypeException e) {
                    // Legacy non-numeric value predating VR_QLI_05_Custom_Attr_Must_Be_Number — skip
                    // rather than fail the whole payload; Odoo expects this field as a number.
                    System.debug('Custom_Attribute_Value__c is not numeric, skipping ns_custom_attribute_value: ' + oi.Custom_Attribute_Value__c);
                }
            }
            
            if (oi.Target_BAN__r != null && oi.Target_BAN__r.Odoo_BAN_ID__c != null) {
                gen.writeNumberField('ns_target_ban_id', Integer.valueOf(oi.Target_BAN__r.Odoo_BAN_ID__c));
            }
            
            if (oi.A_Side_Service_ID__c != null && oi.A_Side_Service_ID__c != '') {
                gen.writeNumberField('ns_a_side_service_id', Integer.valueOf(oi.A_Side_Service_ID__c));
            }
            
            if (oi.Z_Side_Service_ID__c != null && oi.Z_Side_Service_ID__c != '') {
                gen.writeNumberField('ns_z_side_service_id', Integer.valueOf(oi.Z_Side_Service_ID__c));
            }
            
            // Space IDs
            gen.writeFieldName('ns_space_ids');
            gen.writeStartArray();
            Integer spaceCount = 0;
            if (mapLineItemWithSpaceId.containsKey(oi.QuoteLineItemId)) {
                for (Inventory__c invRec : mapLineItemWithSpaceId.get(oi.QuoteLineItemId)) {
                    if (invRec.Odoo_Space_ID__c != null) {
                        gen.writeNumber(Integer.valueOf(invRec.Odoo_Space_ID__c));
                        spaceCount++;
                    }
                }
            }
            gen.writeEndArray();
            System.debug('      - Space IDs added: ' + spaceCount);
            
            // Breaker IDs
            gen.writeFieldName('ns_breaker_ids');
            gen.writeStartArray();
            Integer breakerCount = 0;
            if (mapLineItemWithBreakerId.containsKey(oi.QuoteLineItemId)) {
                for (Inventory__c invRec : mapLineItemWithBreakerId.get(oi.QuoteLineItemId)) {
                    if (invRec.Odoo_Inventory_Id__c != null) {
                        gen.writeNumber(Integer.valueOf(invRec.Odoo_Inventory_Id__c));
                        breakerCount++;
                    }
                }
            }
            gen.writeEndArray();
            System.debug('      - Breaker IDs added: ' + breakerCount);
            
            gen.writeEndObject();
        }
        
        gen.writeEndArray();
        System.debug('   - Total order lines built: ' + lineCount);
        
        gen.writeEndObject();
        gen.writeEndObject();
        gen.writeEndObject();
        
        String payload = gen.getAsString();
        System.debug('📦 IP-1 PAYLOAD SIZE: ' + payload.length() + ' characters');
        
        return payload;
    }

    private static String formatDateTime(Date d) {
        if (d == null) {
            System.debug('⚠️ IP-1 FORMAT: Null date received for formatDateTime');  return '';
        }
        String result = String.valueOf(d) + ' 00:00:00';
        System.debug('📅 IP-1 FORMAT: Date ' + d + ' formatted as ' + result);
        return result;
    }

    private static String formatDate(Date d) {
        if (d == null) {
            System.debug('⚠️ IP-1 FORMAT: Null date received for formatDate');  return '';
        }
        String result = String.valueOf(d);
        System.debug('📅 IP-1 FORMAT: Date ' + d + ' formatted as ' + result);
        return result;
    }

    // Maps Ramp_Identifier__c to Odoo ns_change_type for non-aggregate ramp lines.
    private static String getRampChangeType(String rampIdentifier) {
        if ('Price_Change'.equals(rampIdentifier)) return 'price_change';
        if ('Change'.equals(rampIdentifier))       return 'change';
        return 'add'; // 'Add' or null — genuinely new line in this phase
    }

    private List<Id> getOrdersWithCapacity(List<Id> ids) {
        System.debug('🔍 IP-1 CAPACITY: Checking ' + ids.size() + ' orders for capacity assignments');
        
        Set<Id> capacityOrderIds = new Set<Id>();
        Integer queryCount = 0;
        
        for (OrderItem oi : [SELECT OrderId FROM OrderItem WHERE OrderId IN :ids AND Is_Active__c = true  AND (Space__c != null OR Inventory__c != null) LIMIT 50000]) { capacityOrderIds.add(oi.OrderId);  queryCount++;
        }
        
        System.debug('📊 IP-1 CAPACITY: Found ' + capacityOrderIds.size() + ' orders with capacity (from ' + queryCount + ' OrderItems)');
        return new List<Id>(capacityOrderIds);
    }
}