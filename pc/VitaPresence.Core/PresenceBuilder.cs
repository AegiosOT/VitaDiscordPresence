namespace VitaPresence;

public static class PresenceBuilder
{
    public const string Vita = "PlayStation Vita";
    public const string LiveAreaImage =
        "https://images.weserv.nl/?url=upload.wikimedia.org/wikipedia/commons/thumb/3/3d/PlayStation_Vita_logo.svg/250px-PlayStation_Vita_logo.svg.png&w=256&h=256&fit=contain&bg=white";

    public static DiscordActivity? Activity(VitaTitle title, PresenceSettings settings, DateTimeOffset? sessionStart, string? artwork)
    {
        if (title.IsLiveArea && !settings.ShowLiveArea) return null;
        var name = Name(title);
        var activity = new DiscordActivity
        {
            Type = 0,
            Name = name,
            Details = Details(title),
        };
        if (!string.IsNullOrWhiteSpace(settings.StateText))
            activity.State = settings.StateText;
        if (settings.ShowElapsedTime && sessionStart is { } start)
            activity.Timestamps = new DiscordActivity.ActivityTimestamps { Start = start.ToUnixTimeMilliseconds() };
        var image = LargeImage(title, settings, artwork);
        if (image is not null)
        {
            activity.Assets = new DiscordActivity.ActivityAssets
            {
                LargeImage = image,
                LargeText = ImageText(name, title.TitleId),
            };
        }
        return activity.Sanitized();
    }

    private static string Name(VitaTitle title) => title.Kind switch
    {
        TitleKind.LiveArea => Vita,
        TitleKind.AdrenalineMenu => "Adrenaline",
        _ => title.DisplayName,
    };

    private static string Details(VitaTitle title) => title.Kind switch
    {
        TitleKind.LiveArea => "In the LiveArea",
        TitleKind.PspGame => "PSP on " + Vita,
        TitleKind.Ps1Game => "PS1 on " + Vita,
        _ => Vita,
    };

    private static string? LargeImage(VitaTitle title, PresenceSettings settings, string? artwork)
    {
        if (DiscordActivity.AcceptableImage(settings.LargeImageKey) is { } custom)
            return custom;
        if (!settings.ShowGameArtwork) return null;
        if (title.IsLiveArea) return LiveAreaImage;
        if (title.Kind == TitleKind.SystemApp) return SystemAppIcons.Image(title.TitleId);
        return artwork;
    }

    private static string ImageText(string name, string titleId)
    {
        if (string.IsNullOrEmpty(titleId) || name == titleId) return name;
        var suffix = " (" + titleId + ")";
        var room = Math.Max(DiscordActivity.MaximumTextUnits - suffix.Length, 2);
        return (DiscordText.Clamp(name, 1, room) ?? "") + suffix;
    }
}
