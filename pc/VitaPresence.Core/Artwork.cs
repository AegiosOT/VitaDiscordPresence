using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace VitaPresence;

public interface IArtworkHttp
{
    Task<ArtworkHttpResponse> SendAsync(HttpMethod method, string url, TimeSpan timeout, CancellationToken cancellationToken);
}

public readonly record struct ArtworkHttpResponse(int Status, string? ContentType, byte[] Body, bool Definitive);

public sealed class ArtworkResolver
{
    public const string StoreApi = "https://store.playstation.com/store/api/chihiro/00_09_000";
    public const string CoversUrl = "https://raw.githubusercontent.com/Andiweli/HexFlow-Covers/main/Covers/";
    public const string CatalogUrl = "https://robin994.github.io/NeoVitaDB-Catalog/vita.json";
    public const string IconsUrl = "https://robin994.github.io/NeoVitaDB-Catalog/icons/";
    public const string AdrenalineTitleId = "PSPEMUCFW";

    private readonly IArtworkHttp _http;
    private readonly string? _cacheFile;
    private readonly Dictionary<string, CacheEntry> _cache = new();
    private Catalog? _catalog;
    private bool _catalogLoaded;

    public ArtworkResolver(IArtworkHttp? http = null, string? cacheFile = null)
    {
        _http = http ?? new HttpArtworkClient();
        _cacheFile = cacheFile ?? DefaultCacheFile();
        LoadCache();
    }

