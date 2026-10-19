import Foundation
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what the Alerts screen shows for the settings, what
// its buttons do to them, and what a relaunch gets back.
@MainActor @Suite struct AlertsScreenTests {
    @Test func theSummaryListsThePositionThenOnlyTheOptionsThatAreOn() {
        #expect(Alert(kind: .low, threshold: 3, position: .center, glow: true, sound: true).summary
            == "Center of Screen • Border Glow • Sound")
        #expect(Alert(kind: .low, threshold: 15, position: .top, glow: false, sound: false).summary == "Top of Screen")
        #expect(Alert(kind: .charged, threshold: 80, position: .top, glow: false, sound: true).summary
            == "Top of Screen • Sound")
    }

    @Test func eachListHoldsItsKindLowestThresholdFirstAndAddAndDeleteChangeIt() {
        var settings = AlertSettings.initial
        #expect(settings.alerts(.low).map(\.threshold) == [3, 5, 15])
        #expect(settings.alerts(.charged).map(\.threshold) == [80])

        settings.add(.low)
        #expect(settings.alerts(.low).map(\.threshold) == [3, 5, 10, 15])
        let five = settings.alerts(.low)[1]
        settings.remove(five.id)
        #expect(settings.alerts(.low).map(\.threshold) == [3, 10, 15])
        #expect(settings.alerts(.charged).map(\.threshold) == [80])
    }

    @Test func editsAndTheirSwitchesSurviveARelaunch() throws {
        let defaults = AlertSettingsPersistence.suite()
        let first = try AlertCenter(store: AlertSettingsStore(defaults: defaults), deliver: { _, _ in })
        try first.update { $0.add(.charged); $0.power.pluggedIn = false; $0.enabled = false }

        let relaunched = try AlertCenter(store: AlertSettingsStore(defaults: defaults), deliver: { _, _ in })
        #expect(relaunched.settings == first.settings)
        #expect(relaunched.settings.alerts(.charged).map(\.threshold) == [80, 90])
        #expect(!relaunched.settings.power.pluggedIn && !relaunched.settings.enabled)
    }

    @Test func pluggingInShowsAPillWhileNotificationsAreOnAndNoneWhileTheyAreOff() throws {
        let pills = PillController()
        defer { pills.close() }
        let center = try AlertCenter(
            store: AlertSettingsStore(defaults: AlertSettingsPersistence.suite()),
            deliver: { pills.deliver($0, reading: $1) })
        try center.update { $0.alerts = [] }
        center.observe(try PowerAndTemperatureAlerts.battery())
        try center.update { $0.enabled = false }
        center.observe(try PowerAndTemperatureAlerts.adapter())
        #expect(pills.shown == nil)

        center.observe(try PowerAndTemperatureAlerts.battery())
        try center.update { $0.enabled = true }
        center.observe(try PowerAndTemperatureAlerts.adapter())
        #expect(pills.shown?.headline == "Plugged In")
    }

    @Test func aPowerPillTellsTheEventAndCountsTheReading() throws {
        let pills = PillController()
        defer { pills.close() }
        let battery = try PowerAndTemperatureAlerts.battery()
        pills.deliver(.unplugged(sound: false), reading: battery)
        #expect(pills.shown == PillContent.power("On Battery", severity: .orange, reading: battery))
        #expect(pills.shown?.position == .top && pills.shown?.glow == false)
        #expect(pills.shown?.progress == Double(battery.chargePercent) / 100)

        pills.deliver(.pluggedIn(sound: false), reading: try PowerAndTemperatureAlerts.adapter())
        #expect(pills.shown?.headline == "Plugged In" && pills.shown?.severity == .green)
    }
}
