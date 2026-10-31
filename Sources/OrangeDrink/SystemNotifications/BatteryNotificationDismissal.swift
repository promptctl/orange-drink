import AppKit
import ApplicationServices
import IOKit.ps
import Observation
import OSLog

/// Closes macOS's low battery notification while the General screen's switch is on. Anything going wrong leaves it showing,
/// which is the safe way to fail, and says why in the log.
///
/// Nothing here runs on a timer, for PROJECT.md's 0.1% CPU bar: it wakes when powerd changes the warning level, the switch
/// moves, or the app is activated, and it watches NotificationCenter only during a warning.
///
/// [LAW:one-source-of-truth] The level and trust are the system's, and every pass reads them.
@Observable @MainActor final class BatteryNotificationDismissal {
    /// One warning, from the pass that wants it to the pass that does not.
    enum Episode: Equatable {
        case idle
        case watching(Set<LowBatteryWords>)
        /// A press whose result is not confirmed. It is not pressed again until the warning ends, so a layout event cannot
        /// loop it, and the look goes on saying what is showing.
        case stuck(Set<LowBatteryWords>)
        case cannotRecognise(LowBatteryTables.Failure)

        fileprivate var name: String {
            switch self {
            case .idle: "idle"
            case .watching: "watching"
            case .stuck: "stuck"
            case .cannotRecognise: "cannot recognise"
            }
        }
    }

    /// What a pass did about watching NotificationCenter.
    enum ObserverChange: Equatable {
        case unchanged, started, stopped
        case failed(AXError)

        fileprivate var name: String {
            switch self {
            case .unchanged: "unchanged"
            case .started: "started"
            case .stopped: "stopped"
            case .failed(let error): "failed with AXError \(error.rawValue)"
            }
        }
    }

    /// A look's counts. Notifications' words stay out of the log: they can be another app's.
    struct Seen: Equatable {
        let shown: Int
        let refused: [Refusal: Int]

        init(_ verdicts: [Verdict]) {
            shown = verdicts.count
            refused = verdicts.reduce(into: [:]) { counts, verdict in
                if case .refused(let refusal) = verdict { counts[refusal, default: 0] += 1 }
            }
        }

        fileprivate var line: String {
            "shown \(shown)" + Refusal.allCases.compactMap { refused[$0].map { [name = $0.rawValue] in ", refused \(name) \($0)" } }.joined()
        }
    }

    enum CloseFailure: Equatable {
        case press(AXError)
        case stayed
        case secondLook(LookFailure)

        fileprivate var reason: String {
            switch self {
            case .press(let error): "the press returned AXError \(error.rawValue)"
            case .stayed: "still showing after \(BatteryNotificationDismissal.closeDeadline)"
            case .secondLook(let failure): "the look after the press failed: \(failure.reason)"
            }
        }
    }

    enum Outcome: Equatable {
        case notWanted
        case cannotRecognise(LowBatteryTables.Failure)
        case looked(Seen)
        case lookFailed(LookFailure)
        case closed
        case closeFailed(CloseFailure)

        fileprivate var line: String {
            switch self {
            case .notWanted: "not wanted"
            case .cannotRecognise(let failure): "cannot recognise: \(failure.reason)"
            case .looked(let seen): "looked: \(seen.line)"
            case .lookFailed(let failure): "look failed: \(failure.reason)"
            case .closed: "closed"
            case .closeFailed(let failure): "close failed: \(failure.reason)"
            }
        }
    }

    /// [LAW:nothing-unseen] One record for one pass, whichever way it went, so "off", "untrusted", "no warning", "looked and
    /// found nothing", and "never ran" are told apart from the log alone.
    struct Pass: Equatable {
        let level: IOPSLowBatteryWarningLevel
        let isOn: Bool
        let trusted: Bool
        let episode: Episode
        let observer: ObserverChange
        let outcome: Outcome
    }

    enum Event: Equatable {
        case pass(Pass)
        /// The switch went on. `prompted` is whether the app was untrusted, so macOS was asked to prompt.
        case askedForTrust(prompted: Bool)
        case openedAccessibility
        case noWarningChanges(String)

