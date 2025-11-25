using System.Collections.Concurrent;
using System.Collections.Generic;
using Fluxzy.Core;

internal enum FlowKind
{
    Unknown = 0,
    CheckpointAuth = 1
}

internal sealed record FlowMetadata(
    FlowKind flow_kind,
    bool auto_fetch_logs,
    IReadOnlyDictionary<string, string> log_query_parameters,
    IReadOnlyDictionary<string, string> log_body_parameters,
    string? csrf_token);

internal static class FlowStateStore
{
    private static readonly ConcurrentDictionary<int, FlowMetadata> Store = new();

    public static void Set(Exchange exchange, FlowMetadata metadata)
    {
        Store[exchange.Id] = metadata;
    }

    public static bool TryGet(Exchange exchange, out FlowMetadata? metadata)
    {
        return Store.TryGetValue(exchange.Id, out metadata);
    }

    public static void Remove(Exchange exchange)
    {
        Store.TryRemove(exchange.Id, out _);
    }
}
