import Foundation
import ServiceManagement
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract: the helper writes the one key this Mac's pmset lists, on the power
// source the Mac is on, leaving every other source as System Settings set it; the panel's switch is the system's
// state and moves only when the system posts a change; a press asks for the other of what the switch shows, a
// press while that ask is unanswered does nothing, and a change that did not happen says why until one does.
@Suite struct PowerModeKeyTests {
    /// `pmset -g` on a MacBook Pro with an Energy Mode (Mac16,6, macOS 26.5), trimmed.
    static let energyModeMac = """
    System-wide power settings:
    Currently in use:
     standby              1
     Sleep On Power Button 1
     powernap             1
     sleep                1 (sleep prevented by caffeinate, powerd)
     displaysleep         10 (display sleep prevented by Safari)
     powermode            0
     womp                 0
    """
    /// The same listing on a Mac without one.
    static let otherMac = energyModeMac.replacingOccurrences(of: " powermode            0", with: " lowpowermode         1")

    @Test func aMacWithAnEnergyModeListsPowermodeAndAnyOtherLowpowermode() throws {
        #expect(try PowerModeKey(listing: Self.energyModeMac) == .powermode)
        #expect(try PowerModeKey(listing: Self.otherMac) == .lowpowermode)
    }

    /// The failure reaches the panel, so it says what was missing and leaves the listing out.
    @Test func aListingWithNeitherKeyOrBothIsRefusedWithoutQuotingIt() {
        let neither = Self.energyModeMac.replacingOccurrences(of: " powermode            0\n", with: "")
        #expect { try PowerModeKey(listing: neither) } throws: { "\($0)" == "pmset -g lists neither of powermode and lowpowermode" }
        #expect { try PowerModeKey(listing: Self.energyModeMac + "\n lowpowermode 0") } throws: { "\($0)" == "pmset -g lists both of powermode and lowpowermode" }
    }

    @Test func eachPowerSourceIOKitNamesIsPmsetsFlagAndHeading() throws {
        #expect(try PmsetSource(providing: "AC Power").flag == "-c")
        #expect(try PmsetSource(providing: "Battery Power").flag == "-b")
        #expect(try PmsetSource(providing: "UPS Power").flag == "-u")
        #expect(PmsetSource.battery.heading == "Battery Power:")
        #expect { try PmsetSource(providing: "Solar") } throws: { "\($0)" == "unknown power source \"Solar\"" }
    }

    @Test func theWriteReadsTheListingThenWritesItsKeyOnTheCurrentSourceOnly() throws {
        var ran: [[String]] = []
        let written = try LowPowerModeWrite.perform(true, source: .battery) { arguments throws(HelperFailure) in
            ran.append(arguments)
            return arguments == ["-g"] ? Self.otherMac : ""
        }
        #expect(ran == [["-g"], ["-b", "lowpowermode", "1"]])
        #expect(written == ["-b", "lowpowermode", "1"])
        #expect(PowerModeKey.powermode.arguments(on: false, source: .adapter) == ["-c", "powermode", "0"])
    }

