using System;
using System.Collections.Generic;
using System.Net;

namespace Gyoji.Proxy.Core.Models;

/// <summary>
/// Represents an HTTP response returned by the proxy after transformation.
/// </summary>
public sealed record ResponseEnvelope
{
    public ResponseEnvelope(
        HttpStatusCode statusCode,
        string body,
        IReadOnlyDictionary<string, string>? headers = null)
    {
        StatusCode = statusCode;
        Body = body ?? string.Empty;
        Headers = headers ?? new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    }

    public HttpStatusCode StatusCode { get; }

    public string Body { get; }

    public IReadOnlyDictionary<string, string> Headers { get; }

    public string? GetHeaderValue(string name)
    {
        if (string.IsNullOrWhiteSpace(name))
        {
            return null;
        }

        return Headers.TryGetValue(name, out var value) ? value : null;
    }

    public static ResponseEnvelope Empty(HttpStatusCode statusCode = HttpStatusCode.OK)
    {
        return new ResponseEnvelope(statusCode, string.Empty);
    }
}
