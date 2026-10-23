import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is the sidebar design-docs/README.md describes:
// which screens, in what order, in which group, and how the tiles are coloured.
@Suite struct SettingsSidebar {
    @Test func listsTheTenScreensInOrderWithInsightsLast() {
        let rows = SettingsScreen.allCases.map { ($0.title, $0.group) }
        #expect(rows.map(\.0) == ["General", "Alerts", "Menu Bar", "Charging", "Devices", "Widgets", "Shortcuts",
                                   "App Usage", "Battery", "iPhone & iPad"])
        #expect(rows.prefix(7).allSatisfy { $0.1 == .settings })
        #expect(rows.suffix(3).allSatisfy { $0.1 == .insights })
    }

    @Test func glyphsAreDistinctAndNamed() {
        let glyphs = SettingsScreen.allCases.map(\.glyph)
        #expect(Set(glyphs).count == 10)
        #expect(SettingsScreen.general.glyph == "gearshape.fill")
        #expect(SettingsScreen.alerts.glyph == "bell.fill")
        #expect(SettingsScreen.shortcuts.glyph == "command")
    }

    @Test func tilesStepEvenlyFromYellowGreenToIndigo() {
        let hues = SettingsScreen.allCases.map(\.tileHue)
        #expect(hues.first == SettingsScreen.firstHue && hues.last == SettingsScreen.lastHue)
        let steps = zip(hues, hues.dropFirst()).map { $1 - $0 }
        #expect(steps.allSatisfy { abs($0 - steps[0]) < 1e-9 && $0 > 0 })
        #expect(SettingsScreen.firstHue == 80 && SettingsScreen.lastHue == 255)
    }

    @Test func everyScreenHasItsDocsSubtitleExceptAppUsage() {
        #expect(SettingsScreen.general.subtitle(appName: "App") == "Basic app settings and preferences")
        #expect(SettingsScreen.menuBar.subtitle(appName: "OrangeDrink")?.english == "Customize how OrangeDrink appears in your menu bar")
        #expect(SettingsScreen.appUsage.subtitle(appName: "App") == nil)
        #expect(SettingsScreen.allCases.filter { $0.subtitle(appName: "App") == nil } == [.appUsage])
    }
}

// [LAW:behavior-not-structure] The contract is each design doc's "Background" line: alerts.md, devices.md and charging.md.
@MainActor @Suite struct SettingsBackdrops {
    @Test func glowsSitWhereTheDocsPutThem() {
        let alerts = SettingsScreen.alerts.backdrop.glows
        #expect(alerts.map(\.color) == [.green, .red] && alerts.map(\.center) == [.topTrailing, .center])
        let devices = SettingsScreen.devices.backdrop.glows
        #expect(devices.map(\.color) == [.green] && devices.map(\.center) == [.top])
        let charging = SettingsScreen.charging.backdrop.glows
        #expect(charging.map(\.color) == [.green] && charging.map(\.center) == [.trailing])
    }
}
