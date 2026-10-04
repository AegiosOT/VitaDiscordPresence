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

    public init(index: Int32, titleID: String, name: String) {
        self.index = index
        self.titleID = titleID
        self.name = name
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
}
