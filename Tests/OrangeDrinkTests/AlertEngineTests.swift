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
    static func firings(_ levels: [Int], _ alerts: [Alert]) -> [Int] {
        var engine = AlertEngine()
        return levels.filter { !engine.observe(level: $0, alerts: alerts).isEmpty }
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

    @Test func anAlertAtTheEndOfTheScaleStillFiresAgain() {
        #expect(Self.firings([100, 99, 100, 99], [Self.low(100)]) == [99, 99])
        #expect(Self.firings([2, 3, 0, 3, 0], [Self.charged(3)]) == [3, 3])
    }

    @Test func anAlertRearmsExactlyFivePointsBackFromItsThreshold() {
        #expect(Self.firings([21, 19, 24, 19], [Self.low(20)]) == [19])
        #expect(Self.firings([21, 19, 25, 19], [Self.low(20)]) == [19, 19])
        #expect(Self.firings([79, 80, 76, 80], [Self.charged(80)]) == [80])
        #expect(Self.firings([79, 80, 75, 80], [Self.charged(80)]) == [80, 80])
    }

    @Test func editingAnArmedAlertPastTheLevelDoesNotFireIt() {
        var engine = AlertEngine()
        let alert = Self.low(20)
        _ = engine.observe(level: 40, alerts: [alert])
        var edited = alert
        edited.threshold = 50
        #expect(engine.observe(level: 40, alerts: [edited]) == [])
    }

    @Test func anAlertRemovedAndAddedBackIsMetAsNew() {
        var engine = AlertEngine()
        let alert = Self.low(20)
        _ = engine.observe(level: 21, alerts: [alert])
        _ = engine.observe(level: 19, alerts: [])
        #expect(engine.observe(level: 18, alerts: [alert]) == [])
    }

    @Test func launchingBelowAThresholdDoesNotFireIt() {
        #expect(Self.firings([15, 14, 13], [Self.low(20)]) == [])
    }

    @Test func eachAlertFiresOnItsOwnCrossing() {
        var engine = AlertEngine()
        let alerts = [Self.low(20), Self.low(10)]
        _ = engine.observe(level: 21, alerts: alerts)
        #expect(engine.observe(level: 19, alerts: alerts) == [alerts[0]])
        #expect(engine.observe(level: 9, alerts: alerts) == [alerts[1]])
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
        let saved = AlertSettings(enabled: false, power: PowerSourceAlerts(pluggedIn: false, unplugged: true, sound: false), alerts: [
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
        var delivered: [Firing] = []
        let center = try AlertCenter(store: AlertSettingsStore(defaults: defaults), deliver: { delivered.append($0) })
        let alert = AlertEngineTests.low(20)
        try center.update { $0.alerts = [alert] }
        center.observe(try Self.reading(21))
        center.observe(try Self.reading(19))
        center.observe(nil)
        #expect(delivered == [.threshold(alert)])
        #expect(try AlertCenter(store: AlertSettingsStore(defaults: defaults), deliver: { _ in }).settings.alerts == [alert])
    }

    @Test func nothingIsDeliveredWithTheMasterSwitchOffAndNothingFiresLateWhenItComesOn() throws {
        var delivered: [Firing] = []
        let center = try AlertCenter(store: AlertSettingsStore(defaults: AlertSettingsPersistence.suite()), deliver: { delivered.append($0) })
        try center.update { $0 = AlertSettings(enabled: false, power: $0.power, alerts: [AlertEngineTests.low(20)]) }
        center.observe(try Self.reading(21))
        center.observe(try Self.reading(19))
        try center.update { $0.enabled = true }
        center.observe(try Self.reading(18))
        #expect(delivered == [])
    }
}

// [LAW:behavior-not-structure] The contract is which firings a run of readings produces and what
// a relaunch gets back, as the Done-when of the plug, unplug, and temperature alerts states it.
@MainActor @Suite struct PowerAndTemperatureAlerts {
    static let both = PowerSourceAlerts(pluggedIn: true, unplugged: true, sound: true)

    static func reading(_ source: [String: Any], celsius: Double = 30.93) throws -> BatteryReading {
        var registry = BatteryReadingParse.registry
        registry["Temperature"] = Int(celsius * 100)
        return try #require(try BatteryReading(
            registry: registry, powerSource: source, adapter: BatteryReadingParse.adapter))
    }
    static func battery(celsius: Double = 30.93) throws -> BatteryReading {
        try reading(BatteryReadingParse.discharging(timeToEmpty: 192), celsius: celsius)
    }
    static func adapter(celsius: Double = 30.93) throws -> BatteryReading {
        try reading(BatteryReadingParse.onACNotCharging(charged: false), celsius: celsius)
    }

    /// Every firing the readings set off, in order, with no threshold alerts configured.
    static func firings(_ readings: [BatteryReading], power: PowerSourceAlerts = both) -> [Firing] {
        var engine = AlertEngine()
        return readings.flatMap { engine.observe($0, alerts: [], power: power) }
    }

    @Test func pluggingAndUnpluggingEachFireOnce() throws {
        let (battery, adapter) = (try Self.battery(), try Self.adapter())
        #expect(Self.firings([battery, adapter, adapter, battery, battery])
            == [.pluggedIn(sound: true), .unplugged(sound: true)])
    }

    @Test func eachPowerAlertHasItsOwnSwitchAndTheCardsSound() throws {
        let (battery, adapter) = (try Self.battery(), try Self.adapter())
        let run = [battery, adapter, adapter, battery, battery]
        #expect(Self.firings(run, power: PowerSourceAlerts(pluggedIn: false, unplugged: true, sound: true))
            == [.unplugged(sound: true)])
        #expect(Self.firings(run, power: PowerSourceAlerts(pluggedIn: true, unplugged: false, sound: false))
            == [.pluggedIn(sound: false)])
    }

    @Test func theMasterSwitchSilencesEveryPowerAndTemperatureAlert() throws {
        var delivered: [Firing] = []
        let center = try AlertCenter(
            store: AlertSettingsStore(defaults: AlertSettingsPersistence.suite()), deliver: { delivered.append($0) })
        try center.update { $0.enabled = false }
        for reading in [try Self.battery(), try Self.adapter(), try Self.battery(celsius: 41)] { center.observe(reading) }
        #expect(delivered == [])
    }

    @Test func theTemperatureWarningFiresOncePerMoveOutOfNormal() throws {
        let (normal, hot) = (try Self.battery(), try Self.battery(celsius: 41))
        #expect(Self.firings([normal, hot, hot, normal, hot]) == [.temperatureWarning, .temperatureWarning])
    }

    @Test func warmIsAsFarAsNormalGoesAndStaysOneWarning() throws {
        let (normal, warm, hot) = (try Self.battery(), try Self.battery(celsius: 36), try Self.battery(celsius: 41))
        #expect(Self.firings([normal, warm, hot, warm]) == [.temperatureWarning])
    }

    @Test func aMacLaunchedHotIsNotWarnedAboutAtLaunch() throws {
        #expect(Self.firings([try Self.battery(celsius: 41), try Self.battery(celsius: 42)]) == [])
    }

    @Test func theSwitchesAndSoundComeBackFromARelaunch() throws {
        let defaults = AlertSettingsPersistence.suite()
        let power = PowerSourceAlerts(pluggedIn: false, unplugged: true, sound: false)
        let center = try AlertCenter(store: AlertSettingsStore(defaults: defaults), deliver: { _ in })
        try center.update { $0.power = power }
        let relaunched = try AlertCenter(store: AlertSettingsStore(defaults: defaults), deliver: { _ in })
        #expect(relaunched.settings.power == power)
    }
}
