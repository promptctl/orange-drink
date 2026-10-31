import XCTest

// A new install's first launch, on the copy a check installed and opened itself, because it must be running before the
// prompt can be answered. The prompt is the system's, in a process of its own, so these press it as a person does.
@MainActor final class FirstLaunchUITests: XCTestCase {
    private let prompt = XCUIApplication(bundleIdentifier: "com.apple.UserNotificationCenter")

    override func setUp() {
        continueAfterFailure = false
    }

    private func openPanel() throws -> XCUIApplication {
        let app = try installedApp()
        app.activate()
        press(app.statusItems["OrangeDrink"])
        return app
    }

    /// A click on the status item is the main thread's to handle, so the panel opening is that thread free of the prompt.
    /// Connected Devices stays open across launches, which the test of the refusal counts on.
    func testThePanelOpensWhileThePromptWaits() throws {
        let app = try openPanel()
        press(app.buttons["Connected Devices"])
        let waiting = app.staticTexts["Answer the Bluetooth prompt to see your devices."]
        XCTAssertTrue(waiting.waitForExistence(timeout: Self.installedAppTimeout), "the panel never said it was waiting")
        XCTAssertTrue(prompt.buttons["Allow"].firstMatch.exists, "the prompt was not open behind the panel")
    }

    func testBluetoothIsAllowed() {
        press(prompt.buttons["Allow"])
    }

    func testThePanelSaysBluetoothIsNotAllowed() throws {
        press(prompt.buttons["Don’t Allow"])
        let app = try openPanel()
        // By its start, because a query's string may be no longer than 128 characters.
        let refused = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "This app isn't allowed to use Bluetooth.")).firstMatch
        XCTAssertTrue(refused.waitForExistence(timeout: Self.installedAppTimeout), "the panel never said Bluetooth is not allowed")
    }
}
