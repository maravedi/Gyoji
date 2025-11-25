using Fluxzy.Core;
using Fluxzy.Rules.Actions;
using System.Collections.Generic;

internal static class MicrosoftGraphFlow
{
    public static BodyContent TransformRequest(
        TransformContext context,
        RequestSnapshot snapshot)
    {
        var clientId = snapshot.GetValueOrDefault("client_id");
        var clientSecret = snapshot.GetValueOrDefault("client_secret");

        if (string.IsNullOrWhiteSpace(clientId) || string.IsNullOrWhiteSpace(clientSecret))
        {
            return snapshot.raw_body;
        }

        var grantType = snapshot.GetValueOrDefault("grant_type") ?? "client_credentials";
        var scope = snapshot.GetValueOrDefault("scope") ?? "https://graph.microsoft.com/.default";
        var resource = snapshot.GetValueOrDefault("resource") ?? "https://graph.microsoft.com";

        var formPairs = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["client_id"] = clientId,
            ["client_secret"] = clientSecret,
            ["grant_type"] = grantType,
            ["scope"] = scope,
            ["resource"] = resource
        };

        var encodedBody = RequestPayloadParser.BuildQuery(formPairs);

        context.Exchange.Request.Header.Method = "POST".AsMemory();
        context.Exchange.Request.Header.AltReplaceHeaders("Content-Type", "application/x-www-form-urlencoded", true);
        context.Exchange.Request.Header.AltReplaceHeaders("Accept", "application/json", true);

        ProxyLogger.Info("microsoft_graph_request_transformed", new { exchange = context.Exchange.Id });

        return encodedBody;
    }
}
