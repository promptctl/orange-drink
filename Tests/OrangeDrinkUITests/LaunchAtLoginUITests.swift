import XCTest

// The switch on the General screen, pressed on the copy scripts/login-item-check installed from its disk image. Each test
// is its own launch, so the second also shows what the first left. The script reads what the system said off the app's log.
@MainActor final class LaunchAtLoginUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func theSwitch(in app: XCUIApplication) -> XCUIElement {
        press(app.statusItems["OrangeDrink"])
        press(app.buttons["Settings…"])
        return app.switches["Launch at Login"].firstMatch
    }

    private func pressing(from before: Int, to after: Int) throws {
        let app = try installedApp()
        app.launch()
        let control = theSwitch(in: app)
        XCTAssertTrue(control.wait(for: \.isEnabled, toEqual: true, timeout: Self.installedAppTimeout), "the switch never became enabled")
        XCTAssertEqual(control.value as? Int, before)
        control.click()
        XCTAssertTrue(control.wait(for: \.value as KeyPath<XCUIElement, Any?>, toEqual: after, timeout: Self.installedAppTimeout), "the switch never moved to \(after)")
    }

    func testTurningOn() throws {
        try pressing(from: 0, to: 1)
    }

    func testTurningOff() throws {
        try pressing(from: 1, to: 0)
    }
}
