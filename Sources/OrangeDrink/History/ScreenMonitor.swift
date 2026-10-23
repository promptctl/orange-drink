import AppKit
import os

/// What can keep a person from seeing the screen. Several hold at once: a locked screen whose
/// display then sleeps is both.
enum ScreenHider: String, CaseIterable, Sendable {
    case displayAsleep, systemAsleep, locked, screenSaver, switchedOut
}

/// [LAW:effects-at-boundaries] The one edge that listens for what the screen is doing.
enum ScreenMonitor {
    private static let log = Logger(subsystem: IOKitBattery.logSubsystem, category: "screen")

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

    /// What the system says hides the screen right now, as far as it can be asked: whether the session
    /// is locked or off the console, and whether the main display sleeps. The screen saver and system
    /// sleep cannot be asked, and an app that is running is awake.
    static func asked() -> Set<ScreenHider> {
        asked(session: CGSessionCopyCurrentDictionary() as? [String: Any], mainDisplayAsleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0)
    }

    static func asked(session: [String: Any]?, mainDisplayAsleep: Bool) -> Set<ScreenHider> {
        // [LAW:no-silent-failure] An app with a menu bar item has a window-server session; one without
        // is logged, and the screen is taken as seen, as at any launch.
        if session == nil { log.error("no window-server session to ask whether the screen is locked") }
        let answers: [ScreenHider: Bool] = [
            .locked: session?["CGSSessionScreenIsLocked"] as? Bool == true,
            .switchedOut: session?[kCGSessionOnConsoleKey] as? Bool == false,
            .displayAsleep: mainDisplayAsleep,
        ]
        return Set(answers.filter(\.value).keys)
    }

    /// The hiders in force: first those `ask` says hold that the table can end, then the set each time
    /// it changes. Nothing is polled: the system posts every start and end.
    static func hidden(_ signals: [Signal] = signals, ask: @Sendable () -> Set<ScreenHider> = { asked() }, workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
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
            // [LAW:no-ambient-temporal-coupling] Asked once every row is observed, so a change the answer
            // misses arrives after it. A hider with no row could never end, so it does not start in force.
            fold.start { ask().intersection(signals.map(\.hider)) }
        }
    }

    /// Whether the displays are awake: the `displayAsleep` row of `hidden`, where battery history starts.
    static func changes(_ hidden: AsyncStream<Set<ScreenHider>> = hidden(signals.filter { $0.hider == .displayAsleep }))
        -> AsyncMapSequence<AsyncStream<Set<ScreenHider>>, Bool> {
        hidden.map { !$0.contains(.displayAsleep) }
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
    private let hidden: OSAllocatedUnfairLock<Set<ScreenHider>>
    private let continuation: AsyncStream<Set<ScreenHider>>.Continuation

    init(_ signals: [ScreenMonitor.Signal], continuation: AsyncStream<Set<ScreenHider>>.Continuation) {
        moves = Dictionary(uniqueKeysWithValues: signals.flatMap { [($0.starts, ($0.hider, true)), ($0.ends, ($0.hider, false))] })
        hidden = OSAllocatedUnfairLock(initialState: [])
        self.continuation = continuation
    }

    /// Takes the hiders in force from `ask` and sends them: under the lock, so a post arriving while it
    /// asks is folded in after the answer.
    func start(_ ask: @Sendable () -> Set<ScreenHider>) {
        hidden.withLock { hiders in
            hiders = ask()
            continuation.yield(hiders)
        }
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
