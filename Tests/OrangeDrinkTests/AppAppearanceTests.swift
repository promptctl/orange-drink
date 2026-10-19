import AppKit
import SwiftUI
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what the window and the panel are told to look
// like for each choice, and what a relaunch loads back.
@MainActor @Suite(.serialized) struct AppAppearanceTests {
    static func scratch(_ defaults: UserDefaults = AlertSettingsPersistence.suite()) -> AppAppearanceModel {
        try! AppAppearanceModel(defaults: defaults)
    }

    @Test func eachChoiceIsTheSystemsLightOrDark() throws {
        let look = Self.scratch()
        #expect(look.value.colorScheme == nil)
        try look.update { $0 = .light }
        #expect(look.value.colorScheme == .light)
        try look.update { $0 = .dark }
        #expect(look.value.colorScheme == .dark)
        try look.update { $0 = .auto }
        #expect(look.value.colorScheme == nil)
    }

    /// The window itself, not the model: what AppKit says a real window wearing `appLook` looks like.
    @Test func aWindowWearingTheAppLookTakesOnTheChosenAppearance() throws {
        let look = Self.scratch()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Text("sample").appLook(look, AppLanguageTests.scratch()))
        func looks() -> NSAppearance.Name? {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
            return window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        }
        try look.update { $0 = .light }
        #expect(looks() == .aqua)
        try look.update { $0 = .dark }
        #expect(looks() == .darkAqua)
        try look.update { $0 = .light }
        #expect(looks() == .aqua)
    }

    @Test func theLastChoiceComesBackWhenLoadedAsARelaunchWould() throws {
        let defaults = AlertSettingsPersistence.suite()
        try Self.scratch(defaults).update { $0 = .light }
        #expect(Self.scratch(defaults).value == .light)
        #expect(Self.scratch().value == .auto)
    }

    @Test func offersAutoLightAndDarkInThatOrder() {
        #expect(AppAppearance.allCases.map(\.rawValue) == ["Auto", "Light", "Dark"])
    }

    @Test func aSchemePicksItsOwnSide() {
        #expect(ColorScheme.light.pick(light: "l", dark: "d") == "l")
        #expect(ColorScheme.dark.pick(light: "l", dark: "d") == "d")
    }
}
