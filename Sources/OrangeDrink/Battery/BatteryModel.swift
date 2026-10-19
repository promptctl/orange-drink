import Foundation
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

    /// How often the readings are refreshed on their own, when nothing has pushed one.
    nonisolated static let refreshInterval = Duration.seconds(120)

    private(set) var state: State = .unknown
    /// When the latest reading was taken, by this model's clock; nil until there is one.
    private(set) var readingAt: Date?
    @ObservationIgnored private let timekeeper: any Timekeeper
    @ObservationIgnored private let read: @Sendable () throws -> BatteryReading?
    /// [LAW:types-are-the-program] exception: set once, in init, but Swift will not let the
    /// task capture `self` before every stored property holds a value, so it cannot be a let.
    /// Written on the main actor and read only by deinit, which no other access can overlap;
    /// an isolated deinit would say so in the type, and needs macOS 15.
    @ObservationIgnored nonisolated(unsafe) private var subscription: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var refresher: Task<Void, Never>?

    /// [LAW:composability] The model mirrors whatever readings it is given: the app hands it
    /// `BatteryMonitor.readings()`, a test a recorded stream with no powerd in the room.
    ///
    /// `read` takes one reading on demand, for the refresh the model does on its own and when asked.
    init<Readings: AsyncSequence & Sendable>(
        readings: Readings,
        read: @escaping @Sendable () throws -> BatteryReading? = IOKitBattery.read,
        timekeeper: any Timekeeper = SystemTimekeeper()
    ) where Readings.Element == BatteryReading? {
        self.read = read
        self.timekeeper = timekeeper
        // [LAW:no-ambient-temporal-coupling] The model owns the subscription: it lives exactly
        // as long as the model does, and a dropped model cancels it before the next publish
        // rather than letting the task keep the model alive through it.
        subscription = Task { [weak self] in
            let ending: (any Error)?
            do {
                for try await reading in readings {
                    guard let self else { return }
                    self.take(reading)
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

        // The refresh waits out the interval since the latest reading, however it arrived, and
        // takes one if none has: powerd's own publishes keep resetting the wait. Each use of
        // `self` is its own statement so the wait never holds the model alive.
        refresher = Task { [weak self] in
            while let wait = self?.untilRefreshDue() {
                do { try await timekeeper.sleep(for: wait) } catch { return }
                self?.refreshIfDue()
            }
        }
    }

    /// Takes a reading now, as the panel's "Tap to refresh now" asks. A read that fails ends the
    /// model the way a failed subscription does, so the panel says so instead of going stale.
    func refresh() {
        do { take(try read()) } catch {
            IOKitBattery.log.error("battery refresh failed: \(String(describing: error), privacy: .public)")
            state = .ended(error)
        }
    }

    /// "Updated 3 min ago": the age of the reading on show, whole minutes.
    func updatedText() -> String? {
        readingAt.map { UpdatedFooter.text(age: timekeeper.now().timeIntervalSince($0)) }
    }

    private func take(_ reading: BatteryReading?) {
        readingAt = timekeeper.now()
        state = .known(reading)
    }

    /// How long until a reading is due: the interval less the age of the one held. The refresher
    /// outlives `.ended`, because a powerd publish can bring the model back to `.known`.
    private func untilRefreshDue() -> Duration {
        guard let readingAt else { return Self.refreshInterval }
        let age = Duration.seconds(timekeeper.now().timeIntervalSince(readingAt))
        return max(.zero, Self.refreshInterval - age)
    }

    /// Only a model holding a reading refreshes it: before the first one the subscription is
    /// still delivering, and after a failure it is the failure that is on show.
    private func refreshIfDue() {
        guard case .known = state, untilRefreshDue() == .zero else { return }
        refresh()
    }

    deinit {
        subscription?.cancel()
        refresher?.cancel()
    }
}
