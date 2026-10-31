import AppKit
import ApplicationServices
import IOKit.ps
import Testing
import ViewInspector
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what is closed, what is left showing, when the app looks, and what the log
// says when it cannot. macOS is stood in at its seam: `make battery-notification-check` is the real one.
@MainActor @Suite struct BatteryNotificationDismissalTests {
    /// The app's model over a FakeMac, with the wakes a running app gets.
    @MainActor private final class Bed {
        let mac = FakeMac()
        let clock = ManualTimekeeper()
        let center = NotificationCenter()
        let settings: SystemNotificationSettingsModel
        private(set) var events: [BatteryNotificationDismissal.Event] = []
        private(set) var opened = 0
        private let warnings = AsyncThrowingStream<Void, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        private var pending: [BatteryNotificationDismissal.Event] = []
        private var waiter: CheckedContinuation<BatteryNotificationDismissal.Event, Never>?
        private(set) var model: BatteryNotificationDismissal!

        init(_ test: String = #function, on: Bool = true) throws {
            let defaults = UserDefaults(suiteName: "BatteryNotificationDismissalTests.\(test)")!
            defaults.removePersistentDomain(forName: "BatteryNotificationDismissalTests.\(test)")
            settings = try SystemNotificationSettingsModel(defaults: defaults)
            try settings.update { $0.dismissBatteryNotifications = on }
        }

        /// Builds the model, and returns with its launch's pass done.
        @discardableResult func launch() async throws -> BatteryNotificationDismissal.Pass {
            model = BatteryNotificationDismissal(settings: settings, effects: mac.effects, warningChanges: warnings.stream, center: center, timekeeper: clock,
                                                 record: { [weak self] in self?.arrived($0) },
                                                 openAccessibility: { [weak self] in self?.opened += 1 })
            return try await levelChanged()
        }

        /// powerd's post: returns with the pass it woke.
        @discardableResult func levelChanged() async throws -> BatteryNotificationDismissal.Pass {
            warnings.continuation.yield()
            return await nextPass()
        }

        @discardableResult func warn(_ level: IOPSLowBatteryWarningLevel) async throws -> BatteryNotificationDismissal.Pass {
            mac.with { $0.level = level }
            return try await levelChanged()
        }

        private func arrived(_ event: BatteryNotificationDismissal.Event) {
            events.append(event)
            guard let waiting = waiter else { return pending.append(event) }
            waiter = nil
            waiting.resume(returning: event)
        }

        /// The next event of any kind.
        func nextEvent() async -> BatteryNotificationDismissal.Event {
            if !pending.isEmpty { return pending.removeFirst() }
            return await withCheckedContinuation { waiter = $0 }
        }

        func nextPass() async -> BatteryNotificationDismissal.Pass {
            while true {
                if case .pass(let pass) = await nextEvent() { return pass }
            }
        }

        @discardableResult func activated() async throws -> BatteryNotificationDismissal.Pass {
            center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            return await nextPass()
        }

        func screen() throws -> GeneralScreen {
            GeneralScreen(appearance: try NotificationAppearanceModel(defaults: Self.scratch), look: try AppAppearanceModel(defaults: Self.scratch),
                          language: try AppLanguageModel(defaults: Self.scratch),
                          launchAtLogin: LaunchAtLogin(effects: LaunchAtLogin.Effects(register: { nil }, unregister: { nil }, status: { .notRegistered }), center: center),
                          batteryNotifications: model)
        }

        private static var scratch: UserDefaults { UserDefaults(suiteName: "BatteryNotificationDismissalTests")! }

        func theSwitch() throws -> InspectableView<ViewType.Toggle> {
            try screen().inspect().find(ViewType.Toggle.self, where: { try $0.labelView().text().string() == "Dismiss macOS Battery Notifications" })
        }

        func accessibilityLink() throws -> InspectableView<ViewType.Button> {
            try screen().inspect().find(button: SystemSettingFailureLine.Fix.accessibilityTitle.english)
        }
    }

    // MARK: The row and the switch

    @Test func theSwitchIsOffOnAFirstLaunchAndPressingItStoresItOn() async throws {
        let bed = try Bed(on: false)
        try await bed.launch()
        #expect(try bed.theSwitch().isOn() == false)
        try bed.theSwitch().tap()
        #expect(bed.settings.value.dismissBatteryNotifications)
        #expect(try bed.theSwitch().isOn())
    }

