import AppKit
import os
import ServiceManagement
import Testing
import ViewInspector
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what the switch shows for what the system says, what a press asks of it,
// and what a press the system refuses says. SMAppService is stood in at its seam: `make login-item-check` is the real one.
@MainActor @Suite struct LaunchAtLoginTests {
    /// The system: a status a new model reads as a relaunched app does, and what each call does to it.
    private final class System: @unchecked Sendable {
        let center = NotificationCenter()
        private let state = OSAllocatedUnfairLock(initialState: State())
        @MainActor var events: [LaunchAtLogin.Event] = []
        @MainActor var loginItemsShown = 0

        private struct State {
            var status = SMAppService.Status.notRegistered
            var calls: [String] = []
            /// What register leaves, and the error it gives.
            var registerLeaves = SMAppService.Status.enabled
            var error: NSError?
        }

        var status: SMAppService.Status {
            get { state.withLock { $0.status } }
            set { state.withLock { $0.status = newValue } }
        }
        var calls: [String] { state.withLock { $0.calls } }

        func registering(leaves status: SMAppService.Status, error: NSError? = nil) {
            state.withLock { $0.registerLeaves = status; $0.error = error }
        }

        private var effects: LaunchAtLogin.Effects {
            LaunchAtLogin.Effects(register: {
                self.state.withLock { $0.calls.append("register"); $0.status = $0.registerLeaves; return $0.error }
            }, unregister: {
                self.state.withLock { $0.calls.append("unregister"); $0.status = .notRegistered; return $0.error }
            }, status: { self.status })
        }

        /// The model as the app builds it, once its first read has landed.
        @MainActor func model() async -> LaunchAtLogin {
            let model = LaunchAtLogin(effects: effects, center: center, record: { self.events.append($0) }, openLoginItems: { self.loginItemsShown += 1 })
            await model.asking?.value
            return model
        }

        /// A model whose first read has not been answered, for as long as `gate` stays shut.
        @MainActor func unansweredModel(gate: DispatchSemaphore) -> LaunchAtLogin {
            let effects = effects
            return LaunchAtLogin(effects: LaunchAtLogin.Effects(register: effects.register, unregister: effects.unregister, status: {
                gate.wait()
                return effects.status()
            }), center: center, record: { self.events.append($0) })
        }
    }

    private let system = System()

    private func screen(_ login: LaunchAtLogin) throws -> GeneralScreen {
        GeneralScreen(appearance: try NotificationAppearanceModel(defaults: Self.defaults()), look: try AppAppearanceModel(defaults: Self.defaults()),
                      language: try AppLanguageModel(defaults: Self.defaults()), launchAtLogin: login)
    }

    private static func defaults() -> UserDefaults { UserDefaults(suiteName: "LaunchAtLoginTests")! }

    private func theSwitch(_ login: LaunchAtLogin) throws -> InspectableView<ViewType.Toggle> {
        try screen(login).inspect().find(ViewType.Toggle.self, where: { try $0.labelView().text().string() == "Launch at Login" })
    }

    private func press(_ login: LaunchAtLogin) async throws {
        try theSwitch(login).tap()
        await login.asking?.value
    }

    /// The ticket's test: nothing but the system keeps the choice, so a relaunch shows what the system holds.
    @Test func theSwitchTurnedOnThenOffShowsSoOnTheScreenBuiltAgainAsOnARelaunch() async throws {
        let first = await system.model()
        #expect(try theSwitch(first).isOn() == false)

        try await press(first)
        let relaunched = await system.model()
        #expect(try theSwitch(relaunched).isOn())

        try await press(relaunched)
        let again = await system.model()
        #expect(try theSwitch(again).isOn() == false)
        #expect(system.calls == ["register", "unregister"])
    }

    @Test(arguments: [(SMAppService.Status.enabled, true), (.notRegistered, false), (.notFound, false), (.requiresApproval, false)])
    func onlyWhatMacOSStartsAtLoginReadsOn(status: SMAppService.Status, on: Bool) async {
        system.status = status
        #expect(await system.model().isOn == on)
    }

    @Test func theSwitchCannotBePressedUntilTheSystemHasAnswered() async throws {
        let gate = DispatchSemaphore(value: 0)
        let login = system.unansweredModel(gate: gate)
        #expect(login.status == nil)
        #expect(try theSwitch(login).isDisabled())
        gate.signal()
        await login.asking?.value
        #expect(try theSwitch(login).isDisabled() == false)

        // Coming back starts a read, and a press in it would be dropped with the switch still showing it pressed.
        system.center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(try theSwitch(login).isDisabled())
        gate.signal()
        await login.asking?.value
        #expect(try theSwitch(login).isDisabled() == false)
    }

