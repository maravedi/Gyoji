# Gyoji Authentication Proxy - Project Plan

## Executive Summary

Gyoji is an authentication proxy that bridges the gap between SumoLogic Universal Connectors and third-party log systems (Check Point CloudGuard, Microsoft Graph) when direct authentication isn't possible. The project currently runs as a standalone .NET 8.0 TCP proxy using Fluxzy, but needs to be migrated to Azure Functions for cost-effectiveness and cloud-native scalability.

## Project Objectives

1. **Primary Goal**: Migrate Gyoji from a standalone TCP proxy to an Azure Function App while preserving all authentication transformation logic
2. **Secondary Goals**:
   - Achieve serverless cost model (pay-per-execution vs. always-on VM/container)
   - Enable horizontal scaling for high-volume log collection scenarios
   - Maintain compatibility with existing SumoLogic Universal Connector configurations
   - Improve observability through native Azure Monitor integration

## Current Architecture

### Technology Stack
- **Runtime**: .NET 8.0
- **Proxy Engine**: Fluxzy.Core 1.30.26 (HTTPS MITM proxy)
- **State Management**: In-memory ConcurrentDictionary
- **Deployment Model**: Long-running console application (systemd, Docker, etc.)

### Key Components
- `program.cs` - Proxy initialization and lifecycle management
- `checkpoint_flow.cs` - Check Point authentication and log retrieval transformations
- `microsoft_graph_flow.cs` - Microsoft Graph OAuth token exchange
- `flow_state.cs` - In-memory request/response state correlation
- `request_transformer.cs` / `response_transformer.cs` - Fluxzy filter implementations
- `proxy_logger.cs` - Structured JSON logging

### Current Limitations
1. **Azure Functions Incompatibility**:
   - Cannot bind arbitrary TCP listeners in Function sandbox
   - Cannot run infinite background loops (`Task.Delay(Timeout.Infinite)`)
   - Fluxzy's TCP-level filtering doesn't align with Functions' HTTP trigger model

2. **Scalability Constraints**:
   - Static in-memory state breaks under horizontal scaling
   - Single-instance design limits throughput
   - No built-in retry/back-pressure mechanisms

3. **Operational Overhead**:
   - Requires dedicated VM or container instance
   - Manual scaling and monitoring configuration
   - Higher baseline cost for always-on infrastructure

## Target Architecture

### Azure Functions Model
- **Trigger Type**: HTTP (isolated worker, .NET 8.0)
- **Execution Model**: Request-scoped (stateless, no persistent state needed)
- **State Management**: Local variables within function execution scope
- **Routing**: Single catch-all HTTP trigger with dynamic path routing

### Component Structure
```
Gyoji/
├── src/
│   ├── Gyoji.Proxy.Core/               # Shared transformation library
│   │   ├── Models/
│   │   │   ├── RequestSnapshot.cs      # POCO request envelope
│   │   │   ├── ResponseEnvelope.cs     # POCO response envelope
│   │   │   └── TransformContext.cs     # Request-scoped transformation context
│   │   ├── Services/
│   │   │   └── HttpClientFactory.cs    # Upstream HTTP client with retry
│   │   ├── Transformers/
│   │   │   ├── CheckpointAuthTransformer.cs
│   │   │   ├── CheckpointLogTransformer.cs
│   │   │   └── MicrosoftGraphTransformer.cs
│   │   ├── Configuration/
│   │   │   └── ProxyOptions.cs         # Configuration model
│   │   └── Logging/
│   │       └── ProxyLogger.cs          # Structured logging
│   ├── Gyoji.Proxy.Function/           # Azure Functions project
│   │   ├── Functions/
│   │   │   └── ProxyFunction.cs        # HTTP trigger handler
│   │   ├── Program.cs                  # DI container setup
│   │   ├── host.json                   # Function runtime config
│   │   └── local.settings.json         # Local development settings
│   └── gyoji_proxy/                    # Legacy standalone proxy (maintain for now)
└── tests/
    ├── Gyoji.Proxy.Core.Tests/
    └── Gyoji.Proxy.Function.Tests/
```

## Implementation Plan

### Phase 1: Core Library Extraction (Week 1)
**Objective**: Decouple transformation logic from Fluxzy dependencies

#### Tasks
1. **Create Core Project**
   - [x] Initialize `Gyoji.Proxy.Core` class library (.NET 8.0)
   - [x] Define POCO models (`RequestSnapshot`, `ResponseEnvelope`)
   - [x] Add solution file to track all projects

