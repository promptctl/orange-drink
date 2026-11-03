import Testing
@testable import OrangeDrink

// [LAW:verifiable-goals] The card's rows from simulated devices: no Bluetooth in the room.
struct ConnectedDevicesTests {
    private func device(_ address: String, _ name: String, kind: DeviceKind = .accessory,
                        _ levels: DeviceLevels) -> SourceDevice {
        SourceDevice(id: DeviceID.bluetooth(address), name: name, kind: kind, levels: levels)
    }
    private func single(_ percent: Int, approximate: Bool = false) -> DeviceLevels {
        .single(BatteryLevel(percent: percent, approximate: approximate))
    }
    private func rows(_ devices: [SourceDevice]) -> [DeviceRow] {
        var list = DeviceList(sources: [.bluetooth])
        list.apply(.swept(devices), from: .bluetooth)
        return ConnectedDevices(list, settings: DeviceSettings()).rows
    }

    private var fleet: [SourceDevice] {
        [device("1", "Keyboard", single(54)), device("2", "iPad", kind: .tablet, single(95)),
         device("3", "iPhone", kind: .phone, single(37)), device("4", "AirPods", single(50, approximate: true))]
    }

    @Test func anEmptyCardSaysWhy() {
        var list = DeviceList(sources: [.bluetooth])
        let note = { ConnectedDevices(list, settings: DeviceSettings()).emptyNote }
        #expect(note() == UnreadDevices.waiting.explanation)
        list.apply(.permission(.notDetermined), from: .bluetooth)
        #expect(note() == UnreadDevices.unanswered.explanation)
        list.apply(.permission(.denied), from: .bluetooth)
        #expect(note() == UnreadDevices.denied.explanation)
        list.apply(.permission(.allowed), from: .bluetooth)
        #expect(note() == UnreadDevices.waiting.explanation)
        list.apply(.swept([]), from: .bluetooth)
        #expect(note() == "No connected Bluetooth devices to show.")
        list.end(.bluetooth)
        #expect(note() == UnreadDevices.ended.explanation)
        list.apply(.swept(fleet), from: .bluetooth)
        var hidden = DeviceSettings()
        hidden.hidden = Set(fleet.map(\.id))
        #expect(ConnectedDevices(list, settings: hidden).emptyNote == "Every device is hidden. Show them again in Settings → Devices.")
    }

    @Test func rowsRunLowestFirstWithApproximateLevelsMarked() {
        #expect(rows(fleet).map(\.percent.english) == ["37%", "~50%", "54%", "95%"])
    }

    @Test func onlyANearlyFullDeviceIsGreen() {
        #expect(rows(fleet).map(\.tone) == [.normal, .normal, .normal, .nearlyFull])
    }

    @Test func eachKindHasItsIcon() {
        #expect(rows(fleet).map(\.kind.symbol) == ["iphone", "dot.radiowaves.left.and.right", "dot.radiowaves.left.and.right", "ipad"])
    }

    @Test func aDeviceDroppingToTwentyPercentMovesToTheTop() {
        var devices = fleet
        devices[1] = device("2", "iPad", kind: .tablet, single(20))
        #expect(rows(devices).map(\.name) == ["iPad", "iPhone", "AirPods", "Keyboard"])
    }

    @Test func aDeviceReportingNoLevelHasNoRow() {
        #expect(rows([device("1", "Speaker", .none)]).isEmpty)
    }

    @Test func aDeviceWhoseLevelsAreUnreadKeepsItsRowWithNoLevelBelowTheRanking() {
        let rows = rows([device("1", "Aardvark", .unread), device("2", "Mouse", single(95)), device("3", "Speaker", .none)])
        #expect(rows.map(\.name) == ["Mouse", "Aardvark"])
        #expect(rows.map(\.percent.english) == ["95%", "–"])
        #expect(rows.map(\.fraction) == [0.95, 0])
    }

    @Test func earbudsShowTheirLowestBudNotTheCase() {
        let pods = device("1", "AirPods", .earbuds(left: BatteryLevel(percent: 60, approximate: false), right: nil,
                                                    case: BatteryLevel(percent: 5, approximate: false)))
        #expect(rows([pods]).map(\.percent.english) == ["60%"])
        #expect(rows([pods]).map(\.fraction) == [0.6])
    }

    @Test func ninetyPercentIsNearlyFullAndEightyNineIsNot() {
        let tones = rows([device("1", "A", single(89)), device("2", "B", single(90))]).map(\.tone)
        #expect(tones == [.normal, .nearlyFull])
    }

    @Test func equalLevelsOrderByNameThenAddress() {
        let tied = [device("2", "Mouse", single(50)), device("3", "Keyboard", single(50)), device("1", "Mouse", single(50))]
        #expect(rows(tied).map(\.id.key) == ["3", "1", "2"])
    }
}
