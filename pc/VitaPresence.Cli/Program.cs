using VitaPresence;

Options options;
try
{
    options = Options.Parse(args);
}
catch (Exception ex)
{
    Console.Error.WriteLine(ex.Message);
    Console.Error.WriteLine(Options.Usage);
    return 1;
}
if (options.Help)
{
    Console.WriteLine(Options.Usage);
    return 0;
}

if (options.Scan)
{
    try
    {
        var scanner = new VitaScanner { Port = options.Port };
        var found = await scanner.ScanAsync();
        Console.WriteLine(ScanTable(found));
        return found.Count == 0 ? 1 : 0;
    }
    catch (Exception ex)
    {
        Console.Error.WriteLine(ex.Message);
        return 1;
    }
}

using var cancel = new CancellationTokenSource();
Console.CancelKeyPress += (_, eventArgs) =>
{
    eventArgs.Cancel = true;
    cancel.Cancel();
};

var discord = new DiscordHelperClient();
var runner = new PresenceRunner(discord, locator: new VitaLocator(port: options.Port));
try
{
    while (!cancel.IsCancellationRequested)
    {
        await runner.TickAsync(options.Settings, selected: null, allowScan: true, cancel.Token);
        var where = runner.Located is { } vita ? " @ " + vita.Host : "";
        Console.WriteLine(runner.Status + where);
        var wait = runner.Director.ConsecutiveFailures > 0
            ? PresenceRunner.RetryDelay(runner.Director.ConsecutiveFailures, options.Settings.EffectivePollInterval)
            : options.Settings.EffectivePollInterval;
        await Task.Delay(wait, cancel.Token);
    }
}
catch (OperationCanceledException) { }
finally
{
    await discord.DisconnectAsync();
}
return 0;

static string ScanTable(IReadOnlyList<DiscoveredVita> vitas)
{
    var rows = new List<string[]> { new[] { "IP ADDRESS", "MAC ADDRESS", "TITLE" } };
    rows.AddRange(vitas.Select(vita => new[]
    {
        vita.IpAddress,
        vita.MacAddress?.ToString() ?? "-",
        Describe(vita.Title),
    }));
    var ipWidth = rows.Max(row => row[0].Length);
    var macWidth = rows.Max(row => row[1].Length);
    return string.Join('\n', rows.Select(row => row[0].PadRight(ipWidth) + "  " + row[1].PadRight(macWidth) + "  " + row[2]));
}

static string Describe(VitaTitle title)
{
    if (title.IsLiveArea || title.TitleId.Length == 0 || title.TitleId == title.DisplayName) return title.DisplayName;
    return title.DisplayName + " (" + title.TitleId + ")";
}

sealed class Options
{
    public PresenceSettings Settings { get; } = new() { ConnectOnLaunch = true };
    public bool Scan { get; private set; }
    public bool Help { get; private set; }
    public int Port { get; private set; } = VitaPacket.Port;

    public const string Usage = """
        vitapresence-cli [--address <ip|mac|auto>] [--client-id <id>] [--port <n>]
        vitapresence-cli --scan [--port <n>]

          --address <ip|mac|auto>   Vita to ask. auto finds the one Vita on the network.
          --client-id <id>          Your own Discord application ID. Default: the built-in one.
          --port <n>                Plugin port. Default: 51966.
          --no-artwork              Don't look up or show game artwork.
          --scan                    Print each Vita's IP, MAC, and title, then exit.
        """;

    public static Options Parse(string[] args)
    {
        var options = new Options();
        var positionals = new List<string>();
        for (var i = 0; i < args.Length; i++)
        {
            var arg = args[i];
            string Next() => i + 1 < args.Length ? args[++i] : throw new InvalidOperationException(arg + " needs a value.");
            switch (arg)
            {
                case "--help" or "-h":
                    options.Help = true;
                    break;
                case "--scan":
                    options.Scan = true;
                    break;
                case "--no-artwork":
                    options.Settings.ShowGameArtwork = false;
                    break;
                case "--address":
                    options.Settings.Address = Next();
                    break;
                case "--client-id":
                    options.Settings.ClientId = Next();
                    options.Settings.UseOwnDiscordApplication = true;
                    break;
                case "--port":
                    if (!int.TryParse(Next(), out var port) || port is < 1 or > 65535)
                        throw new InvalidOperationException("--port must be a number from 1 to 65535.");
                    options.Port = port;
                    break;
                default:
                    if (arg.StartsWith('-')) throw new InvalidOperationException("Unknown option " + arg);
                    positionals.Add(arg);
                    break;
            }
        }
        if (positionals.Count > 0 && options.Settings.Address.Length == 0)
            options.Settings.Address = positionals[0];
        if (positionals.Count > 1 && options.Settings.ClientId.Length == 0)
        {
            options.Settings.ClientId = positionals[1];
            options.Settings.UseOwnDiscordApplication = true;
        }
        return options;
    }
}
