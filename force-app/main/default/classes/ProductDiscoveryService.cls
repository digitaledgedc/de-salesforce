/**
 * ProductDiscoveryService
 *
 * Invocable service for the Discover_Products screen flow.
 * Builds the runtime_industries_cpq.ContextDataInput required by the
 * productList LWC component in the RLM product discovery experience.
 */
public with sharing class ProductDiscoveryService {

    public class BuildContextRequest {
        @InvocableVariable(label='Record Id' required=true)
        public String recordId;

        @InvocableVariable(label='Object API Name')
        public String objectApiName;
    }

    public class BuildContextResult {
        @InvocableVariable(label='Context Data Input Array')
        public List<runtime_industries_cpq.ContextDataInput> contextDataInputArray;
    }

    @InvocableMethod(
        label='Build Product Discovery Context'
        description='Creates ContextDataInput for the RLM productList screen component'
        category='Revenue Cloud'
    )
    public static List<BuildContextResult> buildContext(List<BuildContextRequest> requests) {
        List<BuildContextResult> results = new List<BuildContextResult>();
        for (BuildContextRequest req : requests) {
            String apiName = String.isBlank(req.objectApiName) ? 'Quote' : req.objectApiName;

            runtime_industries_cpq.ContextDataInput cdi = new runtime_industries_cpq.ContextDataInput();
            cdi.nodeName = apiName;
            cdi.nodeData = new Map<String, Object>{ 'id' => req.recordId };

            BuildContextResult result = new BuildContextResult();
            result.contextDataInputArray = new List<runtime_industries_cpq.ContextDataInput>{ cdi };
            results.add(result);
        }
        return results;
    }
}