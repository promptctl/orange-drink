import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract: the default combination is ⌃⌥J, and pressing it shows
// the panel when it is closed and hides it when it is open.
@MainActor private final class FakePanel: Panel {
    var isOpen = false
    func open() { isOpen = true }
    func close() { isOpen = false }
}

@MainActor private final class FakeHotKeys: HotKeys {
    private(set) var registered: [(combo: KeyCombo, fire: @MainActor () -> Void)] = []
    var refusal: HotKeyError?

    private final class Registration: HotKeyRegistration { func cancel() {} }

    func register(_ combo: KeyCombo, fire: @escaping @MainActor () -> Void) throws -> any HotKeyRegistration {
        if let refusal { throw refusal }
        registered.append((combo, fire))
        return Registration()
    }

    /// Presses a combination the way the system would deliver it.
    func press(_ combo: KeyCombo) { registered.filter { $0.combo == combo }.forEach { $0.fire() } }
}

@MainActor @Suite struct OpenPanelHotKeyTests {
    @Test func theDefaultCombinationIsControlOptionJ() {
        #expect(KeyCombo.openPanel.display == "⌃⌥J")
        #expect(KeyCombo.openPanel.modifiers == [.control, .option])
    }

    @Test func pressingItOpensTheClosedPanelAndClosesTheOpenOne() throws {
        let keys = FakeHotKeys(), panel = FakePanel()
        _ = try OpenPanelHotKey(hotKeys: keys, panel: panel)
        #expect(keys.registered.map(\.combo) == [.openPanel])
        keys.press(.openPanel)
        #expect(panel.isOpen)
        keys.press(.openPanel)
        #expect(!panel.isOpen)
        keys.press(.openPanel)
        #expect(panel.isOpen)
    }

    @Test func aCombinationTheSystemRefusesIsAnErrorNotAShortcutThatNeverFires() {
        let keys = FakeHotKeys()
        keys.refusal = HotKeyError(combo: .openPanel, status: -9878)
        #expect(throws: HotKeyError.self) { try OpenPanelHotKey(hotKeys: keys, panel: FakePanel()) }
    }

    /// A combination nothing else holds, for the tests that ask the real system.
    private static let spare = KeyCombo(keyCode: KeyCombo.openPanel.keyCode, modifiers: [.control, .option, .shift, .command])

    @Test func theSystemRegistersACombinationAndLetsGoOfIt() throws {
        let carbon = try CarbonHotKeys.shared()
        let registration = try carbon.register(Self.spare, fire: {})
        #expect(throws: HotKeyError.self) { try carbon.register(Self.spare, fire: {}) }
        registration.cancel()
        try carbon.register(Self.spare, fire: {}).cancel()
    }

    // The test host is the app itself, which registers ⌃⌥J as it launches: the system now refuses it to anyone else.
    @Test func theLaunchedAppHoldsTheDefaultCombination() throws {
        #expect(throws: HotKeyError.self) { try CarbonHotKeys.shared().register(.openPanel, fire: {}) }
    }
}
