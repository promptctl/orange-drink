import Foundation
@testable import OrangeDrink

/// A throwaway defaults suite, empty, that no other test shares. Its name is an absolute path, which makes macOS keep
/// it in `<path>.plist` and nowhere else: a bare name puts a plist in ~/Library/Preferences that no removal deletes
/// (an emptied domain keeps a 42-byte file). Each test process keeps its suites in its own directory, named by its
/// pid, so runs in other worktrees at the same time (they share the temporary folder) never touch each other's; the
/// first use removes the directories of processes that have exited.
func scratchDefaults() -> UserDefaults {
    UserDefaults(suiteName: ScratchRoot.path.appendingPathComponent(UUID().uuidString).path)!
}

/// A `GeneralScreen` whose three stored settings models each read a fresh scratch suite.
@MainActor func scratchGeneralScreen(launchAtLogin: LaunchAtLogin, batteryNotifications: BatteryNotificationDismissal) throws -> GeneralScreen {
    GeneralScreen(appearance: try NotificationAppearanceModel(defaults: scratchDefaults()), look: try AppAppearanceModel(defaults: scratchDefaults()),
                  language: try AppLanguageModel(defaults: scratchDefaults()), launchAtLogin: launchAtLogin,
                  batteryNotifications: batteryNotifications)
}

private enum ScratchRoot {
    static let path: URL = {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("OrangeDrinkTests-defaults")
        try! files.createDirectory(at: root, withIntermediateDirectories: true)
        for name in try! files.contentsOfDirectory(atPath: root.path) {
            guard let pid = pid_t(name), kill(pid, 0) != 0, errno == ESRCH else { continue }
            try! files.removeItem(at: root.appendingPathComponent(name))
        }
        let mine = root.appendingPathComponent(String(getpid()))
        try! files.createDirectory(at: mine, withIntermediateDirectories: true)
        return mine
    }()
}
