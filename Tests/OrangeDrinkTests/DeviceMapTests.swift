import Testing
@testable import OrangeDrink

// [LAW:one-source-of-truth] The map's Step is the monitor's whole decision for each usbmuxd message.
@Suite struct DeviceMapDecisions {
    @Test func snapshotThenListenCountsAnAttachOnce() {
        var map = DeviceMap()
        let device = AttachedDevice(handle: 4, connection: .usb(udid: "A"))
        #expect(map.attach(device) == .read(handle: 4, udid: "A"))
        #expect(map.attach(device) == .nothing)
    }

    @Test func wifiEntriesAreNotReadAndDetachingThemIsNotTheCable() {
        var map = DeviceMap()
        #expect(map.attach(AttachedDevice(handle: 5, connection: .network)) == .nothing)
        #expect(map.detach(handle: 5) == .nothing)
    }

    @Test func cableDetachDisconnectsAndAReadFinishingAfterItIsStale() {
        var map = DeviceMap()
        _ = map.attach(AttachedDevice(handle: 6, connection: .usb(udid: "B")))
        #expect(map.holds(handle: 6, udid: "B"))
        #expect(map.detach(handle: 6) == .disconnected(udid: "B"))
        #expect(!map.holds(handle: 6, udid: "B"))
    }

    @Test func detachForAnUnseenHandleIsIgnored() {
        var map = DeviceMap()
        #expect(map.detach(handle: 99) == .nothing)
    }

    @Test func aStaleDetachDoesNotDisconnectADeviceOnItsNewHandle() {
        // Unplug and replug between Listen and ListDevices: the snapshot holds handle 5, then the queued
        // Attached(4) and Detached(4) are applied after it.
        var map = DeviceMap()
        _ = map.attach(AttachedDevice(handle: 5, connection: .usb(udid: "B")))
        _ = map.attach(AttachedDevice(handle: 4, connection: .usb(udid: "B")))
        #expect(map.detach(handle: 4) == .nothing)
        #expect(map.holds(handle: 5, udid: "B"))
        #expect(map.detach(handle: 5) == .disconnected(udid: "B"))
    }

    @Test func aReplugGetsANewHandleAndReadsAgain() {
        var map = DeviceMap()
        _ = map.attach(AttachedDevice(handle: 6, connection: .usb(udid: "B")))
        _ = map.detach(handle: 6)
        #expect(map.attach(AttachedDevice(handle: 7, connection: .usb(udid: "B"))) == .read(handle: 7, udid: "B"))
    }
}
