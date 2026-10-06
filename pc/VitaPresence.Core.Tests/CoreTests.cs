using Xunit;

namespace VitaPresence.Tests;

public class PacketTests
{
    [Fact]
    public void V1PacketRoundTripsAt148Bytes()
    {
        var title = new VitaTitle(1, "PCSE00120", "Persona 4 Golden");
        var bytes = VitaPacket.Encode(title);
        Assert.Equal(VitaPacket.WireLength, bytes.Length);
        var parsed = VitaPacket.Parse(bytes);
        Assert.Equal("PCSE00120", parsed.TitleId);
        Assert.Equal("Persona 4 Golden", parsed.Name);
        Assert.Null(parsed.ContentId);
        Assert.Equal(TitleKind.VitaGame, parsed.Kind);
    }

    [Fact]
    public void V11PacketKeepsTheContentId()
    {
        var title = new VitaTitle(1, "PCSE00120", "Persona 4 Golden", "up0005-pcse00120_00-persona4golden01");
        var bytes = VitaPacket.Encode(title);
        Assert.Equal(VitaPacket.WireLengthWithContentId, bytes.Length);
        var parsed = VitaPacket.Parse(bytes);
        Assert.Equal("UP0005-PCSE00120_00-PERSONA4GOLDEN01", parsed.ContentId);
    }

    [Fact]
    public void LiveAreaIsIndexZero()
    {
        var parsed = VitaPacket.Parse(VitaPacket.Encode(VitaTitle.LiveArea));
        Assert.True(parsed.IsLiveArea);
        Assert.Equal(TitleKind.LiveArea, parsed.Kind);
    }

    [Fact]
    public void AShortOrStrangePacketIsRejected()
    {
        Assert.Throws<VitaPacketException>(() => VitaPacket.Parse(new byte[10]));
        var bytes = VitaPacket.Encode(new VitaTitle(1, "XMB", "Adrenaline"));
        bytes[0] = 0;
        Assert.Throws<VitaPacketException>(() => VitaPacket.Parse(bytes));
    }

    [Fact]
    public void TitleKindsFollowTheTitleId()
    {
        Assert.Equal(TitleKind.AdrenalineMenu, new VitaTitle(1, "XMB", "Adrenaline").Kind);
        Assert.Equal(TitleKind.SystemApp, new VitaTitle(1, "NPXS10015", "Settings").Kind);
        Assert.Equal(TitleKind.PspGame, new VitaTitle(1, "ULUS10041", "Game").Kind);
        Assert.Equal(TitleKind.Ps1Game, new VitaTitle(1, "SLUS00594", "Game").Kind);
        Assert.Equal(TitleKind.Other, new VitaTitle(1, "VITASHELL", "VitaShell").Kind);
    }
}

