# Gyoji

<p align="center">
    <img
        width="96px"
        alt="logo"
        src="./assets/images/logo.png"
    />
</p>

Gyoji is a transparent HTTP(S) proxy that rewrites Sumo Logic Universal Collector requests on the fly so they can satisfy strict third-party API contracts (Check Point, Microsoft Graph, etc.). It injects authentication headers, reshapes payloads, and optionally auto-fetches logs after an authentication flow completes.

## Capabilities
- Terminates TLS through Fluxzy and rewrites both request and response bodies in-flight (optionally via BouncyCastle).
- Normalizes Check Point CloudGuard OAuth calls and converts token responses into Sumo-friendly envelopes.
- Exchanges Microsoft Graph client credentials without exposing secrets inside collectors.
- Auto-fetches logs immediately after successful Check Point authentication, reducing the number of round-trips Sumo must issue.
- Emits structured JSON logs (`ProxyLogger`) so you can ingest telemetry into any SIEM or log aggregator.

## Architecture Overview
```
Sumo Logic Collector ──► HTTPS Proxy (Gyoji) ──► Check Point Auth / Logs
                                    │
                                    └──► Microsoft Graph Token Endpoint
```
1. Sumo Logic is configured to egress via the Gyoji HTTP proxy.
2. Fluxzy inspects every outbound exchange; hosts that match Check Point or Microsoft Graph are rewritten.
3. Requests/responses that are not recognized are forwarded untouched.

## Prerequisites
- .NET 8.0 SDK (for local builds) or ASP.NET Core runtime if you only run published bits.
- Network egress from the proxy host to Check Point and Microsoft Graph endpoints.
- TLS certificates that the collector trusts (Gyoji uses system trust; install corporate roots if needed).

## Quick Start
1. Clone and restore dependencies:
   ```bash
   git clone <repo-url>
   cd gyoji
   dotnet restore src/gyoji_proxy/gyoji_proxy.csproj
   ```
2. Export the required environment variables (see the table below) or copy `.env.sample` into place if you maintain one.
3. Run the proxy:
   ```bash
   dotnet run --project src/gyoji_proxy/gyoji_proxy.csproj
   ```
4. Point the Sumo Logic Universal Collector at the proxy by setting `httpProxyHost`/`httpProxyPort` (or the equivalent UI fields) so that calls destined for Check Point or Microsoft Graph traverse `listen_address:listen_port`.
5. Watch the structured logs for `gyoji_listening` and `checkpoint_*` events to confirm the listener is healthy.

### Local smoke test
Use `curl` with the proxy flag to verify the rewrite logic before involving a collector:
```bash
curl -x http://127.0.0.1:44344 \
     https://cloudinfra-gw.portal.checkpoint.com/auth/external \
     -d "client_id=<id>&client_secret=<secret>&auto_fetch_logs=true"
```
You should see a JSON body with `access_token` in the response.

## Configuration Reference
| Variable | Description | Default |
| --- | --- | --- |
| `GYOJI_LISTEN_ADDRESS` | Interface to bind the proxy listener to. Use `0.0.0.0` to accept remote collectors. | `0.0.0.0` |
| `GYOJI_LISTEN_PORT` | TCP port for the Fluxzy listener. Ensure firewalls/security groups allow inbound traffic. | `44344` |
| `GYOJI_CHECKPOINT_AUTH_URL` | Target Check Point auth endpoint that receives rewritten OAuth payloads. | `https://cloudinfra-gw.portal.checkpoint.com/auth/external` |
| `GYOJI_CHECKPOINT_LOG_URL` | Target Check Point log endpoint used for manual or auto-fetch requests. | `https://cloudinfra-gw-us.portal.checkpoint.com/app/hec-api/v1.0/search/query` |
| `GYOJI_GRAPH_TOKEN_URL` | Microsoft identity endpoint for client credential grants. | `https://login.microsoftonline.com/.../oauth2/token` |
| `GYOJI_AUTO_FETCH_LOGS` | Enables follow-up log pulls after successful auth responses. Collectors can still override per request via `auto_fetch_logs` flags. | `true` |
| `GYOJI_VERBOSE` | Turns on verbose Fluxzy traces for debugging. Disable in production. | `false` |
| `GYOJI_USE_BOUNCY_CASTLE` | Forces Fluxzy to use the BouncyCastle TLS engine (useful for modern cipher suites in locked-down environments). | `false` |
| `GYOJI_UPSTREAM_TIMEOUT_SECONDS` | Timeout for outbound auto-fetch HTTP calls (5–240 seconds). | `30` |

