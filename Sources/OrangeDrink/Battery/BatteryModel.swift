import Observation

/// The app's one battery subscription and the state every view reads from it.
///
/// [LAW:one-source-of-truth] One subscription per process, held from launch: views derive
/// from this and never read IOKit themselves, and the CPU check measures the app with it live.
@Observable @MainActor final class BatteryModel {
    /// [LAW:types-are-the-program] A view can tell "no reading yet" from "no battery" from
    /// "the subscription ended", so none of them is a stale reading in disguise.
    enum State {
        case unknown
        /// The latest reading; nil is a Mac with no battery.
        case known(BatteryReading?)
        /// The subscription ended with this error, and no reading will follow it.
        case unavailable(any Error)
    }

    private(set) var state: State = .unknown

    init() {
        // [LAW:no-ambient-temporal-coupling] The app owns the model for the process lifetime.
        // The task holds the model weakly, so a model that is dropped (a test's) ends its
        // stream at the next publish instead of keeping itself alive through it.
        Task { [weak self] in
            do {
                for try await reading in BatteryMonitor.readings() {
                    guard let self else { return }
                    self.state = .known(reading)
                }
            } catch {
                IOKitBattery.log.error("battery subscription ended: \(String(describing: error), privacy: .public)")
                self?.state = .unavailable(error)
            }
        }
    }

}
