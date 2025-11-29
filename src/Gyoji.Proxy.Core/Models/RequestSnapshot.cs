using System;
using System.Collections.Generic;

namespace Gyoji.Proxy.Core.Models;

/// <summary>
/// Represents an immutable view of an inbound HTTP request so it can be
/// transformed without maintaining external state.
/// </summary>
public sealed record RequestSnapshot
{
    public RequestSnapshot(
        string rawBody,
        IReadOnlyDictionary<string, string> bodyPairs,
        IReadOnlyDictionary<string, string> queryPairs,
        string path,
        string? query)
    {
        ArgumentNullException.ThrowIfNull(bodyPairs);
        ArgumentNullException.ThrowIfNull(queryPairs);

        RawBody = rawBody ?? string.Empty;
        BodyPairs = bodyPairs;
        QueryPairs = queryPairs;
        Path = string.IsNullOrWhiteSpace(path) ? "/" : path;
        Query = query;
    }

    public string RawBody { get; }

    public IReadOnlyDictionary<string, string> BodyPairs { get; }

    public IReadOnlyDictionary<string, string> QueryPairs { get; }

    public string Path { get; }

    public string? Query { get; }

    public bool TryGetValue(string key, out string? value)
    {
        if (string.IsNullOrWhiteSpace(key))
        {
            value = null;
            return false;
        }

        if (BodyPairs.TryGetValue(key, out value) && !string.IsNullOrWhiteSpace(value))
        {
            return true;
        }

        if (QueryPairs.TryGetValue(key, out value) && !string.IsNullOrWhiteSpace(value))
        {
            return true;
        }

        value = null;
        return false;
    }

    public string? GetValueOrDefault(string key)
    {
        return TryGetValue(key, out var value) ? value : null;
    }
}
