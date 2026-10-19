import AppKit
import Foundation
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what a run of readings puts on screen: how many
// pills, where, saying what, filled how far.
@MainActor @Suite(.serialized) struct PillTests {
    static func reading(_ percent: Int, minutes: Int = 9) throws -> BatteryReading {
        try BatteryEvents.reading(BatteryEvents.Fixtures.discharging(timeToEmpty: minutes), percent: percent)
    }

    static func center(_ pills: PillController, alerts: [Alert]) throws -> AlertCenter {
        let center = try AlertCenter(
            store: AlertSettingsStore(defaults: AlertSettingsPersistence.suite()),
            deliver: { pills.deliver($0, reading: $1) })
        try center.update { $0.alerts = alerts }
        return center
    }

    @Test func aLowAlertAtTopOfScreenShowsOnePillForTheReadingThatCrossedIt() throws {
        let pills = PillController(appearance: NotificationAppearanceModel.scratch())
        defer { pills.close() }
        let center = try Self.center(
            pills, alerts: [Alert(kind: .low, threshold: 15, position: .top, glow: false, sound: false)])
        for percent in [16, 15, 14] { center.observe(try Self.reading(percent)) }

        #expect(pills.shown == PillContent(
            headline: "14% Remaining", subline: "9min until empty", severity: .orange, progress: 0.14, position: .top, glow: false))
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first).visibleFrame
        #expect(pills.shownFrame == PillPlacement.frame(.top, on: screen, scale: 1))
        #expect(try #require(pills.shownFrame).maxY > screen.midY)
    }

    @Test func borderGlowFollowsTheAlertThatFiredAndGoesWithItsPill() throws {
        let pills = PillController(appearance: NotificationAppearanceModel.scratch())
        defer { pills.close() }
        let center = try Self.center(pills, alerts: [
            Alert(kind: .low, threshold: 20, position: .top, glow: true, sound: false),
            Alert(kind: .low, threshold: 10, position: .top, glow: false, sound: false),
        ])
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first).frame
        for percent in [21, 19] { center.observe(try Self.reading(percent)) }
        #expect(pills.shown?.glow == true && pills.shownGlowFrame == screen)

        center.observe(try Self.reading(9))
        #expect(pills.shown?.headline == "9% Remaining" && pills.shownGlowFrame == nil)

        pills.show(PillContent(Alert(kind: .low, threshold: 20, position: .top, glow: true, sound: false),
                               reading: try Self.reading(19)))
        #expect(pills.shownGlowFrame == screen)
        pills.close()
        #expect(pills.shownGlowFrame == nil)
    }

    @Test func aCenterAlertSitsAtTheMiddleOfTheScreen() throws {
        let pills = PillController(appearance: NotificationAppearanceModel.scratch())
        defer { pills.close() }
        pills.show(PillContent(Alert(kind: .low, threshold: 5, position: .center, glow: false, sound: false),
                               reading: try Self.reading(4)))
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first).visibleFrame
        let frame = try #require(pills.shownFrame)
        #expect(frame.midX == screen.midX && frame.midY == screen.midY)
    }

    @Test func aNewPillReplacesTheOneShowingAndClosingClearsIt() throws {
        let pills = PillController(appearance: NotificationAppearanceModel.scratch())
        let low = Alert(kind: .low, threshold: 15, position: .top, glow: false, sound: false)
        pills.show(PillContent(low, reading: try Self.reading(14)))
        pills.show(PillContent(low, reading: try Self.reading(13)))
        #expect(pills.shown?.headline == "13% Remaining")
        pills.close()
        #expect(pills.shown == nil && pills.shownFrame == nil)
    }

    @Test func replacingAPillDoesNotReleaseWhoeverWaitsForNoPill() async throws {
        let pills = PillController(appearance: NotificationAppearanceModel.scratch())
        let low = Alert(kind: .low, threshold: 15, position: .top, glow: false, sound: false)
        pills.show(PillContent(low, reading: try Self.reading(14)))
        var released = false
        let waiter = Task { await pills.untilClosed(); released = true }
        await Task.yield()
        pills.show(PillContent(low, reading: try Self.reading(13)))
        await Task.yield()
        #expect(!released)
        pills.close()
        await waiter.value
        #expect(released)
    }

    @Test func pillWordingAndSeverityFollowTheAlertAndTheReading() throws {
        let low = { (threshold: Int) in Alert(kind: .low, threshold: threshold, position: .top, glow: false, sound: false) }
        #expect(PillContent(low(5), reading: try Self.reading(4)).severity == .red)
        #expect(PillContent(low(6), reading: try Self.reading(5)).severity == .orange)
        #expect(PillContent(low(15), reading: try Self.reading(14, minutes: 192)).subline == "3h 12m until empty")
        let charged = Alert(kind: .charged, threshold: 80, position: .top, glow: false, sound: false)
        let content = PillContent(charged, reading: try Self.reading(80))
        #expect(content.headline == "80% Charged" && content.severity == .green)
    }

    /// The ticket's step on a real Mac, run by `make pill-check` with a person at the screen: a
    /// sample pill over a full-screen app at the centre, then at the top, each closed by its ×.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PILL_CHECK"] != nil, "run by make pill-check with a person at the screen"))
    func pillsShowOverAFullScreenApp() async throws {
        // The appearance a person set on the General screen, as the app itself loads it.
        let pills = PillController(appearance: try NotificationAppearanceModel(defaults: .standard))
        defer { pills.close() }
        let sounds = AlertSounds()
        let steps: [(position: Alert.Position, glow: Bool, sound: Bool)] = [
            (.center, false, false), (.top, false, false), (.center, true, true)]
        for (position, glow, sound) in steps {
            let alert = Alert(kind: .low, threshold: 15, position: position, glow: glow, sound: sound)
            pills.deliver(.threshold(alert), reading: try Self.reading(15))
            sounds.deliver(.threshold(alert))
            FileHandle.standardError.write(Data(
                ("\n>>> With an app full screen, find the pill at the \(position) of the screen"
                    + (glow ? ", with an orange glow around the screen edges," : "")
                    + (sound ? " and a chime," : "") + " and click its ×.\n").utf8))
            // [LAW:no-ambient-temporal-coupling] The wait is on the close itself; the deadline only bounds an absent person.
            let deadline = Task { try await Task.sleep(for: .seconds(120)); pills.close() }
            await pills.untilClosed()
            deadline.cancel()
        }
    }
}

extension NotificationAppearanceModel {
    /// An appearance over a throwaway suite, starting from the defaults.
    static func scratch(_ defaults: UserDefaults = AlertSettingsPersistence.suite()) -> NotificationAppearanceModel {
        try! NotificationAppearanceModel(defaults: defaults)
    }
}
