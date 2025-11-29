using System.Threading.Tasks;
using Fluxzy.Core;
using Fluxzy.Rules.Actions;
using Gyoji.Proxy.Core.Models;

internal static class RequestTransformer
{
    public static async Task<BodyContent?> TransformAsync(
        TransformContext context,
        IBodyReader reader,
        ProxyOptions options)
    {
        var exchange = context.Exchange;
        var authority = exchange.Request.Header.Authority.ToString();
        var path = exchange.Request.Header.Path.ToString();
        var originalBody = await reader.ConsumeAsString();
        var snapshot = RequestPayloadParser.Parse(originalBody, path);

        if (EndpointMatcher.IsSameEndpoint(authority, snapshot.Path, options.checkpoint_auth_uri))
        {
            return CheckpointFlow.TransformAuthRequest(context, snapshot, options);
        }

        if (EndpointMatcher.IsSameEndpoint(authority, snapshot.Path, options.checkpoint_log_uri))
        {
            return CheckpointFlow.TransformLogRequest(context, snapshot);
        }

        if (EndpointMatcher.IsSameEndpoint(authority, snapshot.Path, options.microsoft_graph_token_uri))
        {
            return MicrosoftGraphFlow.TransformRequest(context, snapshot);
        }

        return snapshot.RawBody;
    }
}

internal static class EndpointMatcher
{
    public static bool IsSameEndpoint(string authority, string path, Uri target)
    {
        if (!target.IsAbsoluteUri)
        {
            return false;
        }

        var hostPart = authority.Split(':', StringSplitOptions.RemoveEmptyEntries)[0];
        if (!hostPart.Equals(target.Host, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var normalizedTargetPath = string.IsNullOrWhiteSpace(target.AbsolutePath) ? "/" : target.AbsolutePath;
        return path.StartsWith(normalizedTargetPath, StringComparison.OrdinalIgnoreCase);
    }
}
