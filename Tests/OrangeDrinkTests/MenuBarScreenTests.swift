import AppKit
import Foundation
import SwiftUI
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what the status item and the Menu Bar screen's
// preview draw once a choice is made through the model the screen edits, and what a relaunch loads
// back. Both are read from the views' own content, so a label wired to the wrong settings fails.
@MainActor @Suite(.serialized) struct MenuBarScreenTests {
    typealias Config = MenuBarIconConfig

    static func model(_ defaults: UserDefaults = AlertSettingsPersistence.suite()) -> MenuBarIconModel {
        try! MenuBarIconModel(defaults: defaults)
    }

    /// 40% discharging with 3:12 to go.
    static let reading = try! MenuBarIconDrawing.discharging(40)

    /// The icon the status item shows for the model's current choices, on the given bar.
    static func statusIcon(_ model: MenuBarIconModel, on bar: MenuBarIcon.Bar = .dark, state: BatteryModel.State = .known(reading)) throws -> MenuBarIcon {
        guard case .icon(let icon) = StatusItemLabel(state: state, icon: model).content(on: bar) else {
            throw Failure.notAnIcon
        }
        return icon
    }
    enum Failure: Error { case notAnIcon }

    @Test func eachStyleDrawsTheStatusItemAndThePreviewInThatStyle() throws {
        let model = Self.model()
        for style in Config.Style.allCases {
            try model.update { $0.style = style }
            let shapes = [try Self.statusIcon(model), MenuBarPreview.icon(model.value)].map(\.shape)
            for shape in shapes {
                switch (style, shape) {
                case (.batteryIndicator, .indicator), (.minimal, .minimal), (.logo, .logo): break
                default: Issue.record("\(style) drew \(shape)")
                }
            }
        }
    }

    @Test(arguments: [Config.Style.batteryIndicator, .minimal])
    func eachDisplayPrintsItsTextOnTheStatusItemAndThePreview(style: Config.Style) throws {
        let model = Self.model()
        let expected: [(Config.Display, status: String?, preview: String?)] = [
            (.percentage, "40", "75"), (.timeRemaining, "3:12", "1:22"), (.iconOnly, nil, nil),
        ]
        for (display, status, preview) in expected {
            try model.update { $0.style = style; $0.display = display }
            #expect(try Self.statusIcon(model).battery?.text == status, "\(style) \(display)")
            #expect(MenuBarPreview.icon(model.value).battery?.text == preview, "\(style) \(display)")
        }
    }

    @Test func theLogoOffersOnlyIconOnlyAndKeepsTheStoredDisplayForTheBatteryStyles() throws {
        let model = Self.model()
        try model.update { $0.display = .timeRemaining }
        #expect(model.value.style.displays == [.percentage, .timeRemaining, .iconOnly])
        try model.update { $0.style = .logo }
        #expect(model.value.style.displays == [.iconOnly] && model.value.renderedDisplay == .iconOnly)
        try model.update { $0.style = .minimal }
        #expect(model.value.renderedDisplay == .timeRemaining)
    }

    @Test func eachColorDrawsItsInkAndAutomaticFollowsTheBar() throws {
        let model = Self.model()
        #expect(model.value.color == .automatic)
        let expected: [(Config.Color, onDark: MenuBarIcon.Ink, onLight: MenuBarIcon.Ink)] = [
            (.automatic, .light, .dark), (.light, .light, .light), (.dark, .dark, .dark),
        ]
        for (color, onDark, onLight) in expected {
            try model.update { $0.color = color }
            #expect(try Self.statusIcon(model, on: .dark).color == onDark, "\(color) on a dark bar")
            #expect(try Self.statusIcon(model, on: .light).color == onLight, "\(color) on a light bar")
            // The preview's mockup bar is always dark.
            #expect(MenuBarPreview.icon(model.value).color == onDark, "\(color) in the preview")
        }
    }