        /// [LAW:effects-at-boundaries] The log line, a pure function of the event. scripts/battery-notification-check reads
        /// `pass: `, `switch on, trusted`, and `, closed`.
        var line: String {
            switch self {
            case .pass(let pass):
                "pass: level \(pass.level.rawValue), switch \(pass.isOn ? "on" : "off"), \(pass.trusted ? "trusted" : "untrusted"), "
                    + "\(pass.episode.name), observer \(pass.observer.name), \(pass.outcome.line)"
            case .askedForTrust(let prompted): "switch on: \(prompted ? "asked macOS to prompt for Accessibility" : "already trusted")"
            case .openedAccessibility: "opened Accessibility to allow the app"
            case .noWarningChanges(let error): "no low battery notifications: \(error)"
            }
        }
    }

    /// NotificationCenter being watched, and how to stop.
    struct Observer: Sendable {
        let pid: pid_t
        let stop: @Sendable () -> Void
    }

    /// The system calls a pass makes, as one seam. Each crosses a process, so `pass` makes every one through `blocking`.
    struct Effects: Sendable {
        let level: @Sendable () -> IOPSLowBatteryWarningLevel
        /// AXIsProcessTrustedWithOptions, whose option decides whether an untrusted app is prompted.
        let trust: @Sendable (_ prompt: Bool) -> Bool
        let notificationCenter: @Sendable () -> pid_t?
        let windows: @Sendable (pid_t) -> ElementRead<[any AccessibleElement]>
        let observe: @Sendable (pid_t, _ onChange: @escaping @Sendable () -> Void) -> Result<Observer, AXErrorBox>
        let tables: @Sendable () -> Result<Set<LowBatteryWords>, LowBatteryTables.Failure>
    }

    /// AXError does not conform to Error.
    struct AXErrorBox: Error {
        let error: AXError
    }

    /// Closes left the tree within 1.26 s in orange-distribution-kg2.o9e's runs.
    nonisolated static let closeDeadline = Duration.seconds(3)

    let settings: SystemNotificationSettingsModel
    /// The latest pass's answer, for the row: nil until the first pass. No decision rests on this copy.
    private(set) var trusted: Bool?

    /// While the switch is on and macOS has not trusted the app, the row says so.
    var needsAccessibility: Bool { settings.value.dismissBatteryNotifications && trusted == false }

    /// What the row says under the switch, as the screen shows it and the catalog test reads it.
    static func accessibilityExplanation(appName: String) -> Phrase {
        "Allow \(appName) in Accessibility to close them."
    }

    @ObservationIgnored private var episode = Episode.idle
    @ObservationIgnored private var observer: Observer?
    @ObservationIgnored private var wasOn: Bool
    @ObservationIgnored private let effects: Effects
    @ObservationIgnored private let timekeeper: any Timekeeper
    @ObservationIgnored private let record: (Event) -> Void
    @ObservationIgnored private let openAccessibilityPane: () -> Void
    @ObservationIgnored private let wake: AsyncStream<Void>.Continuation

    private static let log = Logger(subsystem: IOKitBattery.logSubsystem, category: "batteryNotifications")

