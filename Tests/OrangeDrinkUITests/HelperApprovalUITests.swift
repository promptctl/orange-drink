import ServiceManagement
import XCTest

// The helper's approval, given as a person gives it, on the copy scripts/update-check installed from its disk image: the
// app registers the helper at launch and macOS holds it until Allow in the Background is on, so the script reads the
// helper answering only after this.
@MainActor final class HelperApprovalUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testAllowing() throws {
        try installedApp().launch()
        SMAppService.openSystemSettingsLoginItems()
        allowInTheBackground()
    }
}
