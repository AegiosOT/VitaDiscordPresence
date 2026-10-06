namespace VitaPresence;

/// Bubble icons for the Vita's built-in apps. Same addresses the Mac client uses.
public static class SystemAppIcons
{
    public static string? Image(string titleId)
    {
        var id = titleId.Trim().ToUpperInvariant();
        return Images.TryGetValue(id, out var url) ? url : null;
    }

    public static IReadOnlyDictionary<string, string> Images { get; } = new Dictionary<string, string>
    {
        ["NPXS10000"] = Icon("20260709162734", "3/3f/Near.png"),
        ["NPXS10001"] = Icon("20260713100805", "e/e5/Party.png"),
        ["NPXS10002"] = Icon("20260713100651", "6/60/PS_Store.png"),
        ["NPXS10003"] = Icon("20260219035241", "d/db/Browser.png"),
        ["NPXS10004"] = Icon("20260707165544", "f/fa/Photos.png"),
        ["NPXS10005"] = Icon("20260713100651", "5/5c/Icon_menu_map.png"),
        ["NPXS10006"] = Icon("20260713100802", "e/e9/Friends.png"),
        ["NPXS10007"] = Icon("20260713100814", "0/0a/Welcome_Park.png"),
        ["NPXS10008"] = Icon("20260713100810", "6/6b/Trophies.png"),
        ["NPXS10009"] = Icon("20260219035246", "2/2c/Music.png"),
        ["NPXS10010"] = Icon("20260219035252", "e/ec/Videos.png"),
        ["NPXS10012"] = Icon("20260713100808", "9/93/Remote_Play.png"),
        ["NPXS10013"] = Icon("20260713100651", "4/49/Icon_menu_ps4link.png"),
        ["NPXS10014"] = Icon("20260216094007", "7/7b/Group_Messaging.png"),
        ["NPXS10015"] = Icon("20260709162734", "9/91/Settings.png"),
        ["NPXS10026"] = Icon("20260219035241", "b/bf/Content_Manager.png"),
        ["NPXS10031"] = Icon("20260713100803", "a/ae/Icon_Package_Installer.png"),
        ["NPXS10072"] = Icon("20260713100803", "3/3e/Icon_menu_mail.png"),
        ["NPXS10078"] = Icon("20260713100808", "5/59/Remote_livearea_02.png"),
        ["NPXS10091"] = Icon("20260713100803", "4/45/Icon_menu_calendar.png"),
        ["NPXS10094"] = Icon("20260713100658", "b/bf/Icon_menu_parental.png"),
        ["NPXS10095"] = Icon("20260707165544", "2/26/Icon_Photo_panorama_camera.png"),
    };

    private static string Icon(string snapshot, string path) =>
        "https://images.weserv.nl/?url=web.archive.org/web/" + snapshot
        + "id_/https://www.psdevwiki.com/vita/images/" + path
        + "&w=256&h=256&fit=contain&output=png";
}
