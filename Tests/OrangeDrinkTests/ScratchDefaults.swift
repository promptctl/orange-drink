import Foundation
@testable import OrangeDrink

/// A throwaway defaults suite, empty, that no other test shares. Its name is an absolute path, which makes macOS keep
/// it in `<path>.plist` and nowhere else: a bare name puts a plist in ~/Library/Preferences that no removal deletes
/// (an emptied domain keeps a 42-byte file). Each test process keeps its suites in a directory of its own in the
/// temporary folder and removes nothing: runs in other worktrees share that folder, and macOS clears it of what no one
/// has used for days.
func scratchDefaults() -> UserDefaults {
    UserDefaults(suiteName: scratchSuitePath())!
}

/// The path a new scratch suite is named by; its plist is this path with `.plist` appended.
func scratchSuitePath() -> String {
    ScratchRoot.path.appendingPathComponent(UUID().uuidString).path
}

/// A `GeneralScreen` whose three stored settings models each read a fresh scratch suite.
@MainActor func scratchGeneralScreen(launchAtLogin: LaunchAtLogin, batteryNotifications: BatteryNotificationDismissal) throws -> GeneralScreen {
    GeneralScreen(appearance: try NotificationAppearanceModel(defaults: scratchDefaults()), look: try AppAppearanceModel(defaults: scratchDefaults()),
                  language: try AppLanguageModel(defaults: scratchDefaults()), launchAtLogin: launchAtLogin,
                  batteryNotifications: batteryNotifications, settingsLog: .unread)
}

private enum ScratchRoot {
    static let path: URL = {
        let mine = FileManager.default.temporaryDirectory.appendingPathComponent("OrangeDrinkTests-defaults")
            .appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        return mine
    }()
}
