import AppKit
import Testing

// [LAW:behavior-not-structure] The contract is "menu-bar-only": the running app has no
// Dock presence. Which plist key or scene type produces that is the implementation.
@Suite struct MenuBarOnlyApp {
    @Test @MainActor func runsAsAccessory() {
        // [LAW:no-silent-failure] Unhosted, NSApplication.shared is the xctest runner and
        // the policy assertion would pass or fail about the wrong process.
        #expect(Bundle.main.bundleURL.pathExtension == "app", "test must run hosted in the app")
        #expect(NSApplication.shared.activationPolicy() == .accessory)
    }
}
