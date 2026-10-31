import XCTest

// An update in place, pressed as a person presses it, on the copy scripts/update-check installed from its disk image.
// A UI test takes the screen, so this target is in no scheme `make test` runs: it runs only in that script's VM, and the
// script reads what each press did off the installed app.
@MainActor final class UpdateInPlaceUITests: XCTestCase {
    private let timeout: TimeInterval = 60

    override func setUp() {
        continueAfterFailure = false
    }

    /// The installed copy, on the local feed for this launch alone: the argument domain leaves nothing in the defaults.
    /// xcodebuild passes each TEST_RUNNER_ variable here without that prefix.
    private func launchedApp() throws -> XCUIApplication {
        let environment = ProcessInfo.processInfo.environment
        let app = XCUIApplication(url: URL(filePath: try XCTUnwrap(environment["UPDATE_CHECK_APP"])))
        app.launchArguments = ["-SUFeedURL", try XCTUnwrap(environment["UPDATE_CHECK_FEED"])]
        app.launch()
        return app
    }

    /// The first match, because an alert's buttons are in the tree again on the Touch Bar a VM reports.
    private func press(_ query: XCUIElement) {
        let control = query.firstMatch
        XCTAssertTrue(control.wait(for: \.isEnabled, toEqual: true, timeout: timeout), "\(query) never became enabled")
        control.click()
    }

    private func checkForUpdates(in app: XCUIApplication) {
        press(app.statusItems["OrangeDrink"])
        press(app.buttons["Check for Updates…"])
    }

    /// macOS asks for Bluetooth at a new install's first launch, and the app waits on the answer
    /// (orange-distribution-kg2.73n), so scripts/update-check opens it itself and this answers.
    func testBluetoothIsAllowed() {
        press(XCUIApplication(bundleIdentifier: "com.apple.UserNotificationCenter").buttons["Allow"])
    }

    func testNothingNewerIsReported() throws {
        let app = try launchedApp()
        checkForUpdates(in: app)
        press(app.buttons["OK"])
    }

    func testANewerBuildIsInstalled() throws {
        let app = try launchedApp()
        checkForUpdates(in: app)
        press(app.buttons["Install Update"])
        press(app.buttons["Install and Relaunch"])

        // A running copy's version is the one it launched with, so the Quit row showing this one is the new process.
        let quit = "Quit OrangeDrink, v\(try XCTUnwrap(ProcessInfo.processInfo.environment["UPDATE_CHECK_VERSION"]))"
        XCTAssertTrue(app.wait(for: .notRunning, timeout: timeout), "the older copy never quit")
        let relaunched = XCUIApplication(url: URL(filePath: try XCTUnwrap(ProcessInfo.processInfo.environment["UPDATE_CHECK_APP"])))
        press(relaunched.statusItems["OrangeDrink"])
        XCTAssertTrue(relaunched.buttons[quit].waitForExistence(timeout: timeout), "the panel never showed \(quit)")
    }
}
