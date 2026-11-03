import AppKit

/// The process's one decision about what it is. Hosting the unit tests, it is a bare application with no
/// scenes: the tests build every subject they test, so nothing appears on the screen of the Mac running them
/// and no model reads or writes the user's own defaults.
@main enum Main {
    static func main() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            NSApplication.shared.run()
        } else {
            OrangeDrinkApp.main()
        }
    }
}
