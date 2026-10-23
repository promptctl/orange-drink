import Foundation
import Observation
import OSLog

/// macOS Low Power Mode, as the panel's switch and the L key show and change it.
///
/// [LAW:one-source-of-truth] The system holds the state. `isOn` is its live copy, read at init and again at
/// each power-state change the system posts, and nothing else writes it. So a change asked for here shows
/// once the system has made it, exactly as a change made in System Settings does.
@Observable @MainActor final class LowPowerMode {
    /// What happened, as the log and the tests read it.
    enum Event: Equatable {
        /// A change was asked of the helper: nil failure once it happened, or why it did not.
        case asked(Bool, failure: String?)
        /// The system posted a change, and this is its state now.
        case changed(Bool)

        /// [LAW:effects-at-boundaries] The log line, a pure function of the event.
        var line: String {
            switch self {
            case .asked(let on, nil): "low power mode \(on ? "on" : "off"): done"
            case .asked(let on, let failure?): "low power mode \(on ? "on" : "off") failed: \(failure)"
            case .changed(let on): "low power mode is \(on ? "on" : "off")"
            }
        }
    }

    private(set) var isOn: Bool
    /// [LAW:no-ambient-temporal-coupling] Whether a change asked of the helper is unanswered: from a press to that
    /// call's reply, and nothing else ends it. Meanwhile a press does nothing, so one call is in flight and its
    /// reply is the only one there is to land.
    private(set) var isAsking = false
    /// Why the last change asked for did not happen; nil once one has, or once the system has moved.
    private(set) var failure: String?

    @ObservationIgnored private let read: () -> Bool
    @ObservationIgnored private let write: @Sendable (Bool) throws -> Void
    @ObservationIgnored private let record: (Event) -> Void

    private static let log = Logger(subsystem: IOKitBattery.logSubsystem, category: "lowPowerMode")

    /// [LAW:composability] `read` is the system's state, `center` posts its changes, `write` asks for a state
    /// and throws when it did not happen, and `record` is told each event. The app passes ProcessInfo, the
    /// default center, the helper, and the log.
    init(read: @escaping () -> Bool, center: NotificationCenter, write: @escaping @Sendable (Bool) throws -> Void,
         record: @escaping (Event) -> Void = { event in LowPowerMode.log.notice("\(event.line, privacy: .public)") }) {
        self.read = read
        self.write = write
        self.record = record
        isOn = read()
        // The observer lives as long as the center; the app's model lives as long as the app.
        _ = center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    convenience init(helper: HelperClient) {
        self.init(read: { ProcessInfo.processInfo.isLowPowerModeEnabled }, center: .default) { on in
            try helper.setLowPowerMode(on)
        }
    }

    /// Asks for the other of the state the switch shows, unless an ask is still unanswered. The switch is what the
    /// user is looking at when they press, even when the system has not yet posted the last write's change. The
    /// call blocks until the helper replies, so it runs off the main thread; the returned task ends at the reply.
    @discardableResult func toggle() -> Task<Void, Never> {
        guard !isAsking else { return Task {} }
        let wanted = !isOn, write = write
        isAsking = true
        return Task {
            let outcome = await Task.detached { Result { try write(wanted) } }.value
            let failure = outcome.failure.map { String(describing: $0) }
            // [LAW:no-silent-failure] The panel shows why under the switch, which stays where the system is.
            self.failure = failure
            isAsking = false
            record(.asked(wanted, failure: failure))
        }
    }

    private func refresh() {
        isOn = read()
        failure = nil
        record(.changed(isOn))
    }
}