    @Test func aFailedStepEndsTheWrite() {
        var ran: [[String]] = []
        #expect(throws: HelperFailure.self) {
            try LowPowerModeWrite.perform(false, source: .adapter) { arguments throws(HelperFailure) in
                ran.append(arguments)
                throw HelperFailure("pmset \(arguments) exited 1")
            }
        }
        #expect(ran == [["-g"]])
    }

    /// The runner the helper uses: a tool that fails is a failure with its output, one that outlives its deadline
    /// is killed and named, and one that cannot start says why.
    @Test func pmsetRunsToItsEndOrItsDeadline() throws {
        let later = Date(timeIntervalSinceNow: 10)
        _ = try PowerModeKey(listing: LowPowerModeWrite.pmset(["-g"], until: later))
        #expect { try LowPowerModeWrite.pmset(["-g", "no-such-setting"], until: later) } throws: { "\($0)".hasPrefix("pmset -g no-such-setting exited 1: ") }
        // A write that waited past its call's deadline is refused without running.
        #expect { try LowPowerModeWrite.pmset(["-g", "no-such-setting"], until: Date(timeIntervalSinceNow: -2)) } throws: {
            "\($0)".hasPrefix("pmset -g no-such-setting not run: the call's deadline passed 2")
        }
        #expect { try ChildProcess.run("/bin/sleep", ["5"], deadline: 1) } throws: { "\($0)" == "/bin/sleep was still running at its 1 s deadline and was killed" }
        #expect { try ChildProcess.run("/no/such/tool", []) } throws: { "\($0)" == "/no/such/tool could not start: No such file or directory" }
    }

    @Test func theLogLineNamesWhoAskedWhatAndWhatPmsetDid() {
        #expect(LowPowerModeWrite.line(true, peer: 42, .success(["-b", "powermode", "1"])) == "low power mode on for pid 42: pmset -b powermode 1 ok")
        #expect(LowPowerModeWrite.line(false, peer: 7, .failure(HelperFailure("pmset -c powermode 0 exited 1: nope")))
                    == "low power mode off for pid 7 failed: pmset -c powermode 0 exited 1: nope")
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct LowPowerModeTests {
    /// The system as the model sees it: a state, the center that posts its changes, what was asked of it, and
    /// how each ask goes.
    final class FakeSystem: @unchecked Sendable {
        var isOn = false
        let center = NotificationCenter()
        let asked: AsyncStream<Bool>
        private let continuation: AsyncStream<Bool>.Continuation
        /// Each ask's delay before it answers, in the order asked; none once they run out.
        var delays: [TimeInterval] = []
        private var answered = 0
        var refusal: HelperUseFailure?
        @MainActor var events: [LowPowerMode.Event] = []

        init() { (asked, continuation) = AsyncStream.makeStream() }

        @MainActor func model() -> LowPowerMode {
            LowPowerMode(read: { self.isOn }, center: center, write: { on throws(HelperUseFailure) in
                self.continuation.yield(on)
                let delay = self.answered < self.delays.count ? self.delays[self.answered] : 0
                self.answered += 1
                Thread.sleep(forTimeInterval: delay)
                if let refusal = self.refusal { throw refusal }
            }, record: { self.events.append($0) }, openLoginItems: { self.loginItemsShown += 1 })
        }

        /// How many times Login Items & Extensions was opened.
        @MainActor var loginItemsShown = 0

        /// The system changes its state and says so, as it does for a change made anywhere.
        @MainActor func change(to on: Bool) {
            isOn = on
            center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        }
    }

    @Test func theSwitchIsTheSystemsStateAndFollowsEachChangeItPosts() {
        let system = FakeSystem()
        system.isOn = true
        let model = system.model()
        #expect(model.isOn)
        system.change(to: false)
        #expect(!model.isOn)
        system.change(to: true)
        #expect(model.isOn)
        #expect(system.events == [.changed(false), .changed(true)])
    }

    /// A press asks for the other of what the switch shows, and the switch moves only when the system posts, which
    /// can be after the reply.
    @Test func aPressAsksForTheOtherOfWhatTheSwitchShows() async {
        let system = FakeSystem()
        let model = system.model()
        let ask = model.toggle()
        #expect(model.isAsking && !model.isOn)
        await ask.value
        #expect(!model.isAsking && !model.isOn)
        system.change(to: true)
        #expect(model.isOn)
        await model.toggle().value
        #expect(system.events == [.asked(true, failure: nil), .changed(true), .asked(false, failure: nil)])
    }

    /// One call in flight: a press before its reply does nothing, and a posted change does not end the ask.
    @Test func aPressWhileAskingDoesNothingUntilTheReply() async {
        let system = FakeSystem()
        system.delays = [0.3]
        let model = system.model()
        let first = model.toggle()
        system.change(to: true)
        #expect(model.isOn && model.isAsking)
        await model.toggle().value
        await first.value
        #expect(!model.isAsking)
        #expect(system.events == [.changed(true), .asked(true, failure: nil)])
        await model.toggle().value
        #expect(system.events.last == .asked(false, failure: nil))
    }

    @Test func aChangeThatFailsSaysWhyUntilOneSucceedsOrTheSystemMoves() async {
        let system = FakeSystem()
        let model = system.model()
        let noReply = HelperUseFailure(call: .noReply(seconds: 10, service: "test"), status: .enabled)
        system.refusal = noReply
        await model.toggle().value
        #expect(model.failure == noReply)
        #expect(!model.isAsking && !model.isOn)
        #expect(system.events.last == .asked(true, failure: noReply))
        system.refusal = nil
        await model.toggle().value
        #expect(model.failure == nil)

        system.refusal = HelperUseFailure(call: .failed("pmset -b powermode 1 exited 1"), status: .enabled)
        await model.toggle().value
        #expect(model.failure?.cause == .other)
        system.change(to: true)
        #expect(model.failure == nil)
    }

    /// The ticket's case: a press before the helper is allowed says so, and once it is allowed the same press works.
    /// The user follows the row to Login Items & Extensions, which closes the panel, so the reopened panel does not
    /// repeat the advice.
    @Test func aPressBeforeApprovalSaysSoAndThePressAfterItWorks() async {
        let system = FakeSystem()
        let model = system.model()
        let unapproved = HelperUseFailure(call: Self.unapproved, status: .requiresApproval)
        system.refusal = unapproved
        await model.toggle().value
        #expect(model.failure?.cause == .needsApproval)
        #expect(LowPowerMode.explanation(of: unapproved, appName: "App") == "Allow \("App") in the background to change Low Power Mode.")
        #expect(!model.isAsking && !model.isOn)
        model.openLoginItems()
        #expect(system.loginItemsShown == 1)
        model.panelDidClose()
        #expect(model.failure == nil)
        system.refusal = nil
        await model.toggle().value
        #expect(model.failure == nil)
        #expect(system.events == [.asked(true, failure: unapproved), .openedLoginItems, .dismissed(unapproved), .asked(true, failure: nil)])
    }

    /// A reply that lands after the panel closed is shown when it opens again: nobody has seen it yet.
    @Test func aFailureThatLandsWhileThePanelIsClosedWaitsForItToOpen() async {
        let system = FakeSystem()
        let model = system.model()
        let unapproved = HelperUseFailure(call: Self.unapproved, status: .requiresApproval)
        system.refusal = unapproved
        let asking = model.toggle()
        model.panelDidClose()
        await asking.value
        #expect(model.failure == unapproved)
        #expect(system.events == [.asked(true, failure: unapproved)])
    }

    /// Any other failure says what went wrong, and closing the panel forgets it too; the log says so.
    @Test func aFailureTheUserCannotFixSaysWhatWentWrong() async {
        let system = FakeSystem()
        let model = system.model()
        let failure = HelperUseFailure(call: .failed("pmset -c powermode 1 exited 1"), status: .enabled)
        system.refusal = failure
        await model.toggle().value
        #expect(LowPowerMode.explanation(of: failure, appName: "App") == "Couldn't change Low Power Mode: \("the helper failed: pmset -c powermode 1 exited 1")")
        model.panelDidClose()
        #expect(model.failure == nil)
        #expect(system.events == [.asked(true, failure: failure), .dismissed(failure)])
    }

    /// What an unapproved helper's call answers, measured (orange-admin-helper-b2q.1d4): launchd has no job to look up.
    static let unapproved = HelperCallError.connection(domain: "NSCocoaErrorDomain", code: 4099, description: "Couldn’t communicate with a helper application.")

    @Test func eachEventSaysItselfInTheLog() {
        #expect(LowPowerMode.Event.asked(true, failure: nil).line == "low power mode on: done")
        #expect(LowPowerMode.Event.asked(false, failure: HelperUseFailure(call: .failed("x"), status: .enabled)).line
                    == "low power mode off failed: the helper failed: x (cause other, helper status enabled)")
        #expect(LowPowerMode.Event.asked(true, failure: HelperUseFailure(call: Self.unapproved, status: .requiresApproval)).line
                    == "low power mode on failed: call failed: domain=NSCocoaErrorDomain code=4099 Couldn’t communicate with a helper application. (cause needsApproval, helper status requiresApproval)")
        #expect(LowPowerMode.Event.changed(true).line == "low power mode is on")
        #expect(LowPowerMode.Event.openedLoginItems.line == "opened Login Items & Extensions to allow the helper")
        #expect(LowPowerMode.Event.dismissed(HelperUseFailure(call: .failed("x"), status: .enabled)).line
                    == "panel closed; no longer showing: the helper failed: x (cause other, helper status enabled)")
    }

    @Test func theLowPowerModeLetterFlipsItAndAHeldLetterIsOnePress() async throws {
        let system = FakeSystem(), events = FakeKeyEvents(), sections = PanelSections(defaults: scratchDefaults())
        let model = system.model()
        PanelKeyboard(sections: sections, lowPowerMode: model, shortcuts: try ShortcutsModel(defaults: scratchDefaults()), events: events)
            .panelDidOpen(shown: { [.batteryInformation] })
        #expect(events.type("l"))
        #expect(events.type("l", repeating: true))
        #expect(events.type("i", repeating: true))
        var asked = system.asked.makeAsyncIterator()
        #expect(await asked.next() == true)
        #expect(sections.open.isEmpty)
        // The one press was the only ask: once it is answered, the next ask is the next press's, for the other of
        // the system's state.
        while model.isAsking { await Task.yield() }
        system.change(to: true)
        #expect(events.type("l"))
        #expect(await asked.next() == false)
    }

    @Test func eachMenuShortcutActsOnItsOwnRow() {
        #expect(MenuShortcut.allCases.map(\.target) == [.section(.batteryInformation), .section(.appsUsingSignificantEnergy), .section(.connectedDevices), .lowPowerMode])
    }
}

