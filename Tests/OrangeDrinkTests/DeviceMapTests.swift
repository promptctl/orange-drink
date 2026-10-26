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

    @Test func pluggingInADeviceMakesItReachableOverTheCableAndSwitchesOnItsWifiSync() {
        var map = DeviceMap()
        #expect(map.attach(Self.usb(4, "A")) == [.reachability(udid: "A", over: .usb), .enableWifiSync(handle: 4, udid: "A")])
        #expect(map.route("A") == DeviceMap.Route(handle: 4, transport: .usb))
    }

    @Test func snapshotThenListenCountsAnAttachOnce() {
        var map = DeviceMap()
        _ = map.attach(Self.usb(4, "A"))
        #expect(map.attach(Self.usb(4, "A")) == [])
    }

    @Test func aDeviceOnWifiAloneIsReachableOverWifi() {
        var map = DeviceMap()
        #expect(map.attach(Self.wifi(5, "A")) == [.reachability(udid: "A", over: .network)])
        #expect(map.route("A") == DeviceMap.Route(handle: 5, transport: .network))
    }

    @Test func theCableBesideWifiTakesTheRouteAndSwitchesOnWifiSync() {
        var map = DeviceMap()
        _ = map.attach(Self.wifi(5, "A"))
        #expect(map.attach(Self.usb(6, "A")) == [.reachability(udid: "A", over: .usb), .enableWifiSync(handle: 6, udid: "A")])
        #expect(map.route("A") == DeviceMap.Route(handle: 6, transport: .usb))
    }

    @Test func pullingTheCableOfADeviceOnWifiMovesItToWifiAndItsLastHandleMakesItUnreachable() {
        var map = DeviceMap()
        _ = map.attach(Self.usb(6, "A"))
        #expect(map.attach(Self.wifi(7, "A")) == [])
        #expect(map.detach(handle: 6) == [.reachability(udid: "A", over: .network)])
        #expect(map.route("A") == DeviceMap.Route(handle: 7, transport: .network))
        #expect(map.detach(handle: 7) == [.reachability(udid: "A", over: nil)])
        #expect(map.route("A") == nil)
    }

    @Test func detachForAnUnseenHandleIsIgnored() {
        var map = DeviceMap()
        #expect(map.detach(handle: 99) == [])
    }

    @Test func anUnknownConnectionTypeIsNeverReachable() {
        var map = DeviceMap()
        #expect(map.attach(AttachedDevice(handle: 3, connection: .other("Bluetooth"))) == [])
        #expect(map.detach(handle: 3) == [])
    }

    @Test func aStaleAttachAndDetachLeaveADeviceOnItsNewHandle() {
        // Unplug and replug between Listen and ListDevices: the snapshot holds handle 5, then the queued
        // Attached(4) and Detached(4) are applied after it. Handle 4 is gone, so nothing is read or written over it.
        var map = DeviceMap()
        _ = map.attach(Self.usb(5, "B"))
        #expect(map.attach(Self.usb(4, "B")) == [])
        #expect(map.detach(handle: 4) == [])
        #expect(map.route("B") == DeviceMap.Route(handle: 5, transport: .usb))
        #expect(map.detach(handle: 5) == [.reachability(udid: "B", over: nil)])
    }

    @Test func theNewestHandleOfATransportIsTheRoute() {
        var map = DeviceMap()
        _ = map.attach(Self.usb(4, "B"))
        _ = map.attach(Self.usb(9, "B"))
        #expect(map.route("B") == DeviceMap.Route(handle: 9, transport: .usb))
    }

    @Test func aNewWifiHandleBeforeTheOldOneDetachesChangesNothingButTheRoute() {
        var map = DeviceMap()
        _ = map.attach(Self.wifi(5, "C"))
        #expect(map.attach(Self.wifi(6, "C")) == [])
        #expect(map.detach(handle: 5) == [])
        #expect(map.route("C") == DeviceMap.Route(handle: 6, transport: .network))
    }

    @Test func pairedSwitchesOnWifiSyncOverTheDevicesCable() {
        var map = DeviceMap()
        _ = map.attach(Self.usb(6, "B"))
        _ = map.attach(Self.wifi(8, "B"))
        #expect(map.paired(handle: 6) == [.enableWifiSync(handle: 6, udid: "B")])
        #expect(map.paired(handle: 8) == [.enableWifiSync(handle: 6, udid: "B")])
        #expect(map.paired(handle: 99) == [])
    }

    @Test func pairedOverWifiAloneDecidesNothing() {
        var map = DeviceMap()
        _ = map.attach(Self.wifi(8, "B"))
        #expect(map.paired(handle: 8) == [])
    }

    @Test func aReplugBeforeTheOldHandleDetachesSwitchesOnWifiSyncOverTheNewCable() {
        var map = DeviceMap()
        _ = map.attach(Self.usb(6, "B"))
        #expect(map.attach(Self.usb(7, "B")) == [.enableWifiSync(handle: 7, udid: "B")])
        #expect(map.detach(handle: 6) == [])
    }

    @Test func aReplugAfterTheOldHandleDetachedMakesItReachableAgain() {
        var map = DeviceMap()
        _ = map.attach(Self.usb(6, "B"))
        _ = map.detach(handle: 6)
        #expect(map.attach(Self.usb(7, "B")) == [.reachability(udid: "B", over: .usb), .enableWifiSync(handle: 7, udid: "B")])
    }
}
