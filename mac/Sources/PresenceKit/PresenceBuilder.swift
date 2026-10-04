import DiscordIPC
import Foundation
import VitaKit

/// Turns what the Vita reports into what Discord should show.
public enum PresenceBuilder {
    /// The activity to show for `title`, or `nil` to clear the presence.
    ///
    /// Rules:
    /// - LiveArea: `nil` when `settings.showLiveArea` is false, otherwise details "In the LiveArea".
    /// - Any app: details = `title.displayName` (the name, or the title ID when the name is empty).
    /// - state = `settings.stateText` when it isn't blank.
    /// - timestamps.start = `sessionStart` in Unix milliseconds, only when `settings.showElapsedTime` is on and
    ///   `sessionStart` isn't `nil`.
    /// - assets only when `settings.largeImageKey` isn't blank: large image = the key, large text =
    ///   `title.displayName`.
    /// - The result is `sanitized()`, so it always passes Discord's field validation.
    public static func activity(
        for title: VitaTitle,
        settings: PresenceSettings,
        sessionStart: Date?
    ) -> DiscordActivity? {
        if title.isLiveArea, !settings.showLiveArea { return nil }
        var activity = DiscordActivity(details: title.isLiveArea ? "In the LiveArea" : title.displayName)
        if !settings.stateText.isBlank {
            activity.state = settings.stateText
        }
        if settings.showElapsedTime, let sessionStart {
            let milliseconds = (sessionStart.timeIntervalSince1970 * 1000).rounded()
            activity.timestamps = DiscordActivity.Timestamps(start: Int64(milliseconds))
        }
        if !settings.largeImageKey.isBlank {
            activity.assets = DiscordActivity.Assets(largeImage: settings.largeImageKey, largeText: title.displayName)
        }
        return activity.sanitized()
    }
}