    @Test func eachSizeDrawsItsScaleOnTheStatusItemAndThePreview() throws {
        let model = Self.model()
        for size in Config.Size.allCases {
            try model.update { $0.size = size }
            #expect(try Self.statusIcon(model).size == size)
            #expect(MenuBarPreview.icon(model.value).size == size)
        }
        try model.update { $0.size = .extraLarge }
        let standard = Self.model()
        #expect(try Self.statusIcon(model).image.size.width > Self.statusIcon(standard).image.size.width)
    }

    @Test func statusColorsTurnTheTintOnAndOffInBoth() throws {
        let charging = try MenuBarIconDrawing.charging(75)
        let model = Self.model()
        #expect(try Self.statusIcon(model, state: .known(charging)).battery?.tint == .green)
        #expect(MenuBarPreview.icon(model.value).battery?.tint == .green)
        try model.update { $0.statusColors = false }
        #expect(try Self.statusIcon(model, state: .known(charging)).battery?.tint == .neutral)
        #expect(MenuBarPreview.icon(model.value).battery?.tint == .neutral)
    }

    @Test func aStatusItemWithoutAReadingNamesWhyAndTheLogoNeedsNone() throws {
        let model = Self.model()
        func symbol(_ state: BatteryModel.State) -> String? {
            if case .symbol(let name) = StatusItemLabel(state: state, icon: model).content(on: .dark) { name } else { nil }
        }
        #expect(symbol(.unknown) == "battery.0percent")
        #expect(symbol(.known(nil)) == "powerplug")
        #expect(symbol(.ended(nil)) == "exclamationmark.triangle")
        try model.update { $0.style = .logo }
        #expect(symbol(.ended(nil)) == nil)
        #expect(try Self.statusIcon(model, state: .ended(nil)).shape == .logo)
    }

    @Test func everyChoiceComesBackWhenLoadedAsARelaunchWould() throws {
        let defaults = AlertSettingsPersistence.suite()
        try Self.model(defaults).update {
            $0.style = .minimal; $0.display = .timeRemaining; $0.color = .dark; $0.size = .extraLarge; $0.statusColors = false
        }
        var expected = Config()
        expected.style = .minimal; expected.display = .timeRemaining; expected.color = .dark; expected.size = .extraLarge
        expected.statusColors = false
        #expect(Self.model(defaults).value == expected)
        #expect(Self.model().value == Config())
    }

    @Test func choicesAreKeptByCaseNameSoRetitlingTheScreenLeavesThemValid() throws {
        let defaults = AlertSettingsPersistence.suite()
        try Self.model(defaults).update { $0.display = .timeRemaining; $0.size = .extraLarge }
        let stored = try #require(defaults.data(forKey: Config.storageKey).flatMap { String(data: $0, encoding: .utf8) })
        #expect(stored.contains("\"timeRemaining\"") && stored.contains("\"extraLarge\""))
    }

    @Test func aFieldAReleaseAddsIsAbsentFromWhatAnEarlierOneStoredAndTakesItsDefault() throws {
        let defaults = AlertSettingsPersistence.suite()
        defaults.set(Data(#"{"style":"minimal"}"#.utf8), forKey: Config.storageKey)
        var expected = Config()
        expected.style = .minimal
        #expect(Self.model(defaults).value == expected)
    }

    @Test func storedChoicesThatDoNotDecodeFailLoudly() {
        let defaults = AlertSettingsPersistence.suite()
        defaults.set(Data(#"{"style":"hologram"}"#.utf8), forKey: Config.storageKey)
        #expect(throws: DecodingError.self) { try MenuBarIconModel(defaults: defaults) }
    }

    @Test func theStyleRowsCarryTheDesignDocsWords() {
        #expect(Config.Style.allCases.map { $0.title(appName: "Orange") } == ["Battery Indicator", "Minimal", "Orange Logo"])
        #expect(Config.Style.logo.description(appName: "Orange") == "Static Orange logo icon")
        #expect(Config.Size.standard.title == "Default")
    }
}
