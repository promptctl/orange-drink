import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is which state each element of the readings
// stream leaves the model in, checked from a stream the test feeds, with no powerd in the room.
@Suite struct BatteryModelStates {
    struct StreamEnded: Error {}

    @MainActor @Test func holdsEachReadingThenTheErrorThatEndedTheStream() async throws {
        let reading = try BatteryEvents.onBattery
        let log = try await TestLog()
        let (readings, feed) = AsyncThrowingStream.makeStream(of: BatteryRead.self)
        let model = BatteryModel(readings: readings, read: { .success(nil) }, log: log.logger)

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
        #expect(try await log.messages().contains("battery subscription ended: \(String(describing: StreamEnded()))"))
    }

    @MainActor @Test func aStreamThatFinishesEndsTheModelWithNoError() async throws {
        let log = try await TestLog()
        let (readings, feed) = AsyncThrowingStream.makeStream(of: BatteryRead.self)
        let model = BatteryModel(readings: readings, read: { .success(nil) }, log: log.logger)

        feed.finish()
        guard case .ended(let error) = await model.state(once: BatteryModel.isEnded) else {
            Issue.record("a finished stream left the model unknown")
            return
        }
        #expect(error == nil)
        #expect(try await log.messages().contains("battery subscription ended: the stream finished"))
    }

    /// A read that gave no reading is a state of the model, not its end: the subscription runs on, the last reading
    /// is not shown in its place, and the next read that gives one replaces it.
    @MainActor @Test(arguments: [
        BatteryRead.unanswered,
        BatteryRead.failure(BatteryReadError.noInternalBatterySource),
    ]) func aReadThatGaveNoReadingIsUnreadAndTheNextReadingReplacesIt(unread: BatteryRead) async throws {
        let log = try await TestLog()
        let (readings, feed) = AsyncThrowingStream.makeStream(of: BatteryRead.self)
        let model = BatteryModel(readings: readings, read: { .success(nil) }, log: log.logger)
        let first = try BatteryEvents.onBattery, second = try BatteryEvents.onAdapter

        feed.yield(first)
        _ = await model.state(once: BatteryModel.isKnown)
        feed.yield(unread)
        guard case .unread = await model.state(once: BatteryModel.isUnread) else {
            Issue.record("a read that gave no reading left the model \(model.state)")
            return
        }
        #expect(model.updatedText() == nil)
        let cause = try #require({ if case .failure(let error) = unread { String(describing: error) } else { nil } }())
        #expect(try await log.messages().contains("battery read gave no reading: \(cause)"))

        feed.yield(second)
        guard case .known(let held) = await model.state(once: BatteryModel.isKnown) else {
            Issue.record("the next reading did not replace the unread state")
            return
        }
        #expect(held == second)
        #expect(!(try await log.messages().contains { $0.hasPrefix("battery subscription ended") }))
    }
}
