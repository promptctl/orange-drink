import Foundation
import os
import ServiceManagement
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract: with the limit on and the adapter in, charging pauses once at the target
// and is let go once below it; the limit off, the battery, and readings that stop each let it go; the helper is asked
// only when an input arrives, never by a reply; a Mac that cannot pause is asked once a run; a failure the user can
// fix is asked about again when the screen comes back; a pause the helper ended is asked for again.

/// A pause the fake helper grants.
final class FakeLease: Sendable {}

/// The helper as the hold calls it: records each call, answers with `failure` when one is set, and holds a pause call
/// at `gate` when one is set.
final class FakeChargeHelper: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var leases: [(lease: FakeLease, lost: @Sendable (FakeLease) -> Void)] = []
    private var answer: HelperUseFailure?
    private var held: DispatchSemaphore?

    /// The helper calls, in order.
    var calls: [String] { lock.withLock { log } }

    var failure: HelperUseFailure? {
        get { lock.withLock { answer } }
        set { lock.withLock { answer = newValue } }
    }

    var gate: DispatchSemaphore? {
        get { lock.withLock { held } }
        set { lock.withLock { held = newValue } }
    }

    /// The helper ends the latest pause it granted.
    func endLatestLease() {
        guard let last = lock.withLock({ leases.last }) else { Issue.record("no lease was granted"); return }
        last.lost(last.lease)
    }

    var effects: ChargeHold<FakeLease>.Effects {
        .init(pause: { lost throws(HelperUseFailure) in
            self.gate?.wait()
            try self.called("pause")
            let lease = FakeLease()
            self.lock.withLock { self.leases.append((lease, lost)) }
            return lease
        }, release: { _ throws(HelperUseFailure) in
            try self.called("release")
        }, resume: { () throws(HelperUseFailure) in
            try self.called("resume")
        })
    }

    private func called(_ name: String) throws(HelperUseFailure) {
        let failure = lock.withLock { log.append(name); return answer }
        if let failure { throw failure }
    }
}

@MainActor @Suite struct ChargeHoldTests {
    typealias Hold = ChargeHold<FakeLease>

    static let on80 = ChargeLimit(isOn: true, target: ChargeTarget.standard)
    static let off = ChargeLimit(isOn: false, target: ChargeTarget.standard)
    static let unapproved = HelperUseFailure(call: LowPowerModeTests.unapproved, status: .requiresApproval)
    static let refused = HelperUseFailure(call: .failed("SMC said no"), status: .enabled)
    static let unsupported = HelperUseFailure(call: .unsupported("read CHTE: SMC result 0x84 (key not found)"), status: .enabled)

    static func adapter(_ percent: Int) throws -> BatteryModel.State {
        .known(try BatteryEvents.reading(BatteryEvents.Fixtures.onACNotCharging(charged: false), percent: percent))
    }

    static func battery(_ percent: Int) throws -> BatteryModel.State {
        .known(try BatteryEvents.reading(BatteryEvents.Fixtures.discharging(timeToEmpty: 192), percent: percent))
    }

    final class Events { var all: [ChargeHoldEvent] = [] }

    static func hold(_ limit: ChargeLimit, _ helper: FakeChargeHelper, _ events: Events = Events()) -> Hold {
        Hold(limit: limit, effects: helper.effects, record: { events.all.append($0) }, openLoginItems: {})
    }

    /// Waits for every ask in flight, and any it chains, to land.
    static func idle(_ hold: Hold) async {
        while let ask = hold.asking { await ask.value }
    }

    /// Waits for work the hold queued on the main actor (a lost lease) to run and land.
    static func settle(_ hold: Hold) async {
        for _ in 0..<20 { await Task.yield() }
        await idle(hold)
    }

    /// The state's case, and whether it carries a failure.
    static func name(_ state: Hold.State) -> String {
        switch state {
        case .unknown(nil): "unknown"
        case .unknown(.some): "unknown(failure)"
        case .allowed(nil): "allowed"
        case .allowed(.some): "allowed(failure)"
        case .paused: "paused"
        case .unavailable: "unavailable"
        }
    }