2. **Extract Configuration**
   - [ ] Move `ProxyOptions` to Core with validation attributes
   - [ ] Replace environment variable parsing with `IConfiguration` binding
   - [ ] Add configuration validation on startup

3. **Refactor Checkpoint Flow**
   - [ ] Convert `CheckpointFlow.TransformAuthRequest` to accept `RequestSnapshot` instead of `TransformContext`
   - [ ] Convert `CheckpointFlow.TransformLogRequest` to pure function
   - [ ] Convert `CheckpointFlow.TransformAuthResponseAsync` to accept string body instead of `IBodyReader`
   - [ ] Extract HTTP client logic to `CheckpointLogFetcher` service

4. **Refactor Microsoft Graph Flow**
   - [ ] Convert to accept POCO parameters instead of Fluxzy types
   - [ ] Extract token exchange logic to `MicrosoftGraphTokenService`

5. **Request Context Model**
   - [ ] Create `TransformContext` class to hold request-scoped data during transformation pipeline
   - [ ] This replaces the need for persistent state - data flows through function execution as local variables
   - [ ] Maintain `FlowMetadata` model for standalone proxy compatibility (uses in-memory store)

6. **Logging Abstraction**
   - [ ] Make `ProxyLogger` work with `ILogger<T>` for Azure Functions compatibility
   - [ ] Keep existing JSON output for standalone proxy

#### Acceptance Criteria
- Core library compiles independently
- No Fluxzy references in Core project
- Existing standalone proxy still works using Core library (with its own in-memory state store)
- Unit tests cover transformation logic (>80% coverage)
- Transformers accept request context as parameter, return transformed data (no side effects)

---

### Phase 2: Azure Functions Infrastructure (Week 2)
**Objective**: Set up Azure Functions project with HTTP client infrastructure

#### Tasks
1. **Initialize Function Project**
   - [ ] Create `Gyoji.Proxy.Function` isolated worker project
   - [ ] Add reference to `Gyoji.Proxy.Core`
   - [ ] Configure DI container in `Program.cs`
   - [ ] Set up `host.json` with appropriate timeouts and concurrency limits

2. **Configure HTTP Client**
   - [ ] Set up `IHttpClientFactory` with named clients for Check Point and Microsoft Graph
   - [ ] Configure Polly retry policies (exponential backoff, circuit breaker)
   - [ ] Set timeouts from `ProxyOptions.http_timeout`
   - [ ] Configure connection pooling and keep-alive settings

3. **Environment Configuration**
   - [ ] Map all `GYOJI_*` env vars to Azure App Settings
   - [ ] Configure Azure Key Vault integration for secrets (if needed)
   - [ ] Set up managed identity for Key Vault access (if needed)
   - [ ] Document configuration mapping from standalone to Function App

#### Acceptance Criteria
- Function project builds and runs locally
- Configuration loads from `local.settings.json` during development
- HTTP clients retry transient failures
- All transformers are registered in DI container

---

### Phase 3: HTTP Trigger Implementation (Week 3)
**Objective**: Build catch-all HTTP trigger that processes SumoLogic requests

#### Tasks
1. **Create Proxy Function**
   ```csharp
   [Function("GyojiProxy")]
   public async Task<HttpResponseData> Run(
       [HttpTrigger(AuthorizationLevel.Function, "get", "post", Route = "{*path}")]
       HttpRequestData request,
       string path)
   {
       // Parse request
       var snapshot = await RequestParser.ParseAsync(request);
       var context = new TransformContext(); // Request-scoped, no persistent storage

       // Transform and forward based on target
       if (IsCheckpointAuth(path)) {
           var authResponse = await ProcessCheckpointAuth(snapshot, context);

           // Auto-fetch uses context data from same execution
           if (ShouldAutoFetch(context)) {
               return await FetchAndReturnLogs(authResponse, context);
           }
           return authResponse;
       }
       // ... other routes
   }
   ```
   - [ ] Parse incoming request to `RequestSnapshot`
   - [ ] Route to appropriate transformer based on target URL
   - [ ] Execute transformation pipeline with request-scoped context
   - [ ] Forward transformed request to upstream API
   - [ ] Transform response and return to caller

2. **Request Routing Logic**
   - [ ] Inspect `path` parameter or request headers to determine target API
   - [ ] Support both transparent proxy mode (path-based) and explicit routes

