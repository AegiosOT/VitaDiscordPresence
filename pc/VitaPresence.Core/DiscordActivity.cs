using System.Globalization;
using System.Text.Json.Serialization;

namespace VitaPresence;

public sealed class DiscordActivity
{
    public const int MaximumTextUnits = 128;
    public const int MaximumImageLength = 300;
    public const int MaximumImageUrlLength = 256;

    public int? Type { get; set; }
    public string? Name { get; set; }
    public string? Details { get; set; }
    public string? State { get; set; }
    public ActivityTimestamps? Timestamps { get; set; }
    public ActivityAssets? Assets { get; set; }

    public DiscordActivity Sanitized()
    {
        var result = new DiscordActivity
        {
            Type = Type,
            Name = DiscordText.Clamp(Name, 1),
            Details = DiscordText.Clamp(Details),
            State = DiscordText.Clamp(State),
        };
        if (Timestamps?.Start is > 0)
            result.Timestamps = new ActivityTimestamps { Start = Timestamps.Start };
        var large = AcceptableImage(Assets?.LargeImage);
        var small = AcceptableImage(Assets?.SmallImage);
        if (large is not null || small is not null)
        {
            result.Assets = new ActivityAssets
            {
                LargeImage = large,
                LargeText = large is null ? null : DiscordText.Clamp(Assets?.LargeText),
                SmallImage = small,
                SmallText = small is null ? null : DiscordText.Clamp(Assets?.SmallText),
            };
        }
        return result;
    }

    public static string? AcceptableImage(string? image)
    {
        if (string.IsNullOrWhiteSpace(image)) return null;
        image = image.Trim();
        var lower = image.ToLowerInvariant();
        if (lower.StartsWith("http:", StringComparison.Ordinal) || lower.StartsWith("https:", StringComparison.Ordinal))
        {
            if (!lower.StartsWith("https://", StringComparison.Ordinal)) return null;
            if (image.Length > MaximumImageUrlLength) return null;
            if (image.Any(char.IsWhiteSpace)) return null;
            return image;
        }
        return DiscordText.Prefix(image, MaximumImageLength);
    }

    public sealed class ActivityTimestamps
    {
        [JsonPropertyName("start")]
        public long? Start { get; set; }
    }

    public sealed class ActivityAssets
    {
        [JsonPropertyName("large_image")]
        public string? LargeImage { get; set; }

        [JsonPropertyName("large_text")]
        public string? LargeText { get; set; }

        [JsonPropertyName("small_image")]
        public string? SmallImage { get; set; }

        [JsonPropertyName("small_text")]
        public string? SmallText { get; set; }
    }
}

public static class DiscordText
{
    public static string? Clamp(string? text, int minUnits = 2, int maxUnits = DiscordActivity.MaximumTextUnits)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var trimmed = text.Trim();
        if (trimmed.Length == 0) return null;
        var result = trimmed;
        if (result.Length > maxUnits)
            result = Prefix(trimmed, maxUnits - 1) + "…";
        while (result.Length < minUnits)
            result += "\u200B";
        return result;
    }

    public static string Prefix(string text, int maxUnits)
    {
        var units = 0;
        var end = 0;
        var enumerator = StringInfo.GetTextElementEnumerator(text);
        while (enumerator.MoveNext())
        {
            var element = enumerator.GetTextElement();
            var count = element.Length;
            if (units + count > maxUnits) break;
            units += count;
            end += element.Length;
        }
        return text[..end];
    }
}
