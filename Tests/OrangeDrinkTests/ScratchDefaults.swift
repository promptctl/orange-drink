import Foundation

/// A throwaway defaults suite, empty, that no other test shares. Its name is an absolute path, which makes macOS keep
/// it in `<path>.plist` and nowhere else: a bare name puts a plist in ~/Library/Preferences that no removal deletes
/// (an emptied domain keeps a 42-byte file). Its siblings are kept under one directory in the temporary folder, which
/// the first use in a run empties of the previous run's.
func scratchDefaults() -> UserDefaults {
    UserDefaults(suiteName: ScratchRoot.path.appendingPathComponent(UUID().uuidString).path)!
}

private enum ScratchRoot {
    static let path: URL = {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OrangeDrinkTests-defaults")
        try? FileManager.default.removeItem(at: root)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }()
}
