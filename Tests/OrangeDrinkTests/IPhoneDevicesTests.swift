import Foundation
import Observation
import Testing
@testable import OrangeDrink

// [LAW:verifiable-goals] The iPhone reader as a device source, at the lowest layer that owns each fact: the mapping over events
// as values; the device list and every surface over stand-in streams, with no usbmuxd and no Bluetooth in the room.
private enum Phone {
    static let udid = "00008110-A"
    static let id = DeviceID(source: .iPhone, key: udid)
    /// The address as lockdown writes it; the claim holds it in IOBluetooth's form.
    static let address = BluetoothAddress("6c:3a:ff:d9:74:42")!
    static let identity = IPhoneIdentity(name: "Brandon's iPhone", productType: "iPhone16,2", bluetooth: address)
    static let identified = IPhoneEvent.identified(udid: udid, identity)

    static func reading(_ level: Int) -> IPhoneBatteryReading {
        IPhoneBatteryReading(level: level, cycleCount: 312,
                             designCapacity: EntryCapacity(mAh: 3_274, place: .topLevel),
                             nominalChargeCapacity: EntryCapacity(mAh: 2_980, place: .topLevel),
                             storedMaximumCapacity: nil)
    }

    /// The phone as the source lists it: named and kinded by its identity, claiming its Bluetooth address.
    static func device(_ levels: DeviceLevels) -> SourceDevice {
        SourceDevice(id: id, name: "Brandon's iPhone", kind: .phone, levels: levels, alsoBluetooth: address)
    }

    static func percent(_ percent: Int) -> DeviceLevels { .single(BatteryLevel(percent: percent, approximate: false)) }
}

struct IPhoneDevicesMappingTests {
    private func events(_ input: [IPhoneEvent]) -> [DeviceEvent?] {
        var devices = IPhoneDevices()
        return input.map { devices.apply($0) }
    }