    @Test func theSwitchOnWithTheAppUntrustedAsksWithThePromptOption() async throws {
        let bed = try Bed(on: false)
        bed.mac.with { $0.trusted = false }
        try await bed.launch()
        try bed.settings.update { $0.dismissBatteryNotifications = true }
        #expect(await bed.nextEvent() == .askedForTrust(prompted: true))
        #expect(bed.mac.promptAsks == 1)
    }

    @Test func theSwitchOnWithTheAppTrustedAsksNothing() async throws {
        let bed = try Bed(on: false)
        try await bed.launch()
        try bed.settings.update { $0.dismissBatteryNotifications = true }
        #expect(await bed.nextEvent() == .askedForTrust(prompted: false))
        #expect(bed.mac.promptAsks == 0)
    }

    @Test func aLaunchWithTheSwitchStoredOnAndTheAppUntrustedDoesNotAsk() async throws {
        let bed = try Bed()
        bed.mac.with { $0.trusted = false }
        try await bed.launch()
        #expect(bed.mac.promptAsks == 0)
        #expect(!bed.events.contains(.askedForTrust(prompted: true)))
    }

    @Test func onAndUntrustedTheRowSaysSoAndOpensAccessibilityUntilAnActivationReadsItTrusted() async throws {
        let bed = try Bed()
        bed.mac.with { $0.trusted = false }
        try await bed.launch()
        #expect(bed.model.needsAccessibility)
        try bed.accessibilityLink().tap()
        #expect(bed.opened == 1)
        #expect(bed.events.contains(.openedAccessibility))

        bed.mac.with { $0.trusted = true }
        try await bed.activated()
        #expect(!bed.model.needsAccessibility)
        #expect(throws: (any Error).self) { try bed.accessibilityLink() }
    }

    @Test func offAndUntrustedTheRowSaysNothing() async throws {
        let bed = try Bed(on: false)
        bed.mac.with { $0.trusted = false }
        try await bed.launch()
        #expect(!bed.model.needsAccessibility)
    }

    @Test func trustGivenWithNoActivationIsReadByTheNextWarning() async throws {
        let bed = try Bed()
        bed.mac.with { $0.trusted = false; $0.showing = [NotificationFixtures.alert] }
        try await bed.launch()
        #expect(try await bed.warn(kIOPSLowBatteryWarningFinal).outcome == .notWanted)

        bed.mac.with { $0.trusted = true }
        async let closing = bed.warn(kIOPSLowBatteryWarningFinal)
        await bed.clock.asleep()
        bed.clock.advance(by: BatteryNotificationDismissal.closeDeadline)
        #expect(try await closing.outcome == .closed)
    }

    // MARK: The rule

    @Test func everyRecordedLowBatteryAlertIsClosedThroughItsSecondCustomAction() {
        for alert in NotificationFixtures.lowBatteryAlerts {
            let custom = alert.actions.filter { $0.hasPrefix("Name:") }
            #expect(alert.verdict(knowing: NotificationFixtures.words) == .close(action: custom[1]), "\(alert.description)")
        }
    }

    /// o9e's shapes: the title alone on macOS 14, and title and body joined by each of these on 15 and 26.
    @Test(arguments: [", ", "、", " ", "\u{200F}\u{2068}"]) func theRecordingsHoldEachDescriptionShape(joiner: String) {
        let joined = NotificationFixtures.lowBatteryAlerts.contains { $0.description.contains($0.title + joiner) || $0.description.contains(joiner + $0.title) }
        let titleAlone = NotificationFixtures.lowBatteryAlerts.contains { $0.description == $0.title }
        #expect(joined && titleAlone)
    }

    @Test func everyRecordedNotificationFromAnotherAppIsLeftShowing() {
        for other in NotificationFixtures.otherApps {
            guard case .refused = other.verdict(knowing: NotificationFixtures.words) else {
                Issue.record("closes \(other.description)")
                continue
            }
        }
    }

