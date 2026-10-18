import AppKit
import Testing

// [LAW:behavior-not-structure] The contract is "menu-bar-only": the running app has no
// Dock presence. Which plist key or scene type produces that is the implementation.
@Suite struct MenuBarOnlyApp {
    @Test @MainActor func runsAsAccessory() {
        #expect(NSApplication.shared.activationPolicy() == .accessory)
    }
}
