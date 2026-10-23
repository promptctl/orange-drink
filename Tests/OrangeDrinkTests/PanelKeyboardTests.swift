import Foundation
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract: while the panel is open, I and D flip their own section as
// clicking its header does, the open state is what the next launch restores, and with the panel closed
// the keys are nobody's.
@MainActor @Suite struct PanelKeyboardTests {
    static let both: Set<PanelSections.Section> = [.batteryInformation, .appsUsingSignificantEnergy, .connectedDevices]

    static func store() -> UserDefaults { scratchDefaults() }

    static func keyboard(_ sections: PanelSections, _ events: FakeKeyEvents) -> PanelKeyboard {
        PanelKeyboard(sections: sections, lowPowerMode: LowPowerModeTests.FakeSystem().model(), shortcuts: try! ShortcutsModel(defaults: scratchDefaults()), events: events)
    }

    @Test func eachKeyFlipsOnlyItsOwnSectionAndASecondPressFlipsItBack() {
        let events = FakeKeyEvents(), sections = PanelSections(defaults: Self.store())
        let keyboard = Self.keyboard(sections, events)
        keyboard.panelDidOpen(shown: { Self.both })
        for (key, section, other) in [("i", PanelSections.Section.batteryInformation, PanelSections.Section.connectedDevices),
                                      ("d", .connectedDevices, .batteryInformation)] as [(PlainKey, PanelSections.Section, PanelSections.Section)] {
            #expect(events.type(key))
            #expect(sections.isOpen(section) && !sections.isOpen(other))
            #expect(events.type(key))
            #expect(!sections.isOpen(section) && !sections.isOpen(other))
        }
    }

    @Test func uFlipsTheAppsUsingSignificantEnergySectionAndItIsRemembered() {
        let defaults = Self.store(), events = FakeKeyEvents(), sections = PanelSections(defaults: defaults)
        Self.keyboard(sections, events).panelDidOpen(shown: { Self.both })
        #expect(events.type("u"))
        #expect(sections.isOpen(.appsUsingSignificantEnergy) && !sections.isOpen(.batteryInformation))
        #expect(PanelSections(defaults: defaults).isOpen(.appsUsingSignificantEnergy))
    }

    @Test func aKeyIsCaseInsensitive() {
        let events = FakeKeyEvents(), sections = PanelSections(defaults: Self.store())
        Self.keyboard(sections, events).panelDidOpen(shown: { Self.both })
        #expect(events.type("I"))
        #expect(sections.isOpen(.batteryInformation))
    }

    @Test func theOpenStateAfterAKeyPressIsTheOneTheNextLaunchRestores() {
        let defaults = Self.store(), events = FakeKeyEvents()
        let sections = PanelSections(defaults: defaults)
        Self.keyboard(sections, events).panelDidOpen(shown: { Self.both })
        _ = events.type("i")
        #expect(PanelSections(defaults: defaults).isOpen(.batteryInformation))
        _ = events.type("i")
        #expect(!PanelSections(defaults: defaults).isOpen(.batteryInformation))
    }

    @Test func withThePanelClosedTheKeysAreNotListenedFor() {
        let events = FakeKeyEvents(), sections = PanelSections(defaults: Self.store())
        let keyboard = Self.keyboard(sections, events)
        #expect(!events.listening)
        #expect(!events.type("i"))
        keyboard.panelDidOpen(shown: { Self.both })
        #expect(events.listening)
        keyboard.panelDidClose()
        #expect(!events.listening)
        #expect(!events.type("i"))
        #expect(!sections.isOpen(.batteryInformation))
    }

    @Test func openingTwiceLeavesOneListener() {
        let events = FakeKeyEvents(), sections = PanelSections(defaults: Self.store())
        let keyboard = Self.keyboard(sections, events)
        keyboard.panelDidOpen(shown: { Self.both })
        keyboard.panelDidOpen(shown: { Self.both })
        keyboard.panelDidClose()
        #expect(!events.listening)
    }

    @Test func otherKeysAndSectionsThePanelIsNotDrawingAreLeftAlone() {
        let events = FakeKeyEvents(), sections = PanelSections(defaults: Self.store())
        Self.keyboard(sections, events).panelDidOpen(shown: { [.batteryInformation] })
        #expect(!events.type("x"))
        #expect(!events.type("d"))
        #expect(!sections.isOpen(.connectedDevices))
    }
}
