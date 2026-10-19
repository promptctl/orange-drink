import Observation
import Testing
@testable import OrangeDrink

extension BatteryModel {
    /// The state once `accepted` holds for it. [LAW:no-ambient-temporal-coupling] Each
    /// change is awaited through Observation on the main actor, never polled for.
    func state(once accepted: (State) -> Bool) async -> State {
        while !accepted(state) {
            await withCheckedContinuation { continuation in
                withObservationTracking { _ = state } onChange: { continuation.resume() }
            }
        }
        return state
    }
}

// [LAW:behavior-not-structure] The contract is which state each element of the readings
// stream leaves the model in, checked from a stream the test feeds, with no powerd in the room.
@Suite struct BatteryModelStates {
    struct StreamEnded: Error {}

    @MainActor @Test func holdsEachReadingThenTheErrorThatEndedTheStream() async throws {
        let reading = try BatteryEvents.onBattery
        let log = try BatteryLog()
        let (readings, feed) = AsyncThrowingStream.makeStream(of: BatteryReading?.self)
        let model = BatteryModel(readings: readings)

        feed.yield(reading)
        guard case .known(let held) = await model.state(once: { if case .known = $0 { true } else { false } }) else {
            Issue.record("a yielded reading left the model unknown")
            return
        }
        #expect(held == reading)

        feed.finish(throwing: StreamEnded())
        guard case .unavailable(let error) = await model.state(once: { if case .unavailable = $0 { true } else { false } }) else {
            Issue.record("a thrown error left the model known")
            return
        }
        #expect(error is StreamEnded)
        #expect(try log.messages().contains("battery subscription ended: \(String(describing: StreamEnded()))"))
    }
}
