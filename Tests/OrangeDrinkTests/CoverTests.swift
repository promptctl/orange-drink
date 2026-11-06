import AppKit
import Carbon.HIToolbox
import Foundation
import os
import SwiftUI
import Testing
import ViewInspector
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what a full-screen alert puts on each display, what
// it says, and what takes it down.
@MainActor @Suite(.serialized) struct CoverTests {
    static let primary = CoverDisplay(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), isPrimary: true)
    static let side = CoverDisplay(frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), isPrimary: false)
    static let critical = Alert(kind: .low, threshold: 3, position: .fullScreen, glow: true, sound: true)
    static let editor = FrontApp(pid: 4242, name: "Editor")

    /// A controller over `displays`, holding each panel it orders front and whether it was made key.
    @MainActor final class Rig {
        var displays: [CoverDisplay]
        var ordered: [(frame: CGRect, key: Bool)] = []
        let clock = ManualTimekeeper()
        /// The app in front, as the cover reads it.
        var frontmost: FrontApp? = CoverTests.editor
        var activated: [FrontApp] = []
        var deactivated = 0
        var windowsClosed = 0
        var announced: [String] = []
        var cover: CoverController!

        /// `seen` is the screen's first answer, as the hider stream gives it; nil gives none.
        init(_ displays: [CoverDisplay], seen: Bool? = true) {
            self.displays = displays
            let focus = CoverFocus(frontmost: { [unowned self] in frontmost }, activate: { [unowned self] in activated.append($0) },
                                   deactivate: { [unowned self] in deactivated += 1 },
                                   closeAppWindows: { [unowned self] in windowsClosed += 1 }, announce: { [unowned self] in announced.append($0) })
            cover = CoverController(language: AppLanguageTests.scratch(), orderFront: { [unowned self] in ordered.append(($0.frame, $1)) },
                                    focus: focus, timekeeper: clock, displays: { [unowned self] in self.displays }, log: .unread)
            if let seen { cover.screen(hidden: seen ? [] : [.locked]) }
        }

        /// Shows a cover for the reading and lets its first second pass.
        func showArmed(_ percent: Int) async throws {
            cover.show(CoverTests.critical, reading: try PillTests.reading(percent))
            await clock.asleep()
            clock.advance(by: CoverController.unarmedFor)
            try await armed()
        }

        /// Waits for the arming task, which resumes off the main actor and hops back, to take input.
        func armed() async throws {
            for _ in 0..<1000 where cover.shownAccepting != true { await Task.yield() }
            try #require(cover.shownAccepting == true, "the cover never armed")
        }
    }

    static func escape(repeating: Bool = false, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                                      characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: repeating, keyCode: UInt16(kVK_Escape)))
    }

    static func pressDismiss(_ panel: CoverPanel) throws {
        try panel.hosted.inspect().find(ViewType.Button.self, where: { try $0.labelView().text().string() == "Dismiss" }).tap()
    }

    @Test func theCoverSaysWhatThePillWouldWithItsRingInTheAlertsColour() throws {
        let content = CoverContent(Self.critical, reading: try PillTests.reading(2))
        #expect(content.headline.english == "2% Remaining" && content.subline?.english == "9min until empty")
        #expect(content.severity == .red && content.progress == 0.02)

        let view = CoverView(shown: CoverShown(content), takesVoiceOverFocus: true, onDismiss: {})
        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(texts == ["2% Remaining", "9min until empty", "Dismiss"])
    }

    @Test func aNewerReadingRewritesTheCoverOnEveryDisplayWithoutDrawingOrArmingItAgain() async throws {
        let rig = Rig([Self.primary, Self.side])
        try await rig.showArmed(3)
        defer { rig.cover.dismiss(.dismissButton) }
        let panels = rig.cover.shownPanels
        let newer = try PillTests.reading(2, minutes: 5)

        rig.cover.observe(newer, changes: [.levelChanged(newer)])
        #expect(rig.cover.shown == CoverContent(Self.critical, reading: newer) && rig.cover.shown?.progress == 0.02)
        for panel in panels {
            let texts = try panel.hosted.inspect().findAll(ViewType.Text.self).map { try $0.string() }
            #expect(texts == ["2% Remaining", "5min until empty", "Dismiss"])
        }
        #expect(rig.cover.shownPanels == panels && rig.ordered.count == 2 && rig.cover.shownAccepting == true)
    }

    /// A reading without an estimate leaves the second line out but keeps its height, so the block it
    /// sits in, headline included, stays where it was.
    @Test func theSecondLineKeepsItsHeightWhileMacOSHasNoEstimate() throws {
        func height(_ subline: Phrase?) -> CGFloat { NSHostingView(rootView: CoverSubline(subline: subline)).fittingSize.height }
        let shown = try PillTests.reading(2, minutes: 9)
        let line = try #require(CoverContent(Self.critical, reading: shown).subline)
        #expect(height(line) > 0 && height(nil) == height(line))
    }

    /// A hosting view redraws only when its body read something the change invalidates; a reading that
    /// changes nothing the cover shows invalidates nothing.
    @Test func theViewRedrawsOnANewerReadingAndOnlyOnOneThatChangesIt() async throws {
        let rig = Rig([Self.primary])
        try await rig.showArmed(3)
        defer { rig.cover.dismiss(.dismissButton) }
        let shown = try #require(rig.cover.shownModel)
        func redraws(after reading: BatteryReading) -> Bool {
            let invalidated = OSAllocatedUnfairLock(initialState: false)
            withObservationTracking { _ = CoverView(shown: shown, takesVoiceOverFocus: true, onDismiss: {}).body } onChange: { invalidated.withLock { $0 = true } }
            rig.cover.observe(reading, changes: [.levelChanged(reading)])
            return invalidated.withLock { $0 }
        }
        let newer = try PillTests.reading(2, minutes: 5)
        #expect(redraws(after: newer))
        #expect(!redraws(after: newer))
    }

    @Test func itCoversEveryDisplayAndTakesFocusOnThePrimaryOne() throws {
        let rig = Rig([Self.side, Self.primary])
        rig.cover.show(Self.critical, reading: try PillTests.reading(2))
        defer { rig.cover.dismiss(.dismissButton) }

        #expect(rig.cover.shownPanels.map(\.frame) == [Self.side.frame, Self.primary.frame])
        #expect(rig.ordered.map(\.frame) == [Self.side.frame, Self.primary.frame] && rig.ordered.map(\.key) == [false, true])
    }

    /// docs/testing.md: what macOS does with a window is asserted by how it is built.
    @Test func itIsAWindowMacOSShowsOverFullScreenAppsThatTakesKeysAndClicks() throws {
        let rig = Rig([Self.primary])
        rig.cover.show(Self.critical, reading: try PillTests.reading(2))
        defer { rig.cover.dismiss(.dismissButton) }
        let panel = try #require(rig.cover.shownPanels.first)
        #expect(panel.level == .cover && panel.level.rawValue > NSWindow.Level.mainMenu.rawValue + 1)
        #expect(panel.collectionBehavior.isSuperset(of: [.canJoinAllSpaces, .fullScreenAuxiliary]))
        #expect(panel.canBecomeKey && !panel.ignoresMouseEvents)
        // A click on a display without focus reaches Dismiss rather than only making its panel key.
        #expect(panel.contentView?.acceptsFirstMouse(for: nil) == true)
    }

    @Test func dismissOnAnyDisplayClearsEveryDisplay() async throws {
        let rig = Rig([Self.primary, Self.side])
        try await rig.showArmed(2)
        try Self.pressDismiss(rig.cover.shownPanels[1])
        #expect(rig.cover.shown == nil && rig.cover.shownPanels.isEmpty)
    }

    @Test func escIsIgnoredForTheFirstSecondThenDismissesIt() async throws {
        let rig = Rig([Self.primary])
        rig.cover.show(Self.critical, reading: try PillTests.reading(2))
        await rig.clock.asleep()
        let panel = try #require(rig.cover.shownPanels.first)

        panel.sendEvent(try Self.escape())
        try Self.pressDismiss(panel)
        #expect(panel.performKeyEquivalent(with: try Self.escape(modifiers: .command)))
        #expect(rig.cover.shown != nil)

        rig.clock.advance(by: CoverController.unarmedFor)
        try await rig.armed()
        panel.sendEvent(try Self.escape(repeating: true))
        panel.sendEvent(try Self.escape(modifiers: .command))
        #expect(rig.cover.shown != nil)
        panel.sendEvent(try Self.escape())
        #expect(rig.cover.shown == nil)
    }

    @Test func aDisplayConnectedLaterIsCoveredAndItsCoverTakesEscAndDismiss() async throws {
        let rig = Rig([Self.primary])
        try await rig.showArmed(2)
        rig.displays = [Self.primary, Self.side]
        rig.cover.screensChanged()
        #expect(rig.cover.shownPanels.map(\.frame) == [Self.primary.frame, Self.side.frame])
        rig.cover.shownPanels[1].sendEvent(try Self.escape())
        #expect(rig.cover.shown == nil)

        try await rig.showArmed(1)
        rig.displays = [Self.side]
        rig.cover.screensChanged()
        #expect(rig.cover.shownPanels.map(\.frame) == [Self.side.frame])
        try Self.pressDismiss(rig.cover.shownPanels[0])
        #expect(rig.cover.shown == nil)
    }

    @Test func aCoverFiredWithNoDisplayIsDrawnOnTheNextOneConnected() async throws {
        let rig = Rig([])
        rig.cover.show(Self.critical, reading: try PillTests.reading(2))
        defer { rig.cover.dismiss(.dismissButton) }
        #expect(rig.cover.shownPanels.isEmpty && rig.cover.shown != nil)
        // An arming started at `show` would be asleep by now, and this advance would wake it.
        for _ in 0..<100 { await Task.yield() }
        rig.clock.advance(by: CoverController.unarmedFor * 2)
        for _ in 0..<100 { await Task.yield() }
        rig.displays = [Self.primary]
        rig.cover.screensChanged()
        #expect(rig.cover.shownPanels.map(\.frame) == [Self.primary.frame] && rig.ordered.last?.key == true)
        // Its unarmed second starts now, when it is first seen.
        #expect(rig.cover.shownAccepting == false)
        rig.cover.shownPanels[0].sendEvent(try Self.escape())
        #expect(rig.cover.shown != nil)
    }

    @Test func aNewerCoverReplacesTheOneUp() async throws {
        let rig = Rig([Self.primary])
        try await rig.showArmed(2)
        let first = try #require(rig.cover.shownPanels.first)
        rig.cover.show(Self.critical, reading: try PillTests.reading(1))
        defer { rig.cover.dismiss(.dismissButton) }
        #expect(!first.isVisible && rig.cover.shown?.headline.english == "1% Remaining")
        // The newer cover holds input off for its own first second.
        #expect(rig.cover.shownAccepting == false)
    }

    @Test func crossingAFullScreenThresholdShowsTheCoverOnceAndNoPill() throws {
        let rig = Rig([Self.primary])
        defer { rig.cover.dismiss(.dismissButton) }
        let pills = PillController(appearance: NotificationAppearanceModel.scratch(), language: AppLanguageTests.scratch(), orderFront: { _ in }, log: .unread)
        defer { pills.close(.closeButton) }
        let presenter = AlertPresenter(pills: pills, cover: rig.cover, sounds: AlertSounds(play: {}), log: .unread)
        let center = try AlertCenter(defaults: scratchDefaults(), log: .unread, deliver: { presenter.deliver($0) })
        try center.model.update { $0.alerts = [Self.critical] }

        for percent in [4, 2, 1] { center.observe(try PillTests.reading(percent)) }
        // Fired once, at 2%, and following the battery since.
        #expect(rig.cover.shown?.headline.english == "1% Remaining" && rig.ordered.count == 1)
        #expect(pills.shown == nil)
    }

    @Test func itClosesThePanelAndSettingsAndHandsFocusBackToTheAppThatWasInFront() async throws {
        let rig = Rig([Self.primary])
        try await rig.showArmed(2)
        #expect(rig.windowsClosed == 1 && rig.activated.isEmpty)
        // Closing Settings left this app in front.
        rig.frontmost = nil
        rig.cover.shownPanels[0].sendEvent(try Self.escape())
        #expect(rig.activated == [Self.editor])

        rig.frontmost = Self.editor
        try await rig.showArmed(2)
        rig.frontmost = nil
        try Self.pressDismiss(rig.cover.shownPanels[0])
        rig.frontmost = Self.editor
        rig.cover.show(Self.critical, reading: try PillTests.reading(2))
        rig.frontmost = nil
        let plugged = try PillTests.reading(2)
        rig.cover.observe(plugged, changes: [.plugged(plugged)])
        #expect(rig.cover.shown == nil && rig.activated == [Self.editor, Self.editor, Self.editor])
    }

    @Test func theCoverClosesThisAppsVisibleTitledWindowsAndNeverAnAlertsOwn() throws {
        func window(_ style: NSWindow.StyleMask) -> NSWindow {
            let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 200, height: 100), styleMask: style, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            return window
        }
        let settings = window([.titled, .closable]), menuBar = window([.borderless]), hiddenSettings = window([.titled])
        let rig = Rig([Self.primary])
        rig.cover.show(Self.critical, reading: try PillTests.reading(2))
        let cover = try #require(rig.cover.shownPanels.first)
        [settings, menuBar, cover].forEach { $0.orderFrontRegardless() }
        defer { [settings, menuBar].forEach { $0.close() }; rig.cover.dismiss(.dismissButton) }
        #expect([settings, menuBar, hiddenSettings, cover].map(CoverFocus.closesUnderCover) == [true, false, false, false])
    }

    @Test func withThisAppInFrontAndNoAppToReturnToItGivesUpFocusWhenItComesDown() throws {
        let rig = Rig([Self.primary])
        // The person was in Settings, which the cover closed.
        rig.frontmost = nil
        rig.cover.show(Self.critical, reading: try PillTests.reading(2))
        rig.cover.dismiss(.dismissButton)
        #expect(rig.activated.isEmpty && rig.deactivated == 1)
    }

    @Test func aCoverShownBeforeTheScreenIsKnownToBeSeenIsUnarmedAndSilentUntilItIs() async throws {
        let rig = Rig([Self.primary], seen: nil)
        rig.frontmost = FrontApp(pid: 99, name: "loginwindow")
        rig.cover.show(Self.critical, reading: try PillTests.reading(2))
        defer { rig.cover.dismiss(.dismissButton) }
        for _ in 0..<100 { await Task.yield() }
        rig.clock.advance(by: CoverController.unarmedFor * 2)
        for _ in 0..<100 { await Task.yield() }
        #expect(rig.cover.shownAccepting == false && rig.announced.isEmpty && rig.cover.shownModel?.seen == 0)
        rig.cover.screen(hidden: [])
        #expect(rig.announced.count == 1 && rig.cover.shownModel?.seen == 1)
    }

    @Test func anAppThePersonMovedToWhileTheCoverWasUpKeepsFocusWhenItComesDown() throws {
        let rig = Rig([Self.primary])
        rig.cover.show(Self.critical, reading: try PillTests.reading(2))
        rig.frontmost = FrontApp(pid: 777, name: "Terminal")
        let plugged = try PillTests.reading(2)
        rig.cover.observe(plugged, changes: [.plugged(plugged)])
        #expect(rig.cover.shown == nil && rig.activated.isEmpty)
    }

    @Test func aReplacingCoverReturnsToTheAppInFrontBeforeTheFirstAndNothingWhenItWasThisApp() async throws {
        let rig = Rig([Self.primary])
        rig.cover.show(Self.critical, reading: try PillTests.reading(2))
        // The first cover is the app in front now; the second must not return to it.
        rig.frontmost = nil
        rig.cover.show(Self.critical, reading: try PillTests.reading(1))
        // Replaced, a cover neither returns focus nor gives it up.
        #expect(rig.activated.isEmpty && rig.deactivated == 0)
        rig.cover.dismiss(.dismissButton)
        #expect(rig.activated == [Self.editor])

        rig.cover.show(Self.critical, reading: try PillTests.reading(1))
        rig.cover.dismiss(.escape)
        #expect(rig.activated == [Self.editor])
    }

    @Test func aWindowOfThisAppComingForwardWhileTheCoverIsUpIsClosedAndTheCoverTakesFocusBack() throws {
        let rig = Rig([Self.side, Self.primary])
        rig.cover.show(Self.critical, reading: try PillTests.reading(2))
        // VoiceOver lands with keyboard focus, on the primary display's cover.
        #expect(try rig.cover.shownPanels.map { try $0.hosted.inspect().find(CoverView.self).actualView().takesVoiceOverFocus } == [false, true])
        let before = (closed: rig.windowsClosed, ordered: rig.ordered.count)
        rig.cover.windowCameForward(isCover: true)
        #expect(rig.windowsClosed == before.closed && rig.ordered.count == before.ordered)
        rig.cover.windowCameForward(isCover: false)
        #expect(rig.windowsClosed == before.closed + 1 && rig.ordered.last?.frame == Self.primary.frame && rig.ordered.last?.key == true)

        rig.cover.dismiss(.dismissButton)
        rig.cover.windowCameForward(isCover: false)
        #expect(rig.windowsClosed == before.closed + 1)
    }

    @Test func afterALockOrSleepItTakesFocusAgainAndIgnoresInputForItsFirstSecondAgain() async throws {
        let rig = Rig([Self.primary])
        try await rig.showArmed(2)
        rig.cover.screen(hidden: [.locked, .displayAsleep])
        #expect(rig.cover.shownAccepting == false)
        // A display change while the screen is hidden does not arm it.
        rig.cover.screensChanged()
        for _ in 0..<100 { await Task.yield() }
        rig.clock.advance(by: CoverController.unarmedFor * 2)
        for _ in 0..<100 { await Task.yield() }
        #expect(rig.cover.shownAccepting == false)

        let ordered = rig.ordered.count
        rig.cover.screen(hidden: [])
        #expect(rig.ordered.count == ordered + 1 && rig.ordered.last?.key == true && rig.cover.shownAccepting == false)
        // Seen again, VoiceOver hears it again and is moved to Dismiss again.
        #expect(rig.announced.count == 2 && rig.cover.shownModel?.seen == 2)
        rig.cover.shownPanels[0].sendEvent(try Self.escape())
        #expect(rig.cover.shown != nil)
        await rig.clock.asleep()
        rig.clock.advance(by: CoverController.unarmedFor)
        try await rig.armed()
        rig.cover.shownPanels[0].sendEvent(try Self.escape())
        #expect(rig.cover.shown == nil)
    }

    @Test func aCoverShownBehindTheLockScreenIgnoresInputUntilItIsSeen() async throws {
        let rig = Rig([Self.primary])
        rig.cover.screen(hidden: [.locked])
        // Behind the lock screen the app in front is macOS's own.
        rig.frontmost = FrontApp(pid: 99, name: "loginwindow")
        rig.cover.show(Self.critical, reading: try PillTests.reading(2))
        for _ in 0..<100 { await Task.yield() }
        rig.clock.advance(by: CoverController.unarmedFor * 2)
        for _ in 0..<100 { await Task.yield() }
        #expect(rig.cover.shownAccepting == false && rig.announced.isEmpty)
        rig.frontmost = Self.editor
        rig.cover.screen(hidden: [])
        #expect(rig.announced.count == 1)
        await rig.clock.asleep()
        rig.clock.advance(by: CoverController.unarmedFor)
        try await rig.armed()
        rig.frontmost = nil
        rig.cover.dismiss(.dismissButton)
        #expect(rig.activated == [Self.editor])
    }

    @Test func voiceOverHearsTheHeadlineAndSecondLineWhenItAppearsAndNotOnARewrite() throws {
        let rig = Rig([Self.primary])
        rig.cover.show(Self.critical, reading: try PillTests.reading(2))
        defer { rig.cover.dismiss(.dismissButton) }
        let language = AppLanguageTests.scratch().value
        let shown = try #require(rig.cover.shown)
        let subline = try #require(shown.subline)
        #expect(rig.announced == ["\(shown.headline.resolve(in: language)). \(subline.resolve(in: language))"])
        rig.cover.observe(try PillTests.reading(1), changes: [])
        #expect(rig.announced.count == 1)
    }
}

