import XCTest

// A UI test takes the screen, so this target is in no scheme `make test` runs: it runs only in the VM of scripts/vm-check-lib,
// on the copy the check installed from its disk image, and the script reads what each press did off that copy.
@MainActor extension XCTestCase {
    static let installedAppTimeout: TimeInterval = 60

    /// The installed copy, which xcodebuild passes as TEST_RUNNER_INSTALLED_APP without that prefix.
    func installedApp() throws -> XCUIApplication {
        XCUIApplication(url: URL(filePath: try XCTUnwrap(ProcessInfo.processInfo.environment["INSTALLED_APP"])))
    }

    /// What System Settings asks of a change to a permission or a login item: the Tart image's user's password.
    func confirmWithThePassword(in settings: XCUIApplication) {
        let password = settings.sheets.firstMatch.secureTextFields["Password"]
        XCTAssertTrue(password.waitForExistence(timeout: Self.installedAppTimeout), "System Settings never asked for the password")
        password.click()
        password.typeText("admin")
        press(settings.sheets.firstMatch.buttons["Modify Settings"])
    }

    /// Waits for a switch to read `value`, which it does once the system's answer has landed.
    func expect(_ control: XCUIElement, toRead value: Int) {
        let reads = expectation(for: NSPredicate(format: "value == %d", value), evaluatedWith: control)
        wait(for: [reads], timeout: Self.installedAppTimeout)
    }

    /// Allows the app in System Settings' Login Items & Extensions as a person does, with the pane already open. The app's
    /// login item and its helper share this switch, which a press turns off when it already reads 1, so it must read 0.
    func allowInTheBackground() {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        let allowed = settings.switches["background-switch-OrangeDrink"]
        expect(allowed, toRead: 0)
        press(allowed)
        confirmWithThePassword(in: settings)
        expect(allowed, toRead: 1)
    }

    /// The app's menu bar item. Its title is the app's name and then the battery's state, which changes
    /// as the battery does, so it is found by the name it begins with.
    func statusItem(of app: XCUIApplication) -> XCUIElement {
        app.statusItems.matching(NSPredicate(format: "label BEGINSWITH %@", "OrangeDrink")).firstMatch
    }

    /// The first match, because an alert's buttons are in the tree again on the Touch Bar a VM reports.
    func press(_ query: XCUIElement) {
        let control = query.firstMatch
        XCTAssertTrue(control.wait(for: \.isEnabled, toEqual: true, timeout: Self.installedAppTimeout), "\(query) never became enabled")
        control.click()
    }
}
