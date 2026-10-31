import XCTest

// An update in place, pressed as a person presses it, on the copy scripts/update-check installed from its disk image.
@MainActor final class UpdateInPlaceUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The installed copy, on the local feed for this launch alone: the argument domain leaves nothing in the defaults.
    private func launchedApp() throws -> XCUIApplication {
        let app = try installedApp()
        app.launchArguments = ["-SUFeedURL", try XCTUnwrap(ProcessInfo.processInfo.environment["UPDATE_CHECK_FEED"])]
        app.launch()
        return app
    }

    private func checkForUpdates(in app: XCUIApplication) {
        press(app.statusItems["OrangeDrink"])
        press(app.buttons["Check for Updates…"])
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
        XCTAssertTrue(app.wait(for: .notRunning, timeout: Self.installedAppTimeout), "the older copy never quit")
        let relaunched = try installedApp()
        press(relaunched.statusItems["OrangeDrink"])
        XCTAssertTrue(relaunched.buttons[quit].waitForExistence(timeout: Self.installedAppTimeout), "the panel never showed \(quit)")
    }
}
