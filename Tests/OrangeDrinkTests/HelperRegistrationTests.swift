import Foundation
import os
import ServiceManagement
import Testing
@testable import OrangeDrink

/// The system a registration talks to, scripted. Each call is noted; a closed `gate` holds the handshake, so a test can
/// see what waits for a step in progress.
final class FakeRegistrationSystem: @unchecked Sendable {
    struct State {
        var calls: [String] = []
        var events: [HelperRegistration.Event] = []
        var status = SMAppService.Status.notRegistered
        /// How many times `register` refuses, and the status it leaves when it does.
        var refusals = 0
        var refusedStatus = SMAppService.Status.notRegistered
        var handshake: HelperCallError?
        var holders: [Int32] = []
        var elapsed = Duration.zero
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    let gate = DispatchSemaphore(value: 0)
    var usesGate = false
    let start = ContinuousClock.now

    static let refusal = NSError(domain: "SMAppServiceErrorDomain", code: 1)

    var calls: [String] { state.withLock { $0.calls } }
    var events: [HelperRegistration.Event] { state.withLock { $0.events } }

    lazy var registration = HelperRegistration(effects: .init(
        register: { [self] in
            state.withLock {
                $0.calls.append("register")
                guard $0.refusals > 0 else { $0.status = .enabled; return nil }
                $0.refusals -= 1
                $0.status = $0.refusedStatus
                return Self.refusal
            }
        },
        unregister: { [self] in state.withLock { $0.calls.append("unregister"); $0.status = .notRegistered; return nil } },
        status: { [self] in state.withLock { $0.status } },
        handshake: { [self] in
            state.withLock { $0.calls.append("handshake") }
            if usesGate { gate.wait() }
            return state.withLock { $0.handshake }
        },
        holders: { [self] () throws(ProcessTableUnreadable) in state.withLock { $0.calls.append("holders"); return $0.holders } },
        now: { [self] in state.withLock { start + $0.elapsed } },
        pause: { [self] duration in state.withLock { $0.elapsed += duration } }
    ), record: { [self] event in state.withLock { $0.events.append(event) } })
}

@Suite struct HelperRegistrationTests {
    static let noReply = HelperCallError.noReply(seconds: 10, service: "x")
    static let notAnswering = HelperUseFailure(call: noReply, status: .enabled)
    static let noJob = HelperUseFailure(call: .connection(domain: "NSCocoaErrorDomain", code: 4099, description: "x"), status: .notRegistered)
    /// A refused `register`, as the outcome reads it.
    static let refusal = HelperRegistration.describe(FakeRegistrationSystem.refusal)

    /// A registration that has run past its exit, which libdispatch traps on releasing, so it is never released.
    static let ended = FakeRegistrationSystem()

    func wedged(_ configure: @Sendable (inout FakeRegistrationSystem.State) -> Void = { _ in }) -> FakeRegistrationSystem {
        let system = FakeRegistrationSystem()
        system.state.withLock { $0.handshake = Self.noReply; $0.status = .enabled; configure(&$0) }
        return system
    }

    @Test func aLaunchRegistersAndNothingElse() {
        let system = FakeRegistrationSystem()
        system.registration.launch()
        system.registration.waitForSteps()
        #expect(system.calls == ["register"])
        #expect(system.events == [.launched(.init(refusal: nil, status: "enabled", attempts: 1, elapsed: .zero))])
    }

    @Test(arguments: [SMAppService.Status.notRegistered, .notFound])
    func aRefusalWithNoRecordIsAskedAgainUntilAccepted(status: SMAppService.Status) {
        let system = FakeRegistrationSystem()
        system.state.withLock { $0.refusals = 3; $0.refusedStatus = status }
        system.registration.launch()
        system.registration.waitForSteps()
        #expect(system.calls == Array(repeating: "register", count: 4))
        #expect(system.events == [.launched(.init(refusal: nil, status: "enabled", attempts: 4, elapsed: .seconds(3)))])
    }

    @Test func aRefusalForApprovalEndsAtOnce() {
        let system = FakeRegistrationSystem()
        system.state.withLock { $0.refusals = 5; $0.refusedStatus = .requiresApproval }
        system.registration.launch()
        system.registration.waitForSteps()
        #expect(system.events == [.launched(.init(refusal: Self.refusal, status: "requiresApproval", attempts: 1, elapsed: .zero))])
    }

    @Test func theWindowEndsInTheRefusal() {
        let system = FakeRegistrationSystem()
        system.state.withLock { $0.refusals = .max }
        system.registration.launch()
        system.registration.waitForSteps()
        #expect(system.events == [.launched(.init(refusal: Self.refusal, status: "notRegistered", attempts: 4, elapsed: .seconds(3)))])
    }

    @Test(arguments: [HelperUseFailure(call: noReply, status: .requiresApproval), HelperUseFailure(call: .failed("x"), status: .enabled)])
    func aFailureNoRegistrationCanHelpDoesNothing(failure: HelperUseFailure) {
        let system = FakeRegistrationSystem()
        system.registration.reconcile(after: failure)
        system.registration.waitForSteps()
        #expect(system.calls.isEmpty && system.events.isEmpty)
    }

