namespace VitaPresence;

/// The application the Vita reports as being in the foreground.
public sealed record VitaTitle(int Index, string TitleId, string Name, string? ContentId = null)
{
    public static VitaTitle LiveArea { get; } = new(0, "", "");

    public bool IsLiveArea => Index == 0;

    /// Changes when the LiveArea state flips or the title ID changes.
    public string SessionKey => IsLiveArea ? "livearea" : "app:" + TitleId;

    public string DisplayName => IsLiveArea ? "LiveArea" : string.IsNullOrEmpty(Name) ? TitleId : Name;

    public TitleKind Kind
    {
        get
        {
            if (IsLiveArea) return TitleKind.LiveArea;
            var id = TitleId.ToUpperInvariant();
            if (id == "XMB") return TitleKind.AdrenalineMenu;
            if (Matches(id, "NPXS", 0)) return TitleKind.SystemApp;
            if (Matches(id, "PCS", 1, 'A', 'H')) return TitleKind.VitaGame;
            if (IsRegionSerial(id, 'U', "CL") || Matches(id, "NP", 2)) return TitleKind.PspGame;
            if (IsRegionSerial(id, 'S', "CL")) return TitleKind.Ps1Game;
            return TitleKind.Other;
        }
    }

    /// lead + a region letter + two letters + five digits. ULUS10041, SLUS00594.
    private static bool IsRegionSerial(string id, char lead, string regions)
    {
        if (id.Length != 9 || id[0] != lead || regions.IndexOf(id[1]) < 0) return false;
        for (var i = 1; i < 4; i++)
            if (id[i] < 'A' || id[i] > 'Z') return false;
        for (var i = 4; i < 9; i++)
            if (id[i] < '0' || id[i] > '9') return false;
        return true;
    }

    /// prefix, then `letters` uppercase letters in range, then exactly five digits.
    private static bool Matches(string id, string prefix, int letters, char from = 'A', char to = 'Z')
    {
        if (id.Length != prefix.Length + letters + 5 || !id.StartsWith(prefix, StringComparison.Ordinal))
            return false;
        for (var i = 0; i < letters; i++)
        {
            var c = id[prefix.Length + i];
            if (c < from || c > to) return false;
        }
        for (var i = prefix.Length + letters; i < id.Length; i++)
            if (id[i] < '0' || id[i] > '9') return false;
        return true;
    }
}

public enum TitleKind
{
    LiveArea,
    SystemApp,
    AdrenalineMenu,
    VitaGame,
    PspGame,
    Ps1Game,
    Other,
}
