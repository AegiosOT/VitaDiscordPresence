import Darwin
import VitaKit

/// `--scan`: probes every host of the local IPv4 subnets and prints the Vitas that answer. Progress and
/// problems go to standard error, so standard output holds only the table.
enum ScanCommand {
    /// Exit status 0 when at least one Vita answered, otherwise 1.
    static func run(port: UInt16) async -> Int32 {
        let interfaces = LocalNetwork.interfaces()
        guard !interfaces.isEmpty else {
            Console.error("\(CommandLineTool.name): no Wi-Fi or Ethernet network to scan")
            return EXIT_FAILURE
        }
        let networks = interfaces.map { "\($0.name) (\($0.address))" }.joined(separator: ", ")
        Console.error("Scanning \(networks) for Vitas on port \(port)…")

        let vitas: [DiscoveredVita]
        do {
            vitas = try await scanner(port: port).scan()
        } catch let error as VitaConnectionError {
            Console.error("\(CommandLineTool.name): \(error.userMessage)")
            if error == .localNetworkDenied {
                Console.error(Usage.localNetworkHint)
            }
            return EXIT_FAILURE
        } catch {
            Console.error("\(CommandLineTool.name): scan failed: \(error)")
            return EXIT_FAILURE
        }
        guard !vitas.isEmpty else {
            Console.error("""
                No Vita found. Make sure it's awake, on the same network as this Mac, and running the
                VitaPresence plugin.
                """)
            return EXIT_FAILURE
        }
        Console.out(ScanTable.render(vitas))
        return EXIT_SUCCESS
    }

    /// A scanner probing `port` with the short timeouts a LAN sweep needs. `run` finds the Vita with it, when
    /// the address is automatic or a MAC address.
    static func scanner(port: UInt16) -> VitaScanner {
        VitaScanner(fetcher: VitaClient(port: port, connectTimeout: .milliseconds(800), readTimeout: .seconds(2)))
    }
}
