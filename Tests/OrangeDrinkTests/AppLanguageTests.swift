import Foundation
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what the app says for each choice, in the same running
// process, and what a relaunch loads back.
@MainActor @Suite(.serialized) struct AppLanguageTests {
    /// The app's bundle, whose String Catalog carries the languages.
    static let app = Bundle(for: BatteryModel.self)
    static let title = "App Language"

    static func scratch(_ defaults: UserDefaults = AlertSettingsPersistence.suite()) -> AppLanguageModel {
        try! AppLanguageModel(defaults: defaults)
    }

    /// What Foundation answers in the Mac's language: the independent path Match System must agree with.
    static var macsOwn: String { app.localizedString(forKey: title, value: nil, table: nil) }

    @Test func aChosenLanguageTranslatesTheTitleAndMatchSystemBringsTheMacsBack() throws {
        let language = Self.scratch()
        #expect(language.value.resolve(Self.title, in: Self.app) == Self.macsOwn)
        try language.update { $0 = AppLanguage(code: "fr") }
        #expect(language.value.resolve(Self.title, in: Self.app) == "Langue de l’app")
        try language.update { $0 = AppLanguage(code: "es") }
        #expect(language.value.resolve(Self.title, in: Self.app) == "Idioma de la app")
        try language.update { $0 = .matchSystem }
        #expect(language.value.resolve(Self.title, in: Self.app) == Self.macsOwn)
    }

    @Test func theLastChoiceComesBackWhenLoadedAsARelaunchWould() throws {
        let defaults = AlertSettingsPersistence.suite()
        try Self.scratch(defaults).update { $0 = AppLanguage(code: "fr") }
        #expect(Self.scratch(defaults).value == AppLanguage(code: "fr"))
        #expect(Self.scratch().value == .matchSystem)
    }

    @Test func offersMatchSystemThenTheCatalogsLanguagesEachInItsOwnName() {
        let choices = AppLanguage.choices(in: Self.app)
        #expect(choices.map(\.code) == [nil, "en", "es", "fr"])
        #expect(choices.map { $0.menuTitle(speaking: .matchSystem, in: Self.app) }.dropFirst() == ["English", "Español", "Français"])
        #expect(AppLanguage(code: "fr").menuTitle(speaking: AppLanguage(code: "es"), in: Self.app) == "Français")
    }

    @Test func matchSystemIsNamedInTheLanguageNowSpoken() {
        #expect(AppLanguage.matchSystem.menuTitle(speaking: AppLanguage(code: "fr"), in: Self.app) == "Suivre le système")
        #expect(AppLanguage.matchSystem.menuTitle(speaking: AppLanguage(code: "es"), in: Self.app) == "Igual que el sistema")
    }

    @Test func aChosenLanguageKeepsTheMacsRegion() {
        let locale = AppLanguage(code: "fr").locale
        #expect(locale.language.languageCode == "fr")
        #expect(locale.region == Locale.current.region)
    }

    @Test func aLanguageTheCatalogLacksFallsBackToTheDevelopmentLanguage() {
        #expect(AppLanguage(code: "ja").resolve(Self.title, in: Self.app) == Self.title)
    }
}
