import Observation

/// The app's one battery subscription and the state every view reads from it.
///
/// [LAW:one-source-of-truth] One subscription per process, held from launch: views derive
/// from this and never read IOKit themselves, and the CPU check measures the app with it live.
@Observable @MainActor final class BatteryModel {
    /// [LAW:types-are-the-program] A view can tell "no reading yet" from "no battery" from
    /// "no more readings", so none of them is a stale reading in disguise.
    enum State {
        case unknown
        /// The latest reading; nil is a Mac with no battery.
        case known(BatteryReading?)
        /// No reading will follow: the stream threw this error, or finished when it is nil.
        case ended((any Error)?)
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
            let ending: (any Error)?
            do {
                for try await reading in readings {
                    guard let self else { return }
                    self.state = .known(reading)
                }
                ending = nil
            } catch {
                ending = error
            }
            // A dropped model cancelled the stream itself, so its ending is no event.
            guard let self else { return }
            let reason = ending.map { String(describing: $0) } ?? "the stream finished"
            IOKitBattery.log.error("battery subscription ended: \(reason, privacy: .public)")
            self.state = .ended(ending)
        }
    }

    deinit { subscription?.cancel() }
}
