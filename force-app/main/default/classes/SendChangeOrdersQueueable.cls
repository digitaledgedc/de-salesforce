/**
 * SendChangeOrdersQueueable - Optimized with Batch Processing & Debug Logs
 * IP-4 (Change Order): Sends Change, Churn, and related Change Orders to Odoo.
 */
public without sharing class SendChangeOrdersQueueable implements Queueable, Database.AllowsCallouts {

    private static final Integer BATCH_SIZE = 10; // Process 10 orders at a time to avoid callout limits
    private List<Id> orderIds;

    public SendChangeOrdersQueueable(List<Id> orderIds) {
        System.debug('🔵 IP-4 INIT: Creating Queueable with ' + orderIds.size() + ' Order IDs');
        System.debug('🔵 IP-4 INIT: Order IDs: ' + orderIds);
        this.orderIds = orderIds;
    }

    public void execute(QueueableContext ctx) {
        System.debug('🔵 IP-4 EXECUTE: Starting execution with ' + orderIds.size() + ' orders');
        
        // Process in smaller batches if too many orders
        if (orderIds.size() > BATCH_SIZE) {
            System.debug('⚠️ IP-4 BATCHING: ' + orderIds.size() + ' orders exceeds batch size of ' + BATCH_SIZE);
            List<Id> currentBatch = new List<Id>();
            List<Id> remainingBatch = new List<Id>();
            
            for (Integer i = 0; i < orderIds.size(); i++) {
                if (i < BATCH_SIZE) {
                    currentBatch.add(orderIds[i]);
                } else {
                    remainingBatch.add(orderIds[i]);
                }
            }
            
            System.debug('📦 IP-4 BATCH: Processing ' + currentBatch.size() + ' orders in current batch');
            System.debug('📦 IP-4 BATCH: ' + remainingBatch.size() + ' orders remaining for next batch');
            
            // Process current batch
            processBatch(currentBatch);
            
            // Queue next batch
            if (!remainingBatch.isEmpty()) {
                System.debug('🔄 IP-4 QUEUE: Enqueuing next batch with ' + remainingBatch.size() + ' orders');
                System.enqueueJob(new SendChangeOrdersQueueable(remainingBatch));
            } else {
                System.debug('✅ IP-4 COMPLETE: All batches processed');
            }
        } else {
            System.debug('📦 IP-4 DIRECT: Processing all ' + orderIds.size() + ' orders in single batch');
            processBatch(orderIds);
        }
    }
    
    private void processBatch(List<Id> batchOrderIds) {
        System.debug('🔵 IP-4 PROCESS BATCH: Starting batch processing for ' + batchOrderIds.size() + ' orders');
        
        OdooIntegrationSettings__c settings = OdooIntegrationSettings__c.getOrgDefaults();
        System.debug('⚙️ IP-4 SETTINGS: Username=' + settings.Username__c + ', Environment=' + settings.Environment__c);

        // Query Site__c once outside the loop
        System.debug('🔍 IP-4 QUERY: Fetching Site__c records');
        Map<String, Site__c> siteMap = new Map<String, Site__c>();
        for (Site__c s : [
            SELECT Name, Odoo_Company_ID__c, Odoo_Country_ID__c,
                   Odoo_Metro_ID__c, Odoo_Site_ID__c
            FROM Site__c
            WHERE Odoo_Site_ID__c > 0
        ]) {
            siteMap.put(s.Name, s);
        }
        System.debug('📍 IP-4 SITES: Found ' + siteMap.size() + ' active Odoo sites');

        // Invoice frequency CMT
        System.debug('🔍 IP-4 QUERY: Fetching Invoice Frequency mappings');
        Map<String, Integer> freqMap = new Map<String, Integer>();
        for (Invoice_Frequency__mdt f : Invoice_Frequency__mdt.getAll().values()) {
            if (f.SF_Frequency__c != null && f.Odoo_Frequency_Id__c != null && f.Odoo_Frequency_Id__c > 0) {
                freqMap.put(f.SF_Frequency__c, Integer.valueOf(f.Odoo_Frequency_Id__c));
            }
        }
        System.debug('📊 IP-4 FREQ MAP: Found ' + freqMap.size() + ' frequency mappings');

        // Optimized order query
        System.debug('🔍 IP-4 QUERY: Fetching Orders with OrderItems for IDs: ' + batchOrderIds);
        List<Order> orders = [
            SELECT Id, OrderNumber, EffectiveDate, Contract_Term_Months__c,
                   Customer_PO_Reference__c, RDD__c, Operation_Site__c,
                   Order_Type__c, Original_Order__c, Order_Number__c,
                   Original_Order__r.Odoo_Subscription_ID__c,
                   BillingAccount__r.Odoo_Partner_ID__c,
                   BillingAccount__r.Odoo_BAN_ID__c,CurrencyIsoCode,
                   BillingAccount__r.Invoice_Frequency__c,
                   (SELECT Id, Product2.Name, Odoo_Product_ID__c, Odoo_Attribute_Value_ID__c,Product_Attribute_Value__c,
                           Description, Charge_Type__c, Billing_Mode__c,
                           Quantity, UnitPrice, ns_change_type__c, QuoteLineItemId,
                           CabE__c, Custom_Attribute_Value__c,
                           A_Side_Service_ID__c, Z_Side_Service_ID__c,
                           Target_BAN__c, Target_BAN__r.Odoo_BAN_ID__c,
                           Odoo_Sub_Line_ID__c, Odoo_Origin_Line_ID__c,
                           Odoo_Project_Task_IDs__c, Odoo_Sub_Task_IDs__c,
                           Original_OrderItem__c,
                           Original_OrderItem__r.Odoo_Sub_Line_ID__c,Line_Remarks__c,
                           Original_OrderItem__r.Odoo_Origin_Line_ID__c,
                           Original_OrderItem__r.Odoo_Project_Task_IDs__c,
                           Original_OrderItem__r.Odoo_Sub_Task_IDs__c
                    FROM OrderItems
                    WHERE Is_Active__c = true)
            FROM Order 
            WHERE Id IN :batchOrderIds
        ];
        System.debug('📋 IP-4 ORDERS: Retrieved ' + orders.size() + ' orders');
        
        // Calculate statistics
        Integer totalOrderItems = 0;
        for (Order o : orders) {
            totalOrderItems += o.OrderItems.size();
        }
        System.debug('📊 IP-4 STATS: Total OrderItems=' + totalOrderItems);

        // Space/Breaker reservations are recorded on Inventory__c.Quote_Line__c (stamped by
        // InventoryController.assignInventoryToLine via the deCapacityReserve LWC) — NOT on
        // OrderItem.Space__c/Inventory__c, which the capacity-assignment flow never populates.
        // Mirrors the same lookup already used by SendNewOrdersQueueable (IP-1).
        Set<Id> quoteLineIds = new Set<Id>();
        for (Order o : orders) {
            for (OrderItem oi : o.OrderItems) {
                if (oi.QuoteLineItemId != null) {
                    quoteLineIds.add(oi.QuoteLineItemId);
                }
            }
        }

        Map<Id, List<Inventory__c>> mapLineItemWithSpaceId = new Map<Id, List<Inventory__c>>();
        Map<Id, List<Inventory__c>> mapLineItemWithBreakerId = new Map<Id, List<Inventory__c>>();

        if (!quoteLineIds.isEmpty()) {
            System.debug('🔍 IP-4 QUERY: Fetching Inventory records for ' + quoteLineIds.size() + ' QuoteLine IDs');
            for (Inventory__c invRec : [
                SELECT Id, Odoo_Space_ID__c, Odoo_Inventory_Id__c, Quote_Line__c, RecordType.DeveloperName
                FROM Inventory__c
                WHERE Quote_Line__c IN :quoteLineIds
            ]) {
                if (invRec.RecordType.DeveloperName == 'Inventory_Space') {
                    if (!mapLineItemWithSpaceId.containsKey(invRec.Quote_Line__c)) {
                        mapLineItemWithSpaceId.put(invRec.Quote_Line__c, new List<Inventory__c>());
                    }
                    mapLineItemWithSpaceId.get(invRec.Quote_Line__c).add(invRec);
                } else {
                    if (!mapLineItemWithBreakerId.containsKey(invRec.Quote_Line__c)) {
                        mapLineItemWithBreakerId.put(invRec.Quote_Line__c, new List<Inventory__c>());
                    }
                    mapLineItemWithBreakerId.get(invRec.Quote_Line__c).add(invRec);
                }
            }
            System.debug('🗄️ IP-4 INVENTORY: Space records found for ' + mapLineItemWithSpaceId.keySet().size() + ' QuoteLines');
            System.debug('🗄️ IP-4 INVENTORY: Breaker records found for ' + mapLineItemWithBreakerId.keySet().size() + ' QuoteLines');
        }

        List<Order> toUpdate = new List<Order>();
        List<DE_Integration_Error__c> errorsToInsert = new List<DE_Integration_Error__c>();
        
        // Auto-confirm mapping (simplified)
        Map<String, Boolean> autoConfirmByOrderType = new Map<String, Boolean>();
        System.debug('⚙️ IP-4 AUTO-CONFIRM: Defaulting to false for all order types');

        // Process each order
        Integer processedCount = 0;
        Integer successCount = 0;
        Integer failureCount = 0;
        
        for (Order o : orders) {
            processedCount++;
            System.debug('🔍 IP-4 PROCESSING Order ' + processedCount + '/' + orders.size() + ': ' + o.Order_Number__c + ' (' + o.Id + ')');
            System.debug('   - Order Type: ' + o.Order_Type__c);
            System.debug('   - Effective Date: ' + o.EffectiveDate);
            System.debug('   - Original Order: ' + o.Original_Order__c);
            
            // Validate site
            Site__c site = siteMap.get(o.Operation_Site__c);
            if (site == null) {
                String errMsg = 'No Site__c record found for site code: ' + o.Operation_Site__c;
                System.debug('❌ IP-4 ERROR: ' + errMsg);
                addError(o, errMsg, errorsToInsert, toUpdate);
                failureCount++;
                continue;
            }
            System.debug('   - Site Found: ' + site.Name);

            // Validate BAN
            if (o.BillingAccount__r == null || 
                o.BillingAccount__r.Odoo_Partner_ID__c == null ||
                o.BillingAccount__r.Odoo_BAN_ID__c == null) {
                String errMsg = 'BAN is missing required Odoo IDs (Odoo_Partner_ID__c or Odoo_BAN_ID__c).';
                System.debug('❌ IP-4 ERROR: ' + errMsg);
                System.debug('   - BAN: ' + o.BillingAccount__c);
                System.debug('   - Partner ID: ' + (o.BillingAccount__r != null ? o.BillingAccount__r.Odoo_Partner_ID__c : 'null'));
                System.debug('   - BAN ID: ' + (o.BillingAccount__r != null ? string.valueof(o.BillingAccount__r.Odoo_BAN_ID__c) : 'null'));
                addError(o, errMsg, errorsToInsert, toUpdate);
                failureCount++;
                continue;
            }
            System.debug('   - BAN Valid: Partner ID=' + o.BillingAccount__r.Odoo_Partner_ID__c + ', BAN ID=' + o.BillingAccount__r.Odoo_BAN_ID__c);

            // Validate OrderItems have product IDs
            Integer missingProductCount = 0;
            for (OrderItem oi : o.OrderItems) {
                if (oi.Odoo_Product_ID__c == null) {
                    missingProductCount++;
                    System.debug('   ⚠️ OrderItem ' + oi.Id + ' missing Odoo_Product_ID__c');
                }
            }
            
            if (missingProductCount > 0) {
                String errMsg = missingProductCount + ' Order Item(s) are missing Odoo_Product_ID__c.';
                System.debug('❌ IP-4 ERROR: ' + errMsg);
                addError(o, errMsg, errorsToInsert, toUpdate);
                failureCount++;
                continue;
            }
            System.debug('   - All ' + o.OrderItems.size() + ' OrderItems have valid Product IDs');

            Boolean autoConfirm = autoConfirmByOrderType.containsKey(o.Order_Type__c)
                ? autoConfirmByOrderType.get(o.Order_Type__c) : false;
            System.debug('   - Auto Confirm: ' + autoConfirm);

            String payload = buildIP4Payload(o, site, autoConfirm, freqMap, settings,
                mapLineItemWithSpaceId, mapLineItemWithBreakerId);
            System.debug('📦 IP-4 PAYLOAD for ' + o.Order_Number__c + ': ' + payload.substring(0, Math.min(500, payload.length())) + (payload.length() > 500 ? '...' : ''));
            System.debug('📦 IP-4 PAYLOAD SIZE: ' + payload.length() + ' characters');
            
            System.debug('🚀 IP-4 CALLOUT: Sending change order to Odoo for ' + o.Order_Number__c);
            OdooCalloutService.Response resp = OdooCalloutService.post('/api/v1/create_change_sale_order', payload);
            
            System.debug('📥 IP-4 RESPONSE for ' + o.Order_Number__c + ':');
            System.debug('   - Success: ' + resp.isSuccess);
            System.debug('   - Odoo ID: ' + resp.odooId);
            System.debug('   - Error: ' + (resp.errorBody != null ? resp.errorBody.substring(0, Math.min(200, resp.errorBody.length())) : 'null'));

            o.Odoo_Sync_Payload__c = payload;

            if (resp.isSuccess) {
                o.Odoo_Order_ID__c = String.valueOf(resp.odooId);
                o.Integration_Status__c = 'Synced';
                o.Integration_Error__c = null;
                successCount++;
                System.debug('✅ IP-4 SUCCESS: Order ' + o.Order_Number__c + ' synced with Odoo ID: ' + resp.odooId);
            } else {
                o.Integration_Status__c = 'Failed';
                o.Integration_Error__c = resp.errorBody;
                errorsToInsert.add(new DE_Integration_Error__c(
                    Record_Id__c = String.valueOf(o.Id), IP_Reference__c = 'IP-4',
                    Error_Message__c = resp.errorBody, Status__c = 'Open',
                    Request_Payload__c = payload));
                failureCount++;
                System.debug('❌ IP-4 FAILURE: Order ' + o.Order_Number__c + ' failed: ' + resp.errorBody);
            }
            toUpdate.add(o);
        }
        
        System.debug('📊 IP-4 BATCH SUMMARY: ' + processedCount + ' processed, ' + successCount + ' succeeded, ' + failureCount + ' failed');

        // DML operations
        if (!errorsToInsert.isEmpty()) {
            System.debug('💾 IP-4 DML: Inserting ' + errorsToInsert.size() + ' error records');
            insert errorsToInsert;
        }
        
        if (!toUpdate.isEmpty()) {
            System.debug('💾 IP-4 DML: Updating ' + toUpdate.size() + ' orders');
            update toUpdate;
        }
        
        System.debug('✅ IP-4 PROCESS BATCH COMPLETE: Batch finished');
    }
    
    private void addError(Order o, String errMsg, 
                         List<DE_Integration_Error__c> errorsToInsert, 
                         List<Order> toUpdate) {
        System.debug('❌ IP-4 ADD ERROR: Order ' + o.Order_Number__c + ' - ' + errMsg);
        o.Integration_Status__c = 'Failed';
        o.Integration_Error__c = errMsg;
        errorsToInsert.add(new DE_Integration_Error__c(
            Record_Id__c = String.valueOf(o.Id), IP_Reference__c = 'IP-4',
            Error_Message__c = errMsg, Status__c = 'Open'));
        toUpdate.add(o);
    }

    @TestVisible
    private static String getSubscriptionManagement(String orderType) {
        String result;
        if (orderType == 'Change/Upsell') {
            result = 'change_order';
        } else if (orderType == 'Churn') {
            result = 'churn';
        } else if (orderType == 'Partial Churn') {
            result = 'change_order';
        } else if (orderType == 'Renewal') {
            result = 'renew';
        } else {
            result = 'change_order';
        }
        System.debug('📋 IP-4 SUBSCRIPTION MGMT: OrderType=' + orderType + ' → ' + result);
        return result;
    }

    @TestVisible
    private String buildIP4Payload(Order o, Site__c site, Boolean autoConfirm,
                                   Map<String, Integer> freqMap, OdooIntegrationSettings__c settings,
                                   Map<Id, List<Inventory__c>> mapLineItemWithSpaceId,
                                   Map<Id, List<Inventory__c>> mapLineItemWithBreakerId) {
        
        System.debug('🔨 IP-4 BUILD PAYLOAD: Creating payload for Order ' + o.Order_Number__c);
        
        String subMgmt = getSubscriptionManagement(o.Order_Type__c);
        JSONGenerator gen = JSON.createGenerator(false);
        
        gen.writeStartObject();
        gen.writeFieldName('params');
        gen.writeStartObject();
        
        gen.writeStringField('username', settings.Username__c != null ? settings.Username__c : '');
        gen.writeStringField('password', settings.Password__c != null ? settings.Password__c : '');
        gen.writeBooleanField('auto_confirm', autoConfirm);
        
        gen.writeFieldName('data');
        gen.writeStartObject();
        
        gen.writeStringField('name', o.Order_Number__c);
        gen.writeBooleanField('is_from_sf', true);
        gen.writeStringField('sf_order_id', o.Id);
        if (o.Original_Order__c != null) {
            gen.writeStringField('sf_origin_id', o.Original_Order__c);
        }
        
        gen.writeStringField('subscription_management', subMgmt);
        gen.writeNumberField('company_id', Integer.valueOf(site.Odoo_Company_ID__c));
        gen.writeStringField('date_order', formatDateTime(o.EffectiveDate));
        gen.writeNumberField('partner_id', Integer.valueOf(o.BillingAccount__r.Odoo_Partner_ID__c));
        
        String clientOrderRef = (o.Customer_PO_Reference__c != null && o.Customer_PO_Reference__c != '')
            ? o.Customer_PO_Reference__c : '';
        gen.writeStringField('client_order_ref', clientOrderRef);
        
        gen.writeNumberField('x_studio_operation_country', Integer.valueOf(site.Odoo_Country_ID__c));
        gen.writeNumberField('x_studio_operation_metro', Integer.valueOf(site.Odoo_Metro_ID__c));
        gen.writeNumberField('x_studio_operation_site', Integer.valueOf(site.Odoo_Site_ID__c));
        gen.writeStringField('x_studio_service_request_date',
            o.RDD__c != null ? formatDate(o.RDD__c) : formatDate(o.EffectiveDate));
        gen.writeNumberField('x_contract_term',
            o.Contract_Term_Months__c != null ? Integer.valueOf(o.Contract_Term_Months__c) : 12);
        gen.writeNumberField('ns_ban_id', Integer.valueOf(o.BillingAccount__r.Odoo_BAN_ID__c));
        gen.writeStringField('currency_id', String.valueOf(o.CurrencyIsoCode));
        // Invoice frequency
        String freqLabel = o.BillingAccount__r.Invoice_Frequency__c != null
            ? o.BillingAccount__r.Invoice_Frequency__c : 'Monthly';
        Integer freqId = freqMap.get(freqLabel);
        if (freqId != null) {
            gen.writeNumberField('ns_invoice_frequency_id', freqId);
            System.debug('   - Invoice Frequency: ' + freqLabel + ' → ID ' + freqId);
        } else {
            gen.writeBooleanField('ns_invoice_frequency_id', false);
            System.debug('   - Invoice Frequency: ' + freqLabel + ' not found in map');
        }
        
        // Subscription ID
        /*if (o.Original_Order__r != null && o.Original_Order__r.Odoo_Subscription_ID__c != null) {
            gen.writeNumberField('ns_subscription_line_id', Integer.valueOf(o.Original_Order__r.Odoo_Subscription_ID__c));
            System.debug('   - Subscription ID: ' + o.Original_Order__r.Odoo_Subscription_ID__c);
        } else {
            System.debug('   - No Subscription ID found for order');
        }*/
        
        // Order lines
        gen.writeFieldName('order_line');
        gen.writeStartArray();
        
        Integer lineCount = 0;
        for (OrderItem oi : o.OrderItems) {
            lineCount++;
            System.debug('   📝 Building line ' + lineCount + '/' + o.OrderItems.size());
            
            String sfChangeType = oi.ns_change_type__c != null ? oi.ns_change_type__c.toUpperCase() : '';
            Boolean isAddLine = 'NEW'.equals(sfChangeType);
            String odooChangeType = getOdooChangeType(sfChangeType);
            
            System.debug('      - Change Type: SF="' + sfChangeType + '" → Odoo="' + odooChangeType + '"');
            System.debug('      - Product ID: ' + oi.Odoo_Product_ID__c);
            System.debug('      - Quantity: ' + oi.Quantity);
            System.debug('      - Unit Price: ' + oi.UnitPrice);
            
            String resolvedSubLineId = resolveOdooField(oi.Odoo_Sub_Line_ID__c,
                oi.Original_OrderItem__r?.Odoo_Sub_Line_ID__c);
            String resolvedOriginLineId = resolveOdooField(oi.Odoo_Origin_Line_ID__c,
                oi.Original_OrderItem__r?.Odoo_Origin_Line_ID__c);
            
            System.debug('      - Resolved Sub Line ID: ' + resolvedSubLineId);
            System.debug('      - Resolved Origin Line ID: ' + resolvedOriginLineId);
            
            gen.writeStartObject();
            
            // SF reference fields
            gen.writeStringField('sf_orderitem_id', oi.Id);
            
            if (o.Original_Order__r != null && o.Original_Order__r.Odoo_Subscription_ID__c != null) {
                gen.writeNumberField('subscription_id', Integer.valueOf(o.Original_Order__r.Odoo_Subscription_ID__c));
            }
            
            gen.writeStringField('ns_change_type', odooChangeType);
            gen.writeNumberField('product_id', Integer.valueOf(oi.Odoo_Product_ID__c));
            gen.writeStringField('name', oi.Description != null ? oi.Description : 
                                (oi.Product2 != null ? oi.Product2.Name : 'Service'));
            
            if (oi.Product_Attribute_Value__c != null) {
                gen.writeStringField('ns_product_attribute_value', String.valueOf(oi.Product_Attribute_Value__c));
            }
            
            gen.writeNumberField('product_uom_qty', oi.Quantity);
            gen.writeNumberField('price_unit', oi.UnitPrice);
            gen.writeStringField('ns_charge_type', oi.Billing_Mode__c != null ? oi.Billing_Mode__c.toLowerCase() : 'arrear');
            gen.writeStringField('x_studio_remarks', (oi.Description != null && oi.Description != '') ? oi.Description : '-');
            
            // Optional fields
            if (oi.CabE__c != null && oi.CabE__c != 0) {
                gen.writeNumberField('ns_cabe', oi.CabE__c);
                System.debug('      - CabE: ' + oi.CabE__c);
            }
            if (oi.Custom_Attribute_Value__c != null && oi.Custom_Attribute_Value__c != '') {
                try {
                    gen.writeNumberField('ns_custom_attribute_value', Decimal.valueOf(oi.Custom_Attribute_Value__c));
                    System.debug('      - Custom Attribute: ' + oi.Custom_Attribute_Value__c);
                } catch (TypeException e) {
                    // Legacy non-numeric value predating VR_QLI_05_Custom_Attr_Must_Be_Number — skip
                    // rather than fail the whole payload; Odoo expects this field as a number.
                    System.debug('Custom_Attribute_Value__c is not numeric, skipping ns_custom_attribute_value: ' + oi.Custom_Attribute_Value__c);
                }
            }
            if (oi.A_Side_Service_ID__c != null && oi.A_Side_Service_ID__c != '') {
                gen.writeNumberField('ns_a_side_service_id', Integer.valueOf(oi.A_Side_Service_ID__c));
            }
            if (oi.Z_Side_Service_ID__c != null && oi.Z_Side_Service_ID__c != '') {
                gen.writeNumberField('ns_z_side_service_id', Integer.valueOf(oi.Z_Side_Service_ID__c));
            }
            if (oi.Original_OrderItem__c != null) {
                gen.writeStringField('sf_originitem_id', oi.Original_OrderItem__c);
            }
            if (oi.Target_BAN__r != null && oi.Target_BAN__r.Odoo_BAN_ID__c != null) {
                gen.writeNumberField('ns_target_ban_id', Integer.valueOf(oi.Target_BAN__r.Odoo_BAN_ID__c));
                System.debug('      - Target BAN ID: ' + oi.Target_BAN__r.Odoo_BAN_ID__c);
            }
            
            // Odoo line IDs
            if (isAddLine) {
                gen.writeBooleanField('ns_origin_sale_line_id', false);
                gen.writeBooleanField('ns_subscription_line_id', false);
                System.debug('      - ADD line: setting origin and sub line IDs to false');
            } else {
                Integer originId = parseOdooId(resolvedOriginLineId);
                Integer subLineId = parseOdooId(resolvedSubLineId);
                if (originId != null) {
                    gen.writeNumberField('ns_origin_sale_line_id', originId);
                    System.debug('      - Origin Line ID: ' + originId);
                }
                if (subLineId != null) {
                    gen.writeNumberField('ns_subscription_line_id', subLineId);
                    System.debug('      - Subscription Line ID: ' + subLineId);
                }
            }
            
            // Space and breaker IDs — reservations live on Inventory__c.Quote_Line__c,
            // looked up in bulk above (see mapLineItemWithSpaceId/mapLineItemWithBreakerId).
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
            
            // Project task IDs
            gen.writeFieldName('ns_project_task_id');
            gen.writeStartArray();
            String taskIdsCsv = resolveOdooField(oi.Odoo_Project_Task_IDs__c,
                oi.Original_OrderItem__r?.Odoo_Project_Task_IDs__c);
            if (taskIdsCsv != null) {
                List<String> taskIds = taskIdsCsv.split(',');
                System.debug('      - Project Task IDs: ' + taskIds.size());
                for (String tid : taskIds) {
                    String trimmed = tid.trim();
                    if (trimmed != '') {
                        gen.writeNumber(Integer.valueOf(trimmed));
                    }
                }
            }
            gen.writeEndArray();
            
            gen.writeFieldName('ns_sub_task_id');
            gen.writeStartArray();
            if (taskIdsCsv != null) {
                for (String tid : taskIdsCsv.split(',')) {
                    String trimmed = tid.trim();
                    if (trimmed != '') {
                        gen.writeNumber(Integer.valueOf(trimmed));
                    }
                }
            }
            gen.writeEndArray();
            
            gen.writeEndObject();
        }
        
        gen.writeEndArray();
        System.debug('   - Total order lines built: ' + lineCount);
        
        gen.writeEndObject();
        gen.writeEndObject();
        gen.writeEndObject();
        
        return gen.getAsString();
    }
    
    private static String getOdooChangeType(String sfChangeType) {
        if ('NEW'.equals(sfChangeType)) return 'add';
        if ('DELETE'.equals(sfChangeType)) return 'delete';
        if ('CHANGE'.equals(sfChangeType)) return 'change';
        if ('CHANGE_PRICE'.equals(sfChangeType)) return 'price_change';
        if ('NO_CHANGE'.equals(sfChangeType)) return 'no';
        return 'add';
    }
    
    private static String resolveOdooField(String ownValue, String fallbackValue) {
        if (ownValue != null && ownValue != '') {
            System.debug('   - Using own value: ' + ownValue);
            return ownValue;
        }
        String result = (fallbackValue != null && fallbackValue != '') ? fallbackValue : null;
        System.debug('   - Using fallback value: ' + result);
        return result;
    }
    
    private static Integer parseOdooId(String val) {
        if (val == null || val == '') {
            System.debug('   - parseOdooId: null or empty input');
            return null;
        }
        
        if (val.isNumeric()) {
            Integer result = Integer.valueOf(val);
            System.debug('   - parseOdooId: Parsed numeric value ' + result + ' from "' + val + '"');
            return result;
        }
        
        try {
            List<String> parts = val.split('_');
            for (Integer i = parts.size() - 1; i >= 0; i--) {
                if (parts[i] != '' && parts[i].isNumeric()) {
                    Integer result = Integer.valueOf(parts[i]);
                    System.debug('   - parseOdooId: Extracted ' + result + ' from external ID "' + val + '"');
                    return result;
                }
            }
        } catch (Exception e) {
            System.debug('   - parseOdooId: Error parsing "' + val + '": ' + e.getMessage());
        }
        
        System.debug('   - parseOdooId: Could not parse value "' + val + '"');
        return null;
    }

    private static String formatDateTime(Date d) {
        if (d == null) {
            System.debug('⚠️ IP-4 FORMAT: Null date received for formatDateTime');
            return '';
        }
        String result = String.valueOf(d) + ' 00:00:00';
        System.debug('📅 IP-4 FORMAT: DateTime ' + d + ' formatted as ' + result);
        return result;
    }

    private static String formatDate(Date d) {
        if (d == null) {
            System.debug('⚠️ IP-4 FORMAT: Null date received for formatDate');
            return '';
        }
        String result = String.valueOf(d);
        System.debug('📅 IP-4 FORMAT: Date ' + d + ' formatted as ' + result);
        return result;
    }
}