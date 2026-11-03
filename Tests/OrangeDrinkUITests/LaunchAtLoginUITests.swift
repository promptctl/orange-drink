import XCTest

// The General screen's switch, pressed on the copy scripts/login-item-check installed from its disk image, as a person
// gets there: macOS holds a login item while the app's Allow in the Background is off, which is how a new install starts,
// because the helper's record shares that switch. Each test is its own launch, so each shows what the one before left, and
// they run in that order. The script reads what the system said after each off the app's log.
@MainActor final class LaunchAtLoginUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launched() throws -> (app: XCUIApplication, control: XCUIElement) {
        let app = try installedApp()
        app.launch()
        press(statusItem(of: app))
        press(app.buttons["Settings…"])
        // macOS exposes a SwiftUI switch as a check box.
        let control = app.checkBoxes["Launch at Login"].firstMatch
        XCTAssertTrue(control.wait(for: \.isEnabled, toEqual: true, timeout: Self.installedAppTimeout), "the switch never became enabled")
        return (app, control)
    }

    func testAllowing() throws {
        let (app, control) = try launched()
        expect(control, toRead: 0)
        control.click()
        let link = app.links["Open Login Items & Extensions…"]
        XCTAssertTrue(link.waitForExistence(timeout: Self.installedAppTimeout), "the row never gave the way to the setting")
        // The native switch moves under the click, ahead of the system's answer, so only this reads that it came back.
        expect(control, toRead: 0)
        press(link)
        allowInTheBackground()
        // Coming back is what reads the change made in System Settings.
        app.activate()
        expect(control, toRead: 1)
    }

    func testTurningOff() throws {
        let (_, control) = try launched()
        expect(control, toRead: 1)
        control.click()
        expect(control, toRead: 0)
    }

    func testTurningOn() throws {
        let (_, control) = try launched()
        expect(control, toRead: 0)
        control.click()
        expect(control, toRead: 1)
    }
}
