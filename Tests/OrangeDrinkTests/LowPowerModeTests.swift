import Foundation
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract: the helper writes the one key this Mac's pmset lists, on every
// power source; the panel's switch is the system's state and moves only when the system posts a change;
// asking for a change asks for the other state, and a change that did not happen says why until one does.
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

    @Test func aListingWithNeitherKeyOrBothIsRefusedQuotingIt() {
        let neither = Self.energyModeMac.replacingOccurrences(of: " powermode            0\n", with: "")
        #expect { try PowerModeKey(listing: neither) } throws: { "\($0)".contains("lists neither") && "\($0)".contains("womp") }
        #expect { try PowerModeKey(listing: Self.energyModeMac + "\n lowpowermode 0") } throws: { "\($0)".contains("lists both") }
    }

    @Test func onIsOneAndOffIsZeroOnEverySource() {
        #expect(PowerModeKey.powermode.arguments(on: true) == ["-a", "powermode", "1"])
        #expect(PowerModeKey.lowpowermode.arguments(on: false) == ["-a", "lowpowermode", "0"])
    }

    @Test func theWriteReadsTheListingThenWritesItsKey() throws {
        var ran: [[String]] = []
        let written = try LowPowerModeWrite.perform(true) { arguments throws(HelperFailure) in
            ran.append(arguments)
            return arguments == ["-g"] ? Self.otherMac : ""
        }
        #expect(ran == [["-g"], ["-a", "lowpowermode", "1"]])
        #expect(written == ["-a", "lowpowermode", "1"])
    }

    @Test func aFailedStepEndsTheWrite() {
        var ran: [[String]] = []
        #expect(throws: HelperFailure.self) {
            try LowPowerModeWrite.perform(false) { arguments throws(HelperFailure) in
                ran.append(arguments)
                throw HelperFailure("pmset \(arguments) exited 1")
            }
        }
        #expect(ran == [["-g"]])
    }

    @Test func theLogLineNamesWhoAskedWhatAndWhatPmsetDid() {
        #expect(LowPowerModeWrite.line(true, peer: 42, .success(["-a", "powermode", "1"])) == "low power mode on for pid 42: pmset -a powermode 1 ok")
        #expect(LowPowerModeWrite.line(false, peer: 7, .failure(HelperFailure("pmset -a powermode 0 exited 1: nope")))
                    == "low power mode off for pid 7 failed: pmset -a powermode 0 exited 1: nope")
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct LowPowerModeTests {
    /// The system as the model sees it: a state, the center that posts its changes, and what was asked of it.
    final class FakeSystem: @unchecked Sendable {
        var isOn = false
        let center = NotificationCenter()
        let asked: AsyncStream<Bool>
        private let continuation: AsyncStream<Bool>.Continuation
        var refusal: (any Error)?

        init() { (asked, continuation) = AsyncStream.makeStream() }

        @MainActor func model() -> LowPowerMode {
            LowPowerMode(read: { self.isOn }, center: center) { on in
                self.continuation.yield(on)
                if let refusal = self.refusal { throw refusal }
            }
        }

        /// The system changes its state and says so, as it does for a change made anywhere.
        @MainActor func change(to on: Bool) {
            isOn = on
            center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        }
    }

    @Test func theSwitchIsTheSystemsStateAndFollowsEachChangeItPosts() async {
        let system = FakeSystem()
        system.isOn = true
        let model = system.model()
        #expect(model.isOn)
        system.change(to: false)
        #expect(!model.isOn)
        system.change(to: true)
        #expect(model.isOn)
    }

    @Test func togglingAsksForTheOtherStateAndLeavesTheSwitchUntilTheSystemMoves() async {
        let system = FakeSystem()
        let model = system.model()
        await model.toggle().value
        var asked = system.asked.makeAsyncIterator()
        #expect(await asked.next() == true)
        #expect(!model.isOn)
        #expect(model.failure == nil)
        system.change(to: true)
        await model.toggle().value
        #expect(await asked.next() == false)
    }

    @Test func aChangeThatFailsSaysWhyUntilOneSucceeds() async {
        let system = FakeSystem()
        let model = system.model()
        system.refusal = HelperCallError.noReply(seconds: 10, service: "test")
        await model.toggle().value
        #expect(model.failure?.contains("no reply in 10 s") == true)
        system.refusal = nil
        await model.toggle().value
        #expect(model.failure == nil)
    }

    @Test func theLowPowerModeLetterFlipsItWithoutTouchingTheSections() async throws {
        let system = FakeSystem(), events = FakeKeyEvents(), sections = PanelSections(defaults: scratchDefaults())
        PanelKeyboard(sections: sections, lowPowerMode: system.model(), shortcuts: try ShortcutsModel(defaults: scratchDefaults()), events: events)
            .panelDidOpen(shown: { [] })
        #expect(events.type("l"))
        var asked = system.asked.makeAsyncIterator()
        #expect(await asked.next() == true)
        #expect(sections.open.isEmpty)
    }

    @Test func eachMenuShortcutActsOnItsOwnRow() {
        #expect(MenuShortcut.allCases.map(\.target) == [.section(.batteryInformation), .section(.appsUsingSignificantEnergy), .section(.connectedDevices), .lowPowerMode])
    }
}
