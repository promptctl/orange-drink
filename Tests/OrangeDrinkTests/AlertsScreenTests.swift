import Foundation
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what the Alerts screen shows for the settings, what
// its buttons do to them, and what a relaunch gets back.
@MainActor @Suite struct AlertsScreenTests {
    @Test func theSummaryListsThePositionThenOnlyTheOptionsThatAreOn() {
        #expect(Alert(kind: .low, threshold: 3, position: .center, glow: true, sound: true).summary.english
            == "Center of Screen • Border Glow • Sound")
        #expect(Alert(kind: .low, threshold: 15, position: .top, glow: false, sound: false).summary.english == "Top of Screen")
        #expect(Alert(kind: .charged, threshold: 80, position: .top, glow: false, sound: true).summary.english
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
        let pills = PillController(appearance: NotificationAppearanceModel.scratch(), language: AppLanguageTests.scratch())
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
        let pills = PillController(appearance: NotificationAppearanceModel.scratch(), language: AppLanguageTests.scratch())
        defer { pills.close() }
        let battery = try PowerAndTemperatureAlerts.battery()
        pills.deliver(.unplugged(sound: false), reading: battery)
        #expect(pills.shown == PillContent.power("On Battery", severity: .orange, reading: battery))
        #expect(pills.shown?.position == .top && pills.shown?.glow == false)
        #expect(pills.shown?.progress == Double(battery.chargePercent) / 100)

        pills.deliver(.pluggedIn(sound: false), reading: try PowerAndTemperatureAlerts.adapter())
        #expect(pills.shown?.headline == "Plugged In" && pills.shown?.severity == .green)
    }

    @Test func anAlertEditedFrom20To12FiresOnceAt11AndItsCardFollowsTheEdit() throws {
        var fired: [Int] = []
        let defaults = AlertSettingsPersistence.suite()
        let center = try AlertCenter(
            store: AlertSettingsStore(defaults: defaults),
            deliver: { firing, reading in
                if case .threshold = firing { fired.append(reading.chargePercent) }
            })
        try center.update { $0.alerts = [Alert(kind: .low, threshold: 20, position: .top, glow: false, sound: false)] }
        let id = center.settings.alerts[0].id
        try center.update { settings in
            settings.edit(id) { $0.threshold = 12 }
            settings.edit(id) { $0.position = .center }
            settings.edit(id) { $0.glow = true }
        }
        let edited = center.settings.alerts[0]
        #expect(edited.threshold == 12 && edited.position == .center && edited.glow)
        for percent in [21, 19, 15, 11] { center.observe(try PillTests.reading(percent)) }
        #expect(fired == [11])

        #expect(center.settings.alerts(.low).map(\.summary.english) == ["Center of Screen • Border Glow"])
        let relaunched = try AlertCenter(store: AlertSettingsStore(defaults: defaults), deliver: { _, _ in })
        #expect(relaunched.settings.alerts == [edited])
    }

    @Test func anEditedThresholdReSortsItsCard() {
        var settings = AlertSettings.initial
        var fifteen = settings.alerts(.low)[2]
        settings.edit(fifteen.id) { $0.threshold = 2 }
        fifteen.threshold = 2
        #expect(settings.alerts(.low).map(\.threshold) == [2, 3, 5])
        #expect(settings.alerts(.low)[0].id == fifteen.id)
    }

    @Test func editingAFiredAlertsThresholdMakesItNewAndEditingAGoneAlertChangesNothing() throws {
        var fired: [Int] = []
        let center = try AlertCenter(
            store: AlertSettingsStore(defaults: AlertSettingsPersistence.suite()),
            deliver: { firing, reading in
                if case .threshold = firing { fired.append(reading.chargePercent) }
            })
        try center.update { $0.alerts = [Alert(kind: .low, threshold: 20, position: .top, glow: false, sound: false)] }
        for percent in [25, 19] { center.observe(try PillTests.reading(percent)) }
        #expect(fired == [19])

        let id = center.settings.alerts[0].id
        try center.update { $0.edit(id) { $0.threshold = 12 } }
        for percent in [15, 11] { center.observe(try PillTests.reading(percent)) }
        #expect(fired == [19, 11])

        let before = center.settings
        try center.update { $0.edit(UUID()) { $0.threshold = 50 } }
        #expect(center.settings == before)
    }

    @Test func alertsAtTheSameThresholdKeepOneOrder() {
        var settings = AlertSettings.initial
        settings.add(.low); settings.add(.low)
        let order = settings.alerts(.low).map(\.id)
        #expect(settings.alerts(.low).map(\.id) == order)
        #expect(Set(order).count == 5)
    }
}
