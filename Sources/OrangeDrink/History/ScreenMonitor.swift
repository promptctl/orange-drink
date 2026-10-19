import AppKit

/// [LAW:effects-at-boundaries] The one edge that listens for the display going to sleep and waking.
enum ScreenMonitor {
    /// true when the displays wake, false when they sleep. Nothing is polled: the system posts both.
    static func changes() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let center = NSWorkspace.shared.notificationCenter
            // NSObjectProtocol tokens are not Sendable; they are only handed back to the center that issued them.
            nonisolated(unsafe) let observers = [(NSWorkspace.screensDidWakeNotification, true), (NSWorkspace.screensDidSleepNotification, false)].map { name, on in
                center.addObserver(forName: name, object: nil, queue: .main) { _ in continuation.yield(on) }
            }
            continuation.onTermination = { _ in observers.forEach(center.removeObserver) }
        }
    }
}