// [LAW:behavior-not-structure] The contract: a call that succeeds asks nothing of the registration; one that fails
// reads the helper's approval once and keeps it beside the call's own error, and only requiresApproval is a failure
// the user fixes by allowing the helper.
@Suite struct HelperAccessTests {
    final class Reads: @unchecked Sendable { var count = 0 }

    /// The app's path end to end, short of a helper: a real call to a service launchd has no job for fails at once
    /// as 4099, and the failure carries the status SMAppService reads for that plist, which this bundle lacks.
    @Test func theAppsCallCarriesTheStatusReadAfterItFails() {
        let access = HelperAccess(service: "dev.orangedrink.no-such-helper", plistName: "dev.orangedrink.no-such-helper.plist", registration: FakeRegistrationSystem().registration)
        #expect { try access.setLowPowerMode(true) } throws: { error in
            guard let failure = error as? HelperUseFailure, case .connection(_, 4099, _) = failure.call else { return false }
            return failure.status == .notFound && failure.cause == .notRegistered
        }
    }

    @Test func aCallThatSucceedsReadsNoStatus() throws {
        let reads = Reads()
        let value = try HelperAccess.explained({ () throws(HelperCallError) in 7 }, status: { reads.count += 1; return .requiresApproval }, reconcile: { _ in reads.count += 1 })
        #expect(value == 7 && reads.count == 0)
    }

    @Test(arguments: [SMAppService.Status.requiresApproval, .enabled, .notRegistered, .notFound])
    func aCallThatFailsKeepsItsErrorAndTheStatusReadOnceAndTheRegistrationHearsIt(status: SMAppService.Status) {
        let reads = Reads()
        let error = HelperCallError.connection(domain: "NSCocoaErrorDomain", code: 4099, description: "x")
        var heard: [HelperUseFailure] = []
        #expect {
            try HelperAccess.explained({ () throws(HelperCallError) in throw error }, status: { reads.count += 1; return status }, reconcile: { heard.append($0) })
        } throws: { ($0 as? HelperUseFailure) == HelperUseFailure(call: error, status: status) }
        #expect(reads.count == 1)
        #expect(heard == [HelperUseFailure(call: error, status: status)])
    }

    static let noReply = HelperCallError.noReply(seconds: 10, service: "x")
    static let connection = HelperCallError.connection(domain: "NSCocoaErrorDomain", code: 4099, description: "x")

    /// [LAW:one-source-of-truth] The one reading of a failure: a helper that answered is there whatever the status says.
    @Test(arguments: [
        (noReply, SMAppService.Status.requiresApproval, HelperUseFailure.Cause.needsApproval),
        (connection, .requiresApproval, .needsApproval),
        (HelperCallError.failed("x"), .requiresApproval, .other),
        (HelperCallError.unsupported("x"), .requiresApproval, .other),
        (connection, .notRegistered, .notRegistered),
        (connection, .notFound, .notRegistered),
        (noReply, .notRegistered, .notRegistered),
        (noReply, .enabled, .notAnswering),
        (connection, .enabled, .other),
        (HelperCallError.failed("x"), .enabled, .other),
        (HelperCallError.failed("x"), .notRegistered, .other),
        (HelperCallError.unsupported("x"), .notFound, .other)
    ])
    func aFailureHasOneCause(call: HelperCallError, status: SMAppService.Status, cause: HelperUseFailure.Cause) {
        #expect(HelperUseFailure(call: call, status: status).cause == cause)
    }

    /// [LAW:no-silent-failure] A status of enabled is not left to read as the truth.
    @Test func aHelperThatIsNotAnsweringSaysSoBesideItsStatus() {
        #expect(HelperUseFailure(call: Self.noReply, status: .enabled).description.hasSuffix("(cause notAnswering, helper status enabled)"))
    }

    @MainActor @Test func aControlSaysTheHelperIsNotAnsweringRatherThanHowToReadLaunchd() {
        for failure in [HelperUseFailure(call: Self.noReply, status: .enabled), HelperUseFailure(call: Self.connection, status: .notRegistered)] {
            #expect(LowPowerMode.explanation(of: failure, appName: "App") == "\("App")'s helper isn't answering, so Low Power Mode didn't change.")
            #expect(ChargingScreen.explanation(of: failure, appName: "App") == "\("App")'s helper isn't answering, so the charge limit isn't held.")
        }
    }
}
