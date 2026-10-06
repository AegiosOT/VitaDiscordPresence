using System.Text.Json;
using Microsoft.Win32;
using VitaPresence;

namespace VitaPresence.App;

public sealed class AppSession
{
    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true };
    private readonly string _path;
    private CancellationTokenSource? _cancel;
    private Task? _loop;
    private DiscordHelperClient? _discord;

    public AppSession()
    {
        var root = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        Directory.CreateDirectory(Path.Combine(root, "VitaPresence"));
        _path = Path.Combine(root, "VitaPresence", "settings.json");
        Settings = new PresenceSettings();
        if (!Load()) ImportLegacy();
    }

    public PresenceSettings Settings { get; }
    public List<VitaProfile> Profiles { get; } = new();
    public List<DiscoveredVita> Found { get; } = new();
    public Guid? SelectedId { get; private set; }
    public string Status { get; private set; } = "Not connected";
    public string? Warning { get; private set; }
    public bool IsActive { get; private set; }
    public bool IsScanning { get; private set; }
    public bool Attention { get; private set; }
    public Action<Action> Post { get; set; } = action => action();
    public event Action? Changed;

    public VitaProfile? Selected => Profiles.FirstOrDefault(profile => profile.Id == SelectedId);

    public void Select(VitaProfile profile)
    {
        SelectedId = profile.Id;
        Settings.Address = "";
        Save();
        Raise();
    }

    public void Remember(LocatedVita vita) => Post(() => RememberCore(vita));

    private void RememberCore(LocatedVita vita)
    {
        var mac = vita.MacAddress?.ToString();
        var profile = Selected ?? Profiles.FirstOrDefault(item =>
            item.LastAddress == vita.Host || (mac is not null && item.MacAddress == mac));
        if (profile is null)
        {
            if (Profiles.Count > 0) return;
            profile = new VitaProfile();
            Profiles.Add(profile);
            SelectedId = profile.Id;
        }
        profile.LastAddress = vita.Host;
        if (mac is not null) profile.MacAddress = mac;
        profile.LastSeen = DateTimeOffset.UtcNow;
        Save();
        Changed?.Invoke();
    }

    public void Use(DiscoveredVita vita)
    {
        var profile = new VitaProfile
        {
            LastAddress = vita.IpAddress,
            MacAddress = vita.MacAddress?.ToString(),
        };
        Profiles.Add(profile);
        SelectedId = profile.Id;
        Settings.Address = "";
        Save();
        Raise();
    }

    public void Remove(VitaProfile profile)
    {
        Profiles.RemoveAll(item => item.Id == profile.Id);
        if (SelectedId == profile.Id) SelectedId = Profiles.FirstOrDefault()?.Id;
        Save();
        Raise();
    }

    public void Save()
    {
        var document = new StoredSettings
        {
            Settings = Settings,
            Profiles = Profiles,
            SelectedProfileId = SelectedId,
            ImportedLegacyConfig = true,
        };
        File.WriteAllText(_path, JsonSerializer.Serialize(document, Json));
    }

    public void Toggle()
    {
        if (IsActive) _ = StopAsync();
        else Start();
    }

    public void Start()
    {
        if (_loop is not null) return;
        IsActive = true;
        Attention = false;
        Status = "Looking for your Vita…";
        Raise();
        _cancel = new CancellationTokenSource();
        _discord = new DiscordHelperClient();
        var runner = new PresenceRunner(_discord);
        _loop = Task.Run(() => RunAsync(runner, _cancel.Token));
    }

    public async Task StopAsync()
    {
        var cancel = _cancel;
        var loop = _loop;
        _cancel = null;
        _loop = null;
        if (cancel is not null) await cancel.CancelAsync();
        if (loop is not null)
        {
            try { await loop; }
            catch (OperationCanceledException) { }
        }
        if (_discord is not null)
        {
            await _discord.DisconnectAsync();
            _discord = null;
        }
        IsActive = false;
        Attention = false;
        Status = "Not connected";
        Raise();
    }

    public async Task ScanAsync()
    {
        if (IsScanning) return;
        IsScanning = true;
        Found.Clear();
        Warning = null;
        Raise();
        try
        {
            var found = await new VitaScanner().ScanAsync();
            Found.Clear();
            Found.AddRange(found);
            if (Found.Count == 0)
                Warning = "No Vita answered. Check that it's awake, on the same network, and running the VitaPresence plugin.";
        }
        catch (Exception ex)
        {
            Warning = ex.Message;
        }
        finally
        {
            IsScanning = false;
            Raise();
        }
    }

    public static void ApplyLaunchAtLogin(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true);
        if (key is null) return;
        if (enabled && Environment.ProcessPath is { Length: > 0 } path)
            key.SetValue("VitaPresence", $"\"{path}\"");
        else
            key.DeleteValue("VitaPresence", throwOnMissingValue: false);
    }

    private async Task RunAsync(PresenceRunner runner, CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                await runner.TickAsync(Settings, Selected, allowScan: true, cancellationToken);
                Status = runner.Status;
                Attention = Settings.Issues().Count > 0;
                if (runner.Located is { } vita) Remember(vita);
                else Raise();
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (Exception ex)
            {
                Status = ex.Message;
                Attention = true;
                Raise();
            }
            var wait = runner.Director.ConsecutiveFailures > 0
                ? PresenceRunner.RetryDelay(runner.Director.ConsecutiveFailures, Settings.EffectivePollInterval)
                : Settings.EffectivePollInterval;
            try
            {
                await Task.Delay(wait, cancellationToken);
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }
    }

    private bool Load()
    {
        if (!File.Exists(_path)) return false;
        try
        {
            var stored = JsonSerializer.Deserialize<StoredSettings>(File.ReadAllText(_path), Json);
            if (stored?.Settings is null) return false;
            Copy(stored.Settings, Settings);
            Profiles.AddRange(stored.Profiles ?? []);
            SelectedId = stored.SelectedProfileId;
            return true;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private void ImportLegacy()
    {
        foreach (var path in new[]
        {
            Path.Combine(AppContext.BaseDirectory, "Config.json"),
            Path.Combine(Directory.GetCurrentDirectory(), "Config.json"),
        })
        {
            if (!File.Exists(path)) continue;
            if (!LegacyConfig.TryImport(File.ReadAllText(path), Settings, Profiles)) continue;
            SelectedId = Profiles.FirstOrDefault()?.Id;
            Save();
            return;
        }
    }

    private void Raise() => Post(() => Changed?.Invoke());

    private static void Copy(PresenceSettings from, PresenceSettings to)
    {
        to.Address = from.Address;
        to.ClientId = from.ClientId;
        to.StateText = from.StateText;
        to.LargeImageKey = from.LargeImageKey;
        to.PollInterval = from.PollInterval;
        to.ShowElapsedTime = from.ShowElapsedTime;
        to.ShowLiveArea = from.ShowLiveArea;
        to.ShowGameArtwork = from.ShowGameArtwork;
        to.ConnectOnLaunch = from.ConnectOnLaunch;
        to.LaunchAtLogin = from.LaunchAtLogin;
        to.UseOwnDiscordApplication = from.UseOwnDiscordApplication;
    }

    private sealed class StoredSettings
    {
        public PresenceSettings? Settings { get; set; }
        public List<VitaProfile>? Profiles { get; set; }
        public Guid? SelectedProfileId { get; set; }
        public bool ImportedLegacyConfig { get; set; }
    }
}
