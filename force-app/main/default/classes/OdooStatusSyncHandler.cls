/**
 * OdooStatusSyncHandler
 *
 * Legacy endpoint alias for IP-5. Delegates to OdooAssetStatusHandler.
 * Endpoint URL: /services/apexrest/odoo/status-sync/v1
 *
 * Odoo should call /services/apexrest/de/assetstatus (OdooAssetStatusHandler).
 * This class exists to handle any Odoo calls still targeting the old URL —
 * it forwards the request body to the active handler so no events are lost.
 */
@RestResource(urlMapping='/odoo/status-sync/v1')
global without sharing class OdooStatusSyncHandler {

    @HttpPost
    global static void handleStatusUpdate() {
        // Delegate to the active IP-5 handler — same request/response context
        OdooAssetStatusHandler.handlePost();
    }
}