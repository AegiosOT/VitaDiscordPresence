using System.Text.Json.Serialization;

namespace VitaPresence;

public sealed class PresenceSettings
{
    public const double DefaultPollInterval = 10;
    public const double MinimumPollInterval = 3;
    public const double MaximumPollInterval = 300;
    public const string DefaultClientId = "1556140114374037715";

    public string Address { get; set; } = "";
    public string ClientId { get; set; } = "";
    public string StateText { get; set; } = "";
    public string LargeImageKey { get; set; } = "";
    public double PollInterval { get; set; } = DefaultPollInterval;
    public bool ShowElapsedTime { get; set; } = true;
    public bool ShowLiveArea { get; set; } = true;
    public bool ShowGameArtwork { get; set; } = true;
    public bool ConnectOnLaunch { get; set; } = true;
    public bool LaunchAtLogin { get; set; }
    public bool UseOwnDiscordApplication { get; set; }

    [JsonIgnore]
    public TimeSpan EffectivePollInterval
    {
        get
        {
            var seconds = double.IsFinite(PollInterval) ? PollInterval : DefaultPollInterval;
            seconds = Math.Clamp(seconds, MinimumPollInterval, MaximumPollInterval);
            return TimeSpan.FromSeconds(seconds);
        }
    }

    [JsonIgnore]
    public string EffectiveClientId
    {
        get
        {
            if (!UseOwnDiscordApplication) return DefaultClientId;
            var custom = ClientId.Trim();
            return custom.Length == 0 ? DefaultClientId : custom;
        }
    }

    public string? LargeImageWarning
    {
        get
        {
            var image = LargeImageKey.Trim();
            if (image.Length == 0) return null;
            var lower = image.ToLowerInvariant();
            if (lower.StartsWith("http:", StringComparison.Ordinal) || lower.StartsWith("https:", StringComparison.Ordinal))
                return DiscordActivity.AcceptableImage(image) is null
                    ? "Use an https URL of at most 256 characters, with no spaces"
                    : null;
            return UseOwnDiscordApplication ? null : "An asset name only works with your own Discord application";
        }
    }

    public IReadOnlyList<string> Issues()
    {
        var issues = new List<string>();
        if (!VitaAddress.TryParse(Address, out _))
            issues.Add("That isn't a valid IP or MAC address");
        if (UseOwnDiscordApplication && !IsValidClientId(ClientId.Trim()))
            issues.Add("The application ID should be 16 to 25 digits");
        return issues;
    }

    public static bool IsValidClientId(string clientId) =>
        clientId.Length is >= 16 and <= 25 && clientId.All(char.IsAsciiDigit);
}

public enum VitaAddressKind { Automatic, Ip, Mac }

public readonly record struct VitaAddress(VitaAddressKind Kind, string Value)
{
    public static bool TryParse(string? text, out VitaAddress address)
    {
        var trimmed = (text ?? "").Trim();
        if (trimmed.Length == 0 || trimmed.Equals("auto", StringComparison.OrdinalIgnoreCase))
        {
            address = new VitaAddress(VitaAddressKind.Automatic, "");
            return true;
        }
        if (System.Net.IPAddress.TryParse(trimmed, out var ip) && ip.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork)
        {
            address = new VitaAddress(VitaAddressKind.Ip, ip.ToString());
            return true;
        }
        if (MacAddress.TryParse(trimmed, out var mac))
        {
            address = new VitaAddress(VitaAddressKind.Mac, mac.ToString());
            return true;
        }
        address = default;
        return false;
    }
}

public readonly record struct MacAddress(byte A, byte B, byte C, byte D, byte E, byte F)
{
    public static bool TryParse(string text, out MacAddress mac)
    {
        var hex = new string(text.Where(Uri.IsHexDigit).ToArray());
        if (hex.Length == 12 && Convert.FromHexString(hex) is { Length: 6 } bytes)
        {
            mac = new MacAddress(bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5]);
            return true;
        }
        mac = default;
        return false;
    }

    public override string ToString() => $"{A:x2}:{B:x2}:{C:x2}:{D:x2}:{E:x2}:{F:x2}";
}
