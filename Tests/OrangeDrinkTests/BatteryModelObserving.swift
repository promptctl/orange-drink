import Observation
@testable import OrangeDrink

/// How a test waits on a BatteryModel. [LAW:one-source-of-truth] The one wait and the one set
/// of state predicates every model assertion reads.
extension BatteryModel {
    /// The state once `accepted` holds for it, or the state at hand once the test is cancelled.
    /// [LAW:no-ambient-temporal-coupling] Each change is awaited through Observation on the
    /// main actor, never polled for, through a stream whose wait ends with the test's time limit.
    func state(once accepted: (State) -> Bool) async -> State {
        let (changes, change) = AsyncStream.makeStream(of: Void.self)
        var next = changes.makeAsyncIterator()
        while !accepted(state) {
            withObservationTracking { _ = state } onChange: { change.yield() }
            guard await next.next() != nil else { break }
        }
        return state
    }

    static func isSettled(_ state: State) -> Bool { if case .unknown = state { false } else { true } }
    static func isKnown(_ state: State) -> Bool { if case .known = state { true } else { false } }
    static func isEnded(_ state: State) -> Bool { if case .ended = state { true } else { false } }
}
