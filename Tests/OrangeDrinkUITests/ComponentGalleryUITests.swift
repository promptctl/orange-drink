import XCTest

// The shared settings components, read the way VoiceOver reads them and pressed as a person presses them, in the Debug
// build's component gallery (Sources/.../ComponentGallery.swift). SwiftUI builds its accessibility tree only for a client of
// the running app, so this is a UI test, and it runs in the VM `make ui-test` boots, where its window shows on no one's screen.
@MainActor final class ComponentGalleryUITests: XCTestCase {
    private var gallery: XCUIElement!

    override func setUp() async throws {
        continueAfterFailure = true
        let app = try installedApp()
        app.launchArguments = ["-ComponentGallery"]
        app.launch()
        gallery = app.windows["Component Gallery"]
        XCTAssertTrue(gallery.waitForExistence(timeout: Self.installedAppTimeout), "the Component Gallery window never appeared")
    }

    private func element(_ words: String) -> XCUIElement {
        gallery.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR title == %@ OR value == %@ OR identifier == %@", words, words, words, words))
            .firstMatch
    }

    func testEveryComponentExposesItsWords() {
        for words in ["Section Title", "Switch Row", "Switch description", "Popup Row", "Popup description",
                      "Info Row", "Info description", "Pills Row", "Pills description", "First Radio", "Second Radio"] {
            XCTAssertTrue(element(words).exists, "\"\(words)\" is not exposed")
        }
        XCTAssertTrue(gallery.checkBoxes.firstMatch.exists || gallery.switches.firstMatch.exists, "no switch control")
        XCTAssertTrue(gallery.popUpButtons.firstMatch.exists || gallery.menuButtons.firstMatch.exists, "no pop-up button")
        XCTAssertTrue(gallery.buttons["Info"].exists, "no info button")
    }

    func testPressingAPillSelectsItAlone() {
        for title in ["Day", "Week", "Month"] { XCTAssertTrue(gallery.buttons[title].exists, "no \(title) pill") }
        XCTAssertTrue(gallery.buttons["Week"].isSelected, "Week should start selected")
        XCTAssertFalse(gallery.buttons["Month"].isSelected, "Month should start unselected")
        press(gallery.buttons["Month"])
        XCTAssertTrue(gallery.buttons["Month"].wait(for: \.isSelected, toEqual: true, timeout: Self.installedAppTimeout), "pressing Month did not select it")
        XCTAssertFalse(gallery.buttons["Week"].isSelected, "Week stayed selected after Month was pressed")
    }

    func testPressingARadioSelectsItAlone() {
        let first = gallery.buttons["First Radio"], second = gallery.buttons["Second Radio"]
        XCTAssertTrue(first.isSelected, "First Radio should start selected")
        XCTAssertFalse(second.isSelected, "Second Radio should start unselected")
        press(second)
        XCTAssertTrue(second.wait(for: \.isSelected, toEqual: true, timeout: Self.installedAppTimeout), "pressing Second Radio did not select it")
        XCTAssertFalse(first.isSelected, "First Radio stayed selected after Second Radio was pressed")
    }
}
