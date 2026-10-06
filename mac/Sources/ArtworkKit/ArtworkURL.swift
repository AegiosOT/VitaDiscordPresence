import Foundation

/// The rules for every image URL handed to Discord.
enum ArtworkURL {
    /// Discord's external-asset endpoint takes at most 256 characters.
    static let maximumLength = 256

    /// `true` for an https URL with a host, at most 256 characters, without whitespace, query string or
    /// fragment.
    static func isAcceptable(_ url: URL) -> Bool {
        let text = url.absoluteString
        return text.lowercased().hasPrefix("https://")
            && !(url.host() ?? "").isEmpty
            && text.utf16.count <= maximumLength
            && !text.contains("?")
            && !text.contains("#")
            && !text.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    /// `true` for a non-empty run of ASCII letters and digits, as title IDs are (`PCSE00120`, `VITASHELL`), so
    /// it can go into a URL path as it is.
    static func isPlainIdentifier(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { $0.isASCIIAlphanumeric }
    }
}

extension Unicode.Scalar {
    var isASCIIAlphanumeric: Bool {
        ("A"..."Z").contains(self) || ("a"..."z").contains(self) || ("0"..."9").contains(self)
    }
}

/// Small JSON files in the Caches folder: dates as seconds since 1970, written atomically into a directory
/// created on demand. Failures are ignored; a file that can't be read or decoded reads as `nil`.
enum JSONFile {
    static func read<Value: Decodable>(_ type: Value.Type, from file: URL) -> Value? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }

    static func write(_ value: some Encodable, to file: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: file, options: .atomic)
    }
}
