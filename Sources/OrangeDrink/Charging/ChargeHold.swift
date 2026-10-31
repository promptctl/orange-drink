import Foundation
import Observation
import OSLog
import ServiceManagement

/// What the Charge Limit wants of charging now: paused, or let run for the one reason that decided it.
enum ChargeWant: Equatable, Sendable {
    case pause
    case allow(Reason)

    enum Reason: String, Equatable, Sendable {
        case limitOff = "limit off"
        case belowTarget = "below target"
        case onBattery = "on battery"
        case noBattery = "no battery"
        case noReadingYet = "no reading yet"
        case readingsEnded = "readings ended"
    }

    /// [LAW:one-source-of-truth] The decision and its reason are one answer: charging pauses only for a reading on the
    /// adapter at or above the target with the limit on, and every other input is let run with the reason it was.
    static func of(limit: ChargeLimit, battery: BatteryModel.State) -> ChargeWant {
        guard limit.isOn else { return .allow(.limitOff) }
        switch battery {
        case .unknown: return .allow(.noReadingYet)
        case .ended: return .allow(.readingsEnded)
        case .known(nil): return .allow(.noBattery)
        case .known(let reading?):
            guard case .adapter = reading.power else { return .allow(.onBattery) }
            return reading.chargePercent >= limit.target.percent ? .pause : .allow(.belowTarget)
        }
    }
}

/// One thing the hold asks of the helper.
enum ChargeAsk: Equatable, Sendable {
    /// Hold charging paused, on a lease.
    case pause
    /// Let go of the lease the hold has.
    case release(ChargeWant.Reason)
    /// Hold nothing, and have the helper bring CHTE to what its holders want: the ask while the hold does not know
    /// what CHTE holds.
    case resume(ChargeWant.Reason)
}

/// What the hold did, as the log and the tests read it.
enum ChargeHoldEvent: Equatable {
    /// An ask and what it asked under: the limit, and the level it saw. nil failure once it happened.
    case asked(ChargeAsk, limit: ChargeLimit, percent: Int?, failure: HelperUseFailure?)
    /// The helper ended the pause the hold had, so it is asked again.
    case lost
    /// This Mac cannot pause charging; nothing is asked again this run.
    case unavailable(HelperUseFailure)
    /// The user took the way the Charging screen offers to allow the helper.
    case openedLoginItems

    /// [LAW:effects-at-boundaries] The log line, a pure function of the event.
    var line: String {
        switch self {
        case .asked(let ask, let limit, let percent, let failure):
            let asked: String = switch ask {
            case .pause: "pause"
            case .release(let reason): "release (\(reason.rawValue))"
            case .resume(let reason): "resume (\(reason.rawValue))"
            }
            let under = "limit \(limit.isOn ? "on" : "off"), target \(limit.target.percent)%, battery \(percent.map { "\($0)%" } ?? "unread")"
            return "\(asked) with \(under): " + (failure.map { "failed: \($0.description)" } ?? "done")
        case .lost: return "the helper ended the pause; asking again"
        case .unavailable(let failure): return "charge limit unavailable on this Mac for this run: \(failure.description)"
        case .openedLoginItems: return "opened Login Items & Extensions to allow the helper"
        }
    }
}

/// Holds the battery at the Charge Limit's target through the helper: pauses charging when a plugged-in Mac reaches
/// the target, and lets it run again below it, with the limit off, on battery, or once readings stop.
///
/// [LAW:single-enforcer] The app's one asker of the helper about charging; the helper is the one writer of CHTE.
/// Asks come only from inputs (a battery state, a limit change, a lost lease, a recheck), never from a reply, so a
/// helper that keeps failing is asked at most once per input.
@Observable @MainActor final class ChargeHold<Lease: AnyObject & Sendable> {
    /// [LAW:types-are-the-program] What the hold knows of CHTE. A failure lives in the state it left, so a pause
    /// carries none and a success clears it by construction.
    enum State: Sendable {
        /// The hold does not know what CHTE holds: at launch, after a lost lease, after a failed ask. Each input asks.
        case unknown(HelperUseFailure?)
        /// Charging runs as far as the hold is concerned. A failure kept here is one the user can fix (the helper not
        /// allowed), which a recheck asks about again.
        case allowed(HelperUseFailure?)
        case paused(Lease)
        /// This Mac cannot pause charging; nothing is asked again this run.
        case unavailable(HelperUseFailure)

