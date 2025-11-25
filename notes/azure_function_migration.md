## Azure Function Migration Notes

### Why the current proxy cannot run inside Azure Functions
- `src/gyoji_proxy/program.cs` boots a long-lived Fluxzy proxy that binds to `listen_address`/`listen_port` and blocks on `Proxy.Run()` before awaiting `Task.Delay(Timeout.Infinite, …)`. Azure Functions sandboxes forbid opening arbitrary listeners or keeping infinite background loops alive, so this entrypoint is incompatible with the Functions runtime.
- Fluxzy installs request/response filters that work at the TCP proxy layer. Function Apps only expose HTTP triggers that are fronted by Azure’s own listener; you cannot insert Fluxzy into that path.
- Flow state is stored in a static in-memory `ConcurrentDictionary<int, FlowMetadata>` (`src/gyoji_proxy/flow_state.cs`). Azure Functions scale out horizontally and recycle workers; static dictionaries are not durable and would corrupt multi-instance flows.

### Migration strategy at a glance
1. **Split the codebase** into a reusable library (e.g., `src/Gyoji.Proxy.Core`) that contains:
   - `ProxyOptions`, `ProxyLogger`, `RequestPayloadParser`, `CheckpointFlow`, `MicrosoftGraphFlow`, `FlowStateStore` (rewritten to use a distributed store such as Azure Table Storage or Azure Cache for Redis).
   - Pure transformation helpers that accept POCO request envelopes instead of Fluxzy-specific types.
2. **Add an Azure Functions isolated worker project** (net8.0) under `src/gyoji_proxy_function/`:
   ```bash
   dotnet new func --name gyoji_proxy_function --worker-runtime dotnet-isolated --target-framework net8.0
   dotnet sln add src/gyoji_proxy_function/gyoji_proxy_function.csproj
   dotnet add src/gyoji_proxy_function/gyoji_proxy_function.csproj reference src/Gyoji.Proxy.Core/Gyoji.Proxy.Core.csproj
   ```
3. **Implement an HTTP trigger** that receives Sumo Logic collector webhook calls:
   ```csharp
   [Function("GyojiProxy")]
   public async Task<HttpResponseData> Run(
       [HttpTrigger(AuthorizationLevel.Function, "post", Route = "{*path}")] HttpRequestData request,
       string path,
       FunctionContext context)
   {
       var payload = await request.ReadAsStringAsync();
       var snapshot = _snapshotFactory.Create(payload, path);
       var rewrite = await _pipeline.TransformAsync(snapshot, _options);
       var upstreamResponse = await _upstreamClient.SendAsync(rewrite, path, _options, context.CancellationToken);
       return await _responseFactory.CreateAsync(request, upstreamResponse);
   }
   ```
4. **Replace Fluxzy constructs**:
   - Swap `TransformContext`/`IBodyReader` with simple RORO DTOs (`RequestSnapshot`, `ResponseEnvelope`) carried through the function pipeline.
   - Provide an `HttpClient` with retry/back-off for outgoing calls to Check Point and Microsoft Graph.
5. **Harden state management**:
   - Persist the equivalent of `FlowStateStore` in Azure Storage (Table, Cosmos DB, or Durable Functions state) keyed by request IDs supplied by Sumo Logic.
   - Set a TTL that matches `GYOJI_UPSTREAM_TIMEOUT_SECONDS`.
6. **Handle configuration via Function App settings**: map existing env vars (`GYOJI_*`) to `appsettings.json` or Azure Key Vault references and load them into `ProxyOptions`.
7. **Provide external exposure**:
   - Deploy the Function App with an HTTP trigger secured via Azure API Management or Function keys.
   - Point the Sumo Logic Universal Collector to the Function URL instead of the on-premises proxy endpoint.

### Deployment checklist
- [ ] Build and publish the isolated worker: `dotnet publish src/gyoji_proxy_function -c Release`.
- [ ] Provision Azure resources (Function App, Storage Account, optional Redis, Application Insights).
- [ ] Configure application settings for all `GYOJI_*` variables and secrets (prefer Key Vault references).
- [ ] Enable managed identity so the function can call Microsoft Graph using `DefaultAzureCredential`.
- [ ] Add Azure Monitor alerts for `ProxyLogger` events forwarded through Application Insights.
- [ ] Document rate limits and back-pressure strategy (Functions scale controller will retry failed executions; ensure idempotency).

Following these steps preserves the transformation logic while moving execution to a cloud-native, HTTP-triggered workflow that Azure Functions supports.
