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
        var handshake = HelperRegistration.Handshake.own
        /// What the handshake ends in once the job has been cleared.
        var handshakeAfterClearing = HelperRegistration.Handshake.own
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
    static let older = HelperRegistration.Handshake.otherCode(executable: "/Applications/OrangeDrink.app/Contents/MacOS/OrangeDrinkHelper", cdhash: Data([2]))
    static let registered = HelperRegistration.Outcome(refusal: nil, status: "enabled", attempts: 1, elapsed: .zero)

    func wedged(_ configure: @Sendable (inout FakeRegistrationSystem.State) -> Void = { _ in }) -> FakeRegistrationSystem {
        let system = FakeRegistrationSystem()
        system.state.withLock { $0.handshake = .failed(Self.noReply); $0.status = .enabled; configure(&$0) }
        return system
    }

    @Test func aLaunchThatFindsItsOwnHelperLeavesTheJob() {
        let system = FakeRegistrationSystem()
        system.registration.launch()
        system.registration.waitForSteps()
        #expect(system.calls == ["register", "handshake"])
        #expect(system.events == [.launched(Self.registered), .leftAlone(.own)])
    }

    /// A crash left the older copy's helper running: `register` leaves it, so this copy's would never serve.
    @Test func aLaunchThatFindsAnotherCopysHelperReplacesIt() {
        let system = FakeRegistrationSystem()
        system.state.withLock { $0.handshake = Self.older }
        system.registration.launch()
        system.registration.waitForSteps()
        #expect(system.calls == ["register", "handshake", "holders", "unregister", "register", "handshake"])
        #expect(system.events == [.launched(Self.registered), .repaired(found: Self.older, .unregistered(error: nil), Self.registered, handshake: .own)])
    }

    @Test func aLaunchLeavesAHelperAnotherRunningCopyHolds() {
        let system = FakeRegistrationSystem()
        system.state.withLock { $0.handshake = Self.older; $0.holders = [41] }
        system.registration.launch()
        system.registration.waitForSteps()
        #expect(system.calls == ["register", "handshake", "holders"])
        #expect(system.events == [.launched(Self.registered), .kept(.heldBy(pids: [41]), Self.older)])
    }

    /// The holder's end tells nobody, so the first failed call after it is what replaces the job.
    @Test func aCallReplacesAHelperOnceTheCopyThatHeldItHasGone() {
        let system = FakeRegistrationSystem()
        system.state.withLock { $0.handshake = Self.older; $0.holders = [41] }
        system.registration.launch()
        system.registration.waitForSteps()
        system.state.withLock { $0.holders = []; $0.status = .enabled }
        system.registration.reconcile(after: HelperUseFailure(call: .connection(domain: "NSCocoaErrorDomain", code: 4097, description: "x"), status: .enabled))
        system.registration.waitForSteps()
        #expect(system.events.last == .repaired(found: Self.older, .unregistered(error: nil), Self.registered, handshake: .own))
    }

    @Test func aRepairThatStillFindsAnotherCopysHelperSaysSo() {
        let system = wedged { $0.handshake = Self.older; $0.handshakeAfterClearing = Self.older }
        system.registration.reconcile(after: Self.notAnswering)
        system.registration.waitForSteps()
        #expect(system.events == [.repaired(found: Self.older, .unregistered(error: nil), Self.registered, handshake: Self.older)])
    }

    @Test func aCallThatFindsNoJobReplacesOneLaunchdStillWillNotRun() {
        let system = FakeRegistrationSystem()
        system.state.withLock { $0.handshake = .failed(Self.noReply) }
        system.registration.reconcile(after: Self.noJob)
        system.registration.waitForSteps()
        #expect(system.calls == ["register", "handshake", "holders", "unregister", "register", "handshake"])
        #expect(system.events == [.reregistered(Self.registered), .repaired(found: .failed(Self.noReply), .unregistered(error: nil), Self.registered, handshake: .own)])
    }

    @Test func aHandshakeReadsTheCDHashNotThePath() {
        typealias Handshake = HelperRegistration.Handshake
        let path = "/Applications/OrangeDrink.app/Contents/MacOS/OrangeDrinkHelper"
        let answer = Result<HelperIdentity, HelperCallError>.success(HelperIdentity(executable: path, euid: 0, cdhash: Data([1])))
        #expect(Handshake(reply: answer, embedded: .success(Data([1]))) == .own)
        #expect(Handshake(reply: answer, embedded: .success(Data([2]))) == .otherCode(executable: path, cdhash: Data([1])))
        #expect(Handshake(reply: .failure(Self.noReply), embedded: .success(Data([1]))) == .failed(Self.noReply))
    }

    /// With no file to run, a new job could not answer, whatever the helper said.
    @Test(arguments: [Result<HelperIdentity, HelperCallError>.failure(noReply), .success(HelperIdentity(executable: "/x", euid: 0, cdhash: Data([1])))])
    func aHandshakeWithNoEmbeddedFileReplacesNothing(reply: Result<HelperIdentity, HelperCallError>) {
        let handshake = HelperRegistration.Handshake(reply: reply, embedded: .failure(HelperFailure("gone")))
        #expect(handshake == .embeddedUnreadable("gone"))
        #expect(!handshake.replacesJob)
    }

    @Test(arguments: [
        (HelperRegistration.Handshake.own, false),
        (older, true),
        (.failed(noReply), true),
        (.failed(.connection(domain: NSCocoaErrorDomain, code: NSXPCConnectionInterrupted, description: "x")), true),
        (.failed(.connection(domain: NSCocoaErrorDomain, code: NSXPCConnectionInvalid, description: "x")), false),
        (.failed(.failed("x")), false),
        (.failed(.unsupported("x")), false),
        (.embeddedUnreadable("x"), false)
    ])
    func oneAnswerSaysWhetherTheJobIsReplaced(handshake: HelperRegistration.Handshake, replaces: Bool) {
        #expect(handshake.replacesJob == replaces)
    }

    @Test(arguments: [SMAppService.Status.notRegistered, .notFound])
    func aRefusalWithNoRecordIsAskedAgainUntilAccepted(status: SMAppService.Status) {
        let system = FakeRegistrationSystem()
        system.state.withLock { $0.refusals = 3; $0.refusedStatus = status }
        system.registration.launch()
        system.registration.waitForSteps()
        #expect(system.calls == Array(repeating: "register", count: 4) + ["handshake"])
        #expect(system.events == [.launched(.init(refusal: nil, status: "enabled", attempts: 4, elapsed: .seconds(3))), .leftAlone(.own)])
    }

    /// `unregister` would take the record out of Login Items, where the user allows it, so other code stays until they do.
    @Test func aRefusalForApprovalEndsAtOnce() {
        let system = FakeRegistrationSystem()
        system.state.withLock { $0.refusals = 5; $0.refusedStatus = .requiresApproval; $0.handshake = Self.older }
        system.registration.launch()
        system.registration.waitForSteps()
        #expect(system.calls == ["register"])
        #expect(system.events == [.launched(.init(refusal: Self.refusal, status: "requiresApproval", attempts: 1, elapsed: .zero)), .awaitingApproval])
    }

    @Test func aCallThatFindsNoJobAndEndsAwaitingApprovalLooksAtNothing() {
        let system = FakeRegistrationSystem()
        system.state.withLock { $0.refusals = 1; $0.refusedStatus = .requiresApproval; $0.handshake = Self.older }
        system.registration.reconcile(after: Self.noJob)
        system.registration.waitForSteps()
        #expect(system.calls == ["register"])
        #expect(system.events.last == .awaitingApproval)
    }

    @Test func theWindowEndsInTheRefusal() {
        let system = FakeRegistrationSystem()
        system.state.withLock { $0.refusals = .max }
        system.registration.launch()
        system.registration.waitForSteps()
        #expect(system.events.first == .launched(.init(refusal: Self.refusal, status: "notRegistered", attempts: 4, elapsed: .seconds(3))))
    }

    @Test func aFailureOfApprovalAsksNothing() {
        let system = FakeRegistrationSystem()
        system.state.withLock { $0.status = .requiresApproval }
        system.registration.reconcile(after: HelperUseFailure(call: Self.noReply, status: .requiresApproval))
        system.registration.waitForSteps()
        #expect(system.calls.isEmpty)
        #expect(system.events == [.awaitingApproval])
    }

    /// An older helper can answer that it cannot do what a newer copy asks, so an answer does not end the look.
    @Test(arguments: [HelperCallError.failed("x"), .unsupported("x")])
    func aFailureTheHelperAnsweredStillLooksAtTheJob(call: HelperCallError) {
        let system = FakeRegistrationSystem()
        system.state.withLock { $0.handshake = Self.older; $0.status = .enabled }
        system.registration.reconcile(after: HelperUseFailure(call: call, status: .enabled))
        system.registration.waitForSteps()
        #expect(system.events == [.repaired(found: Self.older, .unregistered(error: nil), Self.registered, handshake: .own)])
    }

    @Test func aCallThatFindsNoJobRegistersAndUnregistersNothing() {
        let system = FakeRegistrationSystem()
        system.registration.reconcile(after: Self.noJob)
        system.registration.waitForSteps()
        #expect(system.calls == ["register", "handshake"])
        #expect(system.events == [.reregistered(Self.registered), .leftAlone(.own)])
    }

    /// No `unregister` here opens the refusal window, so a copy refused for good holds up no other control's call.
    @Test func aCallThatFindsNoJobAsksOnceAndTheNextInputAsksAgain() {
        let system = FakeRegistrationSystem()
        system.state.withLock { $0.refusals = 1 }
        system.registration.reconcile(after: Self.noJob)
        system.registration.reconcile(after: Self.noJob)
        system.registration.waitForSteps()
        #expect(system.calls == ["register", "handshake", "register", "handshake"])
        #expect(system.events == [.reregistered(.init(refusal: Self.refusal, status: "notRegistered", attempts: 1, elapsed: .zero)), .leftAlone(.own),
                                  .reregistered(Self.registered), .leftAlone(.own)])
    }

    /// An unregister would stop the helper, and with it any pause it holds, so a helper that answers keeps its job.
    @Test func aSlowHelperThatAnswersTheHandshakeKeepsItsJob() {
        let system = wedged { $0.handshake = .own }
        system.registration.reconcile(after: Self.notAnswering)
        system.registration.waitForSteps()
        #expect(system.calls == ["handshake"])
        #expect(system.events == [.leftAlone(.own)])
    }

    @Test func aHandshakeThatFailsAnyOtherWayLeavesTheJobAndSaysHow() {
        let failed = HelperCallError.failed("x")
        let system = wedged { $0.handshake = .failed(failed) }
        system.registration.reconcile(after: Self.notAnswering)
        system.registration.waitForSteps()
        #expect(system.calls == ["handshake"])
        #expect(system.events == [.leftAlone(.failed(failed))])
    }

    @Test func aJobThatAnswersNothingIsClearedThenRegisteredAcrossTheRefusal() {
        let system = wedged { $0.refusals = 2 }
        system.registration.reconcile(after: Self.notAnswering)
        system.registration.waitForSteps()
        #expect(system.calls == ["handshake", "holders", "unregister", "register", "register", "register", "handshake"])
        #expect(system.events == [.repaired(found: .failed(Self.noReply), .unregistered(error: nil), .init(refusal: nil, status: "enabled", attempts: 3, elapsed: .seconds(2)), handshake: .own)])
    }

    /// The status reads enabled through a wedge, so only the handshake can say the repair did not take.
    @Test func aRepairThatLeavesTheHelperSilentSaysSo() {
        let system = wedged { $0.handshakeAfterClearing = .failed(Self.noReply) }
        system.registration.reconcile(after: Self.notAnswering)
        system.registration.waitForSteps()
        #expect(system.events == [.repaired(found: .failed(Self.noReply), .unregistered(error: nil), Self.registered, handshake: .failed(Self.noReply))])
    }

    /// `register` leaves a job launchd will not run as it is, so nothing is asked of it and the line claims no repair.
    @Test func aJobAnotherCopyHoldsIsKept() {
        let system = wedged { $0.holders = [41] }
        system.registration.reconcile(after: Self.notAnswering)
        system.registration.waitForSteps()
        #expect(system.calls == ["handshake", "holders"])
        #expect(system.events == [.kept(.heldBy(pids: [41]), .failed(Self.noReply))])
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
        let system = wedged { $0.handshakeAfterClearing = .failed(Self.noReply) }
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
        let system = wedged { $0.handshakeAfterClearing = .failed(Self.noReply) }
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
