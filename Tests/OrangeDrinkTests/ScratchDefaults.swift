import Foundation
@testable import OrangeDrink

/// A throwaway defaults suite, empty, that no other test shares. Its name is an absolute path, which makes macOS keep
/// it in `<path>.plist` and nowhere else: a bare name puts a plist in ~/Library/Preferences that no removal deletes
/// (an emptied domain keeps a 42-byte file). Each test process keeps its suites in a directory of its own, so runs in
/// other worktrees at the same time (they share the temporary folder) never touch each other's. The first use removes
/// the directories no run has written to for an hour, which no run lasts.
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
                  batteryNotifications: batteryNotifications)
}

private enum ScratchRoot {
    static let path: URL = {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("OrangeDrinkTests-defaults")
        try! files.createDirectory(at: root, withIntermediateDirectories: true)
        let stale = Date().addingTimeInterval(-3600)
        for run in try! files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) {
            // Another run sweeping at the same moment may have removed it, or it may be gone before it can be read.
            guard let written = try? run.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  written < stale else { continue }
            do { try files.removeItem(at: run) } catch CocoaError.fileNoSuchFile {}
            catch { fatalError("can't remove the stale scratch defaults at \(run.path): \(error)") }
        }
        let mine = root.appendingPathComponent(UUID().uuidString)
        try! files.createDirectory(at: mine, withIntermediateDirectories: false)
        return mine
    }()
}
