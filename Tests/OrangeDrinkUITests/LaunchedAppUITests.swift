import AppKit
import XCTest

// What the app wires up as it launches, which only a launched app shows: the unit tests' host builds no app (Main.swift).
@MainActor final class LaunchedAppUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launched() throws -> XCUIApplication {
        let app = try installedApp()
        app.launch()
        XCTAssertTrue(statusItem(of: app).waitForExistence(timeout: Self.installedAppTimeout), "the app never showed its status item; it shows \(app.statusItems.debugDescription)")
        return app
    }

    /// The app as macOS runs it, which the runner can signal and ask about but cannot read the files of.
    private func running() throws -> NSRunningApplication {
        let appURL = URL(filePath: try XCTUnwrap(ProcessInfo.processInfo.environment["INSTALLED_APP"]))
        let identifier = try XCTUnwrap(Bundle(url: appURL)?.bundleIdentifier)
        return try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first)
    }

    // [LAW:behavior-not-structure] Menu-bar-only: the running app has no Dock presence, whichever plist key or scene does it.
    func testTheAppRunsWithNoDockPresence() throws {
        _ = try launched()
        XCTAssertEqual(try running().activationPolicy, .accessory)
    }

    func testTheDefaultCombinationOpensThePanel() throws {
        let app = try launched()
        app.typeKey("j", modifierFlags: [.control, .option])
        XCTAssertTrue(app.buttons["Connected Devices"].waitForExistence(timeout: Self.installedAppTimeout), "⌃⌥J did not open the panel")
    }

    /// This runner sends the SIGTERM, and stays running, so scripts/ui-test finds it named in the app's quit record, which the
    /// sandboxed runner cannot read.
    func testASIGTERMQuitsTheApp() throws {
        let app = try launched()
        let sent = kill(try running().processIdentifier, SIGTERM), error = errno
        XCTAssertEqual(sent, 0, "kill: \(String(cString: strerror(error)))")
        XCTAssertTrue(app.wait(for: .notRunning, timeout: Self.installedAppTimeout), "the app did not quit on SIGTERM")
    }
}
