using System.Threading.Tasks;
using Fluxzy.Rules.Actions;

internal static class ResponseTransformer
{
    public static Task<BodyContent?> TransformAsync(
        TransformContext context,
        IBodyReader reader,
        ProxyOptions options)
    {
        var authority = context.Exchange.Request.Header.Authority.ToString();
        var path = context.Exchange.Request.Header.Path.ToString();
        var (cleanPath, _) = RequestPayloadParser.SplitPathAndQuery(path);

        if (!EndpointMatcher.IsSameEndpoint(authority, cleanPath, options.checkpoint_auth_uri))
        {
            return Task.FromResult<BodyContent?>(null);
        }

        return CheckpointFlow.TransformAuthResponseAsync(context, reader, options);
    }
}
