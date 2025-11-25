using System.Net;
using System.Linq;
using Fluxzy;
using Fluxzy.Rules.Actions;
using Fluxzy.Rules.Filters;
using Fluxzy.Rules.Filters.RequestFilters;
using Fluxzy.Rules.Extensions;

var proxyOptions = ProxyOptionsLoader.Load();
var listenIp = IPAddress.Parse(proxyOptions.listen_address);

ProxyLogger.Info("gyoji_starting", new
{
    proxyOptions.listen_address,
    proxyOptions.listen_port,
    proxyOptions.checkpoint_auth_uri,
    proxyOptions.checkpoint_log_uri,
    proxyOptions.microsoft_graph_token_uri,
    proxyOptions.auto_fetch_logs
});

var fluxzySetting = FluxzySetting.CreateDefault(listenIp, proxyOptions.listen_port)
                                 .SetVerbose(proxyOptions.verbose_logging);

if (proxyOptions.use_bouncy_castle)
{
    fluxzySetting.UseBouncyCastleSslEngine();
}

var checkpointHostsFilter = new HostFilter(proxyOptions.checkpoint_auth_uri.Host, StringSelectorOperation.Exact);
var checkpointLogHostFilter = new HostFilter(proxyOptions.checkpoint_log_uri.Host, StringSelectorOperation.Exact);
var microsoftGraphHostFilter = new HostFilter(proxyOptions.microsoft_graph_token_uri.Host, StringSelectorOperation.Exact);

fluxzySetting.ConfigureRule()
             .WhenAny(checkpointHostsFilter, checkpointLogHostFilter, microsoftGraphHostFilter)
             .Do(new TransformRequestBodyAction((context, bodyReader) =>
                     RequestTransformer.TransformAsync(context, bodyReader, proxyOptions)));

fluxzySetting.ConfigureRule()
             .When(checkpointHostsFilter)
             .Do(new TransformResponseBodyAction((context, bodyReader) =>
                     ResponseTransformer.TransformAsync(context, bodyReader, proxyOptions)));

await using var proxy = new Proxy(fluxzySetting);
var endpoints = proxy.Run().Select(ep => $"{ep.Address}:{ep.Port}").ToArray();

ProxyLogger.Info("gyoji_listening", new { endpoints });

var shutdownSource = new CancellationTokenSource();
Console.CancelKeyPress += (_, args) =>
{
    args.Cancel = true;
    shutdownSource.Cancel();
};

try
{
    await Task.Delay(Timeout.Infinite, shutdownSource.Token);
}
catch (TaskCanceledException)
{
    // graceful shutdown
}

ProxyLogger.Info("gyoji_stopped", new { endpoints });
