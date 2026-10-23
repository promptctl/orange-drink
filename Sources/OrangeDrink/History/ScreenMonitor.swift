import AppKit
import os

/// What can keep a person from seeing the screen. Several hold at once: a locked screen whose
/// display then sleeps is both.
enum ScreenHider: String, CaseIterable, Sendable {
    case displayAsleep, systemAsleep, locked, screenSaver, switchedOut
}

/// [LAW:effects-at-boundaries] The one edge that listens for what the screen is doing.
enum ScreenMonitor {
    /// One hider's start and end, posted on the workspace's center or the distributed one.
    struct Signal: Sendable {
        enum Center: Sendable { case workspace, distributed }
        let hider: ScreenHider
        let center: Center
        let starts: Notification.Name
        let ends: Notification.Name
    }

    /// [LAW:one-source-of-truth] The one table of what hides the screen and what ends it.
    static let signals: [Signal] = [
        Signal(hider: .displayAsleep, center: .workspace, starts: NSWorkspace.screensDidSleepNotification, ends: NSWorkspace.screensDidWakeNotification),
        // On wake, didWake comes before the displays do, so system sleep is a row of its own.
        Signal(hider: .systemAsleep, center: .workspace, starts: NSWorkspace.willSleepNotification, ends: NSWorkspace.didWakeNotification),
        Signal(hider: .switchedOut, center: .workspace, starts: NSWorkspace.sessionDidResignActiveNotification, ends: NSWorkspace.sessionDidBecomeActiveNotification),
        Signal(hider: .locked, center: .distributed, starts: Notification.Name("com.apple.screenIsLocked"), ends: Notification.Name("com.apple.screenIsUnlocked")),
        Signal(hider: .screenSaver, center: .distributed, starts: Notification.Name("com.apple.screensaver.didstart"), ends: Notification.Name("com.apple.screensaver.didstop")),
    ]

    /// The hiders in force, each time that set changes. It starts empty and unsent: a launched app
    /// has someone in front of it. Nothing is polled: the system posts every start and end.
    static func hidden(_ signals: [Signal] = signals, workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
                       distributed: DistributedNotificationCenter = .default()) -> AsyncStream<Set<ScreenHider>> {
        AsyncStream { continuation in
            let fold = HiderFold(signals, continuation: continuation)
            for signal in signals {
                for name in [signal.starts, signal.ends] {
                    switch signal.center {
                    case .workspace: workspace.addObserver(fold, selector: #selector(HiderFold.received), name: name, object: nil)
                    // NSApplication suspends distributed delivery while the app is inactive, and this
                    // menu-bar app nearly always is: held back, a lock would arrive after its pill timed out.
                    case .distributed:
                        distributed.addObserver(fold, selector: #selector(HiderFold.received), name: name, object: nil, suspensionBehavior: .deliverImmediately)
                    }
                }
            }
            let centers: [NotificationCenter] = [workspace, distributed]
            continuation.onTermination = { _ in centers.forEach { $0.removeObserver(fold) } }
        }
    }

    /// true when the displays wake, false when they sleep: the `displayAsleep` row of `hidden`, sent
    /// only when it flips. It starts awake, as `hidden` does.
    static func changes(_ hidden: AsyncStream<Set<ScreenHider>> = hidden()) -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let task = Task {
                var on = true
                // The displays flip when "asleep" comes to equal "on": asleep while on, or awake while off.
                for await hiders in hidden where hiders.contains(.displayAsleep) == on {
                    on.toggle()
                    continuation.yield(on)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Each time displays are added, removed, or rearranged.
    static func layout(_ center: NotificationCenter = .default) -> AsyncStream<Void> {
        AsyncStream { continuation in
            // NSObjectProtocol tokens are not Sendable; it is only handed back to the center that issued it.
            nonisolated(unsafe) let observer = center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
                continuation.yield()
            }
            continuation.onTermination = { _ in center.removeObserver(observer) }
        }
    }
}

/// Folds the table's notifications into the set of hiders in force, sending the set on each change.
private final class HiderFold: NSObject, Sendable {
    private let moves: [Notification.Name: (hider: ScreenHider, hides: Bool)]
    private let hidden = OSAllocatedUnfairLock(initialState: Set<ScreenHider>())
    private let continuation: AsyncStream<Set<ScreenHider>>.Continuation

    init(_ signals: [ScreenMonitor.Signal], continuation: AsyncStream<Set<ScreenHider>>.Continuation) {
        moves = Dictionary(uniqueKeysWithValues: signals.flatMap { [($0.starts, ($0.hider, true)), ($0.ends, ($0.hider, false))] })
        self.continuation = continuation
    }

    @objc func received(_ note: Notification) {
        // Observed only under the table's names, so every arrival has a row.
        let move = moves[note.name]!
        // Sent under the lock, so two centers' posts reach the stream in the order they changed the set.
        hidden.withLock { hiders in
            let changed = move.hides ? hiders.insert(move.hider).inserted : hiders.remove(move.hider) != nil
            if changed { continuation.yield(hiders) }
        }
    }
}
