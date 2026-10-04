import VitaKit

/// Formats `--scan` results as a table with a header row, a MAC address of `-` when the OS doesn't expose it:
///
///     IP ADDRESS    MAC ADDRESS        TITLE
///     192.168.1.31  a4:5e:60:01:02:03  Persona 4 Golden (PCSE00120)
///     192.168.1.40  -                  LiveArea
enum ScanTable {
    static func render(_ vitas: [DiscoveredVita]) -> String {
        let header = ["IP ADDRESS", "MAC ADDRESS", "TITLE"]
        let rows = [header] + vitas.map { vita in
            [vita.ipAddress, vita.macAddress?.description ?? "-", StatusFormatter.describe(vita.title)]
        }
        let ipWidth = rows.map(\.[0].count).max() ?? 0
        let macWidth = rows.map(\.[1].count).max() ?? 0
        return rows
            .map { row in pad(row[0], to: ipWidth) + "  " + pad(row[1], to: macWidth) + "  " + row[2] }
            .joined(separator: "\n")
    }

    private static func pad(_ text: String, to width: Int) -> String {
        text + String(repeating: " ", count: max(0, width - text.count))
    }
}
