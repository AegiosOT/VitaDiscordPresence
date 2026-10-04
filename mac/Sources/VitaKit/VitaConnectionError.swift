/// Why polling the Vita failed.
public enum VitaConnectionError: Error, Equatable, Sendable {
    /// No answer within the timeout: the Vita is off, asleep or out of Wi-Fi range, or the address is wrong.
    case timedOut
    /// The host answered but nothing listens on port 51966. Either the plugin isn't installed or it hasn't
    /// started yet (it waits about 2 s after boot, and after any network error, before listening again).
    case refused
    /// macOS Local Network privacy blocked the connection
    /// (System Settings › Privacy & Security › Local Network).
    case localNetworkDenied
    /// No route to the host, host down, or network unreachable. Carries a diagnostic description.
    case unreachable(String)
    /// The connection closed before a complete packet (at least 146 bytes) arrived.
    case incompletePacket(byteCount: Int)
    /// Data arrived, but it isn't a VitaPresence packet.
    case invalidPacket(VitaPacketError)
    /// The configured address can't be used: not a valid IPv4 or MAC address, or a MAC address that couldn't
    /// be resolved to an IP. Carries a user-facing explanation.
    case unresolvedAddress(String)
    /// Any other failure. Carries a diagnostic description.
    case other(String)

    /// A short, user-facing explanation for a status line, such as
    /// "Vita not responding. Is it awake and on the same Wi-Fi?".
    public var userMessage: String {
        switch self {
        case .timedOut: "Vita not responding. Is it awake and on the same Wi-Fi?"
        case .refused: "Found the Vita, but the VitaPresence plugin isn't running"
        case .localNetworkDenied: "Local Network access is turned off for VitaPresence"
        case .unreachable(let detail): "Can't reach the Vita (\(detail))"
        case .incompletePacket, .invalidPacket: "Unexpected reply. Is this the right device?"
        case .unresolvedAddress(let message), .other(let message): message
        }
    }
}
