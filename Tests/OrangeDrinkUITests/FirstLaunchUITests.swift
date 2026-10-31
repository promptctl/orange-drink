import XCTest

@MainActor final class FirstLaunchUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// macOS asks for Bluetooth at a new install's first launch, and the app waits on the answer
    /// (orange-distribution-kg2.73n), so scripts/vm-check-lib opens it itself and this answers.
    func testBluetoothIsAllowed() {
        press(XCUIApplication(bundleIdentifier: "com.apple.UserNotificationCenter").buttons["Allow"])
    }
}
