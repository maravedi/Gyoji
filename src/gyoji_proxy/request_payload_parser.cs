using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using Gyoji.Proxy.Core.Models;

internal static class RequestPayloadParser
{

    public static RequestSnapshot Parse(string? rawBody, string rawPath)
    {
        var (path, query) = SplitPathAndQuery(rawPath);
        var bodyPairs = ParseBody(rawBody);
        var queryPairs = ParseQuery(query);

        return new RequestSnapshot(
            rawBody ?? string.Empty,
            bodyPairs,
            queryPairs,
            path,
            query);
    }

    public static (string path, string? query) SplitPathAndQuery(string rawPath)
    {
        var candidate = rawPath ?? "/";
        var questionIndex = candidate.IndexOf('?');
        if (questionIndex < 0)
        {
            return (candidate, null);
        }

        var basePath = questionIndex == 0 ? "/" : candidate[..questionIndex];
        var query = questionIndex + 1 < candidate.Length ? candidate[(questionIndex + 1)..] : string.Empty;
        return (string.IsNullOrEmpty(basePath) ? "/" : basePath, query);
    }

    public static string BuildQuery(IReadOnlyDictionary<string, string> pairs)
    {
        return string.Join("&", pairs.Select(pair =>
            $"{Uri.EscapeDataString(pair.Key)}={Uri.EscapeDataString(pair.Value)}"));
    }

    public static IReadOnlyDictionary<string, string> FilterBody(
        IReadOnlyDictionary<string, string> pairs,
        IEnumerable<string>? reservedKeys)
    {
        var reserved = reservedKeys?.Select(k => k.Trim())
                                   .Where(k => !string.IsNullOrWhiteSpace(k))
                                   .ToHashSet(StringComparer.OrdinalIgnoreCase)
                       ?? new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        var filtered = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (key, value) in pairs)
        {
            if (reserved.Contains(key) || string.IsNullOrWhiteSpace(value))
            {
                continue;
            }

            filtered[key] = value;
        }

        return filtered;
    }

    public static IReadOnlyDictionary<string, string> FilterQuery(
        IReadOnlyDictionary<string, string> pairs,
        Func<string, bool> predicate)
    {
        var filtered = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (key, value) in pairs)
        {
            if (!predicate(key) || string.IsNullOrWhiteSpace(value))
            {
                continue;
            }

            filtered[key] = value;
        }

        return filtered;
    }

    public static bool TryGetBoolean(RequestSnapshot snapshot, string key, out bool value)
    {
        if (snapshot.TryGetValue(key, out var rawValue) && rawValue is { Length: > 0 })
        {
            if (bool.TryParse(rawValue, out value))
            {
                return true;
            }

            if (rawValue == "1")
            {
                value = true;
                return true;
            }

            if (rawValue == "0")
            {
                value = false;
                return true;
            }
        }

        value = false;
        return false;
    }

    public static string MergeQuery(RequestSnapshot snapshot, IReadOnlyDictionary<string, string> additions)
    {
        var merged = new Dictionary<string, string>(snapshot.QueryPairs, StringComparer.OrdinalIgnoreCase);
        foreach (var (key, value) in additions)
        {
            merged[key] = value;
        }

        return merged.Count == 0 ? snapshot.Path : $"{snapshot.Path}?{BuildQuery(merged)}";
    }

    private static IReadOnlyDictionary<string, string> ParseBody(string? rawBody)
    {
        if (string.IsNullOrWhiteSpace(rawBody))
        {
            return new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        }

        var trimmed = rawBody.Trim();
        if (trimmed.StartsWith('{') || trimmed.StartsWith('['))
        {
            try
            {
                using var document = JsonDocument.Parse(trimmed);
                var sink = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                ExtractJson(document.RootElement, sink);
                return sink;
            }
            catch (JsonException)
            {
                // fallback to query parsing below
            }
        }

        return ParseQuery(trimmed);
    }

    private static IReadOnlyDictionary<string, string> ParseQuery(string? query)
    {
        var pairs = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (string.IsNullOrWhiteSpace(query))
        {
            return pairs;
        }

        foreach (var part in query.Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var kvp = part.Split('=', 2);
            var key = Uri.UnescapeDataString(kvp[0]);
            var value = kvp.Length > 1 ? Uri.UnescapeDataString(kvp[1]) : string.Empty;

            if (string.IsNullOrWhiteSpace(key))
            {
                continue;
            }

            pairs[key] = value;
        }

        return pairs;
    }

    private static void ExtractJson(JsonElement element, IDictionary<string, string> sink)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
            {
                string? keyProperty = null;
                string? valueProperty = null;

                foreach (var property in element.EnumerateObject())
                {
                    if (property.NameEquals("key"))
                    {
                        keyProperty = property.Value.GetString();
                        continue;
                    }

                    if (property.NameEquals("value"))
                    {
                        valueProperty = property.Value.ToString();
                        continue;
                    }

                    sink[property.Name] = property.Value.ToString();
                }

                if (!string.IsNullOrWhiteSpace(keyProperty) && valueProperty is not null)
                {
                    sink[keyProperty] = valueProperty;
                }

                break;
            }
            case JsonValueKind.Array:
                foreach (var item in element.EnumerateArray())
                {
                    ExtractJson(item, sink);
                }

                break;
            case JsonValueKind.String:
                break;
            default:
                break;
        }
    }
}

 
