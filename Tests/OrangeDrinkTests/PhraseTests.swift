import Foundation
import ServiceManagement
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
        /// The holes a text fills, in the order of the values; a `%` that is neither `%%` nor a hole would
        /// make `String(format:)` read the text after it as a conversion, so it is a hole of its own kind.
        func holes(_ text: String) -> [String] {
            text.matches(of: /%(?:\d+\$)?(?:%|lld|@)|%/).map { String($0.output) }.filter { $0 != "%%" }
                .map { $0.replacing(/\d+\$/, with: "") }
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
    @Test func everyPhraseTheAppCanShowIsInTheCatalog() throws {
        func hasTranslation(_ phrase: Phrase, _ code: String) -> Bool {
            let sentinel = "\u{0}missing"
            guard let lproj = Self.app.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) else {
                Issue.record("the app carries no \(code) localization"); return false
            }
            return lproj.localizedString(forKey: phrase.key, value: sentinel, table: nil) != sentinel
        }
        typealias Words = BatteryInformationWords
        var phrases: [Phrase] = [UpdatedFooter.explanation, UpdatedFooter.action, UpdatedFooter.text(age: 0), UpdatedFooter.text(age: 300)]
        phrases += [ChargeCard.Status.charging, .onBattery, .notCharging, .charged].map(\.title)
        phrases += SettingsScreen.allCases.map(\.comingSoon)
        phrases += PanelAction.allCases.map { $0.title(appName: "App") }
        let helperFailures = [HelperUseFailure(call: .noReply(seconds: 1, service: "x"), status: .requiresApproval), HelperUseFailure(call: .failed("x"), status: .enabled),
                              HelperUseFailure(call: .noReply(seconds: 1, service: "x"), status: .enabled)]
        phrases += helperFailures.map { LowPowerMode.explanation(of: $0, appName: "App") } + [LoginItemFailureLine.openLoginItemsTitle]
        phrases += helperFailures.map { ChargingScreen.explanation(of: $0, appName: "App") }
        phrases += [LaunchAtLogin.Refusal.needsApproval, .failed("x")].map { $0.explanation(appName: "App") }
        phrases += SettingsScreen.allCases.flatMap { [$0.title] + ($0.subtitle(appName: "App").map { [$0] } ?? []) }
        phrases += [3, 15, 40, 80].map { PowerFlow.workload(watts: Double($0)) }
        phrases += ["Not charging", "Charging at \(5) W", "UNTIL EMPTY", "UNTIL FULL", "\(1)h \(2)m"]
        phrases += Alert.Position.allCases.map(\.title)
        phrases += [true, false].flatMap { glow in [Alert(kind: .low, threshold: 5, position: .top, glow: glow, sound: glow).summary] }
        phrases += [Alert.Kind.low, .charged].flatMap { kind in
            [Alert.Action.edit, .delete].map { Alert(kind: kind, threshold: 5, position: .top, glow: false, sound: false).buttonName($0) }
        }
        phrases += MenuBarIconConfig.Style.allCases.flatMap { [$0.title(appName: "App"), $0.description(appName: "App")] }
        phrases += MenuBarIconConfig.Display.allCases.map(\.title) + MenuBarIconConfig.Color.allCases.map(\.title) + MenuBarIconConfig.Size.allCases.map(\.title)
        phrases += [MenuBarPreview.overflowHelp, MenuBarPreview.tutorialHelp, "Control \("App") from the menu bar", "Don't see it?",
                    "Remove default battery icon from menu bar", "Click to see quick tutorial", "Menu bar preview", "Info"]
        let pillAlert = { (kind: Alert.Kind) in Alert(kind: kind, threshold: 20, position: .top, glow: false, sound: false) }
        phrases += [true, false].map { PillContent(DeviceFiring(alert: pillAlert(.low), name: "D", level: BatteryLevel(percent: 19, approximate: $0))).headline }
        phrases += try [Alert.Kind.low, .charged].map { PillContent(pillAlert($0), reading: try PillTests.reading(19)).headline }
        let estimates = try [9, 192].map { PillContent(pillAlert(.low), reading: try PillTests.reading(19, minutes: $0)) }
            + [PillContent(pillAlert(.charged), reading: try MenuBarIconDrawing.charging(19))]
        phrases += estimates.compactMap { $0.subline } + [PillContent.sample.headline, PillContent.sample.subline!]
        phrases += HistoryRange.allCases.map(\.title) + ["HEALTH", "TEMPERATURE", "CYCLES", "of \(1000) rated", "Today, \("2:00 AM")", "Yesterday, \("2:00 AM")",
                    "\("Jan 1"), \("2:00 AM")", "Last charged to \(79)%", "Battery Level", "Battery level over the last \("24h")",
                    "Building your battery-level history — your charge timeline fills in as you use your Mac.",
                    "The battery history could not be read. Quit and reopen the app.", "This Mac has no battery.", "Reading the battery…",
                    "Battery readings stopped. Quit and reopen the app."]
        phrases += ["DAILY USAGE", BatteryOverview.age(0), BatteryOverview.age(120), BatteryOverview.age(7200), BatteryOverview.age(200_000),
                    "Building your daily usage", "\("App") tracks battery discharge and screen-on time across each day. Come back in a couple of days to see your charts fill in.",
                    "\(1) day collected so far", "\(2) days collected so far", "Battery used", "Screen on", "Battery Health",
                    "How much charge the battery holds today compared with when it was new.",
                    "Building your battery-health history — your health trend fills in as you use your Mac.", "Battery health over time"]
        let usage = AppUsageRanking(intervals: [], firstInterval: nil, now: AppUsageTests.t0, range: .day)
        phrases += AppUsageRange.allCases.map(\.title) + ["RIGHT NOW", "TOP DRAINERS · \("24H")", "just now", "\(2)m ago", "\(3)h ago",
                    usage.historyText, "1 day of history collected", "\(3) days of history collected", usage.trackedText, "1 app tracked in the last \("24h")",
                    "\(usage.historyText) • \(usage.trackedText)", "App energy history is unavailable. Quit and reopen the app.",
                    "Collecting app energy — rankings appear after a few minutes of use.",
                    "INSIGHTS", "TOP ENERGY CONSUMERS", "of total", "See details", "Quit", "Share of energy in the last \("24h")", "Share of energy right now"]
        let usageApp = AppUsageTests.app("a")
        let usageShare = AppShare(app: usageApp, nanojoules: 1, share: 0.5)
        phrases += [AppInsight.dominating(usageShare, range: .day), .unusuallyActive(usageShare, ratio: 1.5)].flatMap {
            [$0.heading(), $0.text(locale: Locale(identifier: "en_US"))]
        }
        phrases += ["\("a") is dominating your battery", "\("a") is unusually active right now",
                    "\("50%") of your apps' total energy in the last \("24h"). If you're not actively using it, closing it could meaningfully extend battery life.",
                    "It's drawing about \("1.5")× more energy than its typical share. It may be stuck in a loop or doing background work. Restart it if you're not actively using it."]
        phrases += ["Close", "Plugged In", "On Battery", "Show Glow"]
        phrases += DevicesHelpLine.all.flatMap { [$0.text] + ($0.link.map { [$0.title] } ?? []) }
        phrases += [true, false].flatMap { on in
            let entry = DetectedDevices.Entry(row: DeviceRow(id: DeviceID(address: "d"), name: "D", kind: .accessory, level: BatteryLevel(percent: 50, approximate: false)), isHidden: on, isAlerting: on, isPinned: on)
            return [entry.alertingLabel, entry.pinnedLabel, entry.hiddenLabel]
        }
        phrases += ["Move \("D") up, toward the left of the menu bar", "Move \("D") down, toward the right of the menu bar"]
        phrases += ["＋ \("Add Low Battery Alert")", "Add Low Battery Alert", "Add Charged Alert", "Enable Notifications", "Show battery alerts and notifications",
                    "Low Battery Alerts", "Notify when battery goes below percentage", "Charged Alerts", "Notify when battery reaches percentage",
                    "Power Source Alerts", "Plugged In", "Notify when power adapter is connected", "Unplugged", "Notify when power adapter is disconnected",
                    "Sound", "Play a sound for these alerts", "Power Source Sound", "Threshold", "Below this level", "At or above this level", "Position",
                    "Border Glow", "Light the screen edges", "Play a sound",
                    "Menu Bar Icon", "Display", "Choose what to display in the menu bar icon", "Color", "Match your menu bar style", "Size",
                    "Make the icon and its text larger and easier to read", "Status colors",
                    "Green when charging, orange for low battery. Off keeps the icon neutral and only turns it red when critical.",
                    "Bluetooth Devices", "Show Connected Devices", "Display battery levels for paired Bluetooth devices in the menu bar dropdown",
                    "Detected Devices", "Device readings stopped. Quit and reopen the app.", "No connected Bluetooth devices report a battery.",
                    "Pinned Devices", "Pin a connected device from the Devices screen to arrange it here.",
                    "The top device sits leftmost in the menu bar. Dragging an item in the menu bar is undone when a pinned device connects, disconnects, or is moved here."]
        phrases += ["Charge Limit", "Pause charging at your target so the battery sits in a healthier range.", "Target", "Charging pauses at this level",
                    ChargingScreen.limitHelp]
        for edit: (inout [String: Any]) -> Void in [{ _ in }, { $0["AppleRawMaxCapacity"] = 4000 }, { $0["Temperature"] = 3700 },
                                                     { $0["Temperature"] = 4300 }, { $0["Voltage"] = 8000 }] {
            let info = try Words.reference(edit)
            phrases += [info.health.label, info.temperature.status, info.temperature.caption, info.electrical.voltageNote]
        }
        for phrase in phrases {
            for code in ["fr", "es"] { #expect(hasTranslation(phrase, code), "\(phrase.key) has no \(code) in the catalog") }
        }
    }
}
