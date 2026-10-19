import Foundation
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what the actions card lists and what the Quit
// row says about this build.
@Suite struct PanelActions {
    @Test func listsTheFiveActionsInOrder() {
        let titles = PanelAction.allCases.map { $0.title(appName: "OrangeDrink").english }
        #expect(titles == ["Settings…", "Battery Settings…", "Low Power Mode", "Check for Updates…", "Quit OrangeDrink"])
    }

    @Test func quitNamesTheAppAndShowsItsVersion() {
        #expect(PanelAction.quit.title(appName: "Orange").english == "Quit Orange")
        #expect(PanelAction.versionText(shortVersion: "1.2.0") == "v1.2.0")
    }

    /// The built app's own version, as project.yml sets it: what the Quit row will print.
    @Test func theRowReadsThisBuildsVersion() {
        #expect(PanelAction.versionText(of: .main) == "v0.1.0")
    }
}
