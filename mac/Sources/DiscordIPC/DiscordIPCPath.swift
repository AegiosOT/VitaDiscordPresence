import Foundation

/// Where Discord's IPC socket can be.
public enum DiscordIPCPath {
    /// Candidate socket paths in the order Discord's own clients try them.
    ///
    /// Directories come from `XDG_RUNTIME_DIR`, `TMPDIR`, `TMP`, `TEMP` (non-empty values only), then
    /// `darwinUserTempDir`, then `/tmp`. They are deduplicated after removing trailing slashes. Each directory
    /// contributes `discord-ipc-0` … `discord-ipc-9`. Paths of 104 bytes or more are left out, because they
    /// don't fit `sockaddr_un.sun_path`.
    public static func candidates(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        darwinUserTempDir: String? = DiscordIPCPath.darwinUserTempDir()
    ) -> [String] {
        let variables = ["XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP"].compactMap { environment[$0] }
        let directories = variables + [darwinUserTempDir ?? "", "/tmp"]
        var seen: Set<Substring> = []
        var paths: [String] = []
        for directory in directories where !directory.isEmpty {
            var trimmed = Substring(directory)
            while trimmed.hasSuffix("/") {
                trimmed = trimmed.dropLast()
            }
            guard seen.insert(trimmed).inserted else { continue }
            for index in 0...9 {
                let path = "\(trimmed)/discord-ipc-\(index)"
                if fitsSocketAddress(path) { paths.append(path) }
            }
        }
        return paths
    }

    /// The per-user temporary directory from `confstr(_CS_DARWIN_USER_TEMP_DIR)`, which is where Discord
    /// creates its socket even when the environment has no `TMPDIR` (for example under launchd).
    public static func darwinUserTempDir() -> String? {
        let size = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, size) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return path.isEmpty ? nil : path
    }

    /// Whether `path` is shorter than `sockaddr_un.sun_path` (104 bytes), leaving room for the terminating
    /// NUL. `NWEndpoint.unix(path:)` traps on paths that don't fit, so every path is checked before use.
    static func fitsSocketAddress(_ path: String) -> Bool {
        path.utf8.count < 104
    }
}
