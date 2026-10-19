import Foundation
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is which alerts a run of charge levels fires, and
// what a relaunch gets back; the engine's bookkeeping is not asserted.
@Suite struct AlertEngineTests {
    static func low(_ threshold: Int) -> Alert {
        Alert(kind: .low, threshold: threshold, position: .top, glow: false, sound: false)
    }
    static func charged(_ threshold: Int) -> Alert {
        Alert(kind: .charged, threshold: threshold, position: .top, glow: false, sound: false)
    }

    /// The levels at which `alerts` fire, in order, over the readings.
    static func firings(_ levels: [Int], _ alerts: [Alert], enabled: Bool = true) -> [Int] {
        var engine = AlertEngine()
        return levels.filter { !engine.observe(level: $0, alerts: alerts, enabled: enabled).isEmpty }
    }

    @Test func aLowAlertHoveringAtItsThresholdFiresOnceAtTheFirstReadingBelow() {
        #expect(Self.firings([21, 20, 19, 20, 19, 20, 21], [Self.low(20)]) == [19])
    }

    @Test func aLowAlertFiresAgainOnceTheBatteryHasRechargedAndFallenAgain() {
        let down = Array(stride(from: 100, through: 10, by: -1))
        let up = Array(stride(from: 11, through: 100, by: 1))
        #expect(Self.firings(down + up + down, [Self.low(20)]) == [19, 19])
    }

    @Test func aChargedAlertHoveringAtItsThresholdFiresOnceAtTheReading() {
        #expect(Self.firings([78, 79, 80, 79, 80, 81], [Self.charged(80)]) == [80])
    }

    @Test func aChargedAlertFiresAgainOnceTheBatteryHasRunBackDown() {
        #expect(Self.firings([79, 80, 90, 70, 80], [Self.charged(80)]) == [80, 80])
    }

    @Test func nothingFiresWithTheMasterSwitchOff() {
        #expect(Self.firings([21, 20, 19, 20, 19, 20, 21], [Self.low(20)], enabled: false) == [])
    }

    @Test func switchingTheMasterSwitchOnBelowAThresholdDoesNotFireItLate() {
        var engine = AlertEngine()
        let alerts = [Self.low(20)]
        _ = engine.observe(level: 21, alerts: alerts, enabled: false)
        _ = engine.observe(level: 19, alerts: alerts, enabled: false)
        #expect(engine.observe(level: 18, alerts: alerts, enabled: true) == [])
    }

    @Test func launchingBelowAThresholdDoesNotFireIt() {
        #expect(Self.firings([15, 14, 13], [Self.low(20)]) == [])
    }

    @Test func eachAlertFiresOnItsOwnCrossing() {
        var engine = AlertEngine()
        let alerts = [Self.low(20), Self.low(10)]
        _ = engine.observe(level: 21, alerts: alerts, enabled: true)
        #expect(engine.observe(level: 19, alerts: alerts, enabled: true) == [alerts[0]])
        #expect(engine.observe(level: 9, alerts: alerts, enabled: true) == [alerts[1]])
    }
}

@Suite struct AlertSettingsPersistence {
    static func suite() -> UserDefaults {
        let name = "AlertSettingsPersistence.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func aRelaunchGetsTheSameAlertsAndSwitchBack() throws {
        let defaults = Self.suite()
        let saved = AlertSettings(enabled: false, alerts: [
            Alert(kind: .low, threshold: 7, position: .center, glow: true, sound: false),
            Alert(kind: .charged, threshold: 90, position: .top, glow: false, sound: true),
        ])
        try AlertSettingsStore(defaults: defaults).save(saved)
        #expect(try AlertSettingsStore(defaults: defaults).load() == saved)
    }

    @Test func aFirstLaunchStartsFromTheReferenceSetup() throws {
        #expect(try AlertSettingsStore(defaults: Self.suite()).load() == .initial)
    }

    @Test func storedBytesThatDoNotDecodeFailLoudly() {
        let defaults = Self.suite()
        defaults.set(Data("nonsense".utf8), forKey: "alerts.settings")
        #expect(throws: DecodingError.self) { try AlertSettingsStore(defaults: defaults).load() }
    }
}

@MainActor @Suite struct AlertCenterTests {
    static func reading(_ percent: Int) throws -> BatteryReading {
        try BatteryEvents.reading(BatteryEvents.Fixtures.discharging(timeToEmpty: 192), percent: percent)
    }

    @Test func aReadingCrossingAThresholdDeliversItsAlertAndAnEditSurvivesARelaunch() throws {
        let defaults = AlertSettingsPersistence.suite()
        var delivered: [Alert] = []
        let center = try AlertCenter(store: AlertSettingsStore(defaults: defaults), deliver: { delivered.append($0) })
        let alert = AlertEngineTests.low(20)
        try center.update { $0.alerts = [alert] }
        center.observe(try Self.reading(21))
        center.observe(try Self.reading(19))
        center.observe(nil)
        #expect(delivered == [alert])
        #expect(try AlertCenter(store: AlertSettingsStore(defaults: defaults), deliver: { _ in }).settings.alerts == [alert])
    }
}
