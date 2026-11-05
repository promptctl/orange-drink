import Foundation
import OSLog
import Testing
@testable import OrangeDrink

/// A read the test counts and answers with what it chooses, a reading until it says otherwise.
final class Reads: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var answer: BatteryRead

    init(_ reading: BatteryReading?) { answer = .success(reading) }

    var taken: Int { lock.withLock { count } }
    func answers(_ next: BatteryRead) { lock.withLock { answer = next } }
    func read() -> BatteryRead { lock.withLock { count += 1; return answer } }
}

// [LAW:behavior-not-structure] The contract is when a reading is taken and what "Updated" says,
// on a clock the test moves and readings it supplies.
@Suite @MainActor struct BatteryRefresh {
    /// A model whose first reading has arrived, over a clock and a counted read.
    func model(log: Logger) async throws -> (BatteryModel, ManualTimekeeper, Reads, AsyncThrowingStream<BatteryRead, any Error>.Continuation) {
        let first = try BatteryEvents.onBattery
        let clock = ManualTimekeeper(), reads = Reads(first)
        let (readings, feed) = AsyncThrowingStream.makeStream(of: BatteryRead.self)
        let model = BatteryModel(readings: readings, read: { reads.read() }, timekeeper: clock, log: log)
        feed.yield(first)
        _ = await model.state(once: BatteryModel.isKnown)
        await clock.asleep()
        return (model, clock, reads, feed)
    }

    @Test func aFreshReadingIsTakenTwoMinutesAfterTheLast() async throws {
        let log = try await TestLog()
        let (model, clock, reads, _) = try await model(log: log.logger)
        #expect(reads.taken == 0)
        clock.advance(by: .seconds(119))
        #expect(reads.taken == 0)
        clock.advance(by: .seconds(1))
        await clock.asleep()
        #expect(reads.taken == 1)
        #expect(model.updatedText()?.english == "Updated just now")
        #expect(try await log.messages().contains("battery refresh: reading taken"))
    }

    @Test func updatedCountsWholeMinutesSinceTheReading() async throws {
        let (model, clock, _, _) = try await model(log: .unread)
        #expect(model.updatedText()?.english == "Updated just now")
        clock.advance(by: .seconds(60))
        #expect(model.updatedText()?.english == "Updated 1 min ago")
    }

    @Test func tappingRefreshTakesAReadingAtOnceAndUpdatedReflectsIt() async throws {
        let (model, clock, reads, _) = try await model(log: .unread)
        clock.advance(by: .seconds(90))
        #expect(model.updatedText()?.english == "Updated 1 min ago")
        model.refresh()
        #expect(reads.taken == 1)
        #expect(model.updatedText()?.english == "Updated just now")
    }

    @Test func aReadingThePowerdPushedPostponesTheRefresh() async throws {
        let (model, clock, reads, feed) = try await model(log: .unread)
        clock.advance(by: .seconds(100))
        feed.yield(try BatteryEvents.onAdapter)
        _ = await model.state(once: { if case .known(let r) = $0 { r == (try? BatteryEvents.onAdapter) } else { false } })
        clock.advance(by: .seconds(30))
        await clock.asleep()
        #expect(reads.taken == 0)
    }

    /// Whether powerd did not answer or what it answered was no reading, the refresh says so in place of the reading it
    /// held, and the model is not over: the next read that gives a reading replaces the note.
    @Test(arguments: [
        BatteryRead.unanswered,
        BatteryRead.failure(BatteryReadError.registry(status: 5)),
    ]) func aRefreshThatGivesNoReadingLeavesTheModelUnreadUntilOneDoes(unread: BatteryRead) async throws {
        let log = try await TestLog()
        let (model, _, reads, _) = try await model(log: log.logger)
        reads.answers(unread)
        model.refresh()
        guard case .unread = model.state else {
            Issue.record("a read that gave no reading left the model \(model.state)")
            return
        }
        #expect(model.updatedText() == nil)
        #expect(try await log.messages().contains { $0.hasPrefix("battery read gave no reading: ") })
        #expect(!(try await log.messages().contains("battery refresh: reading taken")))

        let adapter = try BatteryEvents.onAdapter
        reads.answers(.success(adapter))
        model.refresh()
        guard case .known(let held) = model.state else {
            Issue.record("the next reading left the model \(model.state)")
            return
        }
        #expect(held == adapter)
    }

    /// A powerd that stays silent publishes nothing, so the refresh is what finds it answering again: one ask an
    /// interval after each look, however old the last reading is.
    @Test func anUnreadModelAsksAgainAnIntervalAfterEachLook() async throws {
        let (model, clock, reads, _) = try await model(log: .unread)
        reads.answers(.unanswered)
        clock.advance(by: BatteryModel.refreshInterval)
        await clock.asleep()
        #expect(reads.taken == 1)
        #expect(BatteryModel.isUnread(model.state))
        #expect(model.untilRefreshDue() == BatteryModel.refreshInterval)

        clock.advance(by: BatteryModel.refreshInterval - .seconds(1))
        #expect(reads.taken == 1)
        clock.advance(by: .seconds(1))
        await clock.asleep()
        #expect(reads.taken == 2)
        #expect(BatteryModel.isUnread(model.state))
    }

    /// Nothing follows a gone subscription, so the model owes no read, however old its last look is, and a tap on a
    /// refresh that is still offered leaves it ended instead of reviving it.
    @Test func anEndedModelAsksForNoMoreReadsAndStaysEnded() async throws {
        let (model, clock, reads, feed) = try await model(log: .unread)
        feed.finish()
        _ = await model.state(once: BatteryModel.isEnded)
        clock.advance(by: .seconds(600))
        #expect(model.untilRefreshDue() == nil)
        model.refresh()
        #expect(reads.taken == 0)
        #expect(BatteryModel.isEnded(model.state))
    }
}
