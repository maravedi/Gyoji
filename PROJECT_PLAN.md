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
- **Execution Model**: Request-scoped (stateless per invocation)
- **State Store**: Azure Table Storage or Azure Cache for Redis
- **Routing**: Single catch-all HTTP trigger with dynamic path routing

### Component Structure
```
Gyoji/
├── src/
│   ├── Gyoji.Proxy.Core/               # Shared transformation library
│   │   ├── Models/
│   │   │   ├── RequestSnapshot.cs      # POCO request envelope
│   │   │   ├── ResponseEnvelope.cs     # POCO response envelope
│   │   │   └── FlowMetadata.cs         # State correlation metadata
│   │   ├── Services/
│   │   │   ├── IStateStore.cs          # State persistence abstraction
│   │   │   ├── TableStateStore.cs      # Azure Table Storage implementation
│   │   │   ├── RedisStateStore.cs      # Redis implementation (optional)
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
   - [ ] Initialize `Gyoji.Proxy.Core` class library (.NET 8.0)
   - [ ] Define POCO models (`RequestSnapshot`, `ResponseEnvelope`)
   - [ ] Add solution file to track all projects

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

5. **State Store Abstraction**
   - [ ] Define `IStateStore` interface with Get/Set/Remove operations
   - [ ] Implement `InMemoryStateStore` (for backward compatibility with standalone proxy)
   - [ ] Add TTL/expiration support to interface

6. **Logging Abstraction**
   - [ ] Make `ProxyLogger` work with `ILogger<T>` for Azure Functions compatibility
   - [ ] Keep existing JSON output for standalone proxy

#### Acceptance Criteria
- Core library compiles independently
- No Fluxzy references in Core project
- Existing standalone proxy still works using Core library
- Unit tests cover transformation logic (>80% coverage)

---

### Phase 2: Azure Functions Infrastructure (Week 2)
**Objective**: Set up Azure Functions project and distributed state management

#### Tasks
1. **Initialize Function Project**
   - [ ] Create `Gyoji.Proxy.Function` isolated worker project
   - [ ] Add reference to `Gyoji.Proxy.Core`
   - [ ] Configure DI container in `Program.cs`
   - [ ] Set up `host.json` with appropriate timeouts and concurrency limits

2. **Implement State Persistence**
   - [ ] Create `TableStateStore` using Azure.Data.Tables SDK
   - [ ] Design partition/row key strategy (e.g., `PartitionKey = "flow"`, `RowKey = requestId`)
   - [ ] Implement TTL cleanup (use Table Storage entity expiration)
   - [ ] Add retry policy for transient Table Storage failures

3. **Configure HTTP Client**
   - [ ] Set up `IHttpClientFactory` with named clients for Check Point and Microsoft Graph
   - [ ] Configure Polly retry policies (exponential backoff, circuit breaker)
   - [ ] Set timeouts from `ProxyOptions.http_timeout`

4. **Environment Configuration**
   - [ ] Map all `GYOJI_*` env vars to Azure App Settings
   - [ ] Configure Azure Key Vault integration for secrets
   - [ ] Set up managed identity for Key Vault access

#### Acceptance Criteria
- Function project builds and runs locally with Azurite
- State persists across function invocations
- Configuration loads from `local.settings.json` during development
- HTTP clients retry transient failures

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
   ```
   - [ ] Parse incoming request to `RequestSnapshot`
   - [ ] Route to appropriate transformer based on target URL
   - [ ] Execute transformation pipeline
   - [ ] Forward transformed request to upstream API
   - [ ] Transform response and return to caller

2. **Request Routing Logic**
   - [ ] Inspect `path` parameter or custom headers to determine target (Check Point auth, Check Point logs, Microsoft Graph)
   - [ ] Alternative: Use different Function routes (`/checkpoint/auth`, `/checkpoint/logs`, `/msgraph/token`)

