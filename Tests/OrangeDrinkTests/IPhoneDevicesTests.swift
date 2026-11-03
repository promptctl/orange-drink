import Foundation
import Observation
import Testing
@testable import OrangeDrink

// [LAW:verifiable-goals] The iPhone reader as a device source, at the lowest layer that owns each fact: the mapping over events
// as values; the device list and every surface over stand-in streams, with no usbmuxd and no Bluetooth in the room.
private enum Phone {
    static let udid = "00008110-A"
    static let id = DeviceID(source: .iPhone, key: udid)

    static func reading(_ level: Int) -> IPhoneBatteryReading {
        IPhoneBatteryReading(level: level, cycleCount: 312,
                             designCapacity: EntryCapacity(mAh: 3_274, place: .topLevel),
                             nominalChargeCapacity: EntryCapacity(mAh: 2_980, place: .topLevel),
                             storedMaximumCapacity: nil)
    }

    static func device(_ levels: DeviceLevels) -> Device {
        Device(id: id, name: udid, kind: .phone, levels: levels)
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
            .reading(udid: Phone.udid, over: .usb, Phone.reading(62)),
            .unreachable(udid: Phone.udid),
        ]) == [
            .reported(Phone.device(.unread)),
            .reported(Phone.device(Phone.percent(62))),
            .gone(Phone.id),
        ])
    }

    @Test func aFailedReadLeavesTheDeviceListedWithAnUnknownLevel() {
        let failed = IPhoneEvent.readFailed(udid: Phone.udid, over: .usb, .refused("PasswordProtected"))
        #expect(events([.reachable(udid: Phone.udid, over: .usb), .reading(udid: Phone.udid, over: .usb, Phone.reading(62)), failed]).last
                == .reported(Phone.device(.unread)))
    }

    @Test func movingFromTheCableToWifiKeepsTheLevelAndThenTheDeviceIsADropNotADeparture() {
        #expect(events([
            .reachable(udid: Phone.udid, over: .usb),
            .reading(udid: Phone.udid, over: .usb, Phone.reading(62)),
            .reachable(udid: Phone.udid, over: .network),
            .unreachable(udid: Phone.udid),
            .reachable(udid: Phone.udid, over: .network),
            .reading(udid: Phone.udid, over: .network, Phone.reading(60)),
        ]).dropFirst(2) == [
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
            .reachable(udid: Phone.udid, over: .network),
            .reading(udid: Phone.udid, over: .usb, Phone.reading(62)),
            .unreachable(udid: Phone.udid),
        ]).last == .reported(Phone.device(.unread)))
    }

    @Test func aReadOrDropForADeviceThatIsNotListedSaysNothing() {
        #expect(events([
            .reading(udid: Phone.udid, over: .usb, Phone.reading(62)),
            .readFailed(udid: Phone.udid, over: .usb, .refused("PasswordProtected")),
            .unreachable(udid: Phone.udid),
            .wifiSyncOn(udid: Phone.udid),
        ]).allSatisfy { $0 == nil })

        // A read that lands after the cable left must not bring the device back.
        #expect(events([
            .reachable(udid: Phone.udid, over: .usb), .unreachable(udid: Phone.udid), .reading(udid: Phone.udid, over: .usb, Phone.reading(62)),
        ]).last! == nil)
    }

    @Test func theListingRestatesWhatIsAttachedEvenWhenNothingIs() {
        #expect(events([.listed]) == [.swept([])])
        #expect(events([.reachable(udid: Phone.udid, over: .usb), .listed]).last == .swept([Phone.device(.unread)]))
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

    @Test func aReadersIPhoneIsInThePanelsRankingBesideBluetoothDevicesAndLeavesWhenItDetaches() async {
        bluetooth.yield(.swept([DeviceListTests.mouse, DeviceListTests.pods]))
        reader.yield(.reachable(udid: Phone.udid, over: .usb))
        reader.yield(.reading(udid: Phone.udid, over: .usb, Phone.reading(62)))
        reader.yield(.listed)
        let attached = await list { $0.devices.contains { $0.id == Phone.id && $0.levels == Phone.percent(62) } }

        // Lowest level first, whichever source it came from.
        let ranked = [DeviceListTests.mouse.id, DeviceListTests.pods.id, Phone.id]
        #expect(DeviceRanking.rows(attached).map(\.id) == ranked)
        #expect(DeviceRanking.rows(attached).last?.percent.english == "62%")
        #expect(ConnectedDevices(attached, settings: DeviceSettings()).rows.map(\.id) == ranked)
        #expect(DetectedDevices(attached, settings: DeviceSettings()).entries.map(\.id) == ranked)

        reader.yield(.unreachable(udid: Phone.udid))
        let detached = await list { !$0.devices.contains { $0.id == Phone.id } }
        #expect(DeviceRanking.rows(detached).map(\.id) == Array(ranked.dropLast()))
    }

    @Test func theReaderFailingEndsItsSourceAndLeavesBluetoothListed() async {
        bluetooth.yield(.swept([DeviceListTests.mouse]))
        reader.yield(.reachable(udid: Phone.udid, over: .usb))
        reader.yield(.listed)
        reader.yield(.failed(.refused("usbmuxd is gone")))
        let ended = await list { $0.unread(of: .iPhone) == .ended }
        #expect(ended.devices == [DeviceListTests.mouse])
    }

    // Bluetooth denied or ended beside a reader that has listed nothing: the list is not empty because nothing is connected.

    private func settle(bluetoothIs state: (DeviceList) -> Bool) async -> DeviceList {
        reader.yield(.listed)
        return await list(once: state)
    }

    @Test func bluetoothDeniedBesideAWorkingReaderIsShownOnEveryCardAndInTheWidget() async {
        bluetooth.yield(.permission(.denied))
        let list = await settle { $0.unread(of: .bluetooth) == .denied && $0.unread(of: .iPhone) == nil }
        expectShown(.denied, by: list)
    }

    @Test func bluetoothEndedBesideAWorkingReaderIsShownOnEveryCardAndInTheWidget() async {
        bluetooth.finish(throwing: StandIn())
        let list = await settle { $0.unread(of: .bluetooth) == .ended && $0.unread(of: .iPhone) == nil }
        expectShown(.ended, by: list)
    }

    private func expectShown(_ reason: UnreadDevices, by list: DeviceList) {
        #expect(list.devices.isEmpty)
        #expect(ConnectedDevices(list, settings: DeviceSettings()).emptyNote == reason.explanation)
        #expect(DetectedDevices(list, settings: DeviceSettings()).emptyNote == reason.explanation)
        #expect(PinnedDevicesList(list, pinned: PinnedOrder()).emptyNote == reason.explanation)
        #expect(WidgetDevices(list, pinned: PinnedOrder()) == .unread(reason))
    }

    @Test func aReaderThatHasNotListedYetKeepsTheListWaitingEvenWhenBluetoothHasSwept() async {
        bluetooth.yield(.swept([]))
        let list = await list { $0.unread(of: .bluetooth) == nil }
        #expect(list.unread == .waiting)
    }
}
