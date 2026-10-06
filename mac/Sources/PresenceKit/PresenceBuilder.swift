import DiscordIPC
import Foundation
import VitaKit

/// Turns what the Vita reports into what Discord should show.
public enum PresenceBuilder {
    /// The activity to show for `title`, or `nil` to clear the presence.
    ///
    /// The game is the bold title ("Playing **Persona 4 Golden**"):
    /// - Any app: type 0 ("Playing"), name = `title.displayName`, details = the platform: "PSP on PlayStation
    ///   Vita" for `.pspGame`, "PS1 on PlayStation Vita" for `.ps1Game`, otherwise "PlayStation Vita".
    /// - Adrenaline's menu (`XMB`): name "Adrenaline".
    /// - LiveArea: `nil` when `settings.showLiveArea` is false, otherwise name "PlayStation Vita" and details
    ///   "In the LiveArea".
    /// - state = `settings.stateText` when it isn't blank.
    /// - timestamps.start = `sessionStart` in Unix milliseconds, only when `settings.showElapsedTime` is on and
    ///   `sessionStart` isn't `nil`.
    /// - large image = `settings.largeImageKey` when Discord would keep it (an asset key, or an https URL of
    ///   at most 256 characters with no whitespace). A custom value Discord would drop falls back to `artwork`
    ///   when `settings.showGameArtwork` is on, so a bad URL doesn't hide the game's picture. The LiveArea
    ///   uses `liveAreaImage` (the application's icon is a question mark). Large text = name and
    ///   title ID, "Persona 4 Golden (PCSE00120)" (the name alone when there is no title ID or the name is the
    ///   title ID), with a long name shortened so the title ID still fits.
    /// - The result is `sanitized()`, so it always passes Discord's field validation.
    public static func activity(
        for title: VitaTitle,
        settings: PresenceSettings,
        sessionStart: Date?,
        artwork: URL? = nil
    ) -> DiscordActivity? {
        if title.isLiveArea, !settings.showLiveArea { return nil }
        let name = name(of: title)
        var activity = DiscordActivity(type: playing, name: name, details: details(of: title))
        if !settings.stateText.isBlank {
            activity.state = settings.stateText
        }
        if settings.showElapsedTime, let sessionStart {
            let milliseconds = (sessionStart.timeIntervalSince1970 * 1000).rounded()
            activity.timestamps = DiscordActivity.Timestamps(start: Int64(milliseconds))
        }
        if let image = largeImage(for: title, settings: settings, artwork: artwork) {
            activity.assets = DiscordActivity.Assets(largeImage: image, largeText: imageText(name, title.titleID))
        }
        return activity.sanitized()
    }

    /// Discord's activity type for "Playing".
    private static let playing = 0
    private static let vita = "PlayStation Vita"
    /// The LiveArea picture. The built-in Discord application has no icon, so without this the status is a
    /// question mark. The Commons wordmark is black on a clear background, which disappears on Discord's
    /// dark card, so this is that logo padded onto white.
    static let liveAreaImage =
        "https://images.weserv.nl/?url=upload.wikimedia.org/wikipedia/commons/thumb/3/3d/PlayStation_Vita_logo.svg/250px-PlayStation_Vita_logo.svg.png&w=256&h=256&fit=contain&bg=white"
    /// The longest text Discord accepts, in UTF-16 code units.
    private static let maximumTextUnits = 128

    /// The bold title.
    private static func name(of title: VitaTitle) -> String {
        switch title.kind {
        case .liveArea: vita
        case .adrenalineMenu: "Adrenaline"
        case .systemApp, .vitaGame, .pspGame, .ps1Game, .other: title.displayName
        }
    }

    /// The line under the title: where the Vita is, or which system the game runs as.
    private static func details(of title: VitaTitle) -> String {
        switch title.kind {
        case .liveArea: "In the LiveArea"
        case .pspGame: "PSP on \(vita)"
        case .ps1Game: "PS1 on \(vita)"
        case .systemApp, .adrenalineMenu, .vitaGame, .other: vita
        }
    }

    private static func largeImage(for title: VitaTitle, settings: PresenceSettings, artwork: URL?) -> String? {
        if let custom = DiscordActivity.acceptableImage(settings.largeImageKey) { return custom }
        guard settings.showGameArtwork else { return nil }
        if title.isLiveArea { return liveAreaImage }
        return artwork?.absoluteString
    }

    /// "Name (TITLEID)", or `name` alone when the title ID adds nothing.
    private static func imageText(_ name: String, _ titleID: String) -> String {
        guard !titleID.isEmpty, name != titleID else { return name }
        let suffix = " (\(titleID))"
        let room = max(maximumTextUnits - suffix.utf16.count, 2)
        return (DiscordText.clamp(name, minUnits: 1, maxUnits: room) ?? "") + suffix
    }
}
