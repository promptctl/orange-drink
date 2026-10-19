import Foundation
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract: while the panel is open, I and D flip their own section as
// clicking its header does, the open state is what the next launch restores, and with the panel closed
// the keys are nobody's.
@MainActor private final class FakeKeyEvents: KeyEvents {
    private var handler: (@MainActor (PlainKey) -> Bool)?
    var listening: Bool { handler != nil }

    private final class Listener: KeyListening {
        let stop_: () -> Void
        init(_ stop: @escaping () -> Void) { stop_ = stop }
        func stop() { stop_() }
    }

    func listen(_ handle: @escaping @MainActor (PlainKey) -> Bool) -> any KeyListening {
        handler = handle
        return Listener { [weak self] in self?.handler = nil }
    }

    /// A key typed to the app: true when a shortcut used it, false when it goes on to whoever would have had it.
    func type(_ key: PlainKey) -> Bool { handler?(key) ?? false }
}

@MainActor @Suite struct PanelKeyboardTests {
    static let both: Set<PanelSections.Section> = [.batteryInformation, .connectedDevices]

    static func store() -> UserDefaults {
        let name = "panel-keyboard-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func eachKeyFlipsOnlyItsOwnSectionAndASecondPressFlipsItBack() {
        let events = FakeKeyEvents(), sections = PanelSections(defaults: Self.store())
        let keyboard = PanelKeyboard(sections: sections, events: events)
        keyboard.panelDidOpen(shown: { Self.both })
        for (key, section, other) in [("i", PanelSections.Section.batteryInformation, PanelSections.Section.connectedDevices),
                                      ("d", .connectedDevices, .batteryInformation)] as [(PlainKey, PanelSections.Section, PanelSections.Section)] {
            #expect(events.type(key))
            #expect(sections.isOpen(section) && !sections.isOpen(other))
            #expect(events.type(key))
            #expect(!sections.isOpen(section) && !sections.isOpen(other))
        }
    }

    @Test func aKeyIsCaseInsensitive() {
        let events = FakeKeyEvents(), sections = PanelSections(defaults: Self.store())
        PanelKeyboard(sections: sections, events: events).panelDidOpen(shown: { Self.both })
        #expect(events.type("I"))
        #expect(sections.isOpen(.batteryInformation))
    }

    @Test func theOpenStateAfterAKeyPressIsTheOneTheNextLaunchRestores() {
        let defaults = Self.store(), events = FakeKeyEvents()
        let sections = PanelSections(defaults: defaults)
        PanelKeyboard(sections: sections, events: events).panelDidOpen(shown: { Self.both })
        _ = events.type("i")
        #expect(PanelSections(defaults: defaults).isOpen(.batteryInformation))
        _ = events.type("i")
        #expect(!PanelSections(defaults: defaults).isOpen(.batteryInformation))
    }

    @Test func withThePanelClosedTheKeysAreNotListenedFor() {
        let events = FakeKeyEvents(), sections = PanelSections(defaults: Self.store())
        let keyboard = PanelKeyboard(sections: sections, events: events)
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
        let keyboard = PanelKeyboard(sections: sections, events: events)
        keyboard.panelDidOpen(shown: { Self.both })
        keyboard.panelDidOpen(shown: { Self.both })
        keyboard.panelDidClose()
        #expect(!events.listening)
    }

    @Test func otherKeysAndSectionsThePanelIsNotDrawingAreLeftAlone() {
        let events = FakeKeyEvents(), sections = PanelSections(defaults: Self.store())
        PanelKeyboard(sections: sections, events: events).panelDidOpen(shown: { [.batteryInformation] })
        #expect(!events.type("x"))
        #expect(!events.type("d"))
        #expect(!sections.isOpen(.connectedDevices))
    }
}