> Store secrets (client IDs/keys) in the collector configuration or a secrets manager, not inside the proxy host.

## Flow Walkthrough
### Check Point authentication
1. Collector issues a form-encoded request (`client_id`, `client_secret`, optional `auto_fetch_logs`) through the proxy.
2. `CheckpointFlow.TransformAuthRequest` rewrites it into JSON (`clientId`, `accessKey`), strips sensitive query/body keys, and records the sanitized parameters in `FlowStateStore`.
3. `CheckpointFlow.TransformAuthResponseAsync` normalizes the upstream response so the collector receives a standard OAuth envelope.

### Automatic log fetch
If both the collector and proxy enable auto-fetching, `CheckpointFlow` immediately calls `GYOJI_CHECKPOINT_LOG_URL` with the newly minted `access_token`, merges any stored query/body parameters, injects `x-av-req-id` when `csrf` was present, and returns the log data as the response body. Timeouts are governed by `GYOJI_UPSTREAM_TIMEOUT_SECONDS`.

### Microsoft Graph client credentials
Requests that target `GYOJI_GRAPH_TOKEN_URL` are recast with the appropriate `Content-Type`, grant type, scope, and resource defaults (`https://graph.microsoft.com/.default`). The collector’s secrets never leave the proxy host outside of the proxied call.

## Integrating With Sumo Logic Collectors
- **HTTP Source**: Add or edit your Check Point or Microsoft Graph source and configure its “Proxy” settings to point to `listen_address:listen_port`. Gyoji only rewrites hosts that match the configured URIs, so other collector traffic passes through transparently.
- **Certificate trust**: Ensure the collector trusts the root CA used by the proxy (for outbound MITM) if you use custom certificates.
- **Per-source options**: Include `auto_fetch_logs=true` (snake or camel case) in the source request body to request immediate log retrieval after auth.

## Deployment Tips
- **Systemd**: Wrap `dotnet /path/to/gyoji_proxy.dll` inside a service and set `Environment=` entries for each `GYOJI_*` variable.
- **Containers**: Publish with `dotnet publish -c Release` and bake the output into a minimal distroless or Alpine image. Expose `listen_port` and pass configuration as env vars.
- **Scaling**: Gyoji is stateful only for the lifetime of an exchange (stored in-memory). Run a single instance per collector cluster or front it with a TCP load balancer that provides session affinity if you must scale horizontally.

## Observability
- Logs are JSON with `timestamp`, `level`, `eventName`, and a `data` payload. They are emitted to stdout/stderr, making them easy to ship via Fluent Bit, CloudWatch agents, etc.
- Notable events: `gyoji_starting`, `gyoji_listening`, `checkpoint_auth_request_rewritten`, `checkpoint_auto_fetch_failed`, `microsoft_graph_request_transformed`.
- Pair the proxy with a process supervisor that restarts on non-zero exits and scrape metrics (e.g., number of open sockets) via your platform tooling.

## Troubleshooting
- **Proxy never binds**: Verify the port is free and you have permission to bind the requested address. Look for `SocketException` details in the logs.
- **Collector still sees `client_secret` errors**: Confirm traffic is actually egressing via Gyoji (tcpdump or `curl -x`). The proxy only rewrites hosts that exactly match the configured URIs.
- **Auto-fetch silent failures**: Increase `GYOJI_UPSTREAM_TIMEOUT_SECONDS` and inspect `checkpoint_auto_fetch_failed` logs for upstream HTTP status codes.
- **TLS handshake problems**: Enable `GYOJI_USE_BOUNCY_CASTLE=true` for newer cipher coverage, or update the system’s OpenSSL/Schannel stack.

With these steps you can test, operate, and extend Gyoji confidently in front of Sumo Logic collectors.