        var failure: HelperUseFailure? {
            switch self {
            case .unknown(let failure), .allowed(let failure): failure
            case .unavailable(let failure): failure
            case .paused: nil
            }
        }
    }

    /// The helper calls the hold makes, each blocking until its reply, so they run off the main actor.
    struct Effects: Sendable {
        /// Holds charging paused; the lease's `lost` hears the helper end it.
        let pause: @Sendable (@escaping @Sendable (Lease) -> Void) throws(HelperUseFailure) -> Lease
        let release: @Sendable (Lease) throws(HelperUseFailure) -> Void
        let resume: @Sendable () throws(HelperUseFailure) -> Void
    }

    private(set) var state = State.unknown(nil)
    /// The ask in flight, from the input that made it to the reply that ends it; one at a time.
    @ObservationIgnored private(set) var asking: Task<Void, Never>?
    /// An input arrived while an ask was in flight: its reply evaluates once more, against the latest inputs.
    @ObservationIgnored private var pending = false
    @ObservationIgnored private var battery = BatteryModel.State.unknown
    @ObservationIgnored private var limit: ChargeLimit
    @ObservationIgnored private let effects: Effects
    @ObservationIgnored private let record: (ChargeHoldEvent) -> Void
    @ObservationIgnored private let openLoginItemsPane: () -> Void

    nonisolated static var log: Logger { Logger(subsystem: IOKitBattery.logSubsystem, category: "chargeLimit") }

    /// [LAW:composability] `limit` is the setting as it stands, `effects` the helper, `record` is told each event, and
    /// `openLoginItems` shows the setting that allows the helper. Nothing is asked until the first input.
    init(limit: ChargeLimit, effects: Effects,
         record: @escaping (ChargeHoldEvent) -> Void = { event in ChargeHold.log.notice("\(event.line, privacy: .public)") },
         openLoginItems: @escaping () -> Void = { SMAppService.openSystemSettingsLoginItems() }) {
        self.limit = limit
        self.effects = effects
        self.record = record
        openLoginItemsPane = openLoginItems
    }

    var failure: HelperUseFailure? { state.failure }

    /// Every battery state the app's model holds, the first included.
    func observe(_ battery: BatteryModel.State) {
        self.battery = battery
        evaluate()
    }

    /// The setting as it stands; only a change is an input.
    func set(limit: ChargeLimit) {
        guard limit != self.limit else { return }
        self.limit = limit
        evaluate()
    }

    /// Follows the stored setting from now on.
    func follow(_ model: ChargeLimitModel) {
        // Only the setting is read under tracking: the evaluation it starts reads the hold's own state.
        let limit = withObservationTracking { model.value } onChange: { [weak self] in
            Task { @MainActor in self?.follow(model) }
        }
        set(limit: limit)
    }

    /// [LAW:one-source-of-truth] A kept failure is a snapshot of an approval the user changes in System Settings at
    /// any time, so the screen showing it asks again when it appears or its window comes back: once, and only while
    /// the hold holds a failure.
    func recheck() {
        switch state {
        case .allowed(let failure?):
            state = .unknown(failure)
            evaluate()
        case .unknown(.some):
            evaluate()
        case .unknown(nil), .allowed(nil), .paused, .unavailable:
            break
        }
    }

    func openLoginItems() {
        openLoginItemsPane()
        record(.openedLoginItems)
    }

    /// One ask with what it needs: a release carries the lease it lets go of.
    enum Step: Sendable {
        case pause
        case release(Lease, ChargeWant.Reason)
        case resume(ChargeWant.Reason)

