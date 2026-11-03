import SwiftUI
import Testing
import ViewInspector
@testable import OrangeDrink

// [LAW:behavior-not-structure] What VoiceOver reads of an option: its title, then its description as the hint. The hint is
// read here, with no window, because a UI test's element carries no hint (ComponentGalleryUITests reads the rest).
@MainActor @Suite struct RadioRowTests {
    @Test func theDescriptionIsTheHint() throws {
        let row = RadioRow(title: "First Radio", description: "First radio description", isSelected: true) {}
        let button = try row.inspect().find(ViewType.Button.self)
        #expect(try button.accessibilityLabel().string() == "First Radio")
        #expect(try button.accessibilityHint().string() == "First radio description")
    }
}
