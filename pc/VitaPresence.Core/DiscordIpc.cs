using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace VitaPresence;

public enum DiscordOpcode : uint
{
    Handshake = 0,
    Frame = 1,
    Close = 2,
    Ping = 3,
    Pong = 4,
}

public static class DiscordFrames
{
    public const int HeaderLength = 8;
    public const int MaximumPayloadLength = 1 << 20;

    public static byte[] Encode(DiscordOpcode opcode, string json)
    {
        var payload = Encoding.UTF8.GetBytes(json);
        var frame = new byte[HeaderLength + payload.Length];
        WriteU32(frame, 0, (uint)opcode);
        WriteU32(frame, 4, (uint)payload.Length);
        payload.CopyTo(frame, HeaderLength);
        return frame;
    }

    public static bool TryRead(ref ReadOnlyMemory<byte> buffer, out DiscordOpcode opcode, out string json)
    {
        opcode = default;
        json = "";
        if (buffer.Length < HeaderLength) return false;
        var span = buffer.Span;
        var raw = ReadU32(span, 0);
        var length = (int)ReadU32(span, 4);
        if (!Enum.IsDefined(typeof(DiscordOpcode), raw))
            throw new InvalidOperationException($"Unknown opcode {raw}.");
        if (length > MaximumPayloadLength)
            throw new InvalidOperationException($"Frame payload of {length} bytes is too long.");
        if (buffer.Length < HeaderLength + length) return false;
        opcode = (DiscordOpcode)raw;
        json = Encoding.UTF8.GetString(span.Slice(HeaderLength, length));
        buffer = buffer[(HeaderLength + length)..];
        return true;
    }

    public static string Handshake(string clientId) =>
        JsonSerializer.Serialize(new HandshakePayload(clientId), Json);

    public static string SetActivity(int pid, DiscordActivity activity, string nonce) =>
        JsonSerializer.Serialize(new SetActivityPayload(pid, activity, nonce), Json);

    public static string Close() => "{}";

    public static readonly JsonSerializerOptions Json = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    private static uint ReadU32(ReadOnlySpan<byte> bytes, int offset) =>
        bytes[offset] | (uint)bytes[offset + 1] << 8 | (uint)bytes[offset + 2] << 16 | (uint)bytes[offset + 3] << 24;

    private static void WriteU32(byte[] bytes, int offset, uint value)
    {
        bytes[offset] = (byte)value;
        bytes[offset + 1] = (byte)(value >> 8);
        bytes[offset + 2] = (byte)(value >> 16);
        bytes[offset + 3] = (byte)(value >> 24);
    }

    private sealed record HandshakePayload([property: JsonPropertyName("client_id")] string ClientId)
    {
        [JsonPropertyName("v")] public int Version { get; } = 1;
    }

    private sealed class SetActivityPayload
    {
        public SetActivityPayload(int pid, DiscordActivity activity, string nonce)
        {
            Args = new ActivityArgs(pid, activity);
            Nonce = nonce;
        }

        [JsonPropertyName("cmd")] public string Command { get; } = "SET_ACTIVITY";
        [JsonPropertyName("args")] public ActivityArgs Args { get; }
        [JsonPropertyName("nonce")] public string Nonce { get; }

        public sealed class ActivityArgs
        {
            public ActivityArgs(int pid, DiscordActivity activity)
            {
                Pid = pid;
                Activity = activity;
            }

            [JsonPropertyName("pid")] public int Pid { get; }
            public DiscordActivity Activity { get; }
        }
    }
}

/// Speaks Discord's local IPC on a Windows named pipe. Closing the pipe does not send a null activity.
public sealed class DiscordPipe : IAsyncDisposable
{
    private readonly NamedPipeClientStream _pipe;
    private readonly List<byte> _buffer = new();

    private DiscordPipe(NamedPipeClientStream pipe) => _pipe = pipe;

    public static async Task<DiscordPipe> ConnectAsync(string? pipeName, CancellationToken cancellationToken)
    {
        var names = pipeName is { Length: > 0 } chosen ? new[] { chosen } : Enumerable.Range(0, 10).Select(i => "discord-ipc-" + i);
        foreach (var name in names)
        {
            var pipe = new NamedPipeClientStream(".", name, PipeDirection.InOut, PipeOptions.Asynchronous);
            try
            {
                await pipe.ConnectAsync(1500, cancellationToken);
                return new DiscordPipe(pipe);
            }
            catch
            {
                await pipe.DisposeAsync();
            }
        }
        throw new IOException("Discord isn't running.");
    }

    public async Task HandshakeAsync(string clientId, CancellationToken cancellationToken)
    {
        await WriteAsync(DiscordOpcode.Handshake, DiscordFrames.Handshake(clientId), cancellationToken);
        var ready = await ReadUntilAsync(json => json.Contains("\"READY\"", StringComparison.Ordinal), cancellationToken);
        if (!ready.Contains("\"READY\"", StringComparison.Ordinal))
            throw new IOException("Discord didn't accept the application.");
    }

    public async Task SetActivityAsync(DiscordActivity activity, CancellationToken cancellationToken)
    {
        var json = DiscordFrames.SetActivity(Environment.ProcessId, activity.Sanitized(), Guid.NewGuid().ToString("N"));
        await WriteAsync(DiscordOpcode.Frame, json, cancellationToken);
        var reply = await ReadMessageAsync(cancellationToken);
        if (reply.Contains("\"ERROR\"", StringComparison.Ordinal) && !reply.Contains("\"code\":", StringComparison.Ordinal))
            throw new IOException("Discord rejected the activity.");
    }

    public async Task CloseAsync()
    {
        try
        {
            await WriteAsync(DiscordOpcode.Close, DiscordFrames.Close(), CancellationToken.None);
        }
        catch
        {
            // The pipe may already be gone. Leaving it is still a close, not a null activity.
        }
        await _pipe.DisposeAsync();
    }

    public ValueTask DisposeAsync() => _pipe.DisposeAsync();

    private async Task WriteAsync(DiscordOpcode opcode, string json, CancellationToken cancellationToken)
    {
        var frame = DiscordFrames.Encode(opcode, json);
        await _pipe.WriteAsync(frame, cancellationToken);
        await _pipe.FlushAsync(cancellationToken);
    }

    private async Task<string> ReadUntilAsync(Func<string, bool> done, CancellationToken cancellationToken)
    {
        var last = "";
        var deadline = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(8);
        while (DateTimeOffset.UtcNow < deadline)
        {
            last = await ReadMessageAsync(cancellationToken);
            if (done(last) || last.Contains("\"ERROR\"", StringComparison.Ordinal)) return last;
        }
        return last;
    }

    private async Task<string> ReadMessageAsync(CancellationToken cancellationToken)
    {
        var incoming = new byte[4096];
        while (true)
        {
            var snapshot = _buffer.ToArray();
            ReadOnlyMemory<byte> memory = snapshot;
            if (DiscordFrames.TryRead(ref memory, out _, out var json))
            {
                _buffer.RemoveRange(0, snapshot.Length - memory.Length);
                return json;
            }
            var read = await _pipe.ReadAsync(incoming, cancellationToken);
            if (read == 0) throw new IOException("Discord closed the connection.");
            _buffer.AddRange(incoming.AsSpan(0, read).ToArray());
        }
    }
}
