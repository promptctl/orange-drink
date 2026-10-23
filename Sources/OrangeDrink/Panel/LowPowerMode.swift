import Foundation
import Observation
import OSLog
import ServiceManagement

/// macOS Low Power Mode, as the panel's switch and the L key show and change it.
///
/// [LAW:one-source-of-truth] The system holds the state. `isOn` is its live copy, read at init and again at
/// each power-state change the system posts, and nothing else writes it. So a change asked for here shows
/// once the system has made it, exactly as a change made in System Settings does.
@Observable @MainActor final class LowPowerMode {
    /// What happened, as the log and the tests read it.
    enum Event: Equatable {
        /// A change was asked of the helper: nil failure once it happened, or why it did not.
        case asked(Bool, failure: HelperUseFailure?)
        /// The system posted a change, and this is its state now.
        case changed(Bool)
        /// The user took the way the row offers to allow the helper.
        case openedLoginItems

        /// [LAW:effects-at-boundaries] The log line, a pure function of the event.
        var line: String {
            switch self {
            case .asked(let on, nil): "low power mode \(on ? "on" : "off"): done"
            case .asked(let on, let failure?): "low power mode \(on ? "on" : "off") failed: \(failure.description)"
            case .changed(let on): "low power mode is \(on ? "on" : "off")"
            case .openedLoginItems: "opened Login Items & Extensions to allow the helper"
            }
        }
    }

    /// [LAW:one-source-of-truth] What the row says under the switch about a failure, as the panel shows it and the
    /// catalog test reads it: how to fix one the user can fix, what went wrong otherwise.
    static func explanation(of failure: HelperUseFailure, appName: String) -> Phrase {
        failure.needsApproval ? "Allow \(appName) in the background to change Low Power Mode." : "Couldn't change Low Power Mode: \(failure.call.description)"
    }

    /// The row's way to the setting that allows the helper.
    static let openLoginItemsTitle: Phrase = "Open Login Items & Extensions…"

    private(set) var isOn: Bool
    /// [LAW:no-ambient-temporal-coupling] Whether a change asked of the helper is unanswered: from a press to that
    /// call's reply, and nothing else ends it. Meanwhile a press does nothing, so one call is in flight and its
    /// reply is the only one there is to land.
    private(set) var isAsking = false
    /// Why the last change asked for did not happen, while the panel that shows it is open; nil once a change has
    /// happened, the system has moved, or the panel has closed, since the user may have fixed it meanwhile.
    private(set) var failure: HelperUseFailure?

    @ObservationIgnored private let read: () -> Bool
    @ObservationIgnored private let write: @Sendable (Bool) throws(HelperUseFailure) -> Void
    @ObservationIgnored private let record: (Event) -> Void
    @ObservationIgnored private let openLoginItemsPane: () -> Void

    private static let log = Logger(subsystem: IOKitBattery.logSubsystem, category: "lowPowerMode")

    /// [LAW:composability] `read` is the system's state, `center` posts its changes, `write` asks for a state
    /// and throws when it did not happen, `record` is told each event, and `openLoginItems` shows the setting that
    /// allows the helper. The app passes ProcessInfo, the default center, the helper, the log, and System Settings.
    init(read: @escaping () -> Bool, center: NotificationCenter, write: @escaping @Sendable (Bool) throws(HelperUseFailure) -> Void,
         record: @escaping (Event) -> Void = { event in LowPowerMode.log.notice("\(event.line, privacy: .public)") },
         openLoginItems: @escaping () -> Void = { SMAppService.openSystemSettingsLoginItems() }) {
        self.read = read
        self.write = write
        self.record = record
        openLoginItemsPane = openLoginItems
        isOn = read()
        // The observer lives as long as the center; the app's model lives as long as the app.
        _ = center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    convenience init(helper: HelperAccess) {
        self.init(read: { ProcessInfo.processInfo.isLowPowerModeEnabled }, center: .default) { on throws(HelperUseFailure) in
            try helper.setLowPowerMode(on)
        }
    }

    /// Asks for the other of the state the switch shows, unless an ask is still unanswered. The switch is what the
    /// user is looking at when they press, even when the system has not yet posted the last write's change. The
    /// call blocks until the helper replies, so it runs on a dispatch thread, never one of the concurrency pool's;
    /// the returned task ends at the reply.
    @discardableResult func toggle() -> Task<Void, Never> {
        guard !isAsking else { return Task {} }
        let wanted = !isOn, write = write
        isAsking = true
        return Task {
            let outcome = await withCheckedContinuation { asked in
                DispatchQueue.global().async { asked.resume(returning: Result { () throws(HelperUseFailure) in try write(wanted) }) }
            }
            let failure = outcome.failure
            // [LAW:no-silent-failure] The panel shows why under the switch, which stays where the system is.
            self.failure = failure
            isAsking = false
            record(.asked(wanted, failure: failure))
        }
    }

    /// Opens Login Items & Extensions, where the user allows the helper.
    func openLoginItems() {
        openLoginItemsPane()
        record(.openedLoginItems)
    }

    /// The panel closed: the failure it showed is forgotten, so a reopened panel does not repeat advice the user may
    /// have taken meanwhile; the log keeps it.
    func panelDidClose() {
        failure = nil
    }

    private func refresh() {
        isOn = read()
        failure = nil
        record(.changed(isOn))
    }
}