    /// Delivers each state as the battery model would, letting each ask land before the next.
    static func feed(_ hold: Hold, _ states: [BatteryModel.State]) async {
        for state in states {
            hold.observe(state)
            await idle(hold)
        }
    }

    // MARK: The ticket's Done when

    @Test func aChargeAt80PausesOnceAndResumesOnceAt79() async throws {
        let helper = FakeChargeHelper(), events = Events()
        let hold = Self.hold(Self.on80, helper, events)
        await Self.feed(hold, [.unknown] + (try [78, 79, 80, 80, 79].map(Self.adapter)))
        // The launch ask, then one pause at 80 and one release at 79.
        #expect(helper.calls == ["resume", "pause", "release"])
        #expect(events.all == [
            .asked(.resume(.noReadingYet), limit: Self.on80, percent: nil, failure: nil),
            .asked(.pause, limit: Self.on80, percent: 80, failure: nil),
            .asked(.release(.belowTarget), limit: Self.on80, percent: 79, failure: nil),
        ])
        #expect(Self.name(hold.state) == "allowed")
    }

    @Test func turningTheLimitOffWhilePausedReleasesOnce() async throws {
        let helper = FakeChargeHelper(), events = Events()
        let hold = Self.hold(Self.on80, helper, events)
        await Self.feed(hold, [try Self.adapter(85)])
        hold.set(limit: Self.off)
        await Self.idle(hold)
        #expect(helper.calls == ["pause", "release"])
        #expect(events.all.last == .asked(.release(.limitOff), limit: Self.off, percent: 85, failure: nil))
    }

    // MARK: Launch

    @Test func aLaunchWithTheLimitOffAsksOnceToResume() async throws {
        let helper = FakeChargeHelper()
        let hold = Self.hold(Self.off, helper)
        await Self.feed(hold, [.unknown] + (try [85, 85, 70].map(Self.adapter)))
        #expect(helper.calls == ["resume"])
        #expect(Self.name(hold.state) == "allowed")
    }

    @Test func aFailedLaunchAskIsMadeOnceMoreAtTheNextInput() async throws {
        let helper = FakeChargeHelper()
        helper.failure = Self.refused
        let hold = Self.hold(Self.off, helper)
        await Self.feed(hold, [.unknown])
        #expect(Self.name(hold.state) == "unknown(failure)")
        helper.failure = nil
        await Self.feed(hold, [try Self.adapter(70), try Self.adapter(70)])
        #expect(helper.calls == ["resume", "resume"])
        #expect(Self.name(hold.state) == "allowed")
    }

    // MARK: Failures

    @Test func aPauseThatKeepsFailingIsAskedOncePerInputAndNeverByAReply() async throws {
        let helper = FakeChargeHelper()
        helper.failure = Self.refused
        let hold = Self.hold(Self.on80, helper)
        await Self.feed(hold, try [80, 81, 82].map(Self.adapter))
        #expect(helper.calls == ["pause", "pause", "pause"])
        #expect(hold.failure == Self.refused)
        helper.failure = nil
        await Self.feed(hold, [try Self.adapter(83)])
        #expect(Self.name(hold.state) == "paused")
        #expect(hold.failure == nil)
    }

    @Test func anUnapprovedHelperSettlesToAllowedAndBatteryStatesBelowTargetAskNoMore() async throws {
        let helper = FakeChargeHelper()
        helper.failure = Self.unapproved
        let hold = Self.hold(Self.on80, helper)
        await Self.feed(hold, try [70, 71, 72].map(Self.adapter))
        #expect(helper.calls == ["resume"])
        #expect(Self.name(hold.state) == "allowed(failure)")
        #expect(hold.failure?.cause == .needsApproval)
    }

    /// Only a helper that runs ends a pause one that died left behind, so a hold that finds no job keeps asking, once an
    /// input, and the ask that follows the registration's `register` starts that helper.
    @Test(arguments: [SMAppService.Status.notRegistered, .notFound])
    func aHelperWithNoJobLeavesCHTEUnknownSoTheNextInputAsksAgain(status: SMAppService.Status) async throws {
        let helper = FakeChargeHelper()
        helper.failure = HelperUseFailure(call: LowPowerModeTests.unapproved, status: status)
        let hold = Self.hold(Self.on80, helper)
        await Self.feed(hold, try [70, 71].map(Self.adapter))
        #expect(helper.calls == ["resume", "resume"])
        #expect(Self.name(hold.state) == "unknown(failure)")
        helper.failure = nil
        await Self.feed(hold, [try Self.adapter(72)])
        #expect(helper.calls == ["resume", "resume", "resume"])
        #expect(Self.name(hold.state) == "allowed")
    }

    @Test func aMacThatCannotPauseIsAskedOnceForTheWholeRun() async throws {
        let helper = FakeChargeHelper(), events = Events()
        helper.failure = Self.unsupported
        let hold = Self.hold(Self.off, helper, events)
        await Self.feed(hold, [.unknown] + (try [85, 90].map(Self.adapter)))
        hold.set(limit: Self.on80)
        hold.recheck()
        await Self.feed(hold, [try Self.adapter(95), try Self.battery(60)])
        #expect(helper.calls == ["resume"])
        #expect(Self.name(hold.state) == "unavailable")
        #expect(events.all.filter { if case .unavailable = $0 { true } else { false } } == [.unavailable(Self.unsupported)])
    }

    // MARK: Recheck

    @Test func aRecheckAfterApprovalClearsTheLineAndAsksForNoPause() async throws {
        let helper = FakeChargeHelper()
        helper.failure = Self.unapproved
        let hold = Self.hold(Self.off, helper)
        await Self.feed(hold, [.unknown])
        hold.set(limit: Self.on80)
        await Self.feed(hold, [try Self.adapter(50)])
        #expect(hold.failure?.cause == .needsApproval)
        helper.failure = nil
        hold.recheck()
        await Self.idle(hold)
        #expect(hold.failure == nil)
        #expect(helper.calls == ["resume", "resume"])
        hold.recheck()
        await Self.idle(hold)
        #expect(helper.calls == ["resume", "resume"])
    }

    // MARK: Lost leases

    @Test func aPauseTheHelperEndedIsAskedForOnceMore() async throws {
        let helper = FakeChargeHelper(), events = Events()
        let hold = Self.hold(Self.on80, helper, events)
        await Self.feed(hold, [try Self.adapter(80)])
        helper.endLatestLease()
        await Self.settle(hold)
        #expect(helper.calls == ["pause", "pause"])
        #expect(events.all.filter { $0 == .lost }.count == 1)
        #expect(Self.name(hold.state) == "paused")
    }

    @Test func aPauseLostWhenNoNewOneCanBeHadIsResumedOnceTheLimitGoesOff() async throws {
        let helper = FakeChargeHelper()
        let hold = Self.hold(Self.on80, helper)
        await Self.feed(hold, [try Self.adapter(80)])
        helper.failure = Self.refused
        helper.endLatestLease()
        await Self.settle(hold)
        #expect(Self.name(hold.state) == "unknown(failure)")
        helper.failure = nil
        hold.set(limit: Self.off)
        await Self.idle(hold)
        #expect(helper.calls == ["pause", "pause", "resume"])
        #expect(Self.name(hold.state) == "allowed")
    }

    @Test func aLossNamingALeaseAlreadyLetGoChangesNothing() async throws {
        let helper = FakeChargeHelper(), events = Events()
        let hold = Self.hold(Self.on80, helper, events)
        await Self.feed(hold, [try Self.adapter(80), try Self.adapter(79)])
        helper.endLatestLease()
        await Self.settle(hold)
        #expect(helper.calls == ["pause", "release"])
        #expect(!events.all.contains(.lost))
    }

    // MARK: Inputs that let charging run

    @Test func readingsThatStopReleaseThePause() async throws {
        let helper = FakeChargeHelper(), events = Events()
        let hold = Self.hold(Self.on80, helper, events)
        await Self.feed(hold, [try Self.adapter(85), .ended(nil)])
        #expect(helper.calls == ["pause", "release"])
        #expect(events.all.last == .asked(.release(.readingsEnded), limit: Self.on80, percent: nil, failure: nil))
    }

    @Test func unpluggingReleasesThePause() async throws {
        let helper = FakeChargeHelper(), events = Events()
        let hold = Self.hold(Self.on80, helper, events)
        await Self.feed(hold, [try Self.adapter(85), try Self.battery(85)])
        #expect(events.all.last == .asked(.release(.onBattery), limit: Self.on80, percent: 85, failure: nil))
    }

    @Test func inputsDuringAnAskAreEvaluatedOnceWhenItLands() async throws {
        let helper = FakeChargeHelper()
        let gate = DispatchSemaphore(value: 0)
        helper.gate = gate
        let hold = Self.hold(Self.on80, helper)
        hold.observe(try Self.adapter(80))
        hold.observe(try Self.adapter(79))
        hold.observe(try Self.adapter(78))
        gate.signal()
        await Self.idle(hold)
        #expect(helper.calls == ["pause", "release"])
    }

    // MARK: The decision

    @Test func theWantAndItsReasonForEachInput() throws {
        #expect(ChargeWant.of(limit: Self.off, battery: try Self.adapter(90)) == .allow(.limitOff))
        #expect(ChargeWant.of(limit: Self.on80, battery: .unknown) == .allow(.noReadingYet))
        #expect(ChargeWant.of(limit: Self.on80, battery: .ended(nil)) == .allow(.readingsEnded))
        #expect(ChargeWant.of(limit: Self.on80, battery: .known(nil)) == .allow(.noBattery))
        #expect(ChargeWant.of(limit: Self.on80, battery: try Self.battery(90)) == .allow(.onBattery))
        #expect(ChargeWant.of(limit: Self.on80, battery: try Self.adapter(79)) == .allow(.belowTarget))
        #expect(ChargeWant.of(limit: Self.on80, battery: try Self.adapter(80)) == .pause)
        #expect(ChargeWant.of(limit: Self.on80, battery: try Self.adapter(81)) == .pause)
        let charging = BatteryModel.State.known(try BatteryEvents.atTheLimit(percent: 80))
        #expect(ChargeWant.of(limit: Self.on80, battery: charging) == .pause)
    }

    @Test func eachEventSaysItselfInTheLog() {
        #expect(ChargeHoldEvent.asked(.pause, limit: Self.on80, percent: 80, failure: nil).line == "pause with limit on, target 80%, battery 80%: done")
        #expect(ChargeHoldEvent.asked(.release(.belowTarget), limit: Self.on80, percent: 79, failure: nil).line
            == "release (below target) with limit on, target 80%, battery 79%: done")
        #expect(ChargeHoldEvent.asked(.resume(.noReadingYet), limit: Self.off, percent: nil, failure: Self.refused).line
            == "resume (no reading yet) with limit off, target 80%, battery unread: failed: the helper failed: SMC said no (cause other, helper status enabled)")
    }

    @Test func theScreenSaysHowToFixAFailureTheUserCanAndWhatWentWrongOtherwise() {
        #expect(ChargingScreen.explanation(of: Self.unapproved, appName: "App") == "Allow \("App") in the background to hold the charge limit.")
        #expect(ChargingScreen.explanation(of: Self.refused, appName: "App") == "Couldn't hold the charge limit: \("the helper failed: SMC said no")")
    }
}

/// The real client, no helper needed.
@Suite struct ChargeLeaseTests {
    /// A pause asked of a service launchd has no job for fails at once as 4099, and the lease it was not granted is
    /// never reported lost.
    @Test func aPauseNoHelperGrantedFailsAndIsNeverReportedLost() async throws {
        final class Reports: @unchecked Sendable { let count = OSAllocatedUnfairLock(initialState: 0) }
        let reports = Reports()
        let client = HelperClient(service: "dev.orangedrink.no-such-helper")
        #expect {
            _ = try client.pauseCharging(lost: { _ in reports.count.withLock { $0 += 1 } })
        } throws: { error in
            guard case .connection(_, 4099, _) = error as? HelperCallError else { return false }
            return true
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(reports.count.withLock { $0 } == 0)
    }
}
