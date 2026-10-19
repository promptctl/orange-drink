import Foundation
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract: a phrase reads as English to the code that wrote it, says
// itself in the language it is asked for, and every sentence the app can say is in the catalog in every
// language it carries.
@MainActor @Suite struct PhraseTests {
    static let app = Bundle(for: BatteryModel.self)

    @Test func aPhraseWrittenAsALiteralOrWithValuesReadsAsItsEnglishSentence() {
        let watts = 12
        let charging: Phrase = "Charging at \(watts) W"
        #expect(charging.english == "Charging at 12 W")
        #expect(charging.key == "Charging at %lld W")
        let literal: Phrase = "100% sure"
        #expect(literal.english == "100% sure")
        let nested: Phrase = "Updated \(charging) by \("me")"
        #expect(nested.english == "Updated Charging at 12 W by me")
    }

    @Test func twoPhrasesAreEqualWhenTheyAreTheSameSentenceWithTheSameValues() {
        let a: Phrase = "Updated \(3) min ago"
        #expect(a == "Updated \(3) min ago")
        #expect(a != "Updated \(4) min ago")
    }

    @Test func aPhraseIsSaidInTheLanguageItIsAskedFor() {
        let phrase: Phrase = "Updated \(3) min ago"
        #expect(phrase.resolve(in: AppLanguage(code: "fr"), bundle: Self.app) == "Mis à jour il y a 3 min")
        #expect(phrase.resolve(in: AppLanguage(code: "es"), bundle: Self.app) == "Actualizado hace 3 min")
        #expect(phrase.resolve(in: AppLanguage(code: "en"), bundle: Self.app) == "Updated 3 min ago")
    }

    @Test func aPhraseNotInTheCatalogIsSaidAsItsEnglishKey() {
        let phrase: Phrase = "A sentence nobody translated \(7)"
        #expect(phrase.resolve(in: AppLanguage(code: "fr"), bundle: Self.app) == "A sentence nobody translated 7")
    }

    /// Every sentence in the catalog is there in each language, with the same holes to fill.
    @Test func everyCatalogKeyHasEveryLanguageWithTheSameHoles() throws {
        let catalog = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OrangeDrink/Localizable.xcstrings")
        let strings = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any])["strings"] as? [String: [String: Any]]
        func holes(_ text: String) -> [String] {
            text.matches(of: /%(?:lld|@)/).map { String($0.output) }
        }
        for (key, entry) in try #require(strings) {
            let localizations = try #require(entry["localizations"] as? [String: [String: [String: String]]], "\(key)")
            for language in ["en", "es", "fr"] {
                let value = try #require(localizations[language]?["stringUnit"]?["value"], "\(key) has no \(language)")
                #expect(!value.isEmpty, "\(key) is empty in \(language)")
                #expect(holes(value) == holes(key), "\(key) has other holes in \(language)")
            }
        }
    }

    /// A phrase the app says that the catalog has no entry for is said in English whatever the language, so each
    /// phrase the panel and the window's chrome can show is looked for in French and Spanish.
    @Test func everyPhraseThePanelAndTheWindowChromeCanShowIsInTheCatalog() throws {
        func hasTranslation(_ phrase: Phrase, _ code: String) throws -> Bool {
            let sentinel = "\u{0}missing"
            let lproj = try #require(Self.app.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)))
            return lproj.localizedString(forKey: phrase.key, value: sentinel, table: nil) != sentinel
        }
        typealias Words = BatteryInformationWords
        var phrases: [Phrase] = [UpdatedFooter.explanation, UpdatedFooter.action, UpdatedFooter.text(age: 0), UpdatedFooter.text(age: 300)]
        phrases += [ChargeCard.Status.charging, .onBattery, .notCharging, .charged].map(\.title)
        phrases += PanelAction.allCases.map { $0.title(appName: "App") }
        phrases += SettingsScreen.allCases.flatMap { [$0.title] + ($0.subtitle(appName: "App").map { [$0] } ?? []) }
        phrases += [3, 15, 40, 80].map { PowerFlow.workload(watts: Double($0)) }
        phrases += ["Not charging", "Charging at \(5) W", "UNTIL EMPTY", "UNTIL FULL", "\(1)h \(2)m"]
        for edit: (inout [String: Any]) -> Void in [{ _ in }, { $0["AppleRawMaxCapacity"] = 4000 }, { $0["Temperature"] = 3700 },
                                                     { $0["Temperature"] = 4300 }, { $0["Voltage"] = 8000 }] {
            let info = try Words.reference(edit)
            phrases += [info.health.label, info.temperature.status, info.temperature.caption, info.electrical.voltageNote]
        }
        for phrase in phrases {
            for code in ["fr", "es"] { #expect(try hasTranslation(phrase, code), "\(phrase.key) has no \(code) in the catalog") }
        }
    }
}
