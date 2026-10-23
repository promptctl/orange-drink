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

    /// What the system says right now about each hider it can be asked about: whether the session is
    /// locked or off the console, and whether the main display sleeps. The screen saver and system
    /// sleep cannot be asked.
    static func asked() -> [ScreenHider: Bool] {
        asked(session: CGSessionCopyCurrentDictionary() as? [String: Any], mainDisplayAsleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0)
    }

    static func asked(session: [String: Any]?, mainDisplayAsleep: Bool) -> [ScreenHider: Bool] {
        // [LAW:no-silent-failure] An app with a menu bar item has a window-server session; one without
        // is logged, and the system has no word on the lock.
        if session == nil { log.error("no window-server session to ask whether the screen is locked") }
        let said: [ScreenHider: Bool] = session.map {
            [.locked: $0["CGSSessionScreenIsLocked"] as? Bool == true, .switchedOut: $0[kCGSessionOnConsoleKey] as? Bool == false]
        } ?? [:]
        return said.merging([.displayAsleep: mainDisplayAsleep]) { $1 }
    }

    /// The hiders in force: first those `ask` says hold that the table can end, then the set each time
    /// it changes. Nothing is polled: the system posts every start and end, and is asked again at each.
    static func hidden(_ signals: [Signal] = signals, ask: @escaping @Sendable () -> [ScreenHider: Bool] = { asked() }, workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
                       distributed: DistributedNotificationCenter = .default()) -> AsyncStream<Set<ScreenHider>> {
        AsyncStream { continuation in
            let fold = HiderFold(signals, ask: ask, continuation: continuation)
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
            // misses arrives after it.
            fold.start()
        }
    }

    /// true when the displays wake, false when they sleep: the `displayAsleep` row of `hidden`, sent
    /// only when it flips from awake, where battery history starts.
    static func changes(_ hidden: AsyncStream<Set<ScreenHider>> = hidden(signals.filter { $0.hider == .displayAsleep })) -> AsyncStream<Bool> {
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
    private let ask: @Sendable () -> [ScreenHider: Bool]
    private let hidden: OSAllocatedUnfairLock<Set<ScreenHider>>
    private let continuation: AsyncStream<Set<ScreenHider>>.Continuation

    init(_ signals: [ScreenMonitor.Signal], ask: @escaping @Sendable () -> [ScreenHider: Bool], continuation: AsyncStream<Set<ScreenHider>>.Continuation) {
        moves = Dictionary(uniqueKeysWithValues: signals.flatMap { [($0.starts, ($0.hider, true)), ($0.ends, ($0.hider, false))] })
        self.ask = ask
        hidden = OSAllocatedUnfairLock(initialState: [])
        self.continuation = continuation
    }

    /// Takes the hiders in force from the system and sends them: under the lock, so a post arriving
    /// while it asks is folded in after the answer. A hider with no row could never end, so it does not
    /// start in force either.
    func start() {
        let rows = Set(moves.values.map(\.hider))
        hidden.withLock { hiders in
            hiders = Set(ask().filter(\.value).keys).intersection(rows)
            continuation.yield(hiders)
        }
    }

    @objc func received(_ note: Notification) {
        // Observed only under the table's names, so every arrival has a row.
        let move = moves[note.name]!
        // Sent under the lock, so two centers' posts reach the stream in the order they changed the set.
        hidden.withLock { hiders in
            let before = hiders
            if move.hides { hiders.insert(move.hider) } else { hiders.remove(move.hider) }
            // [LAW:one-source-of-truth] An end the app never heard would hold every later pill for good, so
            // the system's word ends any hider it says is over. Not the one this post moves, which the
            // system may not have caught up with; and its word never starts one.
            hiders.subtract(ask().filter { !$0.value && $0.key != move.hider }.keys)
            if hiders != before { continuation.yield(hiders) }
        }
    }
}