    /// macOS can throw for an item already registered, so the status decides.
    @Test func aPressThatThrowsButReachesWhatItAskedForRefusesNothing() async throws {
        system.registering(leaves: .enabled, error: NSError(domain: "d", code: 1, userInfo: [NSLocalizedDescriptionKey: "already registered"]))
        let login = await system.model()
        try await press(login)
        #expect(login.isOn)
        #expect(login.refusal == nil)
        #expect(system.events.last == .answered(.set(true), status: "enabled", error: "d 1 already registered"))
    }

    @Test func aPressMacOSHoldsForApprovalSaysSoAndLeadsToLoginItems() async throws {
        system.registering(leaves: .requiresApproval)
        let login = await system.model()
        #expect(login.refusal == nil)
        try await press(login)
        #expect(login.isOn == false)
        #expect(login.refusal == .needsApproval)
        try screen(login).inspect().find(button: "Open Login Items & Extensions…").tap()
        #expect(system.loginItemsShown == 1)
        #expect(system.events.last == .openedLoginItems)
    }

    @Test func aPressThatFailsSaysWhyAndOffersNoSetting() async throws {
        system.registering(leaves: .notFound, error: NSError(domain: "d", code: 2, userInfo: [NSLocalizedDescriptionKey: "broke"]))
        let login = await system.model()
        try await press(login)
        #expect(login.refusal == .failed("d 2 broke"))
        #expect(throws: (any Error).self) { try screen(login).inspect().find(button: "Open Login Items & Extensions…") }
    }

    /// The status is a Swift name, so it goes in the log and not in front of someone reading French.
    @Test func aPressWithNoErrorThatChangedNothingLogsTheStatusAndShowsNoReason() async {
        system.registering(leaves: .notFound)
        let login = await system.model()
        login.set(true)
        await login.asking?.value
        #expect(login.refusal == .failed(nil))
        #expect(system.events.last == .answered(.set(true), status: "notFound", error: nil))
    }

    /// The user turned it off in System Settings: a plain off switch, with no advice nobody asked for.
    @Test func comingBackPicksUpAChangeMadeInSystemSettingsAndForgetsTheAdvice() async {
        system.registering(leaves: .requiresApproval)
        let login = await system.model()
        login.set(true)
        await login.asking?.value

        system.status = .enabled
        system.center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await login.asking?.value
        #expect(login.isOn)
        #expect(login.refusal == nil)

        system.status = .requiresApproval
        system.center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await login.asking?.value
        #expect(login.isOn == false)
        #expect(login.refusal == nil)
    }

    /// macOS applies an approval late, and someone who went to look and came back has not been answered: the advice is
    /// still true.
    @Test func comingBackToAStatusThatHasNotMovedKeepsTheAdvice() async {
        system.registering(leaves: .requiresApproval)
        let login = await system.model()
        login.set(true)
        await login.asking?.value

        system.center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await login.asking?.value
        #expect(login.refusal == .needsApproval)
    }

    /// A stuck call shows in the log as an ask with no answer, and what it held up, and a later call never overlaps it.
    @Test func aCallUnansweredShowsInTheLogAndHoldsTheOthersBack() async {
        let gate = DispatchSemaphore(value: 0)
        let login = system.unansweredModel(gate: gate)
        login.set(true)
        system.center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(system.events == [.asked(.read), .ignored(.set(true)), .ignored(.read)])
        #expect(system.calls.isEmpty)
        gate.signal()
        await login.asking?.value
        #expect(system.events.last == .answered(.read, status: "notRegistered", error: nil))
    }

    @Test func thePressIsInTheLogBeforeItsAnswer() async {
        let login = await system.model()
        system.events = []
        login.set(true)
        #expect(system.events == [.asked(.set(true))])
        await login.asking?.value
        #expect(system.events == [.asked(.set(true)), .answered(.set(true), status: "enabled", error: nil)])
    }

    /// scripts/login-item-check reads these lines.
    @Test func theLogNamesEachCallAndWhatTheSystemSaid() {
        #expect(LaunchAtLogin.Event.asked(.set(true)).line == "launch at login on: asked")
        #expect(LaunchAtLogin.Event.ignored(.read).line == "launch at login read: ignored, another call is unanswered")
        #expect(LaunchAtLogin.Event.answered(.set(true), status: "enabled", error: nil).line == "launch at login on: status enabled")
        #expect(LaunchAtLogin.Event.answered(.set(false), status: "notRegistered", error: "d 1 x").line == "launch at login off: status notRegistered; d 1 x")
        #expect(LaunchAtLogin.Event.openedLoginItems.line == "opened Login Items & Extensions to allow the login item")
    }
}
