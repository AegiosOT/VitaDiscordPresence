import Darwin
import DiscordIPC
import Foundation

/// Talks to Discord through `vitapresence-discord`. This process never opens the IPC socket.
///
/// `connect` starts the helper. `disconnect` tells it to exit and waits until that process is gone, killing
/// it if it lingers. Discord pins whichever process macOS calls responsible for the connection, and drops
/// the card when that process ends. The helper is started so it is responsible for itself. A normal child
/// would be pinned to this menu-bar app, and the card would stay up after the helper exited.
actor DiscordHelperClient: DiscordPresenceSink {
    private let executable: URL?
    private let socketPath: String?
    private let replyTimeout: Duration

    private var helperPID: pid_t?
    private var exitSource: DispatchSourceProcess?
    private var input: FileHandle?
    private var reader: Task<Void, Never>?
    private var clientID: String?
    private var user: DiscordUser?
    private var ready = false
    private var inbox: [DiscordHelperEvent] = []
    private var waiters: [Waiter] = []

    private struct Waiter {
        var id: UUID
        var continuation: CheckedContinuation<DiscordHelperEvent, any Error>
    }

    /// - Parameters:
    ///   - executable: The helper binary. `nil` uses `vitapresence-discord` beside this app's executable.
    ///   - socketPath: A single Discord socket for tests. `nil` lets the helper search the usual paths.
    init(executable: URL? = nil, socketPath: String? = nil, replyTimeout: Duration = .seconds(12)) {
        self.executable = executable
        self.socketPath = socketPath
        self.replyTimeout = replyTimeout
    }

    /// `true` while the helper process is still running and Discord has answered READY.
    var isHelperRunning: Bool {
        guard let helperPID else { return false }
        return kill(helperPID, 0) == 0
    }

    /// `true` when Discord would pin the helper, not this app. Exiting the helper can then drop the card.
    func helperStandsAlone() -> Bool {
        guard let helperPID, let responsible = Responsibility.pid(for: helperPID) else { return false }
        return responsible == helperPID
    }

    func connect(clientID: String) async throws -> DiscordUser {
        try await connect(clientID: clientID, activity: nil)
    }

    func connect(clientID: String, activity: DiscordActivity?) async throws -> DiscordUser {
        if activity == nil, isHelperRunning, ready, self.clientID == clientID, let user {
            return user
        }
        if helperPID != nil {
            await disconnect()
        }
        try launch()
        try send(.connect(clientID: clientID, socket: socketPath, activity: activity))
        let event = try await nextEvent()
        switch event.evt {
        case "ready":
            guard let user = event.user else {
                throw DiscordIPCError.protocolViolation("ready without a user")
            }
            self.user = user
            self.clientID = clientID
            ready = true
            return user
        case "error":
            throw event.error ?? .io("Discord helper failed")
        default:
            throw DiscordIPCError.protocolViolation("unexpected helper event \(event.evt)")
        }
    }

    func setActivity(_ activity: DiscordActivity?) async throws {
        guard isHelperRunning, ready else { throw DiscordIPCError.notConnected }
        try send(.setActivity(activity))
        let event = try await nextEvent()
        switch event.evt {
        case "activity":
            return
        case "error":
            let error = event.error ?? DiscordIPCError.io("Discord helper failed")
            if case .rpcError = error {} else { ready = false }
            throw error
        default:
            throw DiscordIPCError.protocolViolation("unexpected helper event \(event.evt)")
        }
    }

    /// Asks the helper to exit. Discord clears the presence because that process ends, so no empty activity
    /// is sent.
    func disconnect() async {
        guard let pid = helperPID else { return }
        ready = false
        user = nil
        clientID = nil
        failWaiters(DiscordIPCError.notConnected)
        try? send(.quit())
        let exited = await reap(pid, within: .seconds(1))
        if !exited {
            kill(pid, SIGKILL)
            _ = await reap(pid, within: .milliseconds(300))
        }
        if helperPID == pid {
            forget(pid: pid)
        }
    }

    var isConnected: Bool {
        ready && isHelperRunning
    }

    // MARK: Process

    private func launch() throws {
        signal(SIGPIPE, SIG_IGN)
        let url = try resolveExecutable()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let pid = try spawn(url, input: inputPipe, output: outputPipe)
        helperPID = pid
        input = inputPipe.fileHandleForWriting
        let output = outputPipe.fileHandleForReading
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler {
            source.cancel()
            _ = waitpid(pid, nil, WNOHANG)
            Task { self.didExit(pid: pid) }
        }
        source.resume()
        exitSource = source
        reader = Task { [output] in
            do {
                for try await line in output.bytes.lines {
                    guard let event = try? JSONDecoder().decode(DiscordHelperEvent.self, from: Data(line.utf8))
                    else { continue }
                    self.deliver(event)
                }
            } catch {
                // The helper closed its output.
            }
            self.didExit(pid: pid)
        }
    }

    /// Starts the helper as its own responsible process. Discord then follows that pid, not this app.
    private func spawn(_ url: URL, input: Pipe, output: Pipe) throws -> pid_t {
        let stdinRead = input.fileHandleForReading.fileDescriptor
        let stdinWrite = input.fileHandleForWriting.fileDescriptor
        let stdoutRead = output.fileHandleForReading.fileDescriptor
        let stdoutWrite = output.fileHandleForWriting.fileDescriptor
        let devNull = open("/dev/null", O_WRONLY)
        defer { if devNull >= 0 { close(devNull) } }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw DiscordIPCError.io("Could not start the Discord helper")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else {
            throw DiscordIPCError.io("Could not start the Discord helper")
        }
        defer { posix_spawnattr_destroy(&attr) }

        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        guard posix_spawnattr_setflags(&attr, flags) == 0,
              posix_spawnattr_setpgroup(&attr, 0) == 0,
              Responsibility.disclaim(&attr)
        else {
            throw DiscordIPCError.io("Could not start the Discord helper")
        }

        func step(_ rc: Int32) throws {
            if rc != 0 { throw DiscordIPCError.io("Could not start the Discord helper") }
        }
        try step(posix_spawn_file_actions_adddup2(&actions, stdinRead, STDIN_FILENO))
        try step(posix_spawn_file_actions_adddup2(&actions, stdoutWrite, STDOUT_FILENO))
        if devNull >= 0 {
            try step(posix_spawn_file_actions_adddup2(&actions, devNull, STDERR_FILENO))
        }
        try step(posix_spawn_file_actions_addclose(&actions, stdinRead))
        try step(posix_spawn_file_actions_addclose(&actions, stdinWrite))
        try step(posix_spawn_file_actions_addclose(&actions, stdoutRead))
        try step(posix_spawn_file_actions_addclose(&actions, stdoutWrite))
        if devNull >= 0 {
            try step(posix_spawn_file_actions_addclose(&actions, devNull))
        }

        var pid: pid_t = 0
        let path = url.path
        let rc: Int32 = path.withCString { cPath in
            guard let arg0 = strdup(cPath) else { return Int32(errno) }
            defer { free(arg0) }
            var argv: [UnsafeMutablePointer<CChar>?] = [arg0, nil]
            return posix_spawn(&pid, cPath, &actions, &attr, &argv, environ)
        }
        guard rc == 0, pid > 0 else {
            throw DiscordIPCError.io("Could not start the Discord helper")
        }
        // The child has its own copies. Closing these makes stdout reach EOF when the helper exits.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        return pid
    }

    /// Waits until `pid` has been reaped, or `limit` runs out. `true` when it has exited.
    private func reap(_ pid: pid_t, within limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid { return true }
            if kill(pid, 0) != 0 { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        var status: Int32 = 0
        return waitpid(pid, &status, WNOHANG) == pid || kill(pid, 0) != 0
    }

    private func forget(pid: pid_t) {
        guard helperPID == pid else { return }
        helperPID = nil
        input = nil
        exitSource?.cancel()
        exitSource = nil
        reader?.cancel()
        reader = nil
    }

    private func resolveExecutable() throws -> URL {
        if let executable {
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw DiscordIPCError.io("The Discord helper is missing")
            }
            return executable
        }
        guard let main = Bundle.main.executableURL else {
            throw DiscordIPCError.io("The Discord helper is missing")
        }
        let beside = main.deletingLastPathComponent().appendingPathComponent("vitapresence-discord")
        guard FileManager.default.isExecutableFile(atPath: beside.path) else {
            throw DiscordIPCError.io("The Discord helper is missing")
        }
        return beside
    }

    private func send(_ command: DiscordHelperCommand) throws {
        guard let input else { throw DiscordIPCError.notConnected }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(command)
        line.append(0x0A)
        do {
            try input.write(contentsOf: line)
        } catch {
            throw DiscordIPCError.io("The Discord helper stopped")
        }
    }

    private func deliver(_ event: DiscordHelperEvent) {
        if waiters.isEmpty {
            inbox.append(event)
        } else {
            waiters.removeFirst().continuation.resume(returning: event)
        }
    }

    private func nextEvent() async throws -> DiscordHelperEvent {
        try await withThrowingTaskGroup(of: DiscordHelperEvent.self) { group in
            group.addTask { try await self.waitForEvent() }
            group.addTask {
                try await Task.sleep(for: self.replyTimeout)
                throw DiscordIPCError.timedOut
            }
            defer { group.cancelAll() }
            guard let event = try await group.next() else { throw DiscordIPCError.timedOut }
            return event
        }
    }

    private func waitForEvent() async throws -> DiscordHelperEvent {
        if !inbox.isEmpty { return inbox.removeFirst() }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Drops one waiter when its timeout task is cancelled, without touching a newer command's waiter.
    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func failWaiters(_ error: any Error) {
        let pending = waiters
        waiters.removeAll()
        inbox.removeAll()
        for waiter in pending {
            waiter.continuation.resume(throwing: error)
        }
    }

    private func didExit(pid: Int32) {
        guard helperPID == pid else { return }
        ready = false
        user = nil
        clientID = nil
        _ = waitpid(pid, nil, WNOHANG)
        forget(pid: pid)
        failWaiters(DiscordIPCError.notConnected)
    }
}

/// macOS attributes a child to the app that spawned it. Discord pins that app, so the helper has to be
/// disclaimed or "Playing VitaPresence" stays up after the helper exits.
private enum Responsibility {
    static func disclaim(_ attr: UnsafeMutablePointer<posix_spawnattr_t?>) -> Bool {
        guard let function = disclaimFunction else { return false }
        return function(attr, 1) == 0
    }

    static func pid(for pid: pid_t) -> pid_t? {
        guard let function = responsibleFunction else { return nil }
        let responsible = function(pid)
        return responsible > 0 ? responsible : nil
    }

    private static let disclaimFunction: (@convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, UInt32) -> Int32)? = {
        guard let symbol = dlsym(
            UnsafeMutableRawPointer(bitPattern: -2),
            "responsibility_spawnattrs_setdisclaim"
        ) else { return nil }
        return unsafeBitCast(
            symbol,
            to: (@convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, UInt32) -> Int32).self
        )
    }()

    private static let responsibleFunction: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(
            UnsafeMutableRawPointer(bitPattern: -2),
            "responsibility_get_pid_responsible_for_pid"
        ) else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()
}
