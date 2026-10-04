import Darwin

/// Parses the arguments and runs the requested command.
enum CommandLineTool {
    static let name = "vitapresence-cli"
    /// Keep in sync with `CFBundleShortVersionString` in Resources/Info.plist; a test compares them.
    static let version = "2.0.0"

    /// Returns the exit status: 0 success, 1 runtime failure, 64 usage error.
    static func run(arguments: [String]) async -> Int32 {
        let command: Command
        do {
            command = try CommandLineParser.parse(arguments)
        } catch {
            switch error {
            case .noArguments: Console.error(Usage.synopsis)
            case .invalid(let message): Console.error("\(name): \(message)")
            }
            Console.error(Usage.hint)
            return EX_USAGE
        }

        switch command {
        case .help:
            Console.out(Usage.help)
            return EXIT_SUCCESS
        case .version:
            Console.out("\(name) \(version)")
            return EXIT_SUCCESS
        case .scan(let port):
            return await ScanCommand.run(port: port)
        case .run(let options):
            return await RunCommand.run(options)
        }
    }
}

/// Writes whole lines to standard output or standard error.
enum Console {
    static func out(_ line: String) {
        print(line)
    }

    static func error(_ line: String) {
        fputs(line + "\n", stderr)
    }
}
