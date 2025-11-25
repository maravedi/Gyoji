using System;
using System.Text.Json;

internal static class ProxyLogger
{
    private static readonly JsonSerializerOptions SerializerOptions = new(JsonSerializerDefaults.Web);

    public static void Info(string eventName, object? data = null)
    {
        Write("info", eventName, data);
    }

    public static void Error(string eventName, Exception exception, object? data = null)
    {
        var payload = new
        {
            exception = exception.GetType().Name,
            exception.Message,
            exception.StackTrace,
            data
        };

        Write("error", eventName, payload);
    }

    private static void Write(string level, string eventName, object? data)
    {
        var envelope = new
        {
            timestamp = DateTimeOffset.UtcNow,
            level,
            eventName,
            data
        };

        Console.WriteLine(JsonSerializer.Serialize(envelope, SerializerOptions));
    }
}
