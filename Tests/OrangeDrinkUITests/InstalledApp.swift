import XCTest

// A UI test takes the screen, so this target is in no scheme `make test` runs: it runs only in the VM of scripts/vm-check-lib,
// on the copy the check installed from its disk image, and the script reads what each press did off that copy.
@MainActor extension XCTestCase {
    static let installedAppTimeout: TimeInterval = 60

    /// The installed copy, which xcodebuild passes as TEST_RUNNER_INSTALLED_APP without that prefix.
    func installedApp() throws -> XCUIApplication {
        XCUIApplication(url: URL(filePath: try XCTUnwrap(ProcessInfo.processInfo.environment["INSTALLED_APP"])))
    }

    /// The first match, because an alert's buttons are in the tree again on the Touch Bar a VM reports.
    func press(_ query: XCUIElement) {
        let control = query.firstMatch
        XCTAssertTrue(control.wait(for: \.isEnabled, toEqual: true, timeout: Self.installedAppTimeout), "\(query) never became enabled")
        control.click()
    }
}
