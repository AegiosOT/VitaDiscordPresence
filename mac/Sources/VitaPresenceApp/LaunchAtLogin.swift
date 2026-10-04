import Foundation
import ServiceManagement

/// Launch at login through `SMAppService.mainApp`. Nothing is registered unless the user turns it on.
struct LaunchAtLogin {
    enum State: Equatable {
        case enabled
        case disabled
        /// Registered, but the user has to allow it in System Settings › General › Login Items.
        case requiresApproval
        /// Not running from an installed app bundle (for example `swift run`), so it can't be registered.
        case unavailable
    }

    /// Reads the current state.
    var state: () -> State
    /// Registers (`true`) or unregisters (`false`) the app as a login item.
    var setEnabled: (Bool) throws -> Void
    /// Opens System Settings › General › Login Items.
    var openSystemSettingsLoginItems: () -> Void
}

extension LaunchAtLogin {
    /// This app's login item.
    static var mainApp: LaunchAtLogin {
        LaunchAtLogin(
            state: { State(SMAppService.mainApp.status, bundlePath: Bundle.main.bundlePath) },
            setEnabled: { enabled in
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            },
            openSystemSettingsLoginItems: { SMAppService.openSystemSettingsLoginItems() }
        )
    }
}

extension LaunchAtLogin.State {
    /// Maps the service status for an app running from `bundlePath`. Outside an `.app` bundle there is
    /// nothing to register. A quarantined download runs translocated from a temporary copy until it is moved,
    /// and registering that copy would leave a broken login item, so that is unavailable too.
    init(_ status: SMAppService.Status, bundlePath: String) {
        guard bundlePath.hasSuffix(".app"), !bundlePath.contains("/AppTranslocation/") else {
            self = .unavailable
            return
        }
        switch status {
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notRegistered, .notFound: self = .disabled
        @unknown default: self = .disabled
        }
    }
}
