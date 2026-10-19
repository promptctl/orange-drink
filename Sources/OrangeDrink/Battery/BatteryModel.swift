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
    /// [LAW:types-are-the-program] exception: set once, in init, but Swift will not let the
    /// task capture `self` before every stored property holds a value, so it cannot be a let.
    /// Written on the main actor and read only by deinit, which no other access can overlap;
    /// an isolated deinit would say so in the type, and needs macOS 15.
    @ObservationIgnored nonisolated(unsafe) private var subscription: Task<Void, Never>?

    /// [LAW:composability] The model mirrors whatever readings it is given: the app hands it
    /// `BatteryMonitor.readings()`, a test a recorded stream with no powerd in the room.
    init<Readings: AsyncSequence & Sendable>(readings: Readings) where Readings.Element == BatteryReading? {
        // [LAW:no-ambient-temporal-coupling] The model owns the subscription: it lives exactly
        // as long as the model does, and a dropped model cancels it before the next publish
        // rather than letting the task keep the model alive through it.
        subscription = Task { [weak self] in
            do {
                for try await reading in readings {
                    guard let self else { return }
                    self.state = .known(reading)
                }
            } catch {
                IOKitBattery.log.error("battery subscription ended: \(String(describing: error), privacy: .public)")
                self?.state = .unavailable(error)
            }
        }
    }

    deinit { subscription?.cancel() }
}
