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
