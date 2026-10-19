import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is which state each element of the readings
// stream leaves the model in, checked from a stream the test feeds, with no powerd in the room.
@Suite(.timeLimit(.minutes(1))) struct BatteryModelStates {
    struct StreamEnded: Error {}

    @MainActor @Test func holdsEachReadingThenTheErrorThatEndedTheStream() async throws {
        let reading = try BatteryEvents.onBattery
        let log = try BatteryLog()
        let (readings, feed) = AsyncThrowingStream.makeStream(of: BatteryReading?.self)
        let model = BatteryModel(readings: readings)

        feed.yield(reading)
        guard case .known(let held) = await model.state(once: BatteryModel.isKnown) else {
            Issue.record("a yielded reading left the model unknown")
            return
        }
        #expect(held == reading)

        feed.finish(throwing: StreamEnded())
        guard case .ended(let error) = await model.state(once: BatteryModel.isEnded) else {
            Issue.record("a thrown error left the model known")
            return
        }
        #expect(error is StreamEnded)
        #expect(try log.messages().contains("battery subscription ended: \(String(describing: StreamEnded()))"))
    }

    @MainActor @Test func aStreamThatFinishesEndsTheModelWithNoError() async throws {
        let log = try BatteryLog()
        let (readings, feed) = AsyncThrowingStream.makeStream(of: BatteryReading?.self)
        let model = BatteryModel(readings: readings)

        feed.finish()
        guard case .ended(let error) = await model.state(once: BatteryModel.isEnded) else {
            Issue.record("a finished stream left the model unknown")
            return
        }
        #expect(error == nil)
        #expect(try log.messages().contains("battery subscription ended: the stream finished"))
    }
}
