import Foundation
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract: a recorded shortcut works and the one it replaced does not,
// recordings survive a relaunch, Reset brings the defaults back, and a recording that cannot be kept
// changes nothing.
@MainActor @Suite struct ShortcutsTests {
    static let k = KeyCombo(keyCode: 40, modifiers: [.control, .option])!   // ⌃⌥K

    /// The pieces the app is made of, over throwaway stores; `relaunch` makes the same pieces again over the same store.
    @MainActor struct Rig {
        let defaults: UserDefaults
        let keys = FakeHotKeys()
        let panel = FakePanel()
        let events = FakeKeyEvents()
        let sections: PanelSections
        let controller: ShortcutsController
        let keyboard: PanelKeyboard

        init(defaults: UserDefaults = scratchDefaults()) throws {
            self.defaults = defaults
            sections = PanelSections(defaults: scratchDefaults())
            let model = try ShortcutsModel(defaults: defaults)
            controller = ShortcutsController(model: model, hotKeys: keys, panel: panel)
            keyboard = PanelKeyboard(sections: sections, shortcuts: model, events: events)
            try controller.start()
            keyboard.panelDidOpen(shown: { [.batteryInformation, .connectedDevices] })
        }

        var shortcuts: Shortcuts { controller.model.value }
    }

    @Test func aRecordedGlobalCombinationTogglesThePanelAndTheOldOneNoLongerDoes() throws {
        let rig = try Rig()
        try rig.controller.record(openPanel: Self.k)
        rig.keys.press(.openPanel)
        #expect(!rig.panel.isOpen)
        rig.keys.press(Self.k)
        #expect(rig.panel.isOpen)
        rig.keys.press(Self.k)
        #expect(!rig.panel.isOpen)
        #expect(rig.keys.combos == [Self.k])
    }

    @Test func aRecordedLetterFlipsItsSectionAndTheOldLetterNoLongerDoes() throws {
        let rig = try Rig()
        try rig.controller.record("b", for: .batteryInformation)
        #expect(!rig.events.type("i"))
        #expect(!rig.sections.isOpen(.batteryInformation))
        #expect(rig.events.type("b"))
        #expect(rig.sections.isOpen(.batteryInformation))
    }

    @Test func theRecordingsComeBackWhenLoadedAsALaunchWould() throws {
        let first = try Rig()
        try first.controller.record(openPanel: Self.k)
        try first.controller.record("b", for: .batteryInformation)
        try first.controller.record("p", for: .lowPowerMode)
        let second = try Rig(defaults: first.defaults)
        #expect(second.shortcuts.openPanel == Self.k)
        #expect(second.shortcuts.letter(for: .batteryInformation) == "b")
        #expect(second.shortcuts.letter(for: .lowPowerMode) == "p")
        #expect(second.keys.combos == [Self.k])
    }

    @Test func resetBringsBackTheDefaultCombinationAndLetters() throws {
        let rig = try Rig()
        try rig.controller.record(openPanel: Self.k)
        try rig.controller.record("b", for: .batteryInformation)
        try rig.controller.record("p", for: .lowPowerMode)
        try rig.controller.reset()
        #expect(rig.shortcuts.openPanel == .openPanel)
        #expect(MenuShortcut.allCases.map { rig.shortcuts.letter(for: $0) } == ["i", "u", "d", "l"])
        #expect(rig.keys.combos == [.openPanel])
        rig.keys.press(.openPanel)
        #expect(rig.panel.isOpen)
        #expect(rig.events.type("i"))
    }

    @Test func aLetterAnotherRowHoldsIsRefusedAndNothingChanges() throws {
        let rig = try Rig()
        #expect(throws: ShortcutError.self) { try rig.controller.record("d", for: .batteryInformation) }
        #expect(rig.shortcuts.letter(for: .batteryInformation) == "i")
        #expect(rig.events.type("i"))
    }

    @Test func aCombinationTheSystemRefusesLeavesTheOldOneWorking() throws {
        let rig = try Rig()
        rig.keys.refused = [Self.k]
        #expect(throws: ShortcutError.self) { try rig.controller.record(openPanel: Self.k) }
        #expect(rig.shortcuts.openPanel == .openPanel)
        rig.keys.press(.openPanel)
        #expect(rig.panel.isOpen)
    }

    @Test func recordingTheCurrentCombinationAgainChangesNothing() throws {
        let rig = try Rig()
        try rig.controller.record(openPanel: .openPanel)
        #expect(rig.keys.combos == [.openPanel])
    }

    @Test func aPressIsAGlobalCombinationOnlyAsALetterHeldWithControlOptionOrCommand() throws {
        func press(_ code: UInt32, _ modifiers: KeyCombo.Modifiers, _ character: Character?) -> RecordedKey {
            RecordedKey(keyCode: code, character: character, modifiers: modifiers)
        }
        #expect(try press(40, [.control, .option], "k").globalCombo() == Self.k)
        #expect(try press(40, [.command], "k").globalCombo().display == "⌘K")
        #expect(throws: ShortcutError.self) { try press(40, [], "k").globalCombo() }
        #expect(throws: ShortcutError.self) { try press(40, [.shift], "K").globalCombo() }
        #expect(throws: ShortcutError.self) { try press(18, [.control], "1").globalCombo() }
    }

    @Test func aPressIsAMenuLetterOnlyAsALetterOnItsOwn() throws {
        func press(_ modifiers: KeyCombo.Modifiers, _ character: Character?) -> RecordedKey {
            RecordedKey(keyCode: 40, character: character, modifiers: modifiers)
        }
        #expect(try press([], "k").menuLetter() == "k")
        #expect(try press([.shift], "K").menuLetter() == "k")
        #expect(throws: ShortcutError.self) { try press([.command], "k").menuLetter() }
        #expect(throws: ShortcutError.self) { try press([], "1").menuLetter() }
        #expect(throws: ShortcutError.self) { try press([], nil).menuLetter() }
    }

    @Test func storedShortcutsThatDoNotMakeSenseFailTheLaunchInsteadOfBeingReplaced() throws {
        let defaults = scratchDefaults()
        let twice = #"{"openPanel":{"keyCode":38,"modifiers":3},"letters":{"batteryInformation":"i","appsUsingSignificantEnergy":"i","connectedDevices":"d","lowPowerMode":"l"}}"#
        defaults.set(Data(twice.utf8), forKey: Shortcuts.storageKey)
        #expect(throws: (any Error).self) { try ShortcutsModel(defaults: defaults) }
        let bare = #"{"openPanel":{"keyCode":38,"modifiers":0},"letters":{"batteryInformation":"i","appsUsingSignificantEnergy":"u","connectedDevices":"d","lowPowerMode":"l"}}"#
        defaults.set(Data(bare.utf8), forKey: Shortcuts.storageKey)
        #expect(throws: (any Error).self) { try ShortcutsModel(defaults: defaults) }
    }
}
