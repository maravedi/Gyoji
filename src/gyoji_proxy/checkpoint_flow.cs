using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using Fluxzy.Core;
using Fluxzy.Rules.Actions;
using Gyoji.Proxy.Core.Models;

internal static class CheckpointFlow
{
    private static readonly JsonSerializerOptions SerializerOptions = new(JsonSerializerDefaults.Web)
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DictionaryKeyPolicy = JsonNamingPolicy.CamelCase
    };

    private static readonly HttpClient HttpClient = new(new SocketsHttpHandler
    {
        UseProxy = false,
        AutomaticDecompression = DecompressionMethods.All
    })
    {
        Timeout = Timeout.InfiniteTimeSpan
    };

    private static readonly string[] ReservedAuthKeys =
    {
        "client_id",
        "client_secret",
        "grant_type",
        "key",
        "value",
        "application",
        "Application",
        "auto_fetch_logs",
        "autoFetchLogs"
    };

    private static readonly string[] ReservedLogKeys =
    {
        "access_token",
        "token_type",
        "csrf",
        "key",
        "value",
        "application",
        "Application",
        "auto_fetch_logs",
        "autoFetchLogs"
    };

    public static BodyContent TransformAuthRequest(
        TransformContext context,
        RequestSnapshot snapshot,
        ProxyOptions options)
    {
        var clientId = snapshot.GetValueOrDefault("client_id");
        var clientSecret = snapshot.GetValueOrDefault("client_secret");

        if (string.IsNullOrWhiteSpace(clientId) || string.IsNullOrWhiteSpace(clientSecret))
        {
            ProxyLogger.Info("checkpoint_auth_request_missing_secret", new { exchange = context.Exchange.Id });
            return snapshot.RawBody;
        }

        var payload = new Dictionary<string, string>
        {
            ["clientId"] = clientId,
            ["accessKey"] = clientSecret
        };

        var jsonBody = JsonSerializer.Serialize(payload, SerializerOptions);

        context.Exchange.Request.Header.Method = "POST".AsMemory();
        context.Exchange.Request.Header.AltReplaceHeaders("Content-Type", "application/json", true);
        context.Exchange.Request.Header.AltReplaceHeaders("Accept", "application/json", true);

        var shouldAutoFetch = options.auto_fetch_logs &&
                              (RequestPayloadParser.TryGetBoolean(snapshot, "auto_fetch_logs", out var snake) && snake
                               || RequestPayloadParser.TryGetBoolean(snapshot, "autoFetchLogs", out var camel) && camel);

        var sanitizedQuery = RequestPayloadParser.FilterQuery(
            snapshot.QueryPairs,
            key => !key.Equals("code", StringComparison.OrdinalIgnoreCase)
                   && !key.Equals("auto_fetch_logs", StringComparison.OrdinalIgnoreCase)
                   && !key.Equals("autoFetchLogs", StringComparison.OrdinalIgnoreCase));

        var sanitizedBody = RequestPayloadParser.FilterBody(snapshot.BodyPairs, ReservedAuthKeys);
        var csrfToken = snapshot.GetValueOrDefault("csrf");

        FlowStateStore.Set(context.Exchange, new FlowMetadata(
            FlowKind.CheckpointAuth,
            shouldAutoFetch,
            sanitizedQuery,
            sanitizedBody,
            csrfToken));

        ProxyLogger.Info("checkpoint_auth_request_rewritten",
            new { exchange = context.Exchange.Id, shouldAutoFetch });

        return jsonBody;
    }

    public static BodyContent TransformLogRequest(
        TransformContext context,
        RequestSnapshot snapshot)
    {
        var accessToken = snapshot.GetValueOrDefault("access_token");
        if (string.IsNullOrWhiteSpace(accessToken))
        {
            return snapshot.RawBody;
        }

        context.Exchange.Request.Header.AltReplaceHeaders("Authorization", $"Bearer {accessToken}", true);

        var csrfToken = snapshot.GetValueOrDefault("csrf");
        if (!string.IsNullOrWhiteSpace(csrfToken))
        {
            context.Exchange.Request.Header.AltReplaceHeaders("x-av-req-id", csrfToken, true);
        }

        var sanitized = RequestPayloadParser.FilterBody(snapshot.BodyPairs, ReservedLogKeys);

        var method = context.Exchange.Request.Header.Method.ToString();
        if (string.Equals(method, "GET", StringComparison.OrdinalIgnoreCase))
        {
            var mergedPath = RequestPayloadParser.MergeQuery(snapshot, sanitized);
            context.Exchange.Request.Header.Path = mergedPath.AsMemory();
            return string.Empty;
        }

        if (sanitized.Count == 0)
        {
            return string.Empty;
        }

        context.Exchange.Request.Header.AltReplaceHeaders("Content-Type", "application/json", true);
        var body = JsonSerializer.Serialize(sanitized, SerializerOptions);
        return body;
    }

    public static async Task<BodyContent?> TransformAuthResponseAsync(
        TransformContext context,
        IBodyReader reader,
        ProxyOptions options)
    {
        var raw = await reader.ConsumeAsString();
        if (string.IsNullOrWhiteSpace(raw))
        {
            return raw;
        }

        JsonDocument? document = null;
        try
        {
            document = JsonDocument.Parse(raw);
        }
        catch (JsonException)
        {
            return raw;
        }

        using var disposable = document;
        if (!document.RootElement.TryGetProperty("data", out var dataElement) ||
            !dataElement.TryGetProperty("token", out var tokenElement))
        {
            return raw;
        }

        var envelope = new Dictionary<string, object?>
        {
            ["access_token"] = tokenElement.GetString(),
            ["token_type"] = "Bearer"
        };

        if (dataElement.TryGetProperty("csrf", out var csrfElement) &&
            csrfElement.ValueKind == JsonValueKind.String)
        {
            envelope["csrf"] = csrfElement.GetString();
        }

        if (dataElement.TryGetProperty("expiresIn", out var expiresElement) &&
            expiresElement.TryGetInt32(out var expiresIn))
        {
            envelope["expires_in"] = expiresIn;
        }
        else if (dataElement.TryGetProperty("expires", out var expiresAlt) &&
                 expiresAlt.TryGetInt32(out var expiresAltValue))
        {
            envelope["expires_in"] = expiresAltValue;
        }

        var serialized = JsonSerializer.Serialize(envelope, SerializerOptions);

        if (!FlowStateStore.TryGet(context.Exchange, out var metadata))
        {
            return serialized;
        }

        FlowStateStore.Remove(context.Exchange);

        if (metadata is null
            || metadata.flow_kind != FlowKind.CheckpointAuth
            || !metadata.auto_fetch_logs
            || !options.auto_fetch_logs
            || envelope["access_token"] is not string finalToken
            || string.IsNullOrWhiteSpace(finalToken))
        {
            return serialized;
        }

        var autoFetchBody = await FetchLogsAsync(finalToken, metadata, options);
        return autoFetchBody ?? serialized;
    }

    private static async Task<BodyContent?> FetchLogsAsync(
        string accessToken,
        FlowMetadata metadata,
        ProxyOptions options)
    {
        using var cancellation = new CancellationTokenSource(options.http_timeout);
        try
        {
            var builder = new UriBuilder(options.checkpoint_log_uri);
            if (metadata.log_query_parameters.Count > 0)
            {
                builder.Query = RequestPayloadParser.BuildQuery(metadata.log_query_parameters);
            }

            var method = metadata.log_body_parameters.Count > 0 ? HttpMethod.Post : HttpMethod.Get;
            using var request = new HttpRequestMessage(method, builder.Uri);
            request.Headers.TryAddWithoutValidation("Authorization", $"Bearer {accessToken}");
            if (!string.IsNullOrWhiteSpace(metadata.csrf_token))
            {
                request.Headers.TryAddWithoutValidation("x-av-req-id", metadata.csrf_token);
            }

            if (metadata.log_body_parameters.Count > 0)
            {
                var payload = JsonSerializer.Serialize(metadata.log_body_parameters, SerializerOptions);
                request.Content = new StringContent(payload, Encoding.UTF8, "application/json");
            }

            using var response = await HttpClient.SendAsync(request, cancellation.Token);
            var responseBody = await response.Content.ReadAsStringAsync(cancellation.Token);
            if (!response.IsSuccessStatusCode)
            {
                ProxyLogger.Error("checkpoint_auto_fetch_failed",
                    new InvalidOperationException($"Remote status {(int)response.StatusCode}"),
                    new { status = response.StatusCode, responseBody });

                return null;
            }

            return responseBody;
        }
        catch (Exception exception) when (exception is HttpRequestException or OperationCanceledException)
        {
            ProxyLogger.Error("checkpoint_auto_fetch_exception", exception);
            return null;
        }
    }
}
