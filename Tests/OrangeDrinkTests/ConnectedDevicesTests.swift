import Testing
@testable import OrangeDrink

// [LAW:verifiable-goals] The card's rows from simulated devices: no Bluetooth in the room.
struct ConnectedDevicesTests {
    private func device(_ address: String, _ name: String, kind: DeviceKind = .accessory,
                        _ levels: DeviceLevels) -> Device {
        Device(id: DeviceID(address: address), name: name, kind: kind, levels: levels)
    }
    private func single(_ percent: Int, approximate: Bool = false) -> DeviceLevels {
        .single(BatteryLevel(percent: percent, approximate: approximate))
    }
    private func rows(_ devices: [Device]) -> [DeviceRow] {
        var list = DeviceList()
        list.apply(.swept(devices))
        return ConnectedDevices(list, settings: DeviceSettings()).rows
    }

    private var fleet: [Device] {
        [device("1", "Keyboard", single(54)), device("2", "iPad", kind: .tablet, single(95)),
         device("3", "iPhone", kind: .phone, single(37)), device("4", "AirPods", single(50, approximate: true))]
    }

    @Test func anEmptyCardSaysWhy() {
        var list = DeviceList()
        let note = { ConnectedDevices(list, settings: DeviceSettings()).emptyNote }
        #expect(note() == "No connected Bluetooth devices to show.")
        list.apply(.permission(.notDetermined))
        #expect(note() == BluetoothPermission.notDetermined.explanation)
        list.apply(.permission(.denied))
        #expect(note() == BluetoothPermission.denied.explanation)
        list.apply(.swept(fleet))
        var hidden = DeviceSettings()
        hidden.hidden = Set(fleet.map(\.id))
        #expect(ConnectedDevices(list, settings: hidden).emptyNote == "Every device is hidden. Show them again in Settings → Devices.")
    }

    @Test func rowsRunLowestFirstWithApproximateLevelsMarked() {
        #expect(rows(fleet).map(\.percent) == ["37%", "~50%", "54%", "95%"])
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
        #expect(rows.map(\.percent) == ["95%", "–"])
        #expect(rows.map(\.fraction) == [0.95, 0])
    }

    @Test func earbudsShowTheirLowestBudNotTheCase() {
        let pods = device("1", "AirPods", .earbuds(left: BatteryLevel(percent: 60, approximate: false), right: nil,
                                                    case: BatteryLevel(percent: 5, approximate: false)))
        #expect(rows([pods]).map(\.percent) == ["60%"])
        #expect(rows([pods]).map(\.fraction) == [0.6])
    }

    @Test func ninetyPercentIsNearlyFullAndEightyNineIsNot() {
        let tones = rows([device("1", "A", single(89)), device("2", "B", single(90))]).map(\.tone)
        #expect(tones == [.normal, .nearlyFull])
    }

    @Test func equalLevelsOrderByNameThenAddress() {
        let tied = [device("2", "Mouse", single(50)), device("3", "Keyboard", single(50)), device("1", "Mouse", single(50))]
        #expect(rows(tied).map(\.id.address) == ["3", "1", "2"])
    }
}
