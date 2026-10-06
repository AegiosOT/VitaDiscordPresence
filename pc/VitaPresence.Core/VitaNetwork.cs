using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace VitaPresence;

public sealed record DiscoveredVita(string IpAddress, MacAddress? MacAddress, VitaTitle Title);

public interface IVitaFetcher
{
    Task<VitaTitle> FetchAsync(string host, int port, TimeSpan timeout, CancellationToken cancellationToken);
}

public sealed class VitaClient : IVitaFetcher
{
    public async Task<VitaTitle> FetchAsync(string host, int port, TimeSpan timeout, CancellationToken cancellationToken)
    {
        using var client = new TcpClient();
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        linked.CancelAfter(timeout);
        await client.ConnectAsync(host, port, linked.Token);
        await using var stream = client.GetStream();
        var buffer = new byte[VitaPacket.MaximumReadLength];
        var read = 0;
        while (read < VitaPacket.WireLengthWithContentId)
        {
            var count = await stream.ReadAsync(buffer.AsMemory(read), linked.Token);
            if (count == 0) break;
            read += count;
        }
        return VitaPacket.Parse(buffer.AsSpan(0, read));
    }
}

public sealed class VitaScanner
{
    private readonly IVitaFetcher _fetcher;
    private readonly Func<IReadOnlyList<string>> _hosts;
    private readonly Func<string, MacAddress?> _mac;
    private readonly int _maxConcurrent;
    private readonly TimeSpan _timeout;

    public int Port { get; set; } = VitaPacket.Port;

    public VitaScanner(IVitaFetcher? fetcher = null, Func<IReadOnlyList<string>>? hosts = null, Func<string, MacAddress?>? mac = null, int maxConcurrent = 48, TimeSpan? timeout = null)
    {
        _fetcher = fetcher ?? new VitaClient();
        _hosts = hosts ?? LocalHosts;
        _mac = mac ?? Arp.Lookup;
        _maxConcurrent = maxConcurrent;
        _timeout = timeout ?? TimeSpan.FromSeconds(2);
    }

    public async Task<IReadOnlyList<DiscoveredVita>> ScanAsync(IReadOnlyList<string>? hosts = null, CancellationToken cancellationToken = default)
    {
        var candidates = (hosts ?? _hosts()).Distinct(StringComparer.Ordinal).ToList();
        if (candidates.Count == 0)
            throw new InvalidOperationException("This computer isn't on a network VitaPresence can scan.");
        var found = new List<DiscoveredVita>();
        using var gate = new SemaphoreSlim(_maxConcurrent);
        var tasks = candidates.Select(async host =>
        {
            await gate.WaitAsync(cancellationToken);
            try
            {
                var title = await _fetcher.FetchAsync(host, Port, _timeout, cancellationToken);
                return new DiscoveredVita(host, _mac(host), title);
            }
            catch (Exception) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch
            {
                return null;
            }
            finally
            {
                gate.Release();
            }
        });
        foreach (var result in await Task.WhenAll(tasks))
            if (result is not null) found.Add(result);
        found.Sort((a, b) => CompareIp(a.IpAddress, b.IpAddress));
        return found;
    }

    public static IReadOnlyList<string> LocalHosts()
    {
        var hosts = new List<string>();
        foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (nic.OperationalStatus != OperationalStatus.Up) continue;
            foreach (var address in nic.GetIPProperties().UnicastAddresses)
            {
                if (address.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                if (IPAddress.IsLoopback(address.Address)) continue;
                var mask = address.IPv4Mask;
                if (mask is null) continue;
                hosts.AddRange(Candidates(address.Address, mask, 1024));
            }
        }
        return hosts;
    }

    public static IEnumerable<string> Candidates(IPAddress address, IPAddress mask, int limit)
    {
        var ip = ToUInt(address);
        var bits = ToUInt(mask);
        var network = ip & bits;
        var broadcast = network | ~bits;
        var count = 0;
        for (var host = network + 1; host < broadcast && count < limit; host++)
        {
            if (host == ip) continue;
            count++;
            yield return FromUInt(host);
        }
    }

    private static int CompareIp(string left, string right)
    {
        IPAddress.TryParse(left, out var a);
        IPAddress.TryParse(right, out var b);
        return (a?.GetAddressBytes() ?? []).Zip(b?.GetAddressBytes() ?? [], (x, y) => x.CompareTo(y)).FirstOrDefault(c => c != 0);
    }

    private static uint ToUInt(IPAddress address)
    {
        var bytes = address.GetAddressBytes();
        return ((uint)bytes[0] << 24) | ((uint)bytes[1] << 16) | ((uint)bytes[2] << 8) | bytes[3];
    }

    private static string FromUInt(uint value) =>
        $"{value >> 24}.{(value >> 16) & 255}.{(value >> 8) & 255}.{value & 255}";
}

public static class Arp
{
    public static MacAddress? Lookup(string ipAddress)
    {
        if (!OperatingSystem.IsWindows()) return null;
        return LookupWindows(ipAddress);
    }

