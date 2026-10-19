import AppKit
import Foundation
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what the pill and glow come out as for the chosen
// appearance, and what a relaunch loads back.
@MainActor @Suite(.serialized) struct NotificationAppearanceTests {
    static let alert = Alert(kind: .low, threshold: 15, position: .top, glow: true, sound: false)

    static func shownPill(_ appearance: NotificationAppearanceModel) throws -> (size: CGSize, glowReach: Double?) {
        let pills = PillController(appearance: appearance)
        defer { pills.close() }
        pills.deliver(.threshold(alert), reading: try PillTests.reading(14))
        return (try #require(pills.shownFrame).size, pills.shownGlowFrame == nil ? nil : appearance.appearance.glowStrength.reach)
    }

    @Test func aBubbleSizeAwayFromDefaultMakesTheNextPillADifferentSize() throws {
        let appearance = NotificationAppearanceModel.scratch()
        let standard = try Self.shownPill(appearance).size
        #expect(standard == PillPlacement.size)

        try appearance.update { $0.bubbleSize = .large }
        let large = try Self.shownPill(appearance).size
        #expect(large.width > standard.width && large.height > standard.height)

        try appearance.update { $0.bubbleSize = .small }
        let small = try Self.shownPill(appearance).size
        #expect(small.width < standard.width)
    }

    @Test func aGlowStrengthChangesHowFarTheGlowReaches() throws {
        let appearance = NotificationAppearanceModel.scratch()
        let standard = try #require(try Self.shownPill(appearance).glowReach)
        try appearance.update { $0.glowStrength = .strong }
        #expect(try #require(try Self.shownPill(appearance).glowReach) > standard)
        #expect(NotificationAppearance.GlowStrength.strong.opacity > NotificationAppearance.GlowStrength.default.opacity)
    }

    @Test func bothSettingsComeBackUnchangedWhenLoadedAsARelaunchWould() throws {
        let defaults = AlertSettingsPersistence.suite()
        try NotificationAppearanceModel.scratch(defaults).update { $0.bubbleSize = .large; $0.glowStrength = .subtle }
        let relaunched = NotificationAppearanceModel.scratch(defaults)
        #expect(relaunched.appearance == NotificationAppearance(bubbleSize: .large, glowStrength: .subtle))
        #expect(NotificationAppearanceModel.scratch().appearance == NotificationAppearance())
    }

    @Test func storedAppearanceThatDoesNotDecodeFailsLoudly() {
        let defaults = AlertSettingsPersistence.suite()
        defaults.set(Data("not json".utf8), forKey: "notification.appearance")
        #expect(throws: DecodingError.self) { try NotificationAppearanceModel(defaults: defaults) }
    }
}