    @Test func anotherAppsAlertWithTheSameWordsIsLeftShowing() {
        let alert = NotificationFixtures.alert
        let scriptEditor = NotificationValues(subrole: NotificationValues.alert, title: alert.title, body: alert.body, description: "Script Editor, \(alert.description)", actions: alert.actions)
        #expect(scriptEditor.verdict(knowing: NotificationFixtures.words) == .refused(.description))
    }

    @Test func aStackIsLeftShowing() {
        let alert = NotificationFixtures.alert
        let stacked = NotificationValues(subrole: NotificationValues.alert, title: alert.title, body: alert.body, description: "\(alert.description), stacked", actions: alert.actions + ["Name:Clear All"])
        #expect(stacked.verdict(knowing: NotificationFixtures.words) == .refused(.description))
    }

    @Test(arguments: [["AXPress", "Name:Close"], ["AXPress", "Name:Show Details", "Name:Show", "Name:Close"], ["AXPress"]])
    func anAlertWithoutExactlyTwoCustomActionsIsLeftShowing(actions: [String]) {
        let alert = NotificationFixtures.alert
        let reshaped = NotificationValues(subrole: alert.subrole, title: alert.title, body: alert.body, description: alert.description, actions: actions)
        #expect(reshaped.verdict(knowing: NotificationFixtures.words) == .refused(.actions))
    }

    /// The system's own alert in the same window, which launching the app posts.
    @Test(arguments: [("Background Items Added", "Login Items"), ("App Background Activity", "Login Items, App Background Activity, “OrangeDrink” can run in the background for all users. Do you want to allow this?")])
    func theSystemsLoginItemsAlertIsLeftShowing(title: String, description: String) {
        let alert = NotificationValues(subrole: NotificationValues.alert, title: title, body: "“OrangeDrink” can run in the background for all users. Do you want to allow this?",
                                       description: description, actions: ["AXPress", "Name:Show Details", "Name:Close"])
        #expect(alert.verdict(knowing: NotificationFixtures.words) == .refused(.words))
    }

    // MARK: Closing

    @Test func theAppClosesTheLowBatteryAlertAndNothingElse() async throws {
        let bed = try Bed()
        bed.mac.with { $0.showing = [NotificationFixtures.banner, NotificationFixtures.alert] }
        try await bed.launch()
        async let closing = bed.warn(kIOPSLowBatteryWarningFinal)
        await bed.clock.asleep()
        bed.clock.advance(by: BatteryNotificationDismissal.closeDeadline)
        #expect(try await closing.outcome == .closed)
        #expect(bed.mac.presses == [NotificationFixtures.alert.actions.filter { $0.hasPrefix("Name:") }[1]])
        #expect(bed.mac.with { $0.showing } == [NotificationFixtures.banner])
    }

    @Test func withTheSwitchOffNothingIsClosedOrRead() async throws {
        let bed = try Bed(on: false)
        bed.mac.with { $0.showing = [NotificationFixtures.alert] }
        try await bed.launch()
        #expect(try await bed.warn(kIOPSLowBatteryWarningFinal).outcome == .notWanted)
        #expect(bed.mac.presses.isEmpty && bed.mac.looks == 0 && bed.mac.with { $0.watched } == nil)
    }

    // MARK: When it runs

    @Test func withNoWarningTheAppReadsNoTreeWatchesNothingAndStartsNoTimer() async throws {
        let bed = try Bed()
        bed.mac.with { $0.showing = [NotificationFixtures.alert] }
        #expect(try await bed.launch().outcome == .notWanted)
        try await bed.levelChanged()
        try await bed.activated()
        #expect(bed.mac.looks == 0 && bed.mac.with { $0.watches.isEmpty && $0.tableReads == 0 })
        #expect(bed.clock.sleeping == 0)
    }

    @Test func aWarningStartsWatchingAndClosesWhatArrivesThen() async throws {
        let bed = try Bed()
        try await bed.launch()
        let pass = try await bed.warn(kIOPSLowBatteryWarningEarly)
        #expect(pass.observer == .started && pass.outcome == .looked(.init([])))

        bed.mac.with { $0.showing = [NotificationFixtures.alert] }
        bed.mac.layoutChanged()
        await bed.clock.asleep()
        bed.clock.advance(by: BatteryNotificationDismissal.closeDeadline)
        #expect(await bed.nextPass().outcome == .closed)
    }