public class PresenceTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.UnixEpoch.AddHours(1);

    [Fact]
    public void AGameShowsItsNameAndPlatform()
    {
        var activity = PresenceBuilder.Activity(new VitaTitle(1, "PCSE00120", "Persona 4 Golden"), new PresenceSettings(), Now, null);
        Assert.NotNull(activity);
        Assert.Equal("Persona 4 Golden", activity.Name);
        Assert.Equal("PlayStation Vita", activity.Details);
        Assert.Equal(Now.ToUnixTimeMilliseconds(), activity.Timestamps?.Start);
    }

    [Fact]
    public void AdrenalineAndTheOtherPlatformsUseTheirOwnLines()
    {
        var menu = PresenceBuilder.Activity(new VitaTitle(1, "XMB", "Adrenaline XMB Menu"), new PresenceSettings(), Now, null);
        Assert.Equal("Adrenaline", menu!.Name);
        Assert.Equal("PlayStation Vita", menu.Details);

        var psp = PresenceBuilder.Activity(new VitaTitle(1, "ULUS10041", "A PSP Game"), new PresenceSettings(), Now, null);
        Assert.Equal("PSP on PlayStation Vita", psp!.Details);

        var ps1 = PresenceBuilder.Activity(new VitaTitle(1, "SLUS00594", "A PS1 Game"), new PresenceSettings(), Now, null);
        Assert.Equal("PS1 on PlayStation Vita", ps1!.Details);
    }

    [Fact]
    public void TheLiveAreaCanBeHidden()
    {
        var shown = PresenceBuilder.Activity(VitaTitle.LiveArea, new PresenceSettings(), Now, null);
        Assert.Equal("PlayStation Vita", shown!.Name);
        Assert.Equal("In the LiveArea", shown.Details);
        Assert.Equal(PresenceBuilder.LiveAreaImage, shown.Assets?.LargeImage);

        var hidden = PresenceBuilder.Activity(VitaTitle.LiveArea, new PresenceSettings { ShowLiveArea = false }, Now, null);
        Assert.Null(hidden);
    }

    [Fact]
    public void SettingsGetsItsBubbleIcon()
    {
        var activity = PresenceBuilder.Activity(new VitaTitle(1, "NPXS10015", "Settings"), new PresenceSettings(), Now, "https://example.com/ignored.png");
        Assert.Equal(SystemAppIcons.Image("NPXS10015"), activity!.Assets?.LargeImage);
        Assert.Equal(22, SystemAppIcons.Images.Count);
    }

    [Fact]
    public async Task ANilTitleDoesNotOpenDiscord()
    {
        var discord = new RecordingDiscord();
        var runner = new PresenceRunner(discord, new VitaLocator(new VitaScanner(new LiveAreaFetcher(), () => ["10.0.0.2"], _ => null), new LiveAreaFetcher()));
        var settings = new PresenceSettings { Address = "", ShowLiveArea = false };
        await runner.TickAsync(settings, selected: null, allowScan: true, CancellationToken.None);
        Assert.Empty(discord.Connects);
        Assert.False(discord.IsConnected);
    }

    [Fact]
    public void TwoQuickMissesKeepTheGame()
    {
        var director = new PresenceDirector();
        var game = new VitaTitle(1, "PCSE00120", "Persona 4 Golden");
        Assert.NotNull(director.NoteSuccess(game, new PresenceSettings(), Now, null));
        Assert.False(director.NoteFailure(Now.AddSeconds(10), TimeSpan.FromSeconds(60)));
        Assert.False(director.ShouldDropDiscord);
        Assert.Equal(game, director.Title);
        Assert.True(director.NoteFailure(Now.AddMinutes(2), TimeSpan.FromSeconds(60)));
        Assert.Null(director.Title);
        Assert.True(director.ShouldDropDiscord);
    }

    [Fact]
    public void SetActivityCarriesTheGameAndCloseIsEmpty()
    {
        var activity = PresenceBuilder.Activity(new VitaTitle(1, "PCSE00120", "Persona 4 Golden"), new PresenceSettings(), Now, null)!;
        var json = DiscordFrames.SetActivity(1, activity, "nonce");
        Assert.Contains("Persona 4 Golden", json, StringComparison.Ordinal);
        Assert.DoesNotContain("\"activity\":null", json, StringComparison.Ordinal);
        Assert.Equal("{}", DiscordFrames.Close());
        Assert.Contains("1556140114374037715", DiscordFrames.Handshake(PresenceSettings.DefaultClientId), StringComparison.Ordinal);
    }

    [Fact]
    public void OldConfigBecomesASavedVitaAndOwnApplication()
    {
        var settings = new PresenceSettings();
        var profiles = new List<VitaProfile>();
        const string json = """
            {"IP":"192.168.1.20","Client":"1234567890123456","State":"Busy","UpdateInterval":"15","DisplayTimer":false,"DisplayMainMenu":false}
            """;
        Assert.True(LegacyConfig.TryImport(json, settings, profiles));
        Assert.Equal("192.168.1.20", settings.Address);
        Assert.Equal("192.168.1.20", profiles[0].LastAddress);
        Assert.True(settings.UseOwnDiscordApplication);
        Assert.Equal("1234567890123456", settings.ClientId);
        Assert.Equal("Busy", settings.StateText);
        Assert.Equal(15, settings.PollInterval);
        Assert.False(settings.ShowElapsedTime);
        Assert.False(settings.ShowLiveArea);
    }

    private sealed class LiveAreaFetcher : IVitaFetcher
    {
        public Task<VitaTitle> FetchAsync(string host, int port, TimeSpan timeout, CancellationToken cancellationToken) =>
            Task.FromResult(VitaTitle.LiveArea);
    }

    private sealed class RecordingDiscord : IDiscordPresence
    {
        public List<string> Connects { get; } = new();
        public bool IsConnected { get; private set; }
        public Task ConnectAsync(string clientId, DiscordActivity activity, CancellationToken cancellationToken)
        {
            Connects.Add(clientId);
            IsConnected = true;
            return Task.CompletedTask;
        }
        public Task SetActivityAsync(DiscordActivity activity, CancellationToken cancellationToken) => Task.CompletedTask;
        public Task DisconnectAsync()
        {
            IsConnected = false;
            return Task.CompletedTask;
        }
    }
}