    /// [LAW:composability] `warningChanges` wakes a pass, first at subscribing, so launch needs no wake of its own. `center`
    /// posts the app's activations. The app passes the live effects, BatteryMonitor's stream, the default center, the log,
    /// and System Settings.
    init(settings: SystemNotificationSettingsModel, effects: Effects, warningChanges: AsyncThrowingStream<Void, any Error>, center: NotificationCenter,
         timekeeper: any Timekeeper = SystemTimekeeper(),
         record: @escaping (Event) -> Void = { event in BatteryNotificationDismissal.log.notice("\(event.line, privacy: .public)") },
         openAccessibility: @escaping () -> Void = { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }) {
        self.settings = settings
        self.effects = effects
        self.timekeeper = timekeeper
        self.record = record
        openAccessibilityPane = openAccessibility
        wasOn = settings.value.dismissBatteryNotifications
        // [LAW:no-ambient-temporal-coupling] One consumer, so passes never overlap, and a burst of wakes while one runs is
        // one more pass.
        let (wakes, wake) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.wake = wake
        Task { [weak self] in
            for await _ in wakes { await self?.pass() }
        }
        Task { [weak self] in
            do {
                for try await _ in warningChanges { wake.yield() }
            } catch {
                self?.record(.noWarningChanges(String(describing: error)))
            }
        }
        // The observer lives as long as the center; the app's model lives as long as the app.
        _ = center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in wake.yield() }
        follow()
    }

    deinit { wake.finish() }

    /// Opens Accessibility in System Settings, where the user allows the app.
    func openAccessibility() {
        openAccessibilityPane()
        record(.openedAccessibility)
    }

    /// Follows the stored switch. Only its going from off to on prompts, so a launch with it stored on never does.
    private func follow() {
        let isOn = withObservationTracking { settings.value.dismissBatteryNotifications } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        guard isOn != wasOn else { return }
        wasOn = isOn
        let effects = effects, wake = wake
        Task {
            if isOn {
                let prompted = await blocking {
                    if effects.trust(false) { return false }
                    _ = effects.trust(true)
                    return true
                }
                record(.askedForTrust(prompted: prompted))
            }
            wake.yield()
        }
    }

    /// [LAW:dataflow-not-control-flow] Every wake runs these same steps: what the level, trust, and the switch ask for, then
    /// the observation and the episode moved to it, then whatever that episode does.
    private func pass() async {
        let effects = effects, isOn = settings.value.dismissBatteryNotifications
        let (level, trust) = await blocking { (effects.level(), effects.trust(false)) }
        trusted = trust
        let wanted = isOn && trust && level != kIOPSLowBatteryWarningNone
        let pid = wanted ? await blocking { effects.notificationCenter() } : nil
        let change = await observe(pid)
        episode = await next(wanted: wanted)
        let outcome = await act(on: pid)
        record(.pass(Pass(level: level, isOn: isOn, trusted: trust, episode: episode, observer: change, outcome: outcome)))
    }

    /// One comparison covers starting, ending, and a NotificationCenter that restarted since the last wake. A dead process
    /// posts nothing, so the next wake finds it, and macOS raises its alert just after the level wake that does. It runs
    /// before the look, so nothing arrives between the look and the watching.
    private func observe(_ pid: pid_t?) async -> ObserverChange {
        guard pid != observer?.pid else { return .unchanged }
        let effects = effects, wake = wake, old = observer
        observer = nil
        await blocking { old?.stop() }
        guard let pid else { return .stopped }
        switch await blocking({ effects.observe(pid) { wake.yield() } }) {
        case .success(let new):
            observer = new
            return .started
        case .failure(let failure):
            return .failed(failure.error)
        }
    }

    /// The words are read as a warning starts, so an OS update cannot leave a stale copy and nothing is read outside one.
    private func next(wanted: Bool) async -> Episode {
        guard wanted else { return .idle }
        guard case .idle = episode else { return episode }
        let effects = effects
        switch await blocking({ effects.tables() }) {
        case .success(let words): return .watching(words)
        case .failure(let failure): return .cannotRecognise(failure)
        }
    }

    private func act(on pid: pid_t?) async -> Outcome {
        switch episode {
        case .idle: return .notWanted
        case .cannotRecognise(let failure): return .cannotRecognise(failure)
        case .watching(let words), .stuck(let words):
            switch await look(pid) {
            case .failure(let failure): return .lookFailed(failure)
            case .success(let shown):
                let verdicts = shown.map { $0.values.verdict(knowing: words) }
                for (notification, verdict) in zip(shown, verdicts) {
                    if case .watching = episode, case .close(let action) = verdict {
                        return await close(notification, with: action, words: words, pid: pid)
                    }
                }
                return .looked(Seen(verdicts))
            }
        }
    }

    /// [LAW:no-ambient-temporal-coupling] The one deadline, inside the pass, so nothing else moves while it runs. A press
    /// that is not confirmed gone is never repeated. One confirmed gone stays watching, so a macOS that posts again at the
    /// final warning is closed too.
    private func close(_ notification: ShownNotification, with action: String, words: Set<LowBatteryWords>, pid: pid_t?) async -> Outcome {
        let pressed = await blocking { notification.element.press(action) }
        // `invalidUIElement` is a notification gone since the look, as it is for a read, and the second look says so.
        guard pressed == .success || pressed == .invalidUIElement else { return stuck(words, .press(pressed)) }
        // This task is never cancelled, and a sleep cut short only looks sooner.
        try? await timekeeper.sleep(for: Self.closeDeadline)
        switch await look(pid) {
        case .failure(let failure): return stuck(words, .secondLook(failure))
        case .success(let shown):
            return shown.contains { $0.values.isStill(notification.values) } ? stuck(words, .stayed) : .closed
        }
    }

    private func stuck(_ words: Set<LowBatteryWords>, _ failure: CloseFailure) -> Outcome {
        episode = .stuck(words)
        return .closeFailed(failure)
    }

    private func look(_ pid: pid_t?) async -> Result<[ShownNotification], LookFailure> {
        let effects = effects
        return await blocking {
            guard let pid else { return .failure(.notRunning) }
            return NotificationCenterLook.look(windows: effects.windows(pid))
        }
    }
}
