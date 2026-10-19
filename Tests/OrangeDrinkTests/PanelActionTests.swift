import Foundation
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what the actions card lists and what the Quit
// row says about this build.
@Suite struct PanelActions {
    @Test func listsTheFiveActionsInOrder() {
        let titles = PanelAction.allCases.map { $0.title(appName: "OrangeDrink") }
        #expect(titles == ["Settings…", "Battery Settings…", "Low Power Mode", "Check for Updates…", "Quit OrangeDrink"])
    }

    @Test func quitNamesTheAppAndShowsItsVersion() {
        #expect(PanelAction.quit.title(appName: appName) == "Quit " + appName)
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String
        #expect(PanelAction.versionText(of: .main) == "v" + shortVersion)
    }
}
