import Testing
import ViewInspector
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

    private func connected(_ devices: [Device]) -> ConnectedDevices {
        var list = DeviceList()
        list.apply(.swept(devices))
        return ConnectedDevices(list, settings: DeviceSettings())
    }

    @Test func aDeviceWhoseLevelsAreUnreadHasNoRowAndTheListSaysSo() {
        let unread = connected([device("1", "Speaker", .unread)])
        #expect(unread.rows.isEmpty && unread.levelsUnread)
        #expect(!connected([device("1", "Speaker", .none)]).levelsUnread)
    }

    @MainActor @Test func anEmptyCardSaysLevelsAreUnreadNotThatNothingIsConnected() throws {
        let card = ConnectedDevicesView(connected: connected([device("1", "Speaker", .unread)]), failed: false)
        #expect(throws: Never.self) { try card.inspect().find(text: "Device batteries can't be read right now.") }
        let empty = ConnectedDevicesView(connected: connected([]), failed: false)
        #expect(throws: Never.self) { try empty.inspect().find(text: "No connected Bluetooth devices to show.") }
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