    @Test func aLaunchDuringAWarningClosesWhatIsShowing() async throws {
        let bed = try Bed()
        bed.mac.with { $0.level = kIOPSLowBatteryWarningEarly; $0.showing = [NotificationFixtures.alert] }
        async let launching = bed.launch()
        await bed.clock.asleep()
        bed.clock.advance(by: BatteryNotificationDismissal.closeDeadline)
        #expect(try await launching.outcome == .closed)
    }

    @Test func theSwitchGoingOnDuringAWarningClosesWhatIsShowing() async throws {
        let bed = try Bed(on: false)
        bed.mac.with { $0.level = kIOPSLowBatteryWarningEarly; $0.showing = [NotificationFixtures.alert] }
        try await bed.launch()
        try bed.settings.update { $0.dismissBatteryNotifications = true }
        await bed.clock.asleep()
        bed.clock.advance(by: BatteryNotificationDismissal.closeDeadline)
        #expect(await bed.nextPass().outcome == .closed)
    }

    /// macOS 14 and 15: the early warning's alert is the discharge's one notification.
    @Test func theLevelMovingFromEarlyToFinalWithTheAlertClosedClosesNothingMore() async throws {
        let bed = try Bed()
        bed.mac.with { $0.showing = [NotificationFixtures.alert] }
        try await bed.launch()
        async let closing = bed.warn(kIOPSLowBatteryWarningEarly)
        await bed.clock.asleep()
        bed.clock.advance(by: BatteryNotificationDismissal.closeDeadline)
        #expect(try await closing.outcome == .closed)
        #expect(try await bed.warn(kIOPSLowBatteryWarningFinal).outcome == .looked(.init([])))
        #expect(bed.mac.presses.count == 1)
    }

    @Test func aReposedAlertAtTheFinalWarningIsClosedToo() async throws {
        let bed = try Bed()
        bed.mac.with { $0.showing = [NotificationFixtures.alert] }
        try await bed.launch()
        async let closing = bed.warn(kIOPSLowBatteryWarningEarly)
        await bed.clock.asleep()
        bed.clock.advance(by: BatteryNotificationDismissal.closeDeadline)
        _ = try await closing

        bed.mac.with { $0.showing = [NotificationFixtures.alert] }
        async let again = bed.warn(kIOPSLowBatteryWarningFinal)
        await bed.clock.asleep()
        bed.clock.advance(by: BatteryNotificationDismissal.closeDeadline)
        #expect(try await again.outcome == .closed)
        #expect(bed.mac.presses.count == 2)
    }

    @Test func theLevelFallingToNoneEndsTheWatchingAndALaterWarningClosesAgainWithFreshTables() async throws {
        let bed = try Bed()
        bed.mac.with { $0.showing = [NotificationFixtures.alert] }
        try await bed.launch()
        async let closing = bed.warn(kIOPSLowBatteryWarningFinal)
        await bed.clock.asleep()
        bed.clock.advance(by: BatteryNotificationDismissal.closeDeadline)
        _ = try await closing

        let ended = try await bed.warn(kIOPSLowBatteryWarningNone)
        #expect(ended.observer == .stopped && ended.episode == .idle && bed.mac.with { $0.watched } == nil)

        bed.mac.with { $0.showing = [NotificationFixtures.alert] }
        async let again = bed.warn(kIOPSLowBatteryWarningEarly)
        await bed.clock.asleep()
        bed.clock.advance(by: BatteryNotificationDismissal.closeDeadline)
        #expect(try await again.outcome == .closed)
        #expect(bed.mac.with { $0.tableReads } == 2)
    }

    @Test func theSwitchGoingOffEndsTheWatching() async throws {
        let bed = try Bed()
        bed.mac.with { $0.level = kIOPSLowBatteryWarningEarly }
        try await bed.launch()
        #expect(bed.mac.with { $0.watched } != nil)
        try bed.settings.update { $0.dismissBatteryNotifications = false }
        let pass = await bed.nextPass()
        #expect(pass.observer == .stopped && pass.outcome == .notWanted)
    }

