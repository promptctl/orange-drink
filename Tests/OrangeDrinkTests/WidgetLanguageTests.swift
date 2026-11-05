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

    /// The message each widget draws in each of these states, read from the views, so a test asks about the sentence a view says.
    static func messages() throws -> [Phrase] {
        let mac = try [Shelved.running(MacBattery.noBattery), .running(.ended), .appNotRunning].map {
            try MacBatteryView(entry: MacBatteryEntry(date: .now, battery: .success($0)), appName: "App").inspect().find(Message.self).actualView().text
        }
        let device = WidgetDevice(id: .bluetooth("AA"), name: "iPhone", kind: .phone, level: nil)
        let single = try [(WidgetDeviceList.connected([], pinned: []), nil), (.connected([], pinned: []), "AA"), (.connected([device], pinned: []), nil)].map { (list, chosen: String?) in
            try DeviceBatteryView(entry: DeviceBatteryEntry(date: .now, shelf: .success(.running(list)), chosen: chosen.map(DeviceID.bluetooth)), appName: "App", family: .systemSmall)
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
        let device = WidgetDevice(id: .bluetooth("AA"), name: "Rings", kind: .phone, level: nil)
        let drawn = AllBatteries(mac: .noBattery, devices: .connected([device], pinned: []), settings: AllBatteriesWidgetTests.settings { $0.showNames = true })
        guard case .listed(let batteries, _) = drawn, let name = batteries.first?.name else {
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

    /// The Edit Widget words each sentence of the Widgets screen names.
    static func namesBySentence() throws -> [[LocalizedStringResource]] {
        let intent = AllBatteriesIntent()
        return [
            try [intent.$devices.title] + options(WidgetDeviceChoice.self),
            try [intent.$style.title] + options(WidgetStyle.self),
            [intent.$showNames.title, intent.$includeMac.title],
            try [intent.$appearance.title] + options(WidgetAppearance.self),
        ]
    }

    @Test func editWidgetUsesTheWordsTheWidgetsScreenSays() async throws {
        let bed = try await WidgetsScreenTests.Bed()
        let widgets = try Self.widgets()
        for language in Self.shipped {
            let sentences = try bed.texts(in: Locale(identifier: try #require(language.code)))
            for names in try Self.namesBySentence() {
                let words = names.map { language.resolve($0.key, in: widgets) }
                #expect(sentences.contains { sentence in words.allSatisfy { sentence.contains($0) } }, "\(words) in \(sentences)")
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
        let preview = WidgetPreview(kind: .macBattery, size: .small, mac: .noBattery, devices: .connected([], pinned: []), device: nil, log: .unread)
        #expect(try Self.drawn(preview.speaking(AppLanguage(code: "fr"))) != Self.drawn(preview.speaking(AppLanguage(code: "en"))))
    }

    // MARK: a level

    static let exact = BatteryLevel(percent: 80, approximate: false)
    static let rough = BatteryLevel(percent: 50, approximate: true)
    /// A no-break space, so a level never wraps between its number and its sign.
    static let forms = [("en", ["80%", "~50%"]), ("fr", ["80\u{a0}%", "~50\u{a0}%"]), ("es", ["80\u{a0}%", "~50\u{a0}%"])]

    @Test func aLevelIsSaidTheWayItsLanguageWritesIt() throws {
        for (code, said) in Self.forms {
            let language = AppLanguage(code: code)
            #expect(try [Self.exact, Self.rough].map { try Self.translation(BatteryLevel.text($0), language) } == said)
            #expect([Self.exact, Self.rough].map { BatteryLevel.text($0).resolve(in: language, bundle: Self.app) } == said)
        }
    }

    @Test func aWidgetDrawsALevelTheWayItsLanguageWritesIt() throws {
        for (code, said) in Self.forms {
            for (level, form) in zip([Self.exact, Self.rough], said) {
                let battery = WidgetBattery(glyph: MacBattery.glyph, level: level, charging: false)
                let drawn = BatteryPercentage(battery: battery).speaking(AppLanguage(code: code))
                #expect(try Self.drawn(drawn) == Self.drawn(Text(verbatim: form).monospacedDigit().foregroundStyle(battery.tint)), "\(form)")
            }
        }
    }

    @Test func aPanelRowAndAPlacedWidgetSayALevelInTheLanguageTheySpeak() throws {
        let device = WidgetDevice(id: .bluetooth("A"), name: "Mouse", kind: .accessory, level: Self.exact)
        let row = DeviceRow(id: DeviceID.bluetooth("A"), name: "Mouse", kind: .accessory, level: Self.exact)
        let entry = AllBatteriesWidgetTests.entry(.noBattery, [device], style: .list)
        let ring = DeviceBatteryEntry(date: .now, shelf: .success(.running(.connected([device], pinned: []))), chosen: .bluetooth("A"))
        let views = [
            AnyView(DeviceRowView(row: row)), AnyView(AllBatteriesWidgetTests.view(entry)),
            AnyView(DeviceBatteryView(entry: ring, appName: "Orange Drink", family: .systemSmall)),
        ]
        for (code, said) in Self.forms {
            for view in views {
                let texts = try view.speaking(AppLanguage(code: code)).inspect().findAll(ViewType.Text.self).filter { !$0.isHidden() }.map { try $0.string() }
                #expect(texts.contains(said[0]), "\(texts) in \(code)")
            }
        }
    }

    @Test func aDevicesNameIsDrawnAsItIsInEveryLanguage() throws {
        let name = BatteryName(name: "\("Rings")")
        #expect(try Self.drawn(name.speaking(AppLanguage(code: "fr"))) == Self.drawn(name.speaking(AppLanguage(code: "en"))))
    }
}