    [SupportedOSPlatform("windows")]
    private static MacAddress? LookupWindows(string ipAddress)
    {
        if (!IPAddress.TryParse(ipAddress, out var ip)) return null;
        var size = 0;
        GetIpNetTable(IntPtr.Zero, ref size, true);
        var buffer = Marshal.AllocHGlobal(size);
        try
        {
            if (GetIpNetTable(buffer, ref size, true) != 0) return null;
            var count = Marshal.ReadInt32(buffer);
            var row = buffer + 4;
            var stride = Marshal.SizeOf<MibIpNetRow>();
            var wanted = ToUInt(ip);
            for (var i = 0; i < count; i++)
            {
                var entry = Marshal.PtrToStructure<MibIpNetRow>(row + i * stride);
                if (entry.Addr == wanted && entry.PhysAddrLen >= 6)
                    return new MacAddress(entry.PhysAddr0, entry.PhysAddr1, entry.PhysAddr2, entry.PhysAddr3, entry.PhysAddr4, entry.PhysAddr5);
            }
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
        return null;
    }

    private static uint ToUInt(IPAddress address)
    {
        var bytes = address.GetAddressBytes();
        return bytes[0] | (uint)bytes[1] << 8 | (uint)bytes[2] << 16 | (uint)bytes[3] << 24;
    }

    [DllImport("iphlpapi.dll")]
    private static extern int GetIpNetTable(IntPtr table, ref int size, bool order);

    [StructLayout(LayoutKind.Sequential)]
    private struct MibIpNetRow
    {
        public int Index;
        public int PhysAddrLen;
        public byte PhysAddr0, PhysAddr1, PhysAddr2, PhysAddr3, PhysAddr4, PhysAddr5, PhysAddr6, PhysAddr7;
        public uint Addr;
        public int Type;
    }
}

public sealed class VitaProfile
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public string LastAddress { get; set; } = "";
    public string? MacAddress { get; set; }
    public DateTimeOffset LastSeen { get; set; } = DateTimeOffset.UtcNow;

    public string DisplayName => string.IsNullOrWhiteSpace(Name) ? "PS Vita" : Name.Trim();

    public MacAddress? Mac => MacAddress is not null && VitaPresence.MacAddress.TryParse(MacAddress, out var mac) ? mac : null;
}

/// Picks which host to ask. A remembered console is not replaced by a different Vita that happens to be awake.
public sealed class VitaLocator
{
    private readonly VitaScanner _scanner;
    private readonly IVitaFetcher _fetcher;

    public VitaLocator(VitaScanner? scanner = null, IVitaFetcher? fetcher = null, int? port = null)
    {
        _fetcher = fetcher ?? new VitaClient();
        _scanner = scanner ?? new VitaScanner(_fetcher);
        if (port is int chosen) _scanner.Port = chosen;
    }

    public async Task<LocatedVita?> LocateAsync(VitaAddress address, VitaProfile? selected, bool allowScan, CancellationToken cancellationToken)
    {
        if (address.Kind == VitaAddressKind.Ip)
            return await Probe(address.Value, cancellationToken);

        if (address.Kind == VitaAddressKind.Mac)
        {
            if (!MacAddress.TryParse(address.Value, out var wanted)) return null;
            if (selected?.LastAddress is { Length: > 0 } last && await Probe(last, cancellationToken) is { } direct && MacEquals(direct.MacAddress, wanted))
                return direct;
            if (!allowScan) return null;
            return (await _scanner.ScanAsync(cancellationToken: cancellationToken))
                .Select(ToLocated)
                .FirstOrDefault(found => MacEquals(found.MacAddress, wanted));
        }

        if (selected?.LastAddress is { Length: > 0 } remembered)
        {
            if (await Probe(remembered, cancellationToken) is { } hit)
                return hit;
            if (!allowScan) return null;
            var found = await _scanner.ScanAsync(cancellationToken: cancellationToken);
            var mac = selected.Mac;
            if (mac is { } expected)
                return found.Select(ToLocated).FirstOrDefault(vita => MacEquals(vita.MacAddress, expected));
            return null;
        }

        if (!allowScan) return null;
        var discovered = await _scanner.ScanAsync(cancellationToken: cancellationToken);
        return discovered.Count == 1 ? ToLocated(discovered[0]) : null;
    }

    private async Task<LocatedVita?> Probe(string host, CancellationToken cancellationToken)
    {
        try
        {
            var title = await _fetcher.FetchAsync(host, _scanner.Port, TimeSpan.FromSeconds(3), cancellationToken);
            return new LocatedVita(host, Arp.Lookup(host), title);
        }
        catch
        {
            return null;
        }
    }

    private static LocatedVita ToLocated(DiscoveredVita vita) => new(vita.IpAddress, vita.MacAddress, vita.Title);

    private static bool MacEquals(MacAddress? left, MacAddress right) => left is { } value && value.Equals(right);
}

public sealed record LocatedVita(string Host, MacAddress? MacAddress, VitaTitle Title);