    @Test func notificationCenterRestartingIsWatchedAgainOnTheNextWake() async throws {
        let bed = try Bed()
        bed.mac.with { $0.level = kIOPSLowBatteryWarningEarly }
        try await bed.launch()
        bed.mac.with { $0.notificationCenter = 777 }
        let pass = try await bed.warn(kIOPSLowBatteryWarningFinal)
        #expect(pass.observer == .started)
        #expect(bed.mac.with { $0.watches } == [501, 777])
    }

    // MARK: What goes wrong

    @Test func anAlertStillThereAtTheDeadlineIsPressedOnceAndLogged() async throws {
        let bed = try Bed()
        bed.mac.with { $0.pressCloses = false; $0.showing = [NotificationFixtures.alert] }
        try await bed.launch()
        async let closing = bed.warn(kIOPSLowBatteryWarningFinal)
        await bed.clock.asleep()
        bed.clock.advance(by: BatteryNotificationDismissal.closeDeadline)
        let pass = try await closing
        #expect(pass.outcome == .closeFailed(.stayed))
        #expect(BatteryNotificationDismissal.Event.pass(pass).line.contains("close failed: still showing"))

        bed.mac.layoutChanged()
        let after = await bed.nextPass()
        #expect(after.outcome == .looked(.init([.close(action: "")])))
        #expect(bed.mac.presses.count == 1)
    }

    @Test func aPressThatReturnsAnErrorIsNotRepeatedAndIsLogged() async throws {
        let bed = try Bed()
        bed.mac.with { $0.pressCloses = false; $0.pressReturns = .cannotComplete; $0.showing = [NotificationFixtures.alert] }
        try await bed.launch()
        #expect(try await bed.warn(kIOPSLowBatteryWarningFinal).outcome == .closeFailed(.press(.cannotComplete)))
        bed.mac.layoutChanged()
        _ = await bed.nextPass()
        #expect(bed.mac.presses.count == 1)
    }

    @Test func aSecondLookThatFailsIsNotAClosedAlertAndIsNotPressedAgain() async throws {
        let bed = try Bed()
        bed.mac.with { $0.pressCloses = false; $0.failLookAfterPress = .cannotComplete; $0.showing = [NotificationFixtures.alert] }
        try await bed.launch()
        async let closing = bed.warn(kIOPSLowBatteryWarningFinal)
        await bed.clock.asleep()
        bed.clock.advance(by: BatteryNotificationDismissal.closeDeadline)
        #expect(try await closing.outcome == .closeFailed(.secondLook(.read(attribute: "AXWindows", error: .cannotComplete))))
        #expect(bed.mac.presses.count == 1)
    }

    @Test func aStuckEpisodeEndsWithTheWarning() async throws {
        let bed = try Bed()
        bed.mac.with { $0.pressCloses = false; $0.pressReturns = .cannotComplete; $0.showing = [NotificationFixtures.alert] }
        try await bed.launch()
        #expect(try await bed.warn(kIOPSLowBatteryWarningFinal).outcome == .closeFailed(.press(.cannotComplete)))
        try await bed.warn(kIOPSLowBatteryWarningNone)
        bed.mac.with { $0.pressReturns = .success; $0.pressCloses = true }
        async let again = bed.warn(kIOPSLowBatteryWarningEarly)
        await bed.clock.asleep()
        bed.clock.advance(by: BatteryNotificationDismissal.closeDeadline)
        #expect(try await again.outcome == .closed)
    }

    @Test func aFailedReadIsLoggedAndClosesNothingAndIsNotNothingShowing() async throws {
        let bed = try Bed()
        bed.mac.with { $0.windowsRead = .failed(.cannotComplete); $0.showing = [NotificationFixtures.alert] }
        try await bed.launch()
        let pass = try await bed.warn(kIOPSLowBatteryWarningFinal)
        #expect(pass.outcome == .lookFailed(.read(attribute: "AXWindows", error: .cannotComplete)))
        #expect(bed.mac.presses.isEmpty)
    }

    @Test func notificationCenterNotRunningIsLoggedAsSuch() async throws {
        let bed = try Bed()
        bed.mac.with { $0.notificationCenter = nil }
        try await bed.launch()
        #expect(try await bed.warn(kIOPSLowBatteryWarningFinal).outcome == .lookFailed(.notRunning))
    }

