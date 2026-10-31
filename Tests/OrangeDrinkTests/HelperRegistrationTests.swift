import Foundation
import os
import ServiceManagement
import Testing
@testable import OrangeDrink

/// The system a registration talks to, scripted. Each call is noted; a closed `gate` holds each handshake, and `entered`
/// says one has reached it, so a test can see what waits for a step in progress.
final class FakeRegistrationSystem: @unchecked Sendable {
    struct State {
        var calls: [String] = []
        var events: [HelperRegistration.Event] = []
        var status = SMAppService.Status.notRegistered
        /// How many times `register` refuses, and the status it leaves when it does.
        var refusals = 0
        var refusedStatus = SMAppService.Status.notRegistered
        var handshake: HelperCallError?
        /// What the handshake ends in once the job has been cleared.
        var handshakeAfterClearing: HelperCallError?
        var holders: [Int32] = []
        var elapsed = Duration.zero
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    let gate = DispatchSemaphore(value: 0)
    let entered = DispatchSemaphore(value: 0)
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
        unregister: { [self] in state.withLock { $0.calls.append("unregister"); $0.status = .notRegistered; $0.handshake = $0.handshakeAfterClearing; return nil } },
        status: { [self] in state.withLock { $0.status } },
        handshake: { [self] in
            state.withLock { $0.calls.append("handshake") }
            if usesGate {
                entered.signal()
                gate.wait()
            }
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
        #expect(system.calls == ["register", "handshake"])
        #expect(system.events == [.reregistered(.init(refusal: nil, status: "enabled", attempts: 1, elapsed: .zero), handshake: nil)])
    }

    /// No `unregister` here opens the refusal window, so a copy refused for good holds up no other control's call.
    @Test func aCallThatFindsNoJobAsksOnceAndTheNextInputAsksAgain() {
        let system = FakeRegistrationSystem()
        system.state.withLock { $0.refusals = 1 }
        system.registration.reconcile(after: Self.noJob)
        system.registration.reconcile(after: Self.noJob)
        system.registration.waitForSteps()
        #expect(system.calls == ["register", "handshake", "register", "handshake"])
        #expect(system.events == [.reregistered(.init(refusal: Self.refusal, status: "notRegistered", attempts: 1, elapsed: .zero), handshake: nil),
                                  .reregistered(.init(refusal: nil, status: "enabled", attempts: 1, elapsed: .zero), handshake: nil)])
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
        #expect(system.calls == ["handshake", "holders", "unregister", "register", "register", "register", "handshake"])
        #expect(system.events == [.repaired(.unregistered(error: nil), .init(refusal: nil, status: "enabled", attempts: 3, elapsed: .seconds(2)), handshake: nil)])
    }

    /// The status reads enabled through a wedge, so only the handshake can say the repair did not take.
    @Test func aRepairThatLeavesTheHelperSilentSaysSo() {
        let system = wedged { $0.handshakeAfterClearing = Self.noReply }
        system.registration.reconcile(after: Self.notAnswering)
        system.registration.waitForSteps()
        #expect(system.events == [.repaired(.unregistered(error: nil), .init(refusal: nil, status: "enabled", attempts: 1, elapsed: .zero), handshake: Self.noReply.description)])
    }

    /// `register` leaves a job launchd will not run as it is, so nothing is asked of it and the line claims no repair.
    @Test func aJobAnotherCopyHoldsIsKept() {
        let system = wedged { $0.holders = [41] }
        system.registration.reconcile(after: Self.notAnswering)
        system.registration.waitForSteps()
        #expect(system.calls == ["handshake", "holders"])
        #expect(system.events == [.kept(.heldBy(pids: [41]))])
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
        system.gate.signal()
        registration.waitForSteps()
        #expect(system.events.count == 1)
    }

    /// Every control reaches the helper through HelperAccess, so none meets a job half repaired.
    @Test func aCallWaitsForAReconcileAhead() {
        let system = wedged()
        system.usesGate = true
        let registration = system.registration
        registration.reconcile(after: Self.notAnswering)
        #expect(system.entered.wait(timeout: .now() + .seconds(5)) == .success)
        let access = HelperAccess(service: "dev.orangedrink.no-such-helper", plistName: "dev.orangedrink.no-such-helper.plist", registration: registration)
        let returned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            #expect(throws: HelperUseFailure.self) { try access.setLowPowerMode(true) }
            returned.signal()
        }
        #expect(returned.wait(timeout: .now() + .milliseconds(100)) == .timedOut)
        // The repair's two handshakes, and the one after the reconcile the call's own failure asks for.
        for _ in 0..<3 { system.gate.signal() }
        #expect(returned.wait(timeout: .now() + .seconds(5)) == .success)
        registration.waitForSteps()
    }

    @Test func twoReconcilesDoNotInterleave() {
        let system = wedged { $0.handshakeAfterClearing = Self.noReply }
        system.usesGate = true
        let registration = system.registration
        registration.reconcile(after: Self.notAnswering)
        registration.reconcile(after: Self.notAnswering)
        for _ in 0..<4 { system.gate.signal() }
        registration.waitForSteps()
        let one = ["handshake", "holders", "unregister", "register", "handshake"]
        #expect(system.calls == one + one)
    }

    @Test func theExitReleasesWhatTheStepsAheadOfItRegistered() {
        let system = wedged()
        system.usesGate = true
        let registration = system.registration
        registration.reconcile(after: Self.notAnswering)
        #expect(system.entered.wait(timeout: .now() + .seconds(5)) == .success)
        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            registration.exit()
            exited.signal()
        }
        #expect(exited.wait(timeout: .now() + .milliseconds(100)) == .timedOut)
        system.gate.signal()
        system.gate.signal()
        #expect(exited.wait(timeout: .now() + .seconds(5)) == .success)
        #expect(system.calls == ["handshake", "holders", "unregister", "register", "handshake", "holders", "unregister"])
        #expect(system.events.last == .exited(.unregistered(error: nil), status: "notRegistered"))
    }

    /// A second repair would only be undone by the exit, so the exit waits for the one step already running. The gate
    /// opens for four handshakes, so a second repair shows in the calls instead of hanging.
    @Test func theExitRunsNoReconcileStillWaiting() {
        let system = wedged { $0.handshakeAfterClearing = Self.noReply }
        system.usesGate = true
        let registration = system.registration
        registration.reconcile(after: Self.notAnswering)
        #expect(system.entered.wait(timeout: .now() + .seconds(5)) == .success)
        registration.reconcile(after: Self.notAnswering)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) {
            for _ in 0..<4 { system.gate.signal() }
        }
        registration.exit()
        #expect(system.calls == ["handshake", "holders", "unregister", "register", "handshake", "holders", "unregister"])
    }

    @Test func aCallTheExitCutShortRegistersNothingBehindIt() {
        let system = FakeRegistrationSystem()
        system.registration.exit()
        system.registration.reconcile(after: Self.noJob)
        system.registration.waitForSteps()
        #expect(system.calls == ["holders", "unregister"])
    }
}