3. **Auto-Fetch Implementation**
   - [ ] Store auth request parameters in local `TransformContext` variable
   - [ ] Pass context through to response handler within same function execution
   - [ ] Trigger log fetch synchronously if enabled (context data is in-memory)
   - [ ] Return logs or auth envelope to caller

4. **Error Handling**
   - [ ] Return appropriate HTTP status codes for client/server errors
   - [ ] Log all exceptions with correlation IDs
   - [ ] Implement retry headers for transient failures

#### Acceptance Criteria
- Function responds to HTTP requests on all routes
- Check Point authentication flow completes end-to-end
- Microsoft Graph token exchange works
- Auto-fetch retrieves logs after successful auth using in-memory context
- No persistent state storage required
- Errors are logged with structured event names

---

### Phase 4: Testing & Validation (Week 4)
**Objective**: Ensure functional parity with standalone proxy

#### Tasks
1. **Unit Tests**
   - [ ] Test all transformer methods with sample payloads
   - [ ] Mock state store and HTTP client dependencies
   - [ ] Validate JSON serialization/deserialization
   - [ ] Test error cases (missing credentials, malformed JSON, etc.)

2. **Integration Tests**
   - [ ] Test HTTP client retry policies with fault injection
   - [ ] Test end-to-end flow with mock Check Point/Graph endpoints
   - [ ] Verify auto-fetch works with in-memory context passing

3. **Load Testing**
   - [ ] Simulate concurrent SumoLogic collector requests
   - [ ] Validate horizontal scaling behavior (multiple Function instances)
   - [ ] Measure cold start latency (P50, P95, P99)
   - [ ] Verify stateless execution handles concurrent load correctly

4. **Compatibility Testing**
   - [ ] Test with real SumoLogic Universal Connector (staging environment)
   - [ ] Validate proxy header handling (`X-Forwarded-*`, etc.)
   - [ ] Confirm TLS/certificate trust chain works

#### Acceptance Criteria
- >90% code coverage across Core and Function projects
- All integration tests pass against Azurite
- Function handles 100+ concurrent requests without errors
- SumoLogic collector successfully authenticates and retrieves logs

---

### Phase 5: Deployment & Infrastructure (Week 5)
**Objective**: Provision Azure resources and deploy to production

#### Tasks
1. **Infrastructure as Code**
   - [ ] Create Bicep/Terraform templates for:
     - Function App (consumption or premium plan)
     - Storage Account (for function internals only - no app state)
     - Application Insights (for logging/monitoring)
     - (Optional) API Management for rate limiting/auth

2. **CI/CD Pipeline**
   - [ ] Set up GitHub Actions workflow:
     - Build and test on every PR
     - Publish artifacts on merge to main
     - Deploy to staging environment
     - Smoke tests in staging
     - Manual approval for production deployment

3. **Security Hardening**
   - [ ] Enable managed identity for Function App
   - [ ] Store all secrets in Key Vault (Check Point credentials, Graph client secrets)
   - [ ] Configure Function authorization (function keys or Azure AD)
   - [ ] Enable HTTPS-only access
   - [ ] Set up CORS policies if needed

4. **Monitoring Setup**
   - [ ] Create Application Insights dashboards for:
     - Request throughput and latency
     - Error rates by event type
     - Upstream API latency
     - Auto-fetch success/failure rates
   - [ ] Configure alerts for:
     - High error rates (>5% over 5 minutes)
     - Long cold starts (>10s)
     - Upstream API timeouts
     - Function execution timeouts

#### Acceptance Criteria
- Infrastructure deploys via automated pipeline
- Function is accessible via public HTTPS endpoint
- All secrets are stored in Key Vault
- Application Insights receives structured logs
- Alerts fire on synthetic test failures

---

### Phase 6: Migration & Cutover (Week 6)
**Objective**: Migrate SumoLogic collectors from standalone proxy to Azure Function

#### Tasks
1. **Parallel Run**
   - [ ] Configure subset of collectors to use Azure Function endpoint
   - [ ] Monitor both standalone and Function deployments
   - [ ] Compare log volumes and error rates

2. **SumoLogic Configuration**
   - [ ] Update collector proxy settings to Function URL
   - [ ] Add Function key to collector authentication
   - [ ] Test failover scenarios (Function offline → standalone proxy)

3. **Performance Tuning**
   - [ ] Adjust Function timeout settings if needed (default 5min, max 10min for Consumption)
   - [ ] Optimize HTTP client connection pooling and keep-alive settings
   - [ ] Review cold start metrics and consider Premium Plan if needed

