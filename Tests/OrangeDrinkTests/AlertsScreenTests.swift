import Foundation
import Testing
import ViewInspector
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
        let defaults = scratchDefaults()
        let first = try AlertCenter(defaults: defaults, log: .unread, deliver: { _, _ in })
        try first.model.update { $0.add(.charged); $0.power.pluggedIn = false; $0.enabled = false }

        let relaunched = try AlertCenter(defaults: defaults, log: .unread, deliver: { _, _ in })
        #expect(relaunched.settings == first.settings)
        #expect(relaunched.settings.alerts(.charged).map(\.threshold) == [80, 90])
        #expect(!relaunched.settings.power.pluggedIn && !relaunched.settings.enabled)
    }

    @Test func pluggingInShowsAPillWhileNotificationsAreOnAndNoneWhileTheyAreOff() throws {
        let pills = PillController(appearance: NotificationAppearanceModel.scratch(), language: AppLanguageTests.scratch(), orderFront: { _ in }, log: .unread)
        defer { pills.close(.closeButton) }
        let center = try AlertCenter(
            defaults: scratchDefaults(),
            log: .unread,
            deliver: { pills.deliver($0, reading: $1) })
        try center.model.update { $0.alerts = [] }
        center.observe(try PowerAndTemperatureAlerts.battery())
        try center.model.update { $0.enabled = false }
        center.observe(try PowerAndTemperatureAlerts.adapter())
        #expect(pills.shown == nil)

        center.observe(try PowerAndTemperatureAlerts.battery())
        try center.model.update { $0.enabled = true }
        center.observe(try PowerAndTemperatureAlerts.adapter())
        #expect(pills.shown?.headline == "Plugged In")
    }

    @Test func aPowerPillTellsTheEventAndCountsTheReading() throws {
        let pills = PillController(appearance: NotificationAppearanceModel.scratch(), language: AppLanguageTests.scratch(), orderFront: { _ in }, log: .unread)
        defer { pills.close(.closeButton) }
        let battery = try PowerAndTemperatureAlerts.battery()
        pills.deliver(.unplugged(sound: false), reading: battery)
        #expect(pills.shown == PillContent.power("On Battery", severity: .orange, reading: battery))
        #expect(pills.shown?.position == .top && pills.shown?.glow == false)
        #expect(pills.shown?.progress == Double(battery.chargePercent) / 100)

        pills.deliver(.pluggedIn(sound: false), reading: try PowerAndTemperatureAlerts.adapter())
        #expect(pills.shown?.headline == "Plugged In" && pills.shown?.severity == .green)
    }

    /// An `AlertCenter` delivering to a `PillController`, with no threshold alerts to confuse the pills.
    private func temperatureCenter(_ pills: PillController) throws -> AlertCenter {
        let center = try AlertCenter(defaults: scratchDefaults(), log: .unread, deliver: { pills.deliver($0, reading: $1) })
        try center.model.update { $0.alerts = [] }
        return center
    }

    @Test func aBatteryGoingHotShowsOneRedPillWithItsReadingAndNoneWhileItStaysHot() throws {
        let pills = PillController(appearance: NotificationAppearanceModel.scratch(), language: AppLanguageTests.scratch(), orderFront: { _ in }, log: .unread)
        defer { pills.close(.closeButton) }
        let center = try temperatureCenter(pills)
        center.observe(try PowerAndTemperatureAlerts.battery())
        #expect(pills.shown == nil)

        center.observe(try PowerAndTemperatureAlerts.battery(celsius: 41))
        let pill = try #require(pills.shown)
        #expect(pill.headline == "Battery Hot" && pill.severity == .red)
        #expect(pill.subline?.english == "41.0°C / 105.8°F")
        #expect(pill.position == .top && pill.glow == false)

        pills.close(.closeButton)
        center.observe(try PowerAndTemperatureAlerts.battery(celsius: 42))
        #expect(pills.shown == nil)
    }

    @Test func aBatteryReturningToNormalAndGoingHotAgainShowsAFreshPill() throws {
        let pills = PillController(appearance: NotificationAppearanceModel.scratch(), language: AppLanguageTests.scratch(), orderFront: { _ in }, log: .unread)
        defer { pills.close(.closeButton) }
        let center = try temperatureCenter(pills)
        for celsius in [30.0, 41, 30] { center.observe(try PowerAndTemperatureAlerts.battery(celsius: celsius)) }
        pills.close(.closeButton)

        center.observe(try PowerAndTemperatureAlerts.battery(celsius: 43))
        #expect(pills.shown?.headline == "Battery Hot")
    }

    @Test func aWarmBatteryShowsAnOrangePillAndGoingHotFromThereShowsNoSecondOne() throws {
        let pills = PillController(appearance: NotificationAppearanceModel.scratch(), language: AppLanguageTests.scratch(), orderFront: { _ in }, log: .unread)
        defer { pills.close(.closeButton) }
        let center = try temperatureCenter(pills)
        center.observe(try PowerAndTemperatureAlerts.battery())
        center.observe(try PowerAndTemperatureAlerts.battery(celsius: 36))
        #expect(pills.shown?.headline == "Battery Warm" && pills.shown?.severity == .orange)

        pills.close(.closeButton)
        center.observe(try PowerAndTemperatureAlerts.battery(celsius: 41))
        #expect(pills.shown == nil)
    }

    @Test func theTemperaturePillCountsTheChargeAndIsSilencedByTheMasterSwitch() throws {
        let pills = PillController(appearance: NotificationAppearanceModel.scratch(), language: AppLanguageTests.scratch(), orderFront: { _ in }, log: .unread)
        defer { pills.close(.closeButton) }
        let center = try temperatureCenter(pills)
        try center.model.update { $0.enabled = false }
        center.observe(try PowerAndTemperatureAlerts.battery())
        center.observe(try PowerAndTemperatureAlerts.battery(celsius: 41))
        #expect(pills.shown == nil)

        let hot = try PowerAndTemperatureAlerts.battery(celsius: 41)
        pills.deliver(.temperatureWarning(.hot, sound: false), reading: hot)
        #expect(pills.shown?.progress == Double(hot.chargePercent) / 100)
    }

    private func screen(_ center: AlertCenter) throws -> InspectableView<ViewType.ClassifiedView> {
        try AlertsScreen(center: center, settingsLog: .unread).inspect()
    }

    private func temperatureSwitch(_ center: AlertCenter) throws -> InspectableView<ViewType.Toggle> {
        try screen(center).find(ViewType.Toggle.self, where: { try $0.labelView().text().string() == "Temperature" })
    }

    @Test func theTemperatureRowSitsBetweenUnpluggedAndSoundWithItsWordsAndReadsOnByDefault() throws {
        let center = try AlertCenter(defaults: scratchDefaults(), log: .unread, deliver: { _, _ in })
        let view = try screen(center)
        _ = try view.find(text: "Notify when the battery runs warm or hot")
        #expect(try view.findAll(ViewType.Toggle.self).map { try $0.labelView().text().string() }
            == ["Enable Notifications", "Plugged In", "Unplugged", "Temperature", "Sound"])
        #expect(try temperatureSwitch(center).isOn())
    }

    @Test func turningTheTemperatureSwitchOffSilencesAHotBatteryAndSurvivesARelaunch() throws {
        let pills = PillController(appearance: NotificationAppearanceModel.scratch(), language: AppLanguageTests.scratch(), orderFront: { _ in }, log: .unread)
        defer { pills.close(.closeButton) }
        let defaults = scratchDefaults()
        let center = try AlertCenter(defaults: defaults, log: .unread, deliver: { pills.deliver($0, reading: $1) })
        try center.model.update { $0.alerts = [] }

        try temperatureSwitch(center).tap()
        #expect(try temperatureSwitch(center).isOn() == false)
        center.observe(try PowerAndTemperatureAlerts.battery())
        center.observe(try PowerAndTemperatureAlerts.battery(celsius: 41))
        #expect(pills.shown == nil)

        let relaunched = try AlertCenter(defaults: defaults, log: .unread, deliver: { _, _ in })
        #expect(try temperatureSwitch(relaunched).isOn() == false)
    }

    @Test func anAlertEditedFrom20To12FiresOnceAt11AndItsCardFollowsTheEdit() throws {
        var fired: [Int] = []
        let defaults = scratchDefaults()
        let center = try AlertCenter(
            defaults: defaults,
            log: .unread,
            deliver: { firing, reading in
                if case .threshold = firing { fired.append(reading.chargePercent) }
            })
        try center.model.update { $0.alerts = [Alert(kind: .low, threshold: 20, position: .top, glow: false, sound: false)] }
        let id = center.settings.alerts[0].id
        try center.model.update { settings in
            settings.edit(id) { $0.threshold = 12 }
            settings.edit(id) { $0.position = .center }
            settings.edit(id) { $0.glow = true }
        }
        let edited = center.settings.alerts[0]
        #expect(edited.threshold == 12 && edited.position == .center && edited.glow)
        for percent in [21, 19, 15, 11] { center.observe(try PillTests.reading(percent)) }
        #expect(fired == [11])

        #expect(center.settings.alerts(.low).map(\.summary.english) == ["Center of Screen • Border Glow"])
        let relaunched = try AlertCenter(defaults: defaults, log: .unread, deliver: { _, _ in })
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
            defaults: scratchDefaults(),
            log: .unread,
            deliver: { firing, reading in
                if case .threshold = firing { fired.append(reading.chargePercent) }
            })
        try center.model.update { $0.alerts = [Alert(kind: .low, threshold: 20, position: .top, glow: false, sound: false)] }
        for percent in [25, 19] { center.observe(try PillTests.reading(percent)) }
        #expect(fired == [19])

        let id = center.settings.alerts[0].id
        try center.model.update { $0.edit(id) { $0.threshold = 12 } }
        for percent in [15, 11] { center.observe(try PillTests.reading(percent)) }
        #expect(fired == [19, 11])

        let before = center.settings
        try center.model.update { $0.edit(UUID()) { $0.threshold = 50 } }
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
