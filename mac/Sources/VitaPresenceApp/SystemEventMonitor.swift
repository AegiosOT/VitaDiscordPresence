import AppKit
import Network
import os

/// Calls `onChange` on the main actor when the Mac wakes from sleep or the network becomes usable again,
/// the moments when polling the Vita right away is worth it.
final class SystemEventMonitor {
    /// Where macOS posts `NSWorkspace.didWakeNotification`.
    static var workspaceNotifications: NotificationCenter { NSWorkspace.shared.notificationCenter }

    private let notificationCenter: NotificationCenter
    private let wakeObserver: any NSObjectProtocol
    private let pathMonitor = NWPathMonitor()
    private let pathChanged: @Sendable (NWPath.Status) -> Void

    /// - Parameter notificationCenter: Where wake notifications arrive; tests pass their own center.
    init(
        notificationCenter: NotificationCenter = SystemEventMonitor.workspaceNotifications,
        onChange: @escaping @MainActor @Sendable () -> Void
    ) {
        self.notificationCenter = notificationCenter
        wakeObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { onChange() }
        }

        let lastStatus = OSAllocatedUnfairLock<NWPath.Status?>(initialState: nil)
        pathChanged = { status in
            let previous = lastStatus.withLock { last in
                defer { last = status }
                return last
            }
            if Self.becameSatisfied(from: previous, to: status) {
                Task { @MainActor in onChange() }
            }
        }
        pathMonitor.pathUpdateHandler = { [pathChanged] path in pathChanged(path.status) }
        pathMonitor.start(queue: DispatchQueue(label: "io.github.aegiosot.VitaPresence.path-monitor"))
    }

    deinit {
        notificationCenter.removeObserver(wakeObserver)
        pathMonitor.cancel()
    }

    /// Handles a network path update. The path monitor calls it; tests call it to simulate one.
    func pathDidChange(to status: NWPath.Status) {
        pathChanged(status)
    }

    /// `true` when the path turns satisfied after being unsatisfied. The first update only reports the
    /// current state, so it never counts.
    static func becameSatisfied(from previous: NWPath.Status?, to current: NWPath.Status) -> Bool {
        guard let previous else { return false }
        return previous != .satisfied && current == .satisfied
    }
}
