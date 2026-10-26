import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The stand-in keeps Timekeeper's contract: a sleep throws if its task is cancelled first,
// a sleep whose time has already come returns without an advance, a sleep wakes when its whole duration has passed,
// fractions of a second included, and only a live sleeper counts as asleep.
@Suite struct ManualTimekeeperContract {
    @Test(.timeLimit(.minutes(1)))
    func aTaskCancelledBeforeItSleepsThrowsAndLeavesNoSleeper() async throws {
        let clock = ManualTimekeeper()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await clock.sleep(for: .seconds(60))
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }

        let live = Task { try await clock.sleep(for: .seconds(60)) }
        await clock.asleep()
        clock.advance(by: .seconds(60))
        try await live.value
    }

    @Test(.timeLimit(.minutes(1)))
    func aSleepOfNoTimeReturnsWithoutAnAdvanceAndIsNeverASleeper() async throws {
        let clock = ManualTimekeeper()
        try await clock.sleep(for: .zero)
        #expect(clock.sleeping == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func aSleepWakesOnlyOnceItsFractionalDurationHasPassed() async throws {
        let clock = ManualTimekeeper()
        let sleeper = Task { try await clock.sleep(for: .milliseconds(500)) }
        await clock.asleep()
        clock.advance(by: .milliseconds(250))
        #expect(clock.sleeping == 1)
        clock.advance(by: .milliseconds(250))
        try await sleeper.value
        #expect(clock.sleeping == 0)
    }
}
