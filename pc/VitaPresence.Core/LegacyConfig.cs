using System.Text.Json;

namespace VitaPresence;

/// One-time read of the .NET Framework client's Config.json.
public static class LegacyConfig
{
    public static bool TryImport(string json, PresenceSettings settings, IList<VitaProfile> profiles)
    {
        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(json);
        }
        catch (JsonException)
        {
            return false;
        }
        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return false;
            var changed = false;
            if (String(root, "IP") is { Length: > 0 } address && VitaAddress.TryParse(address, out var parsed) && parsed.Kind != VitaAddressKind.Automatic)
            {
                settings.Address = parsed.Value;
                profiles.Add(new VitaProfile
                {
                    LastAddress = parsed.Kind == VitaAddressKind.Ip ? parsed.Value : "",
                    MacAddress = parsed.Kind == VitaAddressKind.Mac ? parsed.Value : null,
                });
                changed = true;
            }
            if (String(root, "Client") is { Length: > 0 } client)
            {
                settings.ClientId = client;
                settings.UseOwnDiscordApplication = true;
                changed = true;
            }
            if (String(root, "State") is { } state)
            {
                settings.StateText = state;
                changed = true;
            }
            if (String(root, "UpdateInterval") is { } interval && double.TryParse(interval, out var seconds))
            {
                settings.PollInterval = seconds;
                changed = true;
            }
            if (Bool(root, "DisplayTimer") is { } timer)
            {
                settings.ShowElapsedTime = timer;
                changed = true;
            }
            if (Bool(root, "DisplayMainMenu") is { } liveArea)
            {
                settings.ShowLiveArea = liveArea;
                changed = true;
            }
            return changed;
        }
    }

    private static string? String(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out var value) && !root.TryGetProperty(name.ToLowerInvariant(), out value))
            return null;
        return value.ValueKind == JsonValueKind.String ? value.GetString()?.Trim() : null;
    }

    private static bool? Bool(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out var value)) return null;
        return value.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            _ => null,
        };
    }
}
