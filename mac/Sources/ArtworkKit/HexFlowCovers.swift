import Foundation

/// HexFlow-Covers box art: portrait PNGs named by title ID, for most retail Vita, PSP and PS1 games and about
/// 540 homebrew titles. Licensed CC BY-NC-SA 4.0.
enum HexFlowCovers {
    static let coversURL = "https://raw.githubusercontent.com/Andiweli/HexFlow-Covers/main/Covers/"

    enum Folder: String, Sendable {
        case vita = "PSVita"
        case psp = "PSP"
        case ps1 = "PS1"
    }

    /// `…/Covers/<folder>/<TITLEID>.png`, or `nil` when the title ID isn't plain letters and digits.
    static func coverURL(titleID: String, in folder: Folder) -> URL? {
        guard ArtworkURL.isPlainIdentifier(titleID) else { return nil }
        return URL(string: "\(coversURL)\(folder.rawValue)/\(titleID).png")
    }
}
