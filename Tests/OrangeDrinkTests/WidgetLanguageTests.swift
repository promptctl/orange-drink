import AppIntents
import Foundation
import SwiftUI
import Testing
import ViewInspector
import WidgetKit
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what the built extension says in each language the app ships. A widget's
// words are read from the extension's own bundle, because the app's would answer the same with the extension holding no catalog.
@MainActor @Suite struct WidgetLanguageTests {
    static let app = Bundle(for: BatteryModel.self)
    /// Asked for, not stored, so a build with no extension fails these tests and leaves the rest of the run standing.
    static func widgets() throws -> Bundle { try #require(Bundle(url: WidgetIntentMetadataTests.widgets)) }
    static let shipped = AppLanguage.choices(in: app).filter { $0 != .matchSystem }
    static let translated = shipped.filter { $0.code != app.developmentLocalization }

    static func translation(_ phrase: Phrase, _ language: AppLanguage) throws -> String { phrase.resolve(in: language, bundle: try widgets()) }

    /// `key`'s entry in the extension's catalog, or nil when it has none. English is no sign of one being absent: French's
    /// "Monochrome" and Spanish's "Color" are also the English words.
    static func entry(_ key: String, _ language: AppLanguage) throws -> String? {
        let lproj = try #require(try widgets().path(forResource: language.code, ofType: "lproj").flatMap(Bundle.init(path:)))
        let absent = "\u{0}absent"
        let entry = lproj.localizedString(forKey: key, value: absent, table: nil)
        return entry == absent ? nil : entry
    }

    @Test func theExtensionCarriesEveryLanguageTheAppShips() throws {
        #expect(try Self.widgets().localizations.sorted() == Self.app.localizations.sorted())
        #expect(Self.shipped.count == 3)
    }

    // MARK: what a widget draws

    /// Every message each widget draws, read from the views, so a sentence a view says is one this test asks about.
    static func messages() throws -> [Phrase] {
        let mac = try [Shelved.running(MacBattery.noBattery), .running(.ended), .appNotRunning].map {
            try MacBatteryView(entry: MacBatteryEntry(date: .now, battery: .success($0)), appName: "App").inspect().find(Message.self).actualView().text
        }
        let device = WidgetDevice(address: "AA", name: "iPhone", kind: .phone, level: nil)
        let single = try [(WidgetDevices.connected([], pinned: []), nil), (.connected([], pinned: []), "AA"), (.connected([device], pinned: []), nil)].map { (list, chosen: String?) in
            try DeviceBatteryView(entry: DeviceBatteryEntry(date: .now, shelf: .success(.running(list)), chosen: chosen), appName: "App", family: .systemSmall)
                .inspect().find(Message.self).actualView().text
        }
        return mac + single + WidgetDeviceStatesTests.reasons.map(\.text)
    }

    @Test func everyMessageAWidgetDrawsIsTranslatedInTheExtension() throws {
        for language in Self.translated {
            for message in try Self.messages() {
                #expect(try Self.translation(message, language) != message.english, "\(message.key) in \(language.code ?? "?")")
            }
        }
    }

    @Test func theGalleryNamesAndDescribesEachWidgetInTheExtensionsLanguages() throws {
        for kind in WidgetKind.allCases {
            for language in Self.translated {
                #expect(try Self.translation(kind.title, language) != kind.title.english, "\(kind)")
                #expect(try Self.translation(kind.galleryDescription, language) != kind.galleryDescription.english, "\(kind)")
            }
        }
        #expect(try Self.translation(WidgetKind.allBatteries.title, AppLanguage(code: "fr")) == "Toutes les batteries")
        #expect(try Self.translation(WidgetKind.macBattery.galleryDescription, AppLanguage(code: "es")) == "La batería de tu Mac de un vistazo.")
    }

    @Test func theMacIsNamedInEachLanguageAndADeviceKeepsItsOwnName() throws {
        #expect(try Self.translation(MacBattery.name, AppLanguage(code: "fr")) == "Ce Mac")
        #expect(try Self.translation(MacBattery.name, AppLanguage(code: "es")) == "Este Mac")
        let device = WidgetDevice(address: "AA", name: "Rings", kind: .phone, level: nil)
        let drawn = AllBatteries(mac: .noBattery, devices: .connected([device], pinned: []), settings: AllBatteriesWidgetTests.settings { $0.showNames = true })
        guard case .listed(let batteries) = drawn, let name = batteries.first?.name else {
            Issue.record("a named device")
            return
        }
        #expect(try Self.translation(name, AppLanguage(code: "fr")) == "Rings")
    }

    @Test func aDeviceOffTheListHasATranslatedNameInEditWidget() throws {
        #expect(try Self.translation(DeviceQuery.unavailable, AppLanguage(code: "fr")) == "Appareil indisponible")
        #expect(try Self.translation(DeviceQuery.unavailable, AppLanguage(code: "es")) == "Dispositivo no disponible")
    }

    // MARK: Edit Widget

    /// Every `{"key": …}` under a value macOS reads Edit Widget's words from.
    static func localizedKeys(in value: Any) -> [String] {
        switch value {
        case let object as [String: Any]: [object["key"] as? String].compactMap(\.self) + object.values.flatMap(localizedKeys)
        case let array as [Any]: array.flatMap(localizedKeys)
        default: []
        }
    }

    @Test func everyTitleEditWidgetCanShowIsInTheExtensionsCatalog() throws {
        let file = WidgetIntentMetadataTests.metadataFile(of: WidgetIntentMetadataTests.widgets)
        let keys = Set(Self.localizedKeys(in: try JSONSerialization.jsonObject(with: Data(contentsOf: file))))
        #expect(keys.isSuperset(of: ["Show device names", "Include this Mac", "Rings", "Same as menu bar", "Monochrome", "Device"]))
        for language in Self.shipped {
            for key in keys {
                #expect(try Self.entry(key, language) != nil, "\(key) has no \(language.code ?? "?") in the extension")
            }
        }
    }

    static func options<Option: AppEnum & CaseIterable>(_: Option.Type) throws -> [LocalizedStringResource] {
        try Option.allCases.map { try #require(Option.caseDisplayRepresentations[$0]).title }
    }

    /// Each sentence of the Widgets screen, and the Edit Widget words it names.
    static func sentences() throws -> [(sentence: String, names: [LocalizedStringResource])] {
        let intent = AllBatteriesIntent()
        return [
            ("**Devices:** Automatic (as many as fit), Custom (your order), or Same as menu bar", try [intent.$devices.title] + options(WidgetDeviceChoice.self)),
            ("**Style:** Rings, List or Bars", try [intent.$style.title] + options(WidgetStyle.self)),
            ("Show device names · Include this Mac", [intent.$showNames.title, intent.$includeMac.title]),
            ("**Appearance:** Color or Monochrome", try [intent.$appearance.title] + options(WidgetAppearance.self)),
        ]
    }

    @Test func editWidgetUsesTheWordsTheWidgetsScreenSays() throws {
        let widgets = try Self.widgets()
        for language in Self.shipped {
            for (sentence, names) in try Self.sentences() {
                let said = language.resolve(sentence, in: Self.app)
                for name in names {
                    #expect(said.contains(language.resolve(name.key, in: widgets)), "\(name.key) in \(said)")
                }
            }
        }
    }

    // MARK: the preview

    static func drawn(_ view: some View) throws -> Data {
        try #require(NSBitmapImageRep(cgImage: widgetImage(view, size: CGSize(width: 158, height: 158), scheme: .dark, scale: 2)).tiffRepresentation)
    }

    @Test func aMessageIsDrawnInTheLanguageItsViewSpeaks() throws {
        let french = AppLanguage(code: "fr")
        let said = Message(glyph: MacBattery.glyph, text: "No battery").speaking(french)
        #expect(try Self.drawn(said) == Self.drawn(Message(glyph: MacBattery.glyph, text: "\("Pas de batterie")")))
    }

    @Test func thePreviewSpeaksTheAppsLanguage() throws {
        let preview = WidgetPreview(kind: .macBattery, size: .small, mac: .noBattery, devices: .connected([], pinned: []), device: nil)
        #expect(try Self.drawn(preview.speaking(AppLanguage(code: "fr"))) != Self.drawn(preview.speaking(AppLanguage(code: "en"))))
    }

    @Test func aDevicesNameIsDrawnAsItIsInEveryLanguage() throws {
        let name = BatteryName(name: "\("Rings")")
        #expect(try Self.drawn(name.speaking(AppLanguage(code: "fr"))) == Self.drawn(name.speaking(AppLanguage(code: "en"))))
    }
}
