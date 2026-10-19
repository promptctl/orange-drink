import Foundation
import Testing
@testable import OrangeDrink

// [LAW:verifiable-goals] A device's low alert from simulated levels: no Bluetooth in the room.
@MainActor struct DeviceAlertTests {
    static let mouse = DeviceID(address: "m")
    static let pods = DeviceID(address: "p")

    private func list(_ levels: [DeviceID: Int]) -> DeviceList {
        var list = DeviceList()
        list.apply(.swept(levels.map { id, percent in
            Device(id: id, name: id == Self.mouse ? "Magic Mouse" : "AirPods", kind: .accessory,
                   levels: .single(BatteryLevel(percent: percent, approximate: false)))
        }))
        return list
    }

    /// The ticket's sequence: one point above the threshold, at it, one below, at it, one above.
    private let aroundTwenty = [21, 20, 19, 20, 21]
    private let alert = AlertEngineTests.low(20)

    @Test func aWatchedDeviceCrossingItsThresholdFiresExactlyOnce() {
        var engine = DeviceAlertEngine()
        let fired = aroundTwenty.flatMap { engine.observe(list([Self.mouse: $0]), watching: [Self.mouse], alerts: [alert]) }
        #expect(fired == [DeviceFiring(alert: alert, name: "Magic Mouse", level: BatteryLevel(percent: 19, approximate: false))])
    }

    @Test func aDeviceWhoseBellIsOffFiresNothing() {
        var engine = DeviceAlertEngine()
        let fired = aroundTwenty.flatMap { engine.observe(list([Self.mouse: $0]), watching: [], alerts: [alert]) }
        #expect(fired.isEmpty)
    }

    @Test func chargedAlertsAreNotAppliedToDevices() {
        var engine = DeviceAlertEngine()
        let charged = Alert(kind: .charged, threshold: 80, position: .top, glow: false, sound: false)
        _ = engine.observe(list([Self.mouse: 70]), watching: [Self.mouse], alerts: [charged])
        #expect(engine.observe(list([Self.mouse: 85]), watching: [Self.mouse], alerts: [charged]).isEmpty)
    }

    @Test func twoDevicesAreTrackedIndependently() {
        var engine = DeviceAlertEngine()
        let both: Set = [Self.mouse, Self.pods]
        _ = engine.observe(list([Self.mouse: 21, Self.pods: 50]), watching: both, alerts: [alert])
        let fired = engine.observe(list([Self.mouse: 19, Self.pods: 50]), watching: both, alerts: [alert])
        #expect(fired.map(\.name) == ["Magic Mouse"])
        #expect(engine.observe(list([Self.mouse: 19, Self.pods: 19]), watching: both, alerts: [alert]).map(\.name) == ["AirPods"])
    }

    @Test func turningTheBellOnBelowTheThresholdAnnouncesNothing() {
        var engine = DeviceAlertEngine()
        _ = engine.observe(list([Self.mouse: 10]), watching: [], alerts: [alert])
        #expect(engine.observe(list([Self.mouse: 10]), watching: [Self.mouse], alerts: [alert]).isEmpty)
    }

    @Test func turningTheBellOnJustAboveTheThresholdStillAnnouncesTheFall() {
        var engine = DeviceAlertEngine()
        _ = engine.observe(list([Self.mouse: 21]), watching: [], alerts: [alert])
        let fired = engine.observe(list([Self.mouse: 19]), watching: [Self.mouse], alerts: [alert])
        #expect(fired.map(\.level.percent) == [19])
    }

    @Test func budsGoingIntoTheirCaseIsNotTheLevelFalling() {
        func pods(left: Int?, right: Int?, case: Int) -> DeviceList {
            func level(_ percent: Int?) -> BatteryLevel? { percent.map { BatteryLevel(percent: $0, approximate: false) } }
            var list = DeviceList()
            list.apply(.swept([Device(id: Self.pods, name: "AirPods", kind: .accessory,
                                      levels: .earbuds(left: level(left), right: level(right), case: level(`case`)))]))
            return list
        }
        var engine = DeviceAlertEngine()
        let watching: Set = [Self.pods]
        _ = engine.observe(pods(left: 50, right: 50, case: 10), watching: watching, alerts: [alert])
        #expect(engine.observe(pods(left: nil, right: nil, case: 10), watching: watching, alerts: [alert]).isEmpty)
        #expect(engine.observe(pods(left: 50, right: 50, case: 10), watching: watching, alerts: [alert]).isEmpty)
    }

