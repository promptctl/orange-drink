import Foundation
import Testing

/// Pins the CFPreferences behavior `scratchDefaults()` depends on: a suite named by an absolute path is stored at that
/// path, not in ~/Library/Preferences.
struct ScratchDefaultsTests {
    @Test func aSuiteNamedByAPathIsStoredAtThatPathAndNotInThePreferencesFolder() throws {
        let path = scratchSuitePath()
        let defaults = try #require(UserDefaults(suiteName: path))
        defaults.set(true, forKey: "written")
        CFPreferencesAppSynchronize(path as CFString)

        #expect(FileManager.default.fileExists(atPath: path + ".plist"))
        let preferences = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
        let named = try FileManager.default.contentsOfDirectory(atPath: preferences.path)
        #expect(!named.contains { $0.contains((path as NSString).lastPathComponent) })
    }
}
