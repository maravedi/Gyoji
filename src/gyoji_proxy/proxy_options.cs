using System;
using System.Globalization;

internal sealed record ProxyOptions(
    string listen_address,
    int listen_port,
    Uri checkpoint_auth_uri,
    Uri checkpoint_log_uri,
    Uri microsoft_graph_token_uri,
    bool auto_fetch_logs,
    bool verbose_logging,
    bool use_bouncy_castle,
    TimeSpan http_timeout);

internal static class ProxyOptionsLoader
{
    private const string DefaultListenAddress = "0.0.0.0";
    private const int DefaultListenPort = 44344;
    private const string DefaultCheckpointAuthUrl = "https://cloudinfra-gw.portal.checkpoint.com/auth/external";
    private const string DefaultCheckpointLogUrl = "https://cloudinfra-gw-us.portal.checkpoint.com/app/hec-api/v1.0/search/query";
    private const string DefaultGraphTokenUrl = "https://login.microsoftonline.com/567c7a62-8edb-4ead-9138-56f4bd08d619/oauth2/token";

    public static ProxyOptions Load()
    {
        var listenAddress = GetEnvString("GYOJI_LISTEN_ADDRESS", DefaultListenAddress);
        var listenPort = GetEnvInt("GYOJI_LISTEN_PORT", DefaultListenPort);
        var checkpointAuthUri = GetEnvUri("GYOJI_CHECKPOINT_AUTH_URL", DefaultCheckpointAuthUrl);
        var checkpointLogUri = GetEnvUri("GYOJI_CHECKPOINT_LOG_URL", DefaultCheckpointLogUrl);
        var graphTokenUri = GetEnvUri("GYOJI_GRAPH_TOKEN_URL", DefaultGraphTokenUrl);
        var autoFetch = GetEnvBool("GYOJI_AUTO_FETCH_LOGS", true);
        var verbose = GetEnvBool("GYOJI_VERBOSE", false);
        var useBouncyCastle = GetEnvBool("GYOJI_USE_BOUNCY_CASTLE", false);
        var timeoutSeconds = GetEnvInt("GYOJI_UPSTREAM_TIMEOUT_SECONDS", 30);

        return new ProxyOptions(
            listenAddress,
            listenPort,
            checkpointAuthUri,
            checkpointLogUri,
            graphTokenUri,
            autoFetch,
            verbose,
            useBouncyCastle,
            TimeSpan.FromSeconds(Math.Clamp(timeoutSeconds, 5, 240)));
    }

    private static string GetEnvString(string key, string fallback)
    {
        var candidate = Environment.GetEnvironmentVariable(key);
        return string.IsNullOrWhiteSpace(candidate) ? fallback : candidate.Trim();
    }

    private static int GetEnvInt(string key, int fallback)
    {
        var candidate = Environment.GetEnvironmentVariable(key);
        if (string.IsNullOrWhiteSpace(candidate))
        {
            return fallback;
        }

        return int.TryParse(candidate, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed)
            ? parsed
            : fallback;
    }

    private static bool GetEnvBool(string key, bool fallback)
    {
        var candidate = Environment.GetEnvironmentVariable(key);
        if (string.IsNullOrWhiteSpace(candidate))
        {
            return fallback;
        }

        return candidate.Trim().ToLowerInvariant() switch
        {
            "1" => true,
            "true" => true,
            "yes" => true,
            "on" => true,
            "0" => false,
            "false" => false,
            "no" => false,
            "off" => false,
            _ => fallback
        };
    }

    private static Uri GetEnvUri(string key, string fallback)
    {
        var candidate = GetEnvString(key, fallback);
        return Uri.TryCreate(candidate, UriKind.Absolute, out var uri) ? uri : new Uri(fallback);
    }
}
