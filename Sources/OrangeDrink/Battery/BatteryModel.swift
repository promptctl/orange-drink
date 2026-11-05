import Foundation
import Observation
import os

/// The app's one battery subscription and the state every view reads from it.
///
/// [LAW:one-source-of-truth] One subscription per process, held from launch: views derive
/// from this and never read IOKit themselves, and the CPU check measures the app with it live.
@Observable @MainActor final class BatteryModel {
    /// [LAW:types-are-the-program] A view can tell "no reading yet" from "no battery" from "the latest read gave
    /// nothing" from "no more readings", so none of them is a stale reading in disguise.
    enum State {
        case unknown
        /// The latest reading; nil is a Mac with no battery.
        case known(BatteryReading?)
        /// The latest read gave no reading, whether powerd did not answer or what it answered was no reading. The
        /// subscription runs on, and the next read that gives one replaces this.
        case unread
        /// The subscription is gone, and nothing follows: the stream threw this error, or finished when it is nil.
        case ended((any Error)?)
    }

    /// How often the readings are refreshed on their own, when nothing has pushed one.
    nonisolated static let refreshInterval = Duration.seconds(120)

    private(set) var state: State = .unknown
    /// When the latest read was taken, by this model's clock, whether or not it gave a reading; nil until there is one.
    private(set) var lookedAt: Date?
    @ObservationIgnored private let timekeeper: any Timekeeper
    @ObservationIgnored private let read: @Sendable () -> BatteryRead
    @ObservationIgnored private let log: Logger
    /// Told of every state the model holds, the first included, so what acts on them (alerts,
    /// history, widgets) never watches `state`.
    @ObservationIgnored private let onState: @MainActor (State) -> Void
    /// [LAW:types-are-the-program] exception: set once, in init, but Swift will not let the
    /// task capture `self` before every stored property holds a value, so it cannot be a let.
    /// Written on the main actor and read only by deinit, which no other access can overlap;
    /// an isolated deinit would say so in the type, and needs macOS 15.
    @ObservationIgnored nonisolated(unsafe) private var subscription: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var refresher: Task<Void, Never>?

    /// [LAW:composability] The model mirrors whatever readings it is given: the app hands it
    /// `BatteryMonitor.readings()`, a test a recorded stream with no powerd in the room.
    ///
    /// `read` takes one read on demand, for the refresh the model does on its own and when asked.
    init<Readings: AsyncSequence & Sendable>(
        readings: Readings,
        read: @escaping @Sendable () -> BatteryRead,
        timekeeper: any Timekeeper = SystemTimekeeper(),
        log: Logger,
        onState: @escaping @MainActor (State) -> Void = { _ in }
    ) where Readings.Element == BatteryRead {
        self.log = log
        self.read = read
        self.timekeeper = timekeeper
        self.onState = onState
        onState(state)
        // [LAW:no-ambient-temporal-coupling] The model owns the subscription: it lives exactly
        // as long as the model does, and a dropped model cancels it before the next publish
        // rather than letting the task keep the model alive through it.
        subscription = Task { [weak self] in
            let ending: (any Error)?
            do {
                for try await read in readings {
                    guard let self else { return }
                    self.take(read)
                }
                ending = nil
            } catch {
                ending = error
            }
            // A dropped model cancelled the stream itself, so its ending is no event.
            guard let self else { return }
            let reason = ending.map { String(describing: $0) } ?? "the stream finished"
            self.log.error("battery subscription ended: \(reason, privacy: .public)")
            self.set(.ended(ending))
        }

        // The refresh waits out the interval since the latest read, however it arrived, and takes
        // one if none has: powerd's own publishes keep resetting the wait. Each use of `self` is
        // its own statement so the wait never holds the model alive.
        refresher = Task { [weak self] in
            while let wait = self?.untilRefreshDue() {
                do { try await timekeeper.sleep(for: wait) } catch { return }
                self?.refreshIfDue()
            }
        }
    }

    /// Takes a read now, as the panel's "Tap to refresh now" asks, and does nothing once the subscription is gone.
    /// A read that gives no reading leaves the model `.unread` until a later one does.
    func refresh() {
        if case .ended = state { return }
        let result = read()
        take(result)
        if case .success = result { log.info("battery refresh: reading taken") }
    }

    /// "Updated 3 min ago": the age of the reading on show, whole minutes; nil when none is on show.
    func updatedText() -> Phrase? {
        guard case .known = state, let lookedAt else { return nil }
        return UpdatedFooter.text(age: timekeeper.now().timeIntervalSince(lookedAt))
    }

    private func take(_ read: BatteryRead) {
        lookedAt = timekeeper.now()
        switch read {
        case .success(let reading):
            set(.known(reading))
        case .failure(let error):
            log.error("battery read gave no reading: \(String(describing: error), privacy: .public)")
            set(.unread)
        }
    }

    /// [LAW:single-enforcer] Every state change goes through here, so `onState` hears each one.
    private func set(_ new: State) {
        state = new
        onState(new)
    }

    /// Whether the model asks for a read on its own: one that holds a reading, or one whose latest read gave none,
    /// which a powerd that publishes nothing would otherwise leave unread for good. Before the first look the
    /// subscription is still delivering.
    private var refreshes: Bool {
        switch state {
        case .known, .unread: true
        case .unknown, .ended: false
        }
    }

    /// How long until a read is due: the interval less the age of the latest look. nil once the subscription is gone,
    /// which ends the refresher, since nothing can follow.
    func untilRefreshDue() -> Duration? {
        if case .ended = state { return nil }
        guard refreshes, let lookedAt else { return Self.refreshInterval }
        let age = Duration.seconds(timekeeper.now().timeIntervalSince(lookedAt))
        return max(.zero, Self.refreshInterval - age)
    }

    private func refreshIfDue() {
        guard refreshes, untilRefreshDue() == Duration.zero else { return }
        refresh()
    }

    deinit {
        subscription?.cancel()
        refresher?.cancel()
    }
}
