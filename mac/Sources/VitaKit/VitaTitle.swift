/// The application the Vita reports as being in the foreground.
public struct VitaTitle: Sendable, Hashable, Codable {
    /// Raw index from the plugin: `0` when nothing is running (the LiveArea), otherwise the app slot + 1
    /// (1...20). Slots are reused across launches, so this is not an identity; only use it to detect the
    /// LiveArea.
    public var index: Int32
    /// Title ID such as `PCSE00120`, `XMB` for the Adrenaline menu, or `""` in the LiveArea.
    public var titleID: String
    /// Display name such as `Persona 4 Golden`; empty in the LiveArea.
    public var name: String
    /// PlayStation Store content ID such as `UP0005-PCSE00120_00-PERSONA4GOLDEN01`, read from the game's
    /// param.sfo by plugin versions that send it. `nil` for older plugins, the LiveArea, system apps, PSP
    /// games under Adrenaline, and anything without a well-formed ID.
    public var contentID: String?

    public init(index: Int32, titleID: String, name: String, contentID: String? = nil) {
        self.index = index
        self.titleID = titleID
        self.name = name
        self.contentID = contentID
    }

    /// The LiveArea / home screen: nothing in the foreground.
    public static let liveArea = VitaTitle(index: 0, titleID: "", name: "")

    /// `true` when no application is in the foreground.
    public var isLiveArea: Bool { index == 0 }

    /// Identity for elapsed-time sessions. It changes when the LiveArea state flips or the title ID changes.
    /// Never equal for the LiveArea and an app, even an app with an empty title ID.
    public var sessionKey: String { isLiveArea ? "livearea" : "app:" + titleID }

    /// Name to show to people: `LiveArea`, the title name, or the title ID when the name is empty.
    public var displayName: String {
        if isLiveArea { return "LiveArea" }
        return name.isEmpty ? titleID : name
    }

    /// What kind of title this is, judged from the index and the title ID's shape.
    public var kind: Kind {
        if isLiveArea { return .liveArea }
        let id = titleID.uppercased()
        if id == "XMB" { return .adrenalineMenu }
        if Self.matches(id, prefix: "NPXS", letters: 0) { return .systemApp }
        if Self.matches(id, prefix: "PCS", letters: 1, from: "A"..."H") { return .vitaGame }
        // Real serials only. Homebrew often reuses a PS1- or PSP-shaped title ID (`Sxxx` / `Uxxx`) that is
        // not a Sony serial; those stay `.other` and get the homebrew artwork order.
        if Self.isRegionSerial(id, lead: "U", regions: ["C", "L"]) || Self.matches(id, prefix: "NP", letters: 2) {
            return .pspGame
        }
        if Self.isRegionSerial(id, lead: "S", regions: ["C", "L"]) { return .ps1Game }
        return .other
    }

    public enum Kind: Sendable, Hashable {
        /// Nothing in the foreground.
        case liveArea
        /// A Sony system app such as Settings (`NPXS10015`).
        case systemApp
        /// Adrenaline's PSP menu (title ID `XMB`).
        case adrenalineMenu
        /// A retail PS Vita game (`PCSA`…`PCSH` + 5 digits).
        case vitaGame
        /// A PSP game, as reported under Adrenaline (`ULUS10041`, `UCUS98711`, `NPJH50465`, …).
        case pspGame
        /// A PS1 game, as reported under Adrenaline (`SLUS00594`, `SCES00344`, …).
        case ps1Game
        /// Anything else, usually homebrew (`VITASHELL`).
        case other
    }

    /// `lead` + a region letter in `regions` + two letters + five digits. `ULUS10041`, `SLUS00594`.
    private static func isRegionSerial(_ id: String, lead: Character, regions: Set<Character>) -> Bool {
        guard id.count == 9, let first = id.first, first == lead else { return false }
        let scalars = Array(id.unicodeScalars)
        let isLetter = { (scalar: Unicode.Scalar) in ("A"..."Z").contains(scalar) }
        let isDigit = { (scalar: Unicode.Scalar) in ("0"..."9").contains(scalar) }
        guard let region = scalars.dropFirst().first, regions.contains(Character(region)) else { return false }
        return scalars.dropFirst().prefix(3).allSatisfy(isLetter) && scalars.dropFirst(4).allSatisfy(isDigit)
    }

    /// `true` when `id` is `prefix`, then `letters` uppercase letters within `range`, then exactly 5 digits.
    private static func matches(
        _ id: String,
        prefix: String,
        letters: Int,
        from range: ClosedRange<Unicode.Scalar> = "A"..."Z"
    ) -> Bool {
        let scalars = Array(id.unicodeScalars)
        guard scalars.count == prefix.unicodeScalars.count + letters + 5, id.hasPrefix(prefix) else { return false }
        let rest = scalars.dropFirst(prefix.unicodeScalars.count)
        let isDigit = { (s: Unicode.Scalar) in ("0"..."9").contains(s) }
        return rest.prefix(letters).allSatisfy(range.contains) && rest.dropFirst(letters).allSatisfy(isDigit)
    }
}