    @Test func aFailedObserverIsLoggedAndTheLookStillRuns() async throws {
        let bed = try Bed()
        bed.mac.with { $0.observeFails = .cannotComplete }
        try await bed.launch()
        let pass = try await bed.warn(kIOPSLowBatteryWarningFinal)
        #expect(pass.observer == .failed(.cannotComplete) && pass.outcome == .looked(.init([])))
        #expect(BatteryNotificationDismissal.Event.pass(pass).line.contains("observer failed with AXError"))
    }

    @Test(arguments: [LowBatteryTables.Failure.unreadable(table: "InfoPlist"), .noWords])
    func tablesThatCannotGiveTheWordsCloseNothingAndSaySoOnEveryPass(failure: LowBatteryTables.Failure) async throws {
        let bed = try Bed()
        bed.mac.with { $0.words = .failure(failure); $0.showing = [NotificationFixtures.alert] }
        try await bed.launch()
        #expect(try await bed.warn(kIOPSLowBatteryWarningFinal).outcome == .cannotRecognise(failure))
        #expect(try await bed.warn(kIOPSLowBatteryWarningFinal).outcome == .cannotRecognise(failure))
        #expect(bed.mac.presses.isEmpty && bed.mac.looks == 0 && bed.mac.with { $0.tableReads } == 1)
    }

    @Test func aFailedLowBatteryRegistrationIsLogged() async throws {
        let bed = try Bed()
        try await bed.launch()
        let failing = AsyncThrowingStream<Void, any Error> { $0.finish(throwing: BatteryMonitorError.notifyRegistration(status: 1)) }
        let events = AsyncStream<BatteryNotificationDismissal.Event>.makeStream()
        let model = BatteryNotificationDismissal(settings: bed.settings, effects: bed.mac.effects, warningChanges: failing, center: bed.center, record: { events.continuation.yield($0) })
        var iterator = events.stream.makeAsyncIterator()
        guard case .noWarningChanges = await iterator.next() else { throw CancellationError() }
        _ = model
    }

    /// The log tells an alert macOS reshaped from another app's banner, with no notification's words in it.
    @Test func theLogNamesTheClauseThatRefusedAndCarriesNoWords() async throws {
        let bed = try Bed()
        let alert = NotificationFixtures.alert
        let reshaped = NotificationValues(subrole: alert.subrole, title: alert.title, body: alert.body, description: alert.description, actions: alert.actions + ["Name:More"])
        bed.mac.with { $0.showing = [reshaped, NotificationFixtures.banner] }
        try await bed.launch()
        let line = BatteryNotificationDismissal.Event.pass(try await bed.warn(kIOPSLowBatteryWarningFinal)).line
        #expect(line.contains("shown 2, refused subrole 1, refused actions 1"))
        #expect(!line.contains(alert.title))
    }

    @Test func aPassSaysWhyItDidNothing() async throws {
        let bed = try Bed()
        bed.mac.with { $0.trusted = false }
        let line = BatteryNotificationDismissal.Event.pass(try await bed.launch()).line
        #expect(line == "pass: level 1, switch on, untrusted, idle, observer unchanged, not wanted")
    }
}

// [LAW:behavior-not-structure] The contract is what comes back for a tree another process owns.
@Suite struct NotificationCenterLookTests {
    private func look(_ windows: [any AccessibleElement]) -> Result<[ShownNotification], LookFailure> {
        NotificationCenterLook.look(windows: .value(windows))
    }

    @Test func theLookFindsTheNotificationInTheDialogWindowWithItsValues() throws {
        let shown = try look([RecordedElement.window([RecordedElement.notification(NotificationFixtures.alert)])]).get()
        #expect(shown.map(\.values) == [NotificationFixtures.alert])
    }

    @Test func noWindowIsNothingShowing() throws {
        #expect(try NotificationCenterLook.look(windows: .absent).get().isEmpty)
    }

    /// NotificationCenter's widget windows loop, and walking them overflowed the stack on a real Mac.
    @Test func anotherWindowIsNotWalked() throws {
        let widget = RecordedElement.window(subrole: "AXStandardWindow", [])
        widget.kids = [widget]
        #expect(try look([widget, RecordedElement.window([RecordedElement.notification(NotificationFixtures.alert)])]).get().count == 1)
    }