4. **Documentation**
   - [ ] Update README with Azure Function deployment instructions
   - [ ] Document environment variable mappings
   - [ ] Create runbooks for common operational tasks (restart, scale up, etc.)
   - [ ] Add troubleshooting guide for SumoLogic integration

5. **Decommission Standalone Proxy**
   - [ ] Verify all collectors are using Function endpoint
   - [ ] Archive standalone proxy codebase (keep in repo for reference)
   - [ ] Shut down VM/container hosting standalone proxy

#### Acceptance Criteria
- All collectors successfully route through Azure Function
- Log ingestion rates match pre-migration levels
- Zero data loss or authentication failures during cutover
- Documentation is complete and reviewed

---

## Technical Considerations

### State Management Strategy

**No Persistent State Required! 🎉**

After reviewing the OAuth 2.0 Client Credential flow and the current implementation, we've determined that **no persistent state storage is needed**. Here's why:

1. **Session Management**: OAuth sessions are tracked by the client (SumoLogic) and server (Check Point/Graph) via tokens. The proxy doesn't need to maintain session state.

2. **Request-Response Correlation**: In the current Fluxzy proxy, state storage bridges separate request/response filter handlers. In Azure Functions, the entire flow happens within a single execution:
   ```
   Request received → Transform → Call upstream → Receive response → Transform → Return
   ```
   All data flows through local variables/parameters within the function scope.

3. **Auto-Fetch Feature**: The auto-fetch logic needs query parameters and credentials from the auth request when processing the auth response. In Azure Functions:
   ```csharp
   var authParams = ParseAuthRequest(request);      // Step 1: Parse
   var authResponse = await GetToken(authParams);    // Step 2: Get token
   if (authParams.ShouldAutoFetch) {                // Step 3: Use same-execution data
       return await FetchLogs(authResponse.Token, authParams.QueryParams);
   }
   ```
   No storage needed - `authParams` is a local variable!

4. **Standalone Proxy Compatibility**: The existing standalone proxy will keep its in-memory `ConcurrentDictionary` since it uses Fluxzy's async filter model.

**Benefits of Stateless Design**:
- ✅ Simpler architecture - no distributed storage complexity
- ✅ Lower cost - no Table Storage or Redis charges
- ✅ Better performance - no I/O latency for state operations
- ✅ Easier testing - no external dependencies to mock
- ✅ True horizontal scaling - no state synchronization concerns

### Routing Architecture

**Option 1: Single Catch-All Route (Recommended)**
```
POST /api/proxy/{*path}
```
- Function inspects `path` to determine target API
- Mirrors original URL structure
- Simpler for SumoLogic configuration

**Option 2: Explicit Routes**
```
POST /api/checkpoint/auth
POST /api/checkpoint/logs
POST /api/msgraph/token
```
- More explicit, easier to apply route-level policies
- Requires SumoLogic to use different proxy URLs per API

**Recommendation**: Use Option 1 for transparency; SumoLogic doesn't need to know about proxy internals.

### Auto-Fetch Behavior

Current standalone proxy performs auto-fetch synchronously within the auth response handler. This blocks the response until logs are retrieved (or timeout).

**Azure Function Considerations**:
1. **Synchronous** (maintain current behavior):
   - Simple, maintains request/response correlation
   - Risk: Function timeout if log fetch takes >230s (max Function timeout)

2. **Asynchronous** (queue-based):
   - Store auth token in state
   - Return auth response immediately
   - Trigger separate function via Storage Queue to fetch logs
   - SumoLogic must poll for logs separately

**Recommendation**: Keep synchronous for Phase 1, evaluate async if timeouts become frequent.

### Scalability & Performance

**Azure Functions Scaling**:
- **Consumption Plan**: Auto-scales to ~200 instances, pay-per-execution
- **Premium Plan**: Faster cold starts, VNET integration, higher instance limits

**Expected Load**:
- Typical SumoLogic collector: 1-10 requests/minute
- Auth token lifetime: 1-24 hours (infrequent re-auth)
- Log fetch frequency: Every 5-15 minutes

**Recommendation**: Start with Consumption Plan. Upgrade to Premium if cold starts impact auth latency (>5s).

### Security & Compliance

**Secrets Management**:
- Store Check Point/Graph credentials in SumoLogic collector config (not in proxy)
- Proxy only handles credential transformation, never stores them
- Use Function keys or Azure AD for proxy endpoint authentication

