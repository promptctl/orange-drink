import Testing
@testable import OrangeDrink

// [LAW:one-source-of-truth] The map's Steps are the monitor's whole decision for each usbmuxd message, and its route is
// the one answer to "is this device here, and over what".
@Suite struct DeviceMapDecisions {
    private static func usb(_ handle: Int, _ udid: String) -> AttachedDevice {
        AttachedDevice(handle: handle, connection: .device(udid: udid, over: .usb))
    }

    private static func wifi(_ handle: Int, _ udid: String) -> AttachedDevice {
        AttachedDevice(handle: handle, connection: .device(udid: udid, over: .network))
    }

    @Test func pluggingInADeviceReadsItAndSwitchesOnItsWifiSync() {
        var map = DeviceMap()
        #expect(map.attach(Self.usb(4, "A")) == [.pace(udid: "A"), .enableWifiSync(handle: 4, udid: "A")])
        #expect(map.route("A") == DeviceMap.Route(handle: 4, transport: .usb))
    }

    @Test func snapshotThenListenCountsAnAttachOnce() {
        var map = DeviceMap()
        _ = map.attach(Self.usb(4, "A"))
        #expect(map.attach(Self.usb(4, "A")) == [])
    }

    @Test func aDeviceOnWifiAloneIsReadOverWifi() {
        var map = DeviceMap()
        #expect(map.attach(Self.wifi(5, "A")) == [.pace(udid: "A")])
        #expect(map.route("A") == DeviceMap.Route(handle: 5, transport: .network))
    }

    @Test func theCableBesideWifiJoinsTheRouteAndIsPreferred() {
        var map = DeviceMap()
        _ = map.attach(Self.wifi(5, "A"))
        #expect(map.attach(Self.usb(6, "A")) == [.enableWifiSync(handle: 6, udid: "A")])
        #expect(map.route("A") == DeviceMap.Route(handle: 6, transport: .usb))
    }

    @Test func pullingTheCableOfADeviceOnWifiLeavesItPresentOverWifi() {
        var map = DeviceMap()
        _ = map.attach(Self.usb(6, "A"))
        _ = map.attach(Self.wifi(7, "A"))
        #expect(map.detach(handle: 6) == [])
        #expect(map.route("A") == DeviceMap.Route(handle: 7, transport: .network))
        #expect(!map.holds(DeviceMap.Route(handle: 6, transport: .usb), udid: "A"))
        #expect(map.detach(handle: 7) == [.disconnected(udid: "A")])
        #expect(map.route("A") == nil)
    }

    @Test func detachForAnUnseenHandleIsIgnored() {
        var map = DeviceMap()
        #expect(map.detach(handle: 99) == [])
    }

    @Test func anUnknownConnectionTypeIsNeitherReadNorDisconnected() {
        var map = DeviceMap()
        #expect(map.attach(AttachedDevice(handle: 3, connection: .other("Bluetooth"))) == [])
        #expect(map.detach(handle: 3) == [])
    }

    @Test func aStaleDetachDoesNotDisconnectADeviceOnItsNewHandle() {
        // Unplug and replug between Listen and ListDevices: the snapshot holds handle 5, then the queued
        // Attached(4) and Detached(4) are applied after it.
        var map = DeviceMap()
        _ = map.attach(Self.usb(5, "B"))
        _ = map.attach(Self.usb(4, "B"))
        #expect(map.detach(handle: 4) == [])
        #expect(map.holds(DeviceMap.Route(handle: 5, transport: .usb), udid: "B"))
        #expect(map.detach(handle: 5) == [.disconnected(udid: "B")])
    }

    @Test func theNewestHandleOfATransportIsTheRoute() {
        var map = DeviceMap()
        _ = map.attach(Self.usb(4, "B"))
        _ = map.attach(Self.usb(9, "B"))
        #expect(map.route("B") == DeviceMap.Route(handle: 9, transport: .usb))
    }

    @Test func pairedRereadsTheDeviceAndSwitchesOnWifiSyncOverTheCable() {
        var map = DeviceMap()
        _ = map.attach(Self.usb(6, "B"))
        _ = map.attach(Self.wifi(8, "B"))
        #expect(map.paired(handle: 6) == [.pace(udid: "B"), .enableWifiSync(handle: 6, udid: "B")])
        #expect(map.paired(handle: 8) == [.pace(udid: "B")])
        #expect(map.paired(handle: 99) == [])
    }

    @Test func aReplugGetsANewHandleAndReadsAgain() {
        var map = DeviceMap()
        _ = map.attach(Self.usb(6, "B"))
        _ = map.detach(handle: 6)
        #expect(map.attach(Self.usb(7, "B")) == [.pace(udid: "B"), .enableWifiSync(handle: 7, udid: "B")])
    }
}