    @Test func anAttachedIPhoneReadingSixtyTwoPercentIsAConnectedIPhoneDeviceAtSixtyTwoAndADetachRemovesIt() {
        #expect(events([
            .reachable(udid: Phone.udid, over: .usb),
            Phone.identified,
            .reading(udid: Phone.udid, over: .usb, Phone.reading(62)),
            .unreachable(udid: Phone.udid),
        ]) == [
            nil,
            .reported(Phone.device(.unread)),
            .reported(Phone.device(Phone.percent(62))),
            .gone(Phone.id),
        ])
    }

    /// [LAW:types-are-the-program] A device is listed only once its identity has been read, so no report names it by its UDID:
    /// nothing the reader says about a device before that lists it.
    @Test func aDeviceWhoseIdentityHasNotBeenReadIsNotListed() {
        #expect(events([
            .reachable(udid: Phone.udid, over: .usb),
            .readFailed(udid: Phone.udid, over: .usb, .refused("PasswordProtected")),
            .listed,
        ]) == [nil, nil, .swept([])])
    }

    @Test func aFailedReadLeavesTheDeviceListedWithAnUnknownLevel() {
        let failed = IPhoneEvent.readFailed(udid: Phone.udid, over: .usb, .refused("PasswordProtected"))
        #expect(events([.reachable(udid: Phone.udid, over: .usb), Phone.identified, .reading(udid: Phone.udid, over: .usb, Phone.reading(62)), failed]).last
                == .reported(Phone.device(.unread)))
    }

    @Test func movingFromTheCableToWifiKeepsTheLevelAndThenTheDeviceIsADropNotADeparture() {
        #expect(events([
            .reachable(udid: Phone.udid, over: .usb),
            Phone.identified,
            .reading(udid: Phone.udid, over: .usb, Phone.reading(62)),
            .reachable(udid: Phone.udid, over: .network),
            .unreachable(udid: Phone.udid),
            .reachable(udid: Phone.udid, over: .network),
            .reading(udid: Phone.udid, over: .network, Phone.reading(60)),
        ]).dropFirst(3) == [
            .reported(Phone.device(Phone.percent(62))),
            .reported(Phone.device(.unread)),
            .reported(Phone.device(.unread)),
            .reported(Phone.device(Phone.percent(60))),
        ])
    }

    /// A read's transport is where it started, so a late one over the cable, delivered after the route moved to Wi-Fi, must not
    /// make the Wi-Fi drop that follows look like the cable leaving.
    @Test func aReadsOwnTransportDoesNotMoveTheDevicesRoute() {
        #expect(events([
            .reachable(udid: Phone.udid, over: .usb),
            Phone.identified,
            .reachable(udid: Phone.udid, over: .network),
            .reading(udid: Phone.udid, over: .usb, Phone.reading(62)),
            .unreachable(udid: Phone.udid),
        ]).last == .reported(Phone.device(.unread)))
    }

    @Test func aReadOrDropForADeviceThatIsNotReachableSaysNothing() {
        #expect(events([
            Phone.identified,
            .reading(udid: Phone.udid, over: .usb, Phone.reading(62)),
            .readFailed(udid: Phone.udid, over: .usb, .refused("PasswordProtected")),
            .unreachable(udid: Phone.udid),
            .wifiSyncOn(udid: Phone.udid),
        ]).allSatisfy { $0 == nil })

        // A read or an identity that lands after the cable left must not bring the device back.
        #expect(events([
            .reachable(udid: Phone.udid, over: .usb), Phone.identified, .unreachable(udid: Phone.udid),
            .reading(udid: Phone.udid, over: .usb, Phone.reading(62)), Phone.identified,
        ]).suffix(2) == [nil, nil])
    }

    /// The identity belongs to the device and not to its route: the monitor's pacer rests through an unplug and a replug and reads
    /// the device again only when it wakes, so the replug lists the phone at once, under the identity it had.
    @Test func aCableUnpluggedAndPluggedBackBeforeTheNextReadListsThePhoneAgainUnderItsIdentity() {
        #expect(events([
            .reachable(udid: Phone.udid, over: .usb),
            Phone.identified,
            .reading(udid: Phone.udid, over: .usb, Phone.reading(62)),
            .unreachable(udid: Phone.udid),
            .reachable(udid: Phone.udid, over: .usb),
        ]).suffix(2) == [.gone(Phone.id), .reported(Phone.device(.unread))])
    }

    @Test func theListingRestatesWhatIsAttachedEvenWhenNothingIs() {
        #expect(events([.listed]) == [.swept([])])
        #expect(events([.reachable(udid: Phone.udid, over: .usb), Phone.identified, .listed]).last == .swept([Phone.device(.unread)]))
    }

    @Test func aDevicesNameAndKindAreItsIdentitys() throws {
        func listed(_ identity: IPhoneIdentity) -> SourceDevice? {
            var devices = IPhoneDevices()
            _ = devices.apply(.reachable(udid: Phone.udid, over: .usb))
            guard case .reported(let device)? = devices.apply(.identified(udid: Phone.udid, identity)) else { return nil }
            return device
        }
        let tablet = try #require(listed(IPhoneIdentity(name: "Studio iPad", productType: "iPad13,1", bluetooth: Phone.address)))
        #expect((tablet.name, tablet.kind, tablet.alsoBluetooth) == ("Studio iPad", .tablet, Phone.address))
        let goggles = try #require(listed(IPhoneIdentity(name: "SpaceGoggles2", productType: "RealityDevice14,1", bluetooth: Phone.address)))
        #expect((goggles.name, goggles.kind) == ("SpaceGoggles2", .accessory))
        // A blank name is no name: the UDID names the device, as the address names a Bluetooth device (Device.name).
        let unnamed = try #require(listed(IPhoneIdentity(name: " ", productType: "iPhone16,2", bluetooth: Phone.address)))
        #expect(unnamed.name == Phone.udid)
        #expect(Device(id: unnamed.id, name: unnamed.name, kind: unnamed.kind, levels: unnamed.levels).hasName == false)
    }

    /// A name changed on the device shows from the next time the device is identified, and the level is kept.
    @Test func identifyingAListedDeviceAgainRenamesItAndKeepsItsLevel() {
        let renamed = IPhoneIdentity(name: "New name", productType: "iPhone16,2", bluetooth: Phone.address)
        let last = events([
            .reachable(udid: Phone.udid, over: .usb), Phone.identified, .reading(udid: Phone.udid, over: .usb, Phone.reading(62)),
            .identified(udid: Phone.udid, renamed),
        ]).last
        #expect(last == .reported(SourceDevice(id: Phone.id, name: "New name", kind: .phone, levels: Phone.percent(62), alsoBluetooth: Phone.address)))
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct IPhoneDevicesSourceTests {
    private struct StandIn: Error, Equatable {}

    private let bluetooth: AsyncThrowingStream<DeviceEvent, any Error>.Continuation
    private let reader: AsyncStream<IPhoneEvent>.Continuation
    private let model: DevicesModel

    init() {
        let (bluetoothEvents, bluetooth) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let (readerEvents, reader) = AsyncStream.makeStream(of: IPhoneEvent.self)
        self.bluetooth = bluetooth
        self.reader = reader
        model = DevicesModel(sources: [.bluetooth: bluetoothEvents, .iPhone: IPhoneDevices.events(from: readerEvents)])
    }

    /// The list once `accepted` holds for it. [LAW:no-ambient-temporal-coupling] Awaited through Observation, never polled.
    private func list(once accepted: (DeviceList) -> Bool) async -> DeviceList {
        let (changes, change) = AsyncStream.makeStream(of: Void.self)
        var next = changes.makeAsyncIterator()
        while !accepted(model.list) {
            withObservationTracking { _ = model.list } onChange: { change.yield() }
            guard await next.next() != nil else { break }
        }
        return model.list
    }

    /// The phone is presented under the Bluetooth address it claims (`Phone.address`), the identity a pin or a bell of it is stored under.
    @Test func aReadersIPhoneIsInThePanelsRankingBesideBluetoothDevicesAndLeavesWhenItDetaches() async {
        bluetooth.yield(.swept([DeviceListTests.mouse.source, DeviceListTests.pods.source]))
        reader.yield(.reachable(udid: Phone.udid, over: .usb))
        reader.yield(Phone.identified)
        reader.yield(.reading(udid: Phone.udid, over: .usb, Phone.reading(62)))
        reader.yield(.listed)
        let attached = await list { $0.devices.contains { $0.id == Phone.address.identity && $0.levels == Phone.percent(62) } }

        // Lowest level first, whichever source it came from.
        let ranked = [DeviceListTests.mouse.id, DeviceListTests.pods.id, Phone.address.identity]
        #expect(DeviceRanking.rows(attached).map(\.id) == ranked)
        #expect(DeviceRanking.rows(attached).last?.percent.english == "62%")
        #expect(ConnectedDevices(attached, settings: DeviceSettings()).rows.map(\.id) == ranked)
        #expect(DetectedDevices(attached, settings: DeviceSettings()).entries.map(\.id) == ranked)

        reader.yield(.unreachable(udid: Phone.udid))
        let detached = await list { !$0.devices.contains { $0.id == Phone.address.identity } }
        #expect(DeviceRanking.rows(detached).map(\.id) == Array(ranked.dropLast()))
    }

    /// The reader and Bluetooth both list the one phone: the phone's address is its twin's identity, so the panel shows one row, at
    /// the level the reader read, under the identity a pin or a bell of it is stored under.
    @Test func aPhoneTheReaderAndBluetoothBothListIsOneRowUnderItsBluetoothIdentity() async {
        let twin = SourceDevice(id: Phone.address.identity, name: "Brandon’s iPhone", kind: .phone, levels: .unread)
        bluetooth.yield(.swept([twin]))
        reader.yield(.reachable(udid: Phone.udid, over: .usb))
        reader.yield(Phone.identified)
        reader.yield(.reading(udid: Phone.udid, over: .usb, Phone.reading(62)))
        reader.yield(.listed)
        let merged = await list { $0.devices.contains { $0.levels == Phone.percent(62) } }

        #expect(merged.devices.map(\.id) == [Phone.address.identity])
        #expect(DeviceRanking.rows(merged).map(\.id) == [Phone.address.identity])
        #expect(DetectedDevices(merged, settings: DeviceSettings()).entries.map(\.id) == [Phone.address.identity])
    }

    @Test func theReaderFailingEndsItsSourceAndLeavesBluetoothListed() async {
        bluetooth.yield(.swept([DeviceListTests.mouse.source]))
        reader.yield(.reachable(udid: Phone.udid, over: .usb))
        reader.yield(Phone.identified)
        reader.yield(.listed)
        reader.yield(.failed(.refused("usbmuxd is gone")))
        let ended = await list { $0.unread(of: .iPhone) == .iPhone(.ended) }
        #expect(ended.devices == [DeviceListTests.mouse])
    }

    // Bluetooth denied or ended beside a reader that has listed nothing: the list is not empty because nothing is connected.

    private func settle(bluetoothIs state: (DeviceList) -> Bool) async -> DeviceList {
        reader.yield(.listed)
        return await list(once: state)
    }

    @Test func bluetoothDeniedBesideAWorkingReaderIsShownOnEveryCardAndInTheWidget() async {
        bluetooth.yield(.permission(.denied))
        let list = await settle { $0.unread(of: .bluetooth) == .bluetooth(.denied) && $0.unread(of: .iPhone) == nil }
        expectShown(.denied, by: list)
    }

    @Test func bluetoothEndedBesideAWorkingReaderIsShownOnEveryCardAndInTheWidget() async {
        bluetooth.finish(throwing: StandIn())
        let list = await settle { $0.unread(of: .bluetooth) == .bluetooth(.ended) && $0.unread(of: .iPhone) == nil }
        expectShown(.ended, by: list)
    }

    private func expectShown(_ reason: BluetoothNoList, by list: DeviceList) {
        #expect(list.devices.isEmpty)
        let shown = ListNotes.only(.bluetooth(reason))
        #expect(ConnectedDevices(list, settings: DeviceSettings()).notes == shown)
        #expect(DetectedDevices(list, settings: DeviceSettings()).notes == shown)
        #expect(PinnedDevicesList(list, pinned: PinnedOrder()).notes == shown)
        #expect(WidgetDeviceList(list, pinned: PinnedOrder()) == .unread(reason))
    }

    @Test func aReaderThatHasNotListedYetKeepsTheListWaitingEvenWhenBluetoothHasSwept() async {
        bluetooth.yield(.swept([]))
        let list = await list { $0.unread(of: .bluetooth) == nil }
        #expect(list.unreadSources == [.iPhone(.waiting)])
    }
}
