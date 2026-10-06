namespace VitaPresence;

/// Decides when a title is still the current game and when Discord should be dropped.
public sealed class PresenceDirector
{
    public const int ClearAfterFailures = 2;
    public static readonly TimeSpan ClearAfterUnreachable = TimeSpan.FromSeconds(60);
    public static readonly TimeSpan SessionResetAfter = TimeSpan.FromSeconds(60);
    public static readonly TimeSpan ArtworkGrace = TimeSpan.FromMilliseconds(1500);

    public VitaTitle? Title { get; private set; }
    public DateTimeOffset? SessionStart { get; private set; }
    public int ConsecutiveFailures { get; private set; }
    public DateTimeOffset? FailingSince { get; private set; }

    /// True once the Vita has been unreachable long enough that Discord should close.
    public bool ShouldDropDiscord { get; private set; }

    public DiscordActivity? NoteSuccess(VitaTitle title, PresenceSettings settings, DateTimeOffset now, string? artwork)
    {
        ConsecutiveFailures = 0;
        FailingSince = null;
        ShouldDropDiscord = false;
        if (Title?.SessionKey != title.SessionKey)
            SessionStart = now;
        Title = title;
        return PresenceBuilder.Activity(title, settings, SessionStart, artwork);
    }

    /// Returns true when the failure is enough to clear the title and close Discord.
    public bool NoteFailure(DateTimeOffset now, TimeSpan? clearAfterUnreachable = null, int clearAfterFailures = ClearAfterFailures)
    {
        FailingSince ??= now;
        ConsecutiveFailures++;
        var hold = clearAfterUnreachable ?? ClearAfterUnreachable;
        var longEnough = hold <= TimeSpan.Zero || now - FailingSince >= hold;
        if (ConsecutiveFailures < clearAfterFailures || !longEnough)
        {
            ShouldDropDiscord = false;
            return false;
        }
        Title = null;
        ShouldDropDiscord = true;
        if (now - FailingSince >= SessionResetAfter)
            SessionStart = null;
        return true;
    }
}

public interface IDiscordPresence
{
    bool IsConnected { get; }
    Task ConnectAsync(string clientId, DiscordActivity activity, CancellationToken cancellationToken);
    Task SetActivityAsync(DiscordActivity activity, CancellationToken cancellationToken);
    Task DisconnectAsync();
}

/// Polls the Vita and opens Discord only while there is a game or the LiveArea to show.
public sealed class PresenceRunner
{
    private readonly VitaLocator _locator;
    private readonly ArtworkResolver _artwork;
    private readonly IDiscordPresence _discord;
    private readonly PresenceDirector _director = new();
    private readonly List<DateTimeOffset> _sends = new();
    private DiscordActivity? _sent;

    public PresenceRunner(IDiscordPresence discord, VitaLocator? locator = null, ArtworkResolver? artwork = null)
    {
        _discord = discord;
        _locator = locator ?? new VitaLocator();
        _artwork = artwork ?? new ArtworkResolver();
    }

    public PresenceDirector Director => _director;
    public string Status { get; private set; } = "Not connected";
    public string? Artwork { get; private set; }
    public LocatedVita? Located { get; private set; }

    public async Task TickAsync(PresenceSettings settings, VitaProfile? selected, bool allowScan, CancellationToken cancellationToken)
    {
        if (!VitaAddress.TryParse(settings.Address, out var address))
        {
            Status = "That isn't a valid IP or MAC address";
            return;
        }
        var located = await _locator.LocateAsync(address, selected, allowScan, cancellationToken);
        Located = located;
        if (located is null)
        {
            Status = selected is null && address.Kind == VitaAddressKind.Automatic
                ? "Looking for your Vita…"
                : "Vita not responding. Is it awake and on the same Wi-Fi?";
            if (_director.NoteFailure(DateTimeOffset.UtcNow) && _discord.IsConnected)
                await _discord.DisconnectAsync();
            return;
        }

        if (selected is not null)
        {
            selected.LastAddress = located.Host;
            selected.MacAddress = located.MacAddress?.ToString() ?? selected.MacAddress;
            selected.LastSeen = DateTimeOffset.UtcNow;
        }

        string? artwork = null;
        var needsLookup = settings.ShowGameArtwork
            && DiscordActivity.AcceptableImage(settings.LargeImageKey) is null
            && located.Title.Kind is not (TitleKind.LiveArea or TitleKind.SystemApp);
        if (needsLookup)
        {
            var lookup = _artwork.ArtworkAsync(located.Title, cancellationToken);
            artwork = await WaitAsync(lookup, PresenceDirector.ArtworkGrace, cancellationToken);
            Artwork = artwork ?? Artwork;
        }
        else
        {
            Artwork = located.Title.Kind == TitleKind.SystemApp ? SystemAppIcons.Image(located.Title.TitleId) : null;
        }

        var activity = _director.NoteSuccess(located.Title, settings, DateTimeOffset.UtcNow, artwork ?? Artwork);
        Status = located.Title.IsLiveArea
            ? "In the LiveArea"
            : located.Title.DisplayName + (located.Title.TitleId.Length == 0 ? "" : " (" + located.Title.TitleId + ")");
        if (activity is null)
        {
            if (_discord.IsConnected) await _discord.DisconnectAsync();
            _sent = null;
            return;
        }
        try
        {
            if (!_discord.IsConnected)
            {
                await _discord.ConnectAsync(settings.EffectiveClientId, activity, cancellationToken);
                _sent = activity;
                NoteSend();
                return;
            }
            if (!Same(activity, _sent) && await WaitForSlotAsync(cancellationToken))
            {
                await _discord.SetActivityAsync(activity, cancellationToken);
                _sent = activity;
                NoteSend();
            }
        }
        catch (Exception ex) when (ex is IOException or InvalidOperationException)
        {
            Status = string.IsNullOrEmpty(Status) ? ex.Message : Status + " — " + ex.Message;
        }
    }

    public static TimeSpan RetryDelay(int consecutiveFailures, TimeSpan pollInterval)
    {
        var seconds = Math.Min(30, 5 * Math.Pow(2, Math.Max(consecutiveFailures - 1, 0)));
        var backoff = TimeSpan.FromSeconds(seconds);
        return backoff > pollInterval ? backoff : pollInterval;
    }

    private void NoteSend()
    {
        var now = DateTimeOffset.UtcNow;
        _sends.Add(now);
        _sends.RemoveAll(sent => now - sent > TimeSpan.FromSeconds(20));
    }

    private async Task<bool> WaitForSlotAsync(CancellationToken cancellationToken)
    {
        var now = DateTimeOffset.UtcNow;
        _sends.RemoveAll(sent => now - sent > TimeSpan.FromSeconds(20));
        if (_sends.Count < 5) return true;
        var wait = TimeSpan.FromSeconds(20) - (now - _sends[0]);
        if (wait > TimeSpan.Zero)
            await Task.Delay(wait, cancellationToken);
        return true;
    }

    private static async Task<string?> WaitAsync(Task<string?> lookup, TimeSpan grace, CancellationToken cancellationToken)
    {
        var finished = await Task.WhenAny(lookup, Task.Delay(grace, cancellationToken));
        return finished == lookup ? await lookup : null;
    }

    private static bool Same(DiscordActivity left, DiscordActivity? right) =>
        right is not null
        && left.Name == right.Name
        && left.Details == right.Details
        && left.State == right.State
        && left.Assets?.LargeImage == right.Assets?.LargeImage
        && left.Timestamps?.Start == right.Timestamps?.Start;
}