        var ask: ChargeAsk {
            switch self {
            case .pause: .pause
            case .release(_, let reason): .release(reason)
            case .resume(let reason): .resume(reason)
            }
        }
    }

    /// The step that brings the state to the want, or nil when there is none to make.
    static func step(_ state: State, _ want: ChargeWant) -> Step? {
        switch (state, want) {
        case (.unavailable, _), (.paused, .pause), (.allowed, .allow): nil
        case (.paused(let lease), .allow(let reason)): .release(lease, reason)
        case (.allowed, .pause), (.unknown, .pause): .pause
        case (.unknown, .allow(let reason)): .resume(reason)
        }
    }

    private func evaluate() {
        guard asking == nil else {
            pending = true
            return
        }
        guard let step = Self.step(state, ChargeWant.of(limit: limit, battery: battery)) else { return }
        let call = call(for: step), limit = limit, percent = battery.percent
        asking = Task {
            let outcome = await blocking { Result { () throws(HelperUseFailure) in try call() } }
            self.land(step.ask, outcome, limit: limit, percent: percent)
        }
    }

    /// The helper call a step makes, and the state its success leaves.
    private func call(for step: Step) -> @Sendable () throws(HelperUseFailure) -> State {
        let effects = effects
        // A lease can be lost while the reply that granted it is still on its way here, so the loss waits for the ask
        // in flight to land first. It carries the lease itself, which keeps its identity from passing to a newer one.
        let lost: @Sendable (Lease) -> Void = { [weak self] lease in
            Task { @MainActor in
                await self?.asking?.value
                self?.lost(lease)
            }
        }
        return {
            switch step {
            case .pause: return .paused(try effects.pause(lost))
            case .release(let lease, _):
                try effects.release(lease)
                return .allowed(nil)
            case .resume:
                try effects.resume()
                return .allowed(nil)
            }
        }
    }

    private func land(_ ask: ChargeAsk, _ outcome: Result<State, HelperUseFailure>, limit: ChargeLimit, percent: Int?) {
        asking = nil
        switch outcome {
        case .success(let reached): state = reached
        case .failure(let failure): state = Self.settled(after: failure)
        }
        record(.asked(ask, limit: limit, percent: percent, failure: outcome.failure))
        if case .unavailable(let failure) = state { record(.unavailable(failure)) }
        if pending {
            pending = false
            evaluate()
        }
    }

    /// Where a failed ask leaves the hold. A Mac that cannot pause charging stops asking. A helper not yet allowed has
    /// never run here, so charging is as the system left it. Any other failure leaves CHTE unknown, so the next input
    /// asks again: only a helper that runs ends a pause one that died left behind, and a helper the registration has
    /// to register again starts at that ask.
    static func settled(after failure: HelperUseFailure) -> State {
        if case .unsupported = failure.call { return .unavailable(failure) }
        return failure.cause == .needsApproval ? .allowed(failure) : .unknown(failure)
    }

    private func lost(_ ended: Lease) {
        guard case .paused(let lease) = state, lease === ended else { return }
        state = .unknown(nil)
        record(.lost)
        evaluate()
    }
}

extension ChargeHold where Lease == ChargeLease {
    /// The app's hold: the helper's charging calls.
    convenience init(limit: ChargeLimit, helper: HelperAccess) {
        self.init(limit: limit, effects: Effects(
            pause: { lost throws(HelperUseFailure) in try helper.pauseCharging(lost: lost) },
            release: { lease throws(HelperUseFailure) in try helper.release(lease) },
            resume: { () throws(HelperUseFailure) in try helper.resumeCharging() }))
    }
}

typealias AppChargeHold = ChargeHold<ChargeLease>

private extension BatteryModel.State {
    /// The level a state shows, for the log.
    var percent: Int? {
        if case .known(let reading?) = self { reading.chargePercent } else { nil }
    }
}