**Network Isolation**:
- If required, use Premium Plan + VNET integration
- Lock down Function to accept traffic only from SumoLogic IP ranges
- Use Azure Firewall or NSG rules for egress filtering

**Audit Logging**:
- All proxy operations are logged to Application Insights
- Enable Function diagnostic logs for access patterns
- Consider Azure Monitor Logs for long-term retention

---

## Cost Analysis

### Current State (Standalone Proxy)
- **Compute**: Azure VM B1s (~$7.59/month) or Container Instance (~$10/month)
- **Storage**: Negligible (logs only)
- **Total**: ~$7-10/month for always-on infrastructure

### Target State (Azure Function)
**Consumption Plan**:
- **Function Executions**: 50,000 requests/month = $0 (1M free tier)
- **Execution Time**: 1s avg × 50k = 50k GB-s = $0.80
- **Storage Account**: Function internals only (~1GB) = $0.02
- **Application Insights**: 5GB/month (first 5GB free) = $0
- **Total**: ~$0.82/month (95% cost reduction)

**Premium Plan** (if needed):
- **EP1 Instance**: ~$146/month (always-on, faster cold start)
- **Storage/Insights**: Same as above
- **Total**: ~$147/month (but supports VNET, higher scale)

**Recommendation**: Start with Consumption Plan for cost optimization.

---

## Risk Assessment

| Risk | Probability | Impact | Mitigation |
|------|------------|--------|------------|
| **Azure Function cold start delays auth** | Medium | Medium | Use Premium Plan or implement app warm-up; cache auth tokens in SumoLogic where possible |
| **Breaking change in Fluxzy removal** | Low | High | Maintain comprehensive test suite; run parallel deployment during migration |
| **Function timeout during auto-fetch** | Low | Medium | Set appropriate timeout in `host.json`; add retry logic in SumoLogic collector if needed |
| **SumoLogic collector incompatibility** | Low | High | Test with real collector in staging before production cutover |
| **HTTP client connection pool exhaustion** | Low | Medium | Configure `IHttpClientFactory` with appropriate connection limits; monitor with Application Insights |

---

## Success Metrics

### Functional Metrics
- **Auth Success Rate**: >99.9% (same as standalone proxy)
- **Log Retrieval Success Rate**: >99% (accounting for upstream API availability)
- **Data Correctness**: 100% (no malformed requests/responses)

### Performance Metrics
- **P50 Latency**: <500ms (auth), <2s (log fetch)
- **P95 Latency**: <1s (auth), <5s (log fetch)
- **Cold Start**: <3s for P95

### Operational Metrics
- **Uptime**: >99.9% (Azure Functions SLA)
- **Cost**: <$2/month for typical load
- **Deployment Frequency**: <10 minutes from code commit to production

---

## Open Questions

1. ~~**SumoLogic Request IDs**: Does SumoLogic provide correlation IDs in request headers?~~ ✅ **RESOLVED**: Not needed - no persistent state required.
2. **Credential Rotation**: How are Check Point/Graph credentials rotated? Do we need to support dynamic credential loading?
3. **Multi-Tenancy**: Will a single Function instance serve multiple SumoLogic accounts? If so, how is tenant isolation enforced?
4. **Backward Compatibility**: Should we maintain the standalone proxy indefinitely for on-premises scenarios?

---

## Next Steps

1. **Review this plan** with stakeholders and address open questions
2. **Create GitHub issues** for each task in Phase 1
3. **Set up project board** to track progress
4. **Begin Phase 1** with Core library extraction
5. **Schedule weekly sync** to review blockers and adjust timeline

---

## Appendix

### References
- [Azure Functions HTTP Trigger](https://learn.microsoft.com/en-us/azure/azure-functions/functions-bindings-http-webhook-trigger)
- [Azure Table Storage .NET SDK](https://learn.microsoft.com/en-us/azure/storage/tables/table-storage-overview)
- [SumoLogic Universal Connector Docs](https://help.sumologic.com/docs/send-data/hosted-collectors/cloud-to-cloud-integration-framework/)

### Glossary
- **MITM**: Man-in-the-Middle (TLS interception)
- **POCO**: Plain Old CLR Object (simple data transfer object)
- **TTL**: Time-to-Live (expiration period for cached data)
- **DI**: Dependency Injection
- **RORO**: Receive Object, Return Object (parameter passing pattern)