    @Test func anApproximateLevelIsMarkedOnThePill() {
        let firing = DeviceFiring(alert: alert, name: "AirPods", level: BatteryLevel(percent: 19, approximate: true))
        #expect(PillContent(firing).headline.english == "AirPods: ~19% Remaining")
    }

    @Test func theModelTellsItsCallbackTheListAfterEveryEvent() async {
        let (events, send) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        var seen: [Int] = []
        let (counts, count) = AsyncStream.makeStream(of: Int.self)
        let model = DevicesModel(events: events, onChange: { seen.append($0.devices.count); count.yield($0.devices.count) })
        send.yield(.swept([DeviceListTests.mouse]))
        send.yield(.reported(DeviceListTests.pods))
        var iterator = counts.makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()
        #expect(seen == [1, 2])
        _ = model
    }

    @Test func theBellShowsOnItsDetectedRow() {
        var settings = DeviceSettings()
        settings.toggleAlerting(DeviceListTests.mouse.id)
        var devices = DeviceList()
        devices.apply(.swept([DeviceListTests.mouse, DeviceListTests.pods]))
        #expect(DetectedDevices(devices, settings: settings).entries.map(\.isAlerting) == [true, false])
    }

    @Test func aDeviceReportingNoLevelIsNotObserved() {
        var engine = DeviceAlertEngine()
        var silent = DeviceList()
        silent.apply(.swept([Device(id: Self.mouse, name: "Magic Mouse", kind: .accessory, levels: .none)]))
        #expect(engine.observe(silent, watching: [Self.mouse], alerts: [alert]).isEmpty)
    }

    private func center(_ delivered: Box) throws -> AlertCenter {
        let defaults = UserDefaults(suiteName: "DeviceAlertTests.\(UUID())")!
        let center = try AlertCenter(store: AlertSettingsStore(defaults: defaults), deliver: { _, _ in },
                                     deliverDevice: { delivered.firings.append($0) })
        try center.update { $0.alerts = [alert] }
        return center
    }

    final class Box { var firings: [DeviceFiring] = [] }

    @Test func theCenterDeliversAWatchedDevicesFiringOnce() throws {
        let delivered = Box()
        let center = try center(delivered)
        for level in aroundTwenty { center.observe(devices: list([Self.mouse: level]), watching: [Self.mouse]) }
        #expect(delivered.firings.map(\.level.percent) == [19])
    }

    @Test func theMasterSwitchOffDeliversNothingButKeepsTracking() throws {
        let delivered = Box()
        let center = try center(delivered)
        try center.update { $0.enabled = false }
        for level in aroundTwenty { center.observe(devices: list([Self.mouse: level]), watching: [Self.mouse]) }
        #expect(delivered.firings.isEmpty)
        // Tracking ran with the switch off, so switching on while still below does not announce the crossing it missed.
        try center.update { $0.enabled = true }
        center.observe(devices: list([Self.mouse: 18]), watching: [Self.mouse])
        #expect(delivered.firings.isEmpty)
    }

    @Test func aDeviceFiringsPillNamesTheDeviceItsLevelAndTheAlertsLook() {
        let firing = DeviceFiring(alert: AlertEngineTests.low(5), name: "Magic Mouse", level: BatteryLevel(percent: 4, approximate: false))
        let pill = PillContent(firing)
        #expect(pill.headline.english == "Magic Mouse: 4% Remaining")
        #expect(pill.severity == .red)
        #expect(pill.progress == 0.04)
    }

    @Test func theBellPersistsAndAnOlderStoredValueWithoutItStillLoads() throws {
        let defaults = UserDefaults(suiteName: "DeviceAlertTests.\(UUID())")!
        defaults.set(Data(#"{"showConnectedDevices":true,"hidden":[]}"#.utf8), forKey: DeviceSettings.storageKey)
        let first = try DeviceSettingsModel(defaults: defaults)
        #expect(first.value.alerting.isEmpty)
        try first.update { $0.toggleAlerting(Self.mouse) }
        #expect(try DeviceSettingsModel(defaults: defaults).value.alerting == [Self.mouse])
    }
}