    @Test func aCallThatFindsNoJobRegistersAndUnregistersNothing() {
        let system = FakeRegistrationSystem()
        system.registration.reconcile(after: Self.noJob)
        system.registration.waitForSteps()
        #expect(system.calls == ["register"])
        #expect(system.events == [.reregistered(.init(refusal: nil, status: "enabled", attempts: 1, elapsed: .zero))])
    }

    /// An unregister would stop the helper, and with it any pause it holds, so a helper that answers keeps its job.
    @Test func aSlowHelperThatAnswersTheHandshakeKeepsItsJob() {
        let system = wedged { $0.handshake = nil }
        system.registration.reconcile(after: Self.notAnswering)
        system.registration.waitForSteps()
        #expect(system.calls == ["handshake"])
        #expect(system.events == [.leftAlone(handshake: nil)])
    }

    @Test func aHandshakeThatFailsAnyOtherWayLeavesTheJobAndSaysHow() {
        let failed = HelperCallError.failed("x")
        let system = wedged { $0.handshake = failed }
        system.registration.reconcile(after: Self.notAnswering)
        system.registration.waitForSteps()
        #expect(system.calls == ["handshake"])
        #expect(system.events == [.leftAlone(handshake: failed.description)])
    }

    @Test func aJobThatAnswersNothingIsClearedThenRegisteredAcrossTheRefusal() {
        let system = wedged { $0.refusals = 2 }
        system.registration.reconcile(after: Self.notAnswering)
        system.registration.waitForSteps()
        #expect(system.calls == ["handshake", "holders", "unregister", "register", "register", "register"])
        #expect(system.events == [.repaired(.unregistered(error: nil), .init(refusal: nil, status: "enabled", attempts: 3, elapsed: .seconds(2)))])
    }

    @Test func aJobAnotherCopyHoldsIsNotCleared() {
        let system = wedged { $0.holders = [41] }
        system.registration.reconcile(after: Self.notAnswering)
        system.registration.waitForSteps()
        #expect(system.calls == ["handshake", "holders", "register"])
        #expect(system.events == [.repaired(.heldBy(pids: [41]), .init(refusal: nil, status: "enabled", attempts: 1, elapsed: .zero))])
    }

    @Test func aFailedCallReturnsBeforeItsReconcileEnds() {
        let system = wedged()
        system.usesGate = true
        let registration = system.registration
        #expect(throws: Self.notAnswering) {
            try HelperAccess.explained({ () throws(HelperCallError) in throw Self.noReply }, status: { .enabled }, reconcile: registration.reconcile(after:))
        }
        #expect(system.events.isEmpty)
        system.gate.signal()
        registration.waitForSteps()
        #expect(system.events.count == 1)
    }

    /// An ask comes after what is ahead of it, so it does not meet a job half repaired.
    @Test func anAskWaitsForAReconcileAhead() {
        let system = wedged()
        system.usesGate = true
        let registration = system.registration
        registration.reconcile(after: Self.notAnswering)
        let passed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            registration.waitForSteps()
            passed.signal()
        }
        #expect(passed.wait(timeout: .now() + .milliseconds(100)) == .timedOut)
        system.gate.signal()
        #expect(passed.wait(timeout: .now() + .seconds(5)) == .success)
    }

    @Test func twoReconcilesDoNotInterleave() {
        let system = wedged()
        system.usesGate = true
        let registration = system.registration
        registration.reconcile(after: Self.notAnswering)
        registration.reconcile(after: Self.notAnswering)
        system.gate.signal()
        system.gate.signal()
        registration.waitForSteps()
        let one = ["handshake", "holders", "unregister", "register"]
        #expect(system.calls == one + one)
    }

    @Test func theExitReleasesWhatTheStepsAheadOfItRegistered() {
        let system = wedged()
        system.usesGate = true
        let ended = FakeRegistrationSystem.keep(system)
        ended.reconcile(after: Self.notAnswering)
        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            ended.exit()
            exited.signal()
        }
        #expect(exited.wait(timeout: .now() + .milliseconds(100)) == .timedOut)
        system.gate.signal()
        #expect(exited.wait(timeout: .now() + .seconds(5)) == .success)
        #expect(system.calls == ["handshake", "holders", "unregister", "register", "holders", "unregister"])
        #expect(system.events.last == .exited(.unregistered(error: nil), status: "notRegistered"))
    }

    @Test func aCallTheExitCutShortRegistersNothingBehindIt() {
        let registration = Self.ended.registration
        registration.exit()
        registration.reconcile(after: Self.noJob)
        Thread.sleep(forTimeInterval: 0.1)
        #expect(Self.ended.calls == ["holders", "unregister"])
    }
}

extension FakeRegistrationSystem {
    private static let kept = OSAllocatedUnfairLock<[FakeRegistrationSystem]>(initialState: [])

    /// Its registration, kept for the run: one past its exit traps on release.
    static func keep(_ system: FakeRegistrationSystem) -> HelperRegistration {
        kept.withLock { $0.append(system) }
        return system.registration
    }
}
