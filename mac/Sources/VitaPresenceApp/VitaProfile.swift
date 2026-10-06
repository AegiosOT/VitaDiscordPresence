import Foundation
import VitaKit

/// One PS Vita this Mac has connected to. The last address is polled first; the MAC address is how the same
/// console is recognized after its IP address changes.
struct VitaProfile: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    /// What the Settings window shows. Empty is shown as `defaultName`.
    var name: String
    /// The IPv4 address it last answered on.
    var lastAddress: String
    /// Canonical MAC address, when the Mac could read it. `nil` until then.
    var macAddress: String?
    var lastSeen: Date

    static let defaultName = "PS Vita"

    var mac: MACAddress? {
        macAddress.flatMap(MACAddress.init)
    }

    /// The name to show, using `defaultName` when `name` is blank.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultName : trimmed
    }
}

/// The Vita automatic discovery should look for: where it last answered, and which console that was.
struct RememberedVita: Equatable, Sendable {
    var host: String?
    var macAddress: MACAddress?

    static let none = RememberedVita(host: nil, macAddress: nil)
}
