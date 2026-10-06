using System.Diagnostics;
using System.Text.Json;

namespace VitaPresence;

/// Talks to the helper process that owns the Discord pipe. Quitting that process, rather than
/// sending an empty activity, is what takes the card down.
public sealed class DiscordHelperClient : IDiscordPresence
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private Process? _process;

    public DiscordHelperClient(string? helperPath = null)
    {
        HelperPath = helperPath ?? Path.Combine(
            AppContext.BaseDirectory,
            OperatingSystem.IsWindows() ? "vitapresence-discord.exe" : "vitapresence-discord");
    }

    public string HelperPath { get; }

    public bool IsConnected => _process is { HasExited: false };

    public async Task ConnectAsync(string clientId, DiscordActivity activity, CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            await StopCoreAsync();
            if (!File.Exists(HelperPath))
                throw new InvalidOperationException("Discord helper was not found next to VitaPresence.");
            var process = new Process
            {
                StartInfo = new ProcessStartInfo(HelperPath)
                {
                    RedirectStandardInput = true,
                    RedirectStandardOutput = true,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                },
            };
            // A framework-dependent helper has to see the same runtime that launched us.
            var runtime = Path.GetDirectoryName(typeof(object).Assembly.Location);
            if (runtime is not null)
            {
                var root = Path.GetFullPath(Path.Combine(runtime, "..", "..", ".."));
                if (File.Exists(Path.Combine(root, OperatingSystem.IsWindows() ? "dotnet.exe" : "dotnet")))
                {
                    process.StartInfo.Environment["DOTNET_ROOT"] = root;
                    process.StartInfo.Environment["DOTNET_ROOT_ARM64"] = root;
                    process.StartInfo.Environment["DOTNET_ROOT_X64"] = root;
                }
            }
            if (!process.Start())
                throw new InvalidOperationException("Discord helper did not start.");
            _process = process;
            await WriteAsync(process, new HelperLine("connect", clientId, activity), cancellationToken);
            await ExpectAsync(process, "ready", cancellationToken);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task SetActivityAsync(DiscordActivity activity, CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            if (_process is not { HasExited: false } process)
                throw new InvalidOperationException("Discord is not connected.");
            await WriteAsync(process, new HelperLine("setActivity", null, activity), cancellationToken);
            await ExpectAsync(process, "activity", cancellationToken);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task DisconnectAsync()
    {
        await _gate.WaitAsync();
        try
        {
            await StopCoreAsync();
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task ExpectAsync(Process process, string expected, CancellationToken cancellationToken)
    {
        var reply = await process.StandardOutput.ReadLineAsync(cancellationToken);
        if (reply is null)
            throw new IOException("Discord helper exited.");
        using var document = JsonDocument.Parse(reply);
        var evt = document.RootElement.GetProperty("evt").GetString();
        if (evt == expected) return;
        var message = document.RootElement.TryGetProperty("message", out var text) ? text.GetString() : null;
        await StopCoreAsync();
        throw new IOException(string.IsNullOrEmpty(message) ? "Discord did not accept the presence." : message);
    }

    private static async Task WriteAsync(Process process, HelperLine line, CancellationToken cancellationToken)
    {
        var json = JsonSerializer.Serialize(line, DiscordFrames.Json);
        await process.StandardInput.WriteLineAsync(json.AsMemory(), cancellationToken);
        await process.StandardInput.FlushAsync(cancellationToken);
    }

    private async Task StopCoreAsync()
    {
        var process = _process;
        _process = null;
        if (process is null) return;
        try
        {
            if (!process.HasExited)
            {
                try
                {
                    await process.StandardInput.WriteLineAsync("{\"cmd\":\"quit\"}");
                    await process.StandardInput.FlushAsync();
                }
                catch (IOException) { }
                using var wait = new CancellationTokenSource(TimeSpan.FromSeconds(1));
                try
                {
                    await process.WaitForExitAsync(wait.Token);
                }
                catch (OperationCanceledException)
                {
                    process.Kill(entireProcessTree: true);
                }
            }
        }
        catch (InvalidOperationException) { }
        finally
        {
            process.Dispose();
        }
    }

    private sealed record HelperLine(string Cmd, string? ClientID, DiscordActivity? Activity);
}
