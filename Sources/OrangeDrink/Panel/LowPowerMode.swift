import Foundation
import Observation
import OSLog

/// macOS Low Power Mode, as the panel's switch and the L key show and change it.
///
/// [LAW:one-source-of-truth] The system holds the state. `isOn` is its live copy, read at init and again at
/// each power-state change the system posts, and nothing else writes it. So a change asked for here shows
/// once the system has made it, exactly as a change made in System Settings does.
@Observable @MainActor final class LowPowerMode {
    private(set) var isOn: Bool
    /// Why the last change asked for did not happen; nil once one has.
    private(set) var failure: String?

    @ObservationIgnored private let read: () -> Bool
    @ObservationIgnored private let write: @Sendable (Bool) throws -> Void
    @ObservationIgnored private var changes: (any NSObjectProtocol)?

    private static let log = Logger(subsystem: IOKitBattery.logSubsystem, category: "lowPowerMode")

    /// The helper's deadline for one change, the one its live check gives every call.
    nonisolated static let deadline = 10

    /// [LAW:composability] `read` is the system's state, `center` posts its changes, and `write` asks for a
    /// state, throwing when it did not happen. The app passes ProcessInfo, the default center, and the helper.
    init(read: @escaping () -> Bool, center: NotificationCenter, write: @escaping @Sendable (Bool) throws -> Void) {
        self.read = read
        self.write = write
        isOn = read()
        changes = center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    convenience init(helper: HelperClient) {
        self.init(read: { ProcessInfo.processInfo.isLowPowerModeEnabled }, center: .default) { on in
            try helper.setLowPowerMode(on, within: Self.deadline)
        }
    }

    /// Asks for the other state, off the main thread since the call blocks until the helper replies. The
    /// returned task ends once the answer is in; `isOn` moves when the system posts the change.
    @discardableResult func toggle() -> Task<Void, Never> {
        let wanted = !isOn, write = write
        return Task {
            let outcome = await Task.detached { Result { try write(wanted) } }.value
            switch outcome {
            case .success:
                Self.log.notice("low power mode \(wanted ? "on" : "off", privacy: .public): done")
                failure = nil
            case .failure(let error):
                // [LAW:no-silent-failure] The panel shows why under the switch, which stays where the system is.
                Self.log.error("low power mode \(wanted ? "on" : "off", privacy: .public) failed: \(String(describing: error), privacy: .public)")
                failure = String(describing: error)
            }
        }
    }

    private func refresh() {
        isOn = read()
        Self.log.notice("low power mode is \(self.isOn ? "on" : "off", privacy: .public)")
    }
}
