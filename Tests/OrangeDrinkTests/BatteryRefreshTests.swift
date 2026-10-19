import Foundation
import Testing
@testable import OrangeDrink

/// A read the test counts and answers with a reading it chooses.
final class Reads: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private(set) var reading: BatteryReading?

    init(_ reading: BatteryReading?) { self.reading = reading }

    var taken: Int { lock.withLock { count } }
    func read() -> BatteryReading? { lock.withLock { count += 1; return reading } }
}

// [LAW:behavior-not-structure] The contract is when a reading is taken and what "Updated" says,
// on a clock the test moves and readings it supplies.
@Suite(.timeLimit(.minutes(1))) @MainActor struct BatteryRefresh {
    /// A model whose first reading has arrived, over a clock and a counted read.
    func model() async throws -> (BatteryModel, ManualTimekeeper, Reads, AsyncThrowingStream<BatteryReading?, any Error>.Continuation) {
        let first = try BatteryEvents.onBattery
        let clock = ManualTimekeeper(), reads = Reads(first)
        let (readings, feed) = AsyncThrowingStream.makeStream(of: BatteryReading?.self)
        let model = BatteryModel(readings: readings, read: { reads.read() }, timekeeper: clock)
        feed.yield(first)
        _ = await model.state(once: BatteryModel.isKnown)
        await clock.asleep()
        return (model, clock, reads, feed)
    }

    @Test func aFreshReadingIsTakenTwoMinutesAfterTheLast() async throws {
        let (model, clock, reads, _) = try await model()
        #expect(reads.taken == 0)
        clock.advance(by: .seconds(119))
        #expect(reads.taken == 0)
        clock.advance(by: .seconds(1))
        await clock.asleep()
        #expect(reads.taken == 1)
        #expect(model.updatedText() == "Updated just now")
    }

    @Test func updatedCountsWholeMinutesSinceTheReading() async throws {
        let (model, clock, _, _) = try await model()
        #expect(model.updatedText() == "Updated just now")
        clock.advance(by: .seconds(60))
        #expect(model.updatedText() == "Updated 1 min ago")
    }

    @Test func tappingRefreshTakesAReadingAtOnceAndUpdatedReflectsIt() async throws {
        let (model, clock, reads, _) = try await model()
        clock.advance(by: .seconds(90))
        #expect(model.updatedText() == "Updated 1 min ago")
        model.refresh()
        #expect(reads.taken == 1)
        #expect(model.updatedText() == "Updated just now")
    }

    @Test func aReadingThePowerdPushedPostponesTheRefresh() async throws {
        let (model, clock, reads, feed) = try await model()
        clock.advance(by: .seconds(100))
        feed.yield(try BatteryEvents.onAdapter)
        _ = await model.state(once: { if case .known(let r) = $0 { r == (try? BatteryEvents.onAdapter) } else { false } })
        clock.advance(by: .seconds(30))
        await clock.asleep()
        #expect(reads.taken == 0)
    }

    @Test func aFailedRefreshEndsTheModelInsteadOfLeavingAStaleReading() async throws {
        struct Unreadable: Error {}
        let clock = ManualTimekeeper()
        let (readings, feed) = AsyncThrowingStream.makeStream(of: BatteryReading?.self)
        let model = BatteryModel(readings: readings, read: { throw Unreadable() }, timekeeper: clock)
        feed.yield(try BatteryEvents.onBattery)
        _ = await model.state(once: BatteryModel.isKnown)
        model.refresh()
        guard case .ended(let error) = model.state else {
            Issue.record("a failed read left the model \(model.state)")
            return
        }
        #expect(error is Unreadable)
    }
}