3. **Auto-Fetch Implementation**
   - [ ] Store auth request metadata in Table Storage
   - [ ] Retrieve metadata in auth response handler
   - [ ] Trigger log fetch asynchronously if enabled
   - [ ] Return logs or auth envelope to caller

4. **Error Handling**
   - [ ] Return appropriate HTTP status codes for client/server errors
   - [ ] Log all exceptions with correlation IDs
   - [ ] Implement retry headers for transient failures

#### Acceptance Criteria
- Function responds to HTTP requests on all routes
- Check Point authentication flow completes end-to-end
- Microsoft Graph token exchange works
- Auto-fetch retrieves logs after successful auth
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
   - [ ] Test against live Azure Table Storage (Azurite)
   - [ ] Test HTTP client retry policies with fault injection
   - [ ] Test end-to-end flow with mock Check Point/Graph endpoints

3. **Load Testing**
   - [ ] Simulate concurrent SumoLogic collector requests
   - [ ] Validate horizontal scaling behavior (multiple Function instances)
   - [ ] Measure cold start latency (P50, P95, P99)
   - [ ] Verify no state corruption under concurrent load

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
     - Storage Account (for state and function internals)
     - Application Insights (for logging/monitoring)
     - (Optional) Azure Cache for Redis
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
     - State store operation metrics
     - Upstream API latency
   - [ ] Configure alerts for:
     - High error rates (>5% over 5 minutes)
     - Long cold starts (>10s)
     - State store failures
     - Upstream API timeouts

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
   - [ ] Adjust Function timeout settings if needed
   - [ ] Tune state store TTL based on observed request patterns
   - [ ] Optimize HTTP client connection pooling

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

**Option 1: Azure Table Storage (Recommended for MVP)**
- **Pros**: Low cost, automatic scaling, simple schema
- **Cons**: Higher latency (10-50ms), eventual consistency
- **Design**:
  - PartitionKey: `"gyoji-flow"` (single partition for simplicity)
  - RowKey: `{requestId}` (SumoLogic provides correlation ID or generate GUID)
  - TTL: Set `expiresAt` property, manual cleanup or lifecycle policy

**Option 2: Azure Cache for Redis**
- **Pros**: Sub-millisecond latency, atomic operations
- **Cons**: Higher cost (~$15/month for Basic tier), requires connection management
- **Design**:
  - Key: `gyoji:flow:{requestId}`
  - Value: JSON-serialized `FlowMetadata`
  - TTL: Redis native EXPIRE command

**Recommendation**: Start with Table Storage for cost optimization. Migrate to Redis if latency becomes an issue (P95 >100ms).

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
- **Table Storage**: 10k transactions/month + 1GB = $0.10
- **Application Insights**: 5GB/month (first 5GB free) = $0
- **Total**: ~$0.90/month (94% cost reduction)

**Premium Plan** (if needed):
- **EP1 Instance**: ~$146/month (always-on, faster cold start)
- **Storage/Insights**: Same as above
- **Total**: ~$147/month (but supports VNET, higher scale)

**Recommendation**: Start with Consumption Plan for cost optimization.

---

## Risk Assessment

| Risk | Probability | Impact | Mitigation |
|------|------------|--------|------------|
| **State corruption under concurrent load** | Medium | High | Implement optimistic concurrency control in Table Storage; add integration tests for race conditions |
| **Azure Function cold start delays auth** | Medium | Medium | Use Premium Plan or implement app warm-up; cache auth tokens in SumoLogic where possible |
| **Breaking change in Fluxzy removal** | Low | High | Maintain comprehensive test suite; run parallel deployment during migration |
| **Table Storage latency exceeds timeout** | Low | Medium | Add monitoring for P95 latency; prepare Redis migration path |
| **SumoLogic collector incompatibility** | Low | High | Test with real collector in staging before production cutover |

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

1. **SumoLogic Request IDs**: Does SumoLogic provide correlation IDs in request headers? If not, how should we generate state keys?
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