    @Test func aTreeWithACycleEnds() {
        let window = RecordedElement.window([])
        window.kids = [window]
        #expect(throws: LookFailure.pastBound) { try look([window]).get() }
    }

    private func chain(depth: Int) -> RecordedElement {
        (0..<depth).reduce(RecordedElement.window([])) { child, _ in RecordedElement.window([child]) }
    }

    @Test func aTreePastTheDepthBoundEnds() throws {
        #expect(try look([chain(depth: NotificationCenterLook.depthBound)]).get().isEmpty)
        #expect(throws: LookFailure.pastBound) { try look([chain(depth: NotificationCenterLook.depthBound + 1)]).get() }
    }

    @Test func aTreePastTheVisitBoundEnds() {
        let wide = RecordedElement.window((0...NotificationCenterLook.visitBound).map { _ in RecordedElement() })
        #expect(throws: LookFailure.pastBound) { try look([wide]).get() }
    }

    @Test(arguments: ["AXChildren", "AXSubrole"]) func aFailedReadInsideTheTreeIsAFailure(attribute: String) {
        let inner = RecordedElement()
        inner.failing[attribute] = .cannotComplete
        #expect(throws: LookFailure.read(attribute: attribute, error: .cannotComplete)) { try look([RecordedElement.window([inner])]).get() }
    }

    @Test func aFailedActionsReadIsAFailureAndNotAnAlertWithNoActions() {
        let notification = RecordedElement.notification(NotificationFixtures.alert)
        (notification.kids[0] as! RecordedElement).failing["actions"] = .cannotComplete
        #expect(throws: LookFailure.read(attribute: "actions", error: .cannotComplete)) { try look([RecordedElement.window([notification])]).get() }
    }

    @Test func aFailedWindowsReadIsAFailure() {
        #expect(throws: LookFailure.read(attribute: "AXWindows", error: .cannotComplete)) { try NotificationCenterLook.look(windows: .failed(.cannotComplete)).get() }
    }
}

// [LAW:behavior-not-structure] The contract is the words the rule compares with, and a failure where there are none.
@Suite struct LowBatteryTablesTests {
    private static var names: [String: Any] { ["en": ["CFBundleDisplayName": "Low Battery", "NSHumanReadableCopyright": "©"], "LocProvenance": ["en": 1]] }
    private static var bodies: [String: Any] { ["en": ["LOW_BATTERY_BODY": "Plug it in.", "LOW_BATTERY_LOCKDOWN_BODY": "Lockdown."], "LocProvenance": ["en": 1]] }

    @Test func everyLanguageGivesItsTitleWithEachBodyAndProvenanceIsNotAReshape() throws {
        #expect(try LowBatteryTables.parse(names: Self.names, bodies: Self.bodies).get()
            == [LowBatteryWords(title: "Low Battery", body: "Plug it in."), LowBatteryWords(title: "Low Battery", body: "Lockdown.")])
    }

    @Test func aReshapedTableIsAFailure() {
        #expect(throws: LowBatteryTables.Failure.noWords) { try LowBatteryTables.parse(names: ["en": ["Title": "Low Battery"]], bodies: Self.bodies).get() }
        #expect(throws: LowBatteryTables.Failure.noWords) { try LowBatteryTables.parse(names: Self.names, bodies: ["en": "Plug it in."]).get() }
    }

    @Test func aMissingTableIsAFailure() {
        #expect(throws: LowBatteryTables.Failure.unreadable(table: "InfoPlist")) {
            try LowBatteryTables.read(from: URL(fileURLWithPath: "/nonexistent")).get()
        }
    }

    @Test func aFileThatIsNotATableIsAFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not a table".utf8).write(to: directory.appendingPathComponent("InfoPlist.loctable"))
        #expect(throws: LowBatteryTables.Failure.unreadable(table: "InfoPlist")) { try LowBatteryTables.read(from: directory).get() }
    }

    /// macOS's own tables, on the macOS running this test.
    @Test func theSystemsTablesGiveTheEnglishWords() throws {
        let words = try LowBatteryTables.read(from: LowBatteryTables.directory).get()
        #expect(words.contains(NotificationFixtures.words.first { $0.title == "Low Battery" }!))
    }
}
