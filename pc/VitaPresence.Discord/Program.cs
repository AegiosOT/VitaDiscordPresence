using System.Text.Json;
using VitaPresence;

// Owns the Discord pipe. Exiting, after a close frame and without a null activity, is what drops the card.
Console.InputEncoding = System.Text.Encoding.UTF8;
var json = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };

DiscordPipe? pipe = null;
try
{
    string? line;
    while ((line = Console.ReadLine()) is not null)
    {
        if (line.Trim().Length == 0) continue;
        using var document = JsonDocument.Parse(line);
        var command = document.RootElement.GetProperty("cmd").GetString();
        if (command == "quit") break;
        if (command == "connect")
        {
            var clientId = document.RootElement.GetProperty("clientID").GetString() ?? PresenceSettings.DefaultClientId;
            var socket = document.RootElement.TryGetProperty("socket", out var socketElement) ? socketElement.GetString() : null;
            DiscordActivity? activity = null;
            if (document.RootElement.TryGetProperty("activity", out var activityElement) && activityElement.ValueKind == JsonValueKind.Object)
                activity = activityElement.Deserialize<DiscordActivity>(json);
            await ConnectAsync(clientId, socket, activity);
        }
        else if (command == "setActivity")
        {
            if (pipe is null) continue;
            if (!document.RootElement.TryGetProperty("activity", out var activityElement) || activityElement.ValueKind != JsonValueKind.Object)
                continue;
            var activity = activityElement.Deserialize<DiscordActivity>(json);
            if (activity is null) continue;
            await pipe.SetActivityAsync(activity, CancellationToken.None);
            Write("activity");
        }
    }
}
catch (Exception ex)
{
    Write("error", ex.Message);
}
finally
{
    if (pipe is not null) await pipe.CloseAsync();
}

async Task ConnectAsync(string clientId, string? socket, DiscordActivity? activity)
{
    if (pipe is not null)
    {
        await pipe.CloseAsync();
        pipe = null;
    }
    try
    {
        pipe = await DiscordPipe.ConnectAsync(socket, CancellationToken.None);
        await pipe.HandshakeAsync(clientId, CancellationToken.None);
    }
    catch (Exception ex)
    {
        Write("error", ex.Message);
        return;
    }
    if (activity is not null)
    {
        try
        {
            await pipe.SetActivityAsync(activity, CancellationToken.None);
        }
        catch (Exception ex)
        {
            Write("error", ex.Message);
            await pipe.CloseAsync();
            pipe = null;
            Environment.Exit(0);
        }
    }
    Write("ready");
}

static void Write(string evt, string? message = null)
{
    var payload = message is null
        ? "{\"evt\":\"" + evt + "\"}"
        : "{\"evt\":\"" + evt + "\",\"message\":" + JsonSerializer.Serialize(message) + "}";
    Console.WriteLine(payload);
    Console.Out.Flush();
}
