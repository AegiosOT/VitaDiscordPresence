import Foundation

/// Bubble icons for the Vita's built-in apps (`NPXS…`).
///
/// These are the pictures from the Vita developer wiki. The wiki refuses a direct fetch, so each address is
/// an Internet Archive copy of that file, resized by images.weserv.nl. Discord loads the result itself.
/// Nothing is looked up: a title that isn't in this list still has no icon.
enum SystemAppIcons {
    static func image(for titleID: String) -> String? {
        let id = titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return images[id]
    }

    /// Title ID to icon URL. The archive timestamp is the snapshot that actually has the file.
    static let images: [String: String] = [
        "NPXS10000": icon("20260709162734", "3/3f/Near.png"), // Near
        "NPXS10001": icon("20260713100805", "e/e5/Party.png"), // Party
        "NPXS10002": icon("20260713100651", "6/60/PS_Store.png"), // PlayStation Store
        "NPXS10003": icon("20260219035241", "d/db/Browser.png"), // Browser
        "NPXS10004": icon("20260707165544", "f/fa/Photos.png"), // Photos
        "NPXS10005": icon("20260713100651", "5/5c/Icon_menu_map.png"), // Maps
        "NPXS10006": icon("20260713100802", "e/e9/Friends.png"), // Friends
        "NPXS10007": icon("20260713100814", "0/0a/Welcome_Park.png"), // Welcome Park
        "NPXS10008": icon("20260713100810", "6/6b/Trophies.png"), // Trophies
        "NPXS10009": icon("20260219035246", "2/2c/Music.png"), // Music
        "NPXS10010": icon("20260219035252", "e/ec/Videos.png"), // Videos
        "NPXS10012": icon("20260713100808", "9/93/Remote_Play.png"), // PS3 Remote Play
        "NPXS10013": icon("20260713100651", "4/49/Icon_menu_ps4link.png"), // PS4 Link
        "NPXS10014": icon("20260216094007", "7/7b/Group_Messaging.png"), // Messages
        "NPXS10015": icon("20260709162734", "9/91/Settings.png"), // Settings
        "NPXS10026": icon("20260219035241", "b/bf/Content_Manager.png"), // Content Manager
        "NPXS10031": icon("20260713100803", "a/ae/Icon_Package_Installer.png"), // Package Installer
        "NPXS10072": icon("20260713100803", "3/3e/Icon_menu_mail.png"), // Email
        "NPXS10078": icon("20260713100808", "5/59/Remote_livearea_02.png"), // Cross-Controller
        "NPXS10091": icon("20260713100803", "4/45/Icon_menu_calendar.png"), // Calendar
        "NPXS10094": icon("20260713100658", "b/bf/Icon_menu_parental.png"), // Parental Controls
        "NPXS10095": icon("20260707165544", "2/26/Icon_Photo_panorama_camera.png"), // Panoramic Camera
    ]

    private static func icon(_ snapshot: String, _ path: String) -> String {
        "https://images.weserv.nl/?url=web.archive.org/web/\(snapshot)id_/https://www.psdevwiki.com/vita/images/\(path)&w=256&h=256&fit=contain&output=png"
    }
}
