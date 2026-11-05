import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
import ViewInspector
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what a full-screen alert puts on each display, what
// it says, and what takes it down.
@MainActor @Suite(.serialized) struct CoverTests {
    static let primary = CoverDisplay(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), isPrimary: true)
    static let side = CoverDisplay(frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), isPrimary: false)
    static let critical = Alert(kind: .low, threshold: 3, position: .fullScreen, glow: true, sound: true)

    /// A controller over `displays`, holding each panel it orders front and whether it was made key.
    @MainActor final class Rig {
        var displays: [CoverDisplay]
        var ordered: [(frame: CGRect, key: Bool)] = []
        let clock = ManualTimekeeper()
        var cover: CoverController!

        init(_ displays: [CoverDisplay]) {
            self.displays = displays
            cover = CoverController(language: AppLanguageTests.scratch(), orderFront: { [unowned self] in ordered.append(($0.frame, $1)) },
                                    timekeeper: clock, displays: { [unowned self] in self.displays }, log: .unread)
        }

        /// Shows a cover for the reading and lets its first second pass.
        func showArmed(_ percent: Int) async throws {
            cover.show(CoverContent(CoverTests.critical, reading: try PillTests.reading(percent)))
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

        let view = CoverView(content: content, onDismiss: {})
        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(texts == ["2% Remaining", "9min until empty", "Dismiss"])
    }

    @Test func itCoversEveryDisplayAndTakesFocusOnThePrimaryOne() throws {
        let rig = Rig([Self.side, Self.primary])
        rig.cover.show(CoverContent(Self.critical, reading: try PillTests.reading(2)))
        defer { rig.cover.dismiss(.dismissButton) }

        #expect(rig.cover.shownPanels.map(\.frame) == [Self.side.frame, Self.primary.frame])
        #expect(rig.ordered.map(\.frame) == [Self.side.frame, Self.primary.frame] && rig.ordered.map(\.key) == [false, true])
    }

    /// docs/testing.md: what macOS does with a window is asserted by how it is built.
    @Test func itIsAWindowMacOSShowsOverFullScreenAppsThatTakesKeysAndClicks() throws {
        let rig = Rig([Self.primary])
        rig.cover.show(CoverContent(Self.critical, reading: try PillTests.reading(2)))
        defer { rig.cover.dismiss(.dismissButton) }
        let panel = try #require(rig.cover.shownPanels.first)
        #expect(panel.level == .pill && panel.level.rawValue > NSWindow.Level.mainMenu.rawValue + 1)
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
        rig.cover.show(CoverContent(Self.critical, reading: try PillTests.reading(2)))
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
        rig.cover.show(CoverContent(Self.critical, reading: try PillTests.reading(2)))
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
        rig.cover.show(CoverContent(Self.critical, reading: try PillTests.reading(1)))
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
        let presenter = AlertPresenter(pills: pills, cover: rig.cover)
        let center = try AlertCenter(defaults: scratchDefaults(), log: .unread, deliver: { presenter.deliver($0, reading: $1) })
        try center.model.update { $0.alerts = [Self.critical] }

        for percent in [4, 2, 1] { center.observe(try PillTests.reading(percent)) }
        #expect(rig.cover.shown?.headline.english == "2% Remaining" && rig.ordered.count == 1)
        #expect(pills.shown == nil)
    }
}
