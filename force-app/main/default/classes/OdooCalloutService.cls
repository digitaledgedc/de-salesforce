/**
 * OdooCalloutService
 * Shared HTTP utility for all Odoo callouts (IP-1 new orders, IP-1 change orders, IP-3).
 * All outbound callouts must use this class.
 * Named Credential selection is environment-driven via OdooIntegrationSettings__c.Environment__c.
 *
 * CRITICAL: Odoo always returns HTTP 200 even for application errors.
 * Always check JSON body for "error" key after confirming HTTP 200.
 * Relying on HTTP status alone silently misses all application-level errors.
 */
public with sharing class OdooCalloutService {

    public class Response {
        public Boolean isSuccess;
        public Integer odooId;       // parsed from result.id
        public String  rawBody;
        public String  errorBody;
    }

    /**
     * Resolves the base endpoint — Named Credential preferred; falls back to
     * Base_URL__c from the custom setting when the NC is not yet provisioned
     * (e.g. during initial org setup or before the NC principal is configured).
     */
    public static String resolveBaseEndpoint(OdooIntegrationSettings__c s) {
        if (s.Base_URL__c != null && s.Base_URL__c != '') {
            return s.Base_URL__c;
        }
        return 'callout:DigitalEdge_Odoo_' + s.Environment__c;
    }

    public static Response post(String path, String jsonBody) {
        OdooIntegrationSettings__c s = OdooIntegrationSettings__c.getOrgDefaults();

        HttpRequest req = new HttpRequest();
        req.setEndpoint(resolveBaseEndpoint(s) + path);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setBody(jsonBody);
        req.setTimeout(120000);

        return execute(req);
    }

    public static Response get(String path) {
        OdooIntegrationSettings__c s = OdooIntegrationSettings__c.getOrgDefaults();

        HttpRequest req = new HttpRequest();
        req.setEndpoint(resolveBaseEndpoint(s) + path);
        req.setMethod('GET');
        req.setTimeout(60000);

        return execute(req);
    }

    public static Response patch(String path, String jsonBody) {
        OdooIntegrationSettings__c s = OdooIntegrationSettings__c.getOrgDefaults();

        HttpRequest req = new HttpRequest();
        req.setEndpoint(resolveBaseEndpoint(s) + path);
        req.setMethod('PATCH');
        req.setHeader('Content-Type', 'application/json');
        req.setBody(jsonBody);
        req.setTimeout(30000);

        return execute(req);
    }

    public static Response execute(HttpRequest req) {
        Response res = new Response();
        System.debug('INTEGRATION ▶ OdooCalloutService — ' + req.getMethod() + ' ' + req.getEndpoint());
        try {
            HttpResponse raw = new Http().send(req);
            res.rawBody = raw.getBody();
            System.debug('INTEGRATION ▶ OdooCalloutService — HTTP ' + raw.getStatusCode()
                + ' | Body length: ' + (res.rawBody != null ? res.rawBody.length() : 0));
            System.debug('INTEGRATION ▶ OdooCalloutService — Response body: '
                + (res.rawBody != null && res.rawBody.length() > 2000
                    ? res.rawBody.substring(0, 2000) + '...[truncated]' : res.rawBody));

            // Odoo always returns HTTP 200 — errors are in the body
            if (raw.getStatusCode() == 200) {
                Map<String,Object> parsed =
                    (Map<String,Object>) JSON.deserializeUntyped(res.rawBody);
                if (parsed.containsKey('error')) {
                    // JSON-RPC top-level error (protocol/authentication failure)
                    res.isSuccess = false;
                    res.errorBody = JSON.serialize(parsed.get('error'));
                    System.debug('INTEGRATION ▶ OdooCalloutService — JSON-RPC ERROR: ' + res.errorBody);
                } else {
                    Map<String,Object> result =
                        (Map<String,Object>) parsed.get('result');
                    // Odoo application-level error: result.status == "error"
                    if (result != null && 'error'.equals(String.valueOf(result.get('status')))) {
                        res.isSuccess = false;
                        res.errorBody = String.valueOf(result.get('message'));
                        System.debug('INTEGRATION ▶ OdooCalloutService — APP ERROR: ' + res.errorBody);
                    } else {
                        res.isSuccess = true;
                        if (result != null) {
                            // IP-1 (new + change orders): Odoo returns order_id
                            Object rawId = result.containsKey('order_id')
                                ? result.get('order_id')
                                : result.get('id');
                            if (rawId != null) {
                                res.odooId = Integer.valueOf(rawId);
                            }
                        }
                        System.debug('INTEGRATION ▶ OdooCalloutService — SUCCESS | odooId: ' + res.odooId);
                    }
                }
            } else {
                res.isSuccess = false;
                String endpoint = req.getEndpoint();
                Integer code = raw.getStatusCode();
                if (code == 403) {
                    res.errorBody = 'HTTP 403 Forbidden — The Odoo API endpoint (' + endpoint
                        + ') is blocked by the Azure Application Gateway. '
                        + 'Verify that the /api/v1/* path is whitelisted on the gateway WAF rules. '
                        + 'The Odoo web UI (/web/login) may be accessible while API routes remain blocked.';
                } else if (code == 404) {
                    res.errorBody = 'HTTP 404 Not Found — The Odoo API endpoint (' + endpoint
                        + ') does not exist. Verify the path and Base_URL in OdooIntegrationSettings__c.';
                } else if (code >= 500) {
                    res.errorBody = 'HTTP ' + code + ' Server Error — The Odoo server at ' + endpoint
                        + ' returned an internal error. Raw response: '
                        + (res.rawBody != null && res.rawBody.length() > 500
                            ? res.rawBody.substring(0, 500) + '...[truncated]' : res.rawBody);
                } else {
                    res.errorBody = 'HTTP ' + code + ' from ' + endpoint + ': '
                        + (res.rawBody != null && res.rawBody.length() > 500
                            ? res.rawBody.substring(0, 500) + '...[truncated]' : res.rawBody);
                }
                System.debug('INTEGRATION ▶ OdooCalloutService — HTTP ERROR: ' + res.errorBody);
            }
        } catch (Exception e) {
            res.isSuccess = false;
            res.errorBody = e.getMessage();
            System.debug('INTEGRATION ▶ OdooCalloutService — EXCEPTION: ' + e.getMessage()
                + ' | Stack: ' + e.getStackTraceString());
        }
        return res;
    }

    /**
     * Log a callout failure to DE_Integration_Error__c.
     * Assigns to Integration Admin queue if it exists, otherwise to running user.
     */
    public static void logError(Id recordId, String ipRef, String msg) {
        DE_Integration_Error__c err = new DE_Integration_Error__c(
            Record_Id__c    = recordId != null ? String.valueOf(recordId) : null,
            IP_Reference__c = ipRef,
            Error_Message__c = msg,
            Status__c        = 'Open'
        );
        // TODO (Module 12): Assign to Integration Admin queue
        // List<Group> adminQueue = [SELECT Id FROM Group WHERE Name = 'Integration Admin' AND Type = 'Queue' LIMIT 1];
        // if (!adminQueue.isEmpty()) err.OwnerId = adminQueue[0].Id;
        insert err;
    }
}