    public static string? DefaultCacheFile()
    {
        var root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrEmpty(root)) return null;
        return Path.Combine(root, "VitaPresence", "artwork.json");
    }

    public async Task<string?> ArtworkAsync(VitaTitle title, CancellationToken cancellationToken = default)
    {
        if (Query.Create(title) is not { } query) return null;
        if (Lookup(query.Key) is { } cached) return cached;
        string? found = null;
        var definitive = true;
        foreach (var source in query.Sources)
        {
            var answer = await AskAsync(query, source, cancellationToken);
            if (answer.Url is not null)
            {
                found = answer.Url;
                definitive = answer.Definitive;
                break;
            }
            if (!answer.Definitive) definitive = false;
        }
        if (found is not null || definitive)
            Remember(query.Key, found, definitive ? (found is null ? TimeSpan.FromDays(3) : TimeSpan.FromDays(30)) : TimeSpan.FromMinutes(10));
        return found;
    }

    private async Task<(string? Url, bool Definitive)> AskAsync(Query query, Source source, CancellationToken cancellationToken)
    {
        switch (source)
        {
            case Source.StoreImage image:
                return await ProbeAsync(StoreImage(image.ContentId), cancellationToken);
            case Source.StoreSearch:
                return await SearchStoreAsync(query, cancellationToken);
            case Source.Catalog catalog:
                return await CatalogIconAsync(catalog, cancellationToken);
            case Source.HexFlow hex:
                if (await ShouldSkipSharedHexFlow(query, cancellationToken))
                    return (null, true);
                return await ProbeAsync(CoverUrl(query.TitleId, hex.Folder), cancellationToken);
            default:
                return (null, true);
        }
    }

    private async Task<(string? Url, bool Definitive)> SearchStoreAsync(Query query, CancellationToken cancellationToken)
    {
        var storefront = Storefront.ForTitle(query.TitleId);
        var definitive = true;
        foreach (var name in SearchQueries(query.Name))
        {
            var url = SearchUrl(name, storefront);
            if (url is null) continue;
            ArtworkHttpResponse response;
            try
            {
                response = await _http.SendAsync(HttpMethod.Get, url, TimeSpan.FromSeconds(15), cancellationToken);
            }
            catch (Exception) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch
            {
                definitive = false;
                continue;
            }
            if (response.Status != 200)
            {
                if (!response.Definitive) definitive = false;
                continue;
            }
            var ids = Products(response.Body, query.TitleId);
            if (ids.Count == 0) continue;
            var probe = await ProbeManyAsync(ids.Select(id => StoreImage(id, storefront)), cancellationToken);
            return (probe.Url, probe.Definitive && definitive);
        }
        return (null, definitive);
    }

    private async Task<(string? Url, bool Definitive)> CatalogIconAsync(Source.Catalog source, CancellationToken cancellationToken)
    {
        var catalog = await CurrentCatalogAsync(cancellationToken);
        if (catalog is null) return (null, false);
        var entries = Candidates(catalog, source.TitleId, source.Name, source.Rule);
        foreach (var entry in entries)
        {
            var url = IconUrl(entry.Icon);
            if (url is null) continue;
            var probe = await ProbeAsync(url, cancellationToken);
            if (probe.Url is not null || !probe.Definitive) return probe;
        }
        return (null, true);
    }

    private async Task<bool> ShouldSkipSharedHexFlow(Query query, CancellationToken cancellationToken)
    {
        if (query.Kind != TitleKind.Other) return false;
        var catalog = await CurrentCatalogAsync(cancellationToken);
        if (catalog is null) return false;
        var entries = catalog.Entries.Where(entry => entry.TitleId == query.TitleId).ToArray();
        if (entries.Length < 2) return false;
        return Candidates(catalog, query.TitleId, query.Name, NameRule.Required).Count == 0;
    }

    private Task<(string? Url, bool Definitive)> ProbeAsync(string? url, CancellationToken cancellationToken) =>
        ProbeManyAsync([url], cancellationToken);

    private async Task<(string? Url, bool Definitive)> ProbeManyAsync(IEnumerable<string?> urls, CancellationToken cancellationToken)
    {
        var definitive = true;
        foreach (var url in urls)
        {
            if (url is null || DiscordActivity.AcceptableImage(url) is null) continue;
            try
            {
                var response = await _http.SendAsync(HttpMethod.Head, url, TimeSpan.FromSeconds(12), cancellationToken);
                if (response.Status == 405)
                    response = await _http.SendAsync(HttpMethod.Get, url, TimeSpan.FromSeconds(12), cancellationToken);
                if (response.Status == 200 && (response.ContentType ?? "").StartsWith("image/", StringComparison.OrdinalIgnoreCase))
                    return (url, true);
                if (!response.Definitive) definitive = false;
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch
            {
                definitive = false;
            }
        }
        return (null, definitive);
    }

    private async Task<Catalog?> CurrentCatalogAsync(CancellationToken cancellationToken)
    {
        if (!_catalogLoaded)
        {
            _catalogLoaded = true;
            _catalog = LoadCatalog();
        }
        if (_catalog is { } held && DateTimeOffset.UtcNow - held.FetchedAt < TimeSpan.FromDays(1))
            return held;
        try
        {
            var response = await _http.SendAsync(HttpMethod.Get, CatalogUrl, TimeSpan.FromSeconds(30), cancellationToken);
            if (response.Status != 200) return _catalog;
            var entries = ParseCatalog(response.Body);
            if (entries.Count == 0) return _catalog;
            _catalog = new Catalog(DateTimeOffset.UtcNow, entries);
            SaveCatalog(_catalog);
            return _catalog;
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch
        {
            return _catalog;
        }
    }

    public static string? StoreImage(string contentId) => StoreImage(contentId, Storefront.ForContent(contentId));

    private static string? StoreImage(string contentId, Storefront storefront)
    {
        if (!IsContentId(contentId)) return null;
        return $"{StoreApi}/container/{storefront.Country}/{storefront.Language}/19/{contentId.ToUpperInvariant()}/1534563384000/image";
    }

    public static bool IsContentId(string text)
    {
        if (text.Length != 36) return false;
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            if (i is 6 or 19) { if (c != '-') return false; }
            else if (i == 16) { if (c != '_') return false; }
            else if (!char.IsAsciiLetterOrDigit(c)) return false;
        }
        return true;
    }

    public static IReadOnlyList<string> Products(byte[] body, string titleId)
    {
        var marker = "-" + titleId.ToUpperInvariant() + "_00-";
        try
        {
            var response = JsonSerializer.Deserialize<SearchResponse>(body);
            var ids = new List<string>();
            foreach (var link in response?.Links ?? [])
            {
                var id = link.Id?.ToUpperInvariant();
                if (id is null || !IsContentId(id) || !id.Contains(marker, StringComparison.Ordinal)) continue;
                if (link.TopCategory == "add_on" || ids.Contains(id)) continue;
                ids.Add(id);
            }
            return ids;
        }
        catch (JsonException)
        {
            return [];
        }
    }

    public static IReadOnlyList<string> SearchQueries(string name)
    {
        var full = CleanedName(name.Replace('/', ' '));
        var shorter = new List<string>();
        AddPrefix(shorter, full, ":");
        AddPrefix(shorter, full, "：");
        AddPrefix(shorter, full, " - ");
        AddPrefix(shorter, full, " – ");
        AddPrefix(shorter, full, " — ");
        var slash = name.Split('/', 2)[0];
        var cleanedSlash = CleanedName(slash);
        if (cleanedSlash.Length > 0) shorter.Add(cleanedSlash);
        shorter.Sort((a, b) => b.Length.CompareTo(a.Length));
        var queries = new List<string>();
        foreach (var query in new[] { full }.Concat(shorter))
        {
            if (query.Length == 0 || queries.Contains(query)) continue;
            queries.Add(query);
            if (queries.Count == 3) break;
        }
        return queries;
    }

    public static string CleanedName(string name)
    {
        var cleaned = Regex.Replace(name, "[™®©]", " ");
        cleaned = Regex.Replace(cleaned, @"\s+", " ");
        cleaned = Regex.Replace(cleaned, @"\s*:?\s*PlayStation\s*Vita\s+Edition\s*$", "", RegexOptions.IgnoreCase);
        cleaned = Regex.Replace(cleaned, @"\s+(?=[:：])", "");
        return cleaned.Trim();
    }

    private static void AddPrefix(List<string> into, string text, string separator)
    {
        var index = text.IndexOf(separator, StringComparison.Ordinal);
        if (index > 0) into.Add(text[..index].Trim());
    }

    private static string? SearchUrl(string query, Storefront storefront)
    {
        var safe = Regex.Replace(query.Replace('/', ' '), @"\s+", " ").Trim();
        if (safe.Length == 0) return null;
        var path = Uri.EscapeDataString(safe).Replace("%2D", "-").Replace("%2E", ".").Replace("%5F", "_").Replace("%7E", "~");
        return $"{StoreApi}/tumbler/{storefront.Country}/{storefront.Language}/999/{path}?suggested_size=10&mode=game";
    }

    private static string? CoverUrl(string titleId, string folder)
    {
        if (!titleId.All(char.IsAsciiLetterOrDigit)) return null;
        return CoversUrl + folder + "/" + titleId + ".png";
    }

    private static string? IconUrl(string icon)
    {
        if (icon.Length == 0 || !char.IsAsciiLetterOrDigit(icon[0])) return null;
        if (!icon.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '-' or '_')) return null;
        return IconsUrl + icon;
    }

    private static List<CatalogEntry> Candidates(Catalog catalog, string titleId, string name, NameRule rule)
    {
        var entries = catalog.Entries.Where(entry => entry.TitleId == titleId).ToList();
        var equal = entries.Where(entry => NameMatch(entry.Name, name) == Match.Equal).ToList();
        var similar = entries.Where(entry => NameMatch(entry.Name, name) == Match.Contained).ToList();
        return rule switch
        {
            NameRule.Preferred => equal.Concat(similar).Concat(entries.Where(entry => NameMatch(entry.Name, name) is null)).ToList(),
            NameRule.RequiredIfShared when entries.Count == 1 => entries,
            _ => equal.Concat(similar).ToList(),
        };
    }

    private static Match? NameMatch(string left, string right)
    {
        var a = Comparable(left);
        var b = Comparable(right);
        if (a.Length == 0 || b.Length == 0) return null;
        if (a == b) return Match.Equal;
        var shorter = a.Length < b.Length ? a : b;
        var longer = a.Length < b.Length ? b : a;
        return shorter.Length >= 4 && longer.Contains(shorter, StringComparison.Ordinal) ? Match.Contained : null;
    }

    private static string Comparable(string name)
    {
        var folded = Regex.Replace(name, "[™℠®©]", "");
        folded = folded.Normalize(System.Text.NormalizationForm.FormKD).ToLowerInvariant();
        return new string(folded.Where(char.IsLetterOrDigit).ToArray());
    }

    private static List<CatalogEntry> ParseCatalog(byte[] body)
    {
        var published = JsonSerializer.Deserialize<List<PublishedEntry>>(body) ?? [];
        return published.Select(entry =>
        {
            var id = entry.TitleId?.Trim().ToUpperInvariant() ?? "";
            if (id.Length == 0 || string.IsNullOrEmpty(entry.Icon)) return null;
            return new CatalogEntry(id, entry.Name ?? "", entry.Icon);
        }).OfType<CatalogEntry>().ToList();
    }

    private string? Lookup(string key)
    {
        if (!_cache.TryGetValue(key, out var entry)) return null;
        if (entry.Expires <= DateTimeOffset.UtcNow)
        {
            _cache.Remove(key);
            return null;
        }
        return entry.Found ? entry.Url : null;
    }

    private void Remember(string key, string? url, TimeSpan ttl)
    {
        _cache[key] = new CacheEntry(url, url is not null, DateTimeOffset.UtcNow + ttl);
        SaveCache();
    }

    private void LoadCache()
    {
        if (_cacheFile is null || !File.Exists(_cacheFile)) return;
        try
        {
            var stored = JsonSerializer.Deserialize<Dictionary<string, CacheEntry>>(File.ReadAllText(_cacheFile));
            if (stored is null) return;
            foreach (var pair in stored)
                _cache[pair.Key] = pair.Value;
        }
        catch (Exception)
        {
            // A broken cache is ignored; the next lookup fills it again.
        }
    }

    private void SaveCache()
    {
        if (_cacheFile is null) return;
        Directory.CreateDirectory(Path.GetDirectoryName(_cacheFile)!);
        File.WriteAllText(_cacheFile, JsonSerializer.Serialize(_cache));
    }

    private Catalog? LoadCatalog()
    {
        var path = CatalogPath();
        if (path is null || !File.Exists(path)) return null;
        try { return JsonSerializer.Deserialize<Catalog>(File.ReadAllText(path)); }
        catch (Exception) { return null; }
    }

    private void SaveCatalog(Catalog catalog)
    {
        var path = CatalogPath();
        if (path is null) return;
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, JsonSerializer.Serialize(catalog));
    }

    private string? CatalogPath() =>
        _cacheFile is null ? null : Path.Combine(Path.GetDirectoryName(_cacheFile)!, "neovitadb.json");

    private sealed record CacheEntry(string? Url, bool Found, DateTimeOffset Expires);

    private sealed record Catalog(DateTimeOffset FetchedAt, List<CatalogEntry> Entries);

    private sealed record CatalogEntry(string TitleId, string Name, string Icon);

    private sealed class PublishedEntry
    {
        [JsonPropertyName("titleid")] public string? TitleId { get; set; }
        [JsonPropertyName("name")] public string? Name { get; set; }
        [JsonPropertyName("icon")] public string? Icon { get; set; }
    }

    private sealed class SearchResponse
    {
        [JsonPropertyName("links")] public List<SearchLink>? Links { get; set; }
    }

    private sealed class SearchLink
    {
        [JsonPropertyName("id")] public string? Id { get; set; }
        [JsonPropertyName("top_category")] public string? TopCategory { get; set; }
    }

    private enum Match { Equal, Contained }
    private enum NameRule { Preferred, RequiredIfShared, Required }

    private readonly record struct Storefront(string Country, string Language)
    {
        public static Storefront ForContent(string contentId) => char.ToUpperInvariant(contentId.FirstOrDefault()) switch
        {
            'E' => new("GB", "en"),
            'J' => new("JP", "ja"),
            'H' => new("SG", "en"),
            'K' => new("KR", "ko"),
            _ => new("US", "en"),
        };

        public static Storefront ForTitle(string titleId)
        {
            var id = titleId.ToUpperInvariant();
            char? region = null;
            if (id.StartsWith("PCS", StringComparison.Ordinal) && id.Length > 3)
            {
                region = id[3] switch
                {
                    'A' or 'E' => 'U',
                    'B' or 'F' => 'E',
                    'C' or 'G' => 'J',
                    'D' or 'H' => 'H',
                    _ => null,
                };
            }
            else if (id.Length > 2)
            {
                region = id[2];
            }
            return region switch
            {
                'E' => new("GB", "en"),
                'J' => new("JP", "ja"),
                'A' or 'H' => new("SG", "en"),
                'K' => new("KR", "ko"),
                _ => new("US", "en"),
            };
        }
    }

    private abstract record Source
    {
        public sealed record StoreImage(string ContentId) : Source;
        public sealed record StoreSearch : Source;
        public sealed record Catalog(string TitleId, string Name, NameRule Rule) : Source;
        public sealed record HexFlow(string Folder) : Source;
    }

    private sealed record Query(string TitleId, string Name, string? ContentId, TitleKind Kind)
    {
        public string Key
        {
            get
            {
                var baseKey = ContentId is null ? TitleId : TitleId + "|" + ContentId;
                if (Kind != TitleKind.Other) return baseKey;
                var normalized = string.Join(' ', Name.ToLowerInvariant().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
                return normalized.Length == 0 ? baseKey : baseKey + "|" + normalized;
            }
        }

        public IReadOnlyList<Source> Sources
        {
            get
            {
                var storeImage = ContentId is null ? [] : new Source[] { new Source.StoreImage(ContentId) };
                var storeSearch = Name.Length == 0 || Name.Equals(TitleId, StringComparison.OrdinalIgnoreCase)
                    ? Array.Empty<Source>()
                    : [new Source.StoreSearch()];
                var named = Name.Length == 0
                    ? Array.Empty<Source>()
                    : new Source[] { new Source.Catalog(TitleId, Name, NameRule.Required) };
                return Kind switch
                {
                    TitleKind.AdrenalineMenu => [new Source.Catalog(AdrenalineTitleId, "Adrenaline", NameRule.Preferred)],
                    TitleKind.VitaGame => storeImage.Concat(storeSearch).Concat(named).Append(new Source.HexFlow("PSVita")).ToArray(),
                    TitleKind.PspGame => storeImage.Concat(storeSearch).Concat(named).Append(new Source.HexFlow("PSP")).ToArray(),
                    TitleKind.Ps1Game => storeImage.Concat(named).Append(new Source.HexFlow("PS1")).ToArray(),
                    TitleKind.Other => storeImage.Append(new Source.Catalog(TitleId, Name, NameRule.RequiredIfShared)).Append(new Source.HexFlow("PSVita")).ToArray(),
                    _ => [],
                };
            }
        }

        public static Query? Create(VitaTitle title)
        {
            var id = title.TitleId.Trim().ToUpperInvariant();
            var name = title.Name.Trim();
            var normalized = title with { TitleId = id, Name = name };
            if (id.Length == 0 || normalized.Kind is TitleKind.LiveArea or TitleKind.SystemApp) return null;
            var content = title.ContentId?.Trim().ToUpperInvariant();
            if (content is not null && !IsContentId(content)) content = null;
            return new Query(id, name, content, normalized.Kind);
        }
    }
}

public sealed class HttpArtworkClient : IArtworkHttp
{
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(40) };

    public async Task<ArtworkHttpResponse> SendAsync(HttpMethod method, string url, TimeSpan timeout, CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(method, url);
        request.Headers.UserAgent.Add(new ProductInfoHeaderValue("VitaPresence", "2.0"));
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        linked.CancelAfter(timeout);
        try
        {
            using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, linked.Token);
            var body = method == HttpMethod.Head ? [] : await response.Content.ReadAsByteArrayAsync(linked.Token);
            var definitive = (int)response.StatusCode is >= 200 and < 500 && response.StatusCode != HttpStatusCode.TooManyRequests;
            return new ArtworkHttpResponse((int)response.StatusCode, response.Content.Headers.ContentType?.MediaType, body, definitive);
        }
        catch (Exception) when (!cancellationToken.IsCancellationRequested)
        {
            return new ArtworkHttpResponse(0, null, [], false);
        }
    }
}
