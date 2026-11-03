import Foundation
import Observation
import Testing
@testable import OrangeDrink

// [LAW:verifiable-goals] The list fed by more than one source, each a stand-in stream: no Bluetooth and no usbmuxd in the room.
private enum Fleet {
    static let mouse = DeviceListTests.mouse
    static let pods = DeviceListTests.pods
    static let phone = Device(id: DeviceID(source: .iPhone, key: "00008110-A"), name: "Brandon's iPhone", kind: .phone,
                              levels: .single(BatteryLevel(percent: 62, approximate: false)))
    static let tablet = Device(id: DeviceID(source: .iPhone, key: "00008110-B"), name: "Brandon's iPad", kind: .tablet,
                               levels: .single(BatteryLevel(percent: 12, approximate: false)))
}

struct DeviceSourcesListTests {
    private func both() -> DeviceList {
        var list = DeviceList()
        list.apply(.swept([Fleet.mouse, Fleet.pods]), from: .bluetooth)
        list.apply(.swept([Fleet.phone, Fleet.tablet]), from: .iPhone)
        return list
    }

    @Test func aSourceThatHasNotSpokenIsWaitingNotRead() {
        var list = DeviceList()
        #expect(list.unread(of: .iPhone) == .waiting)
        list.apply(.swept([Fleet.mouse]), from: .bluetooth)
        #expect(list.unread(of: .bluetooth) == nil)
        #expect(list.unread(of: .iPhone) == .waiting)
    }

    @Test func oneSourcesSweepLeavesTheOthersDevices() {
        var list = both()
        list.apply(.swept([Fleet.mouse]), from: .bluetooth)
        #expect(Set(list.devices.map(\.id)) == [Fleet.mouse.id, Fleet.phone.id, Fleet.tablet.id])
        list.apply(.swept([]), from: .iPhone)
        #expect(list.devices == [Fleet.mouse])
    }

    @Test func oneSourcesEndOrPermissionEmptiesOnlyItsOwnDevices() {
        var ended = both()
        ended.end(.bluetooth)
        #expect(Set(ended.devices.map(\.id)) == [Fleet.phone.id, Fleet.tablet.id])
        #expect(ended.unread(of: .bluetooth) == .ended)
        #expect(ended.unread(of: .iPhone) == nil)

        var denied = both()
        denied.apply(.permission(.denied), from: .bluetooth)
        #expect(Set(denied.devices.map(\.id)) == [Fleet.phone.id, Fleet.tablet.id])
        #expect(denied.unread(of: .bluetooth) == .denied)
    }

    @Test func aDeviceIsHeldOnceWhicheverSourceReportsIt() {
        var list = DeviceList()
        list.apply(.reported(Fleet.phone), from: .iPhone)
        list.apply(.reported(Fleet.phone), from: .bluetooth)
        #expect(list.devices == [Fleet.phone])
        list.end(.bluetooth)
        // It is the iPhone source's by identity, so only the iPhone source's end clears it.
        #expect(list.devices == [Fleet.phone])
        list.end(.iPhone)
        #expect(list.devices.isEmpty)
    }

    // The list-wide reason: nil once any source has swept, else the first source in `DeviceSource.allCases` order that is not
    // merely waiting, else waiting.
    static let reasons: [(bluetooth: UnreadDevices?, iPhone: UnreadDevices?, expected: UnreadDevices?)] = [
        (nil, nil, nil),
        (nil, .ended, nil),
        (.denied, nil, nil),
        (.waiting, .denied, .denied),
        (.waiting, .ended, .ended),
        (.denied, .ended, .denied),
        (.ended, .waiting, .ended),
        (.waiting, .waiting, .waiting),
    ]

    @Test(arguments: reasons)
    func theListWideReasonIsNilOnceAnySourceHasSweptElseTheFirstSettledOne(bluetooth: UnreadDevices?, iPhone: UnreadDevices?, expected: UnreadDevices?) {
        var list = DeviceList()
        for (source, state) in [(DeviceSource.bluetooth, bluetooth), (.iPhone, iPhone)] {
            switch state {
            case nil: list.apply(.swept([]), from: source)
            case .denied?: list.apply(.permission(.denied), from: source)
            case .ended?: list.end(source)
            case .unanswered?: list.apply(.permission(.notDetermined), from: source)
            case .waiting?: break
            }
        }
        #expect(list.unread == expected)
    }
}

@MainActor struct DeviceSourcesModelTests {
    private struct StandIn: Error { let reason: String }

    private func model(_ bluetooth: AsyncThrowingStream<DeviceEvent, any Error>, _ iPhone: AsyncThrowingStream<DeviceEvent, any Error>) -> DevicesModel {
        DevicesModel(sources: [.bluetooth: bluetooth, .iPhone: iPhone])
    }

    /// The list once `accepted` holds for it. [LAW:no-ambient-temporal-coupling] Awaited through Observation, never polled.
    private func list(of model: DevicesModel, once accepted: (DeviceList) -> Bool) async -> DeviceList {
        let (changes, change) = AsyncStream.makeStream(of: Void.self)
        var next = changes.makeAsyncIterator()
        while !accepted(model.list) {
            withObservationTracking { _ = model.list } onChange: { change.yield() }
            guard await next.next() != nil else { break }
        }
        return model.list
    }

    @Test func devicesOfTwoSourcesAreOneRankedListOnEverySurfaceThatReadsIt() async throws {
        let (bluetooth, sendBluetooth) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let (iPhone, sendIPhone) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let model = model(bluetooth, iPhone)
        sendBluetooth.yield(.swept([Fleet.mouse, Fleet.pods]))
        sendIPhone.yield(.swept([Fleet.phone, Fleet.tablet]))
        let merged = await list(of: model) { $0.devices.count == 4 }

        // Lowest level first, whichever source it came from.
        let ranked = [Fleet.tablet.id, Fleet.mouse.id, Fleet.pods.id, Fleet.phone.id]
        #expect(DeviceRanking.rows(merged).map(\.id) == ranked)
        #expect(ConnectedDevices(merged, settings: DeviceSettings()).rows.map(\.id) == ranked)
        #expect(DetectedDevices(merged, settings: DeviceSettings()).entries.map(\.id) == ranked)
        #expect(merged.unread == nil)

        // A sweep of one source replaces its devices and leaves the other's.
        sendBluetooth.yield(.swept([Fleet.mouse]))
        let swept = await list(of: model) { $0.devices.count == 3 }
        #expect(DeviceRanking.rows(swept).map(\.id) == [Fleet.tablet.id, Fleet.mouse.id, Fleet.phone.id])
    }

    @Test func aSourceFailingLeavesTheOthersDevicesListedAndLogsWhichEnded() async throws {
        let log = try BatteryLog(category: "devices")
        let (bluetooth, sendBluetooth) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let (iPhone, sendIPhone) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let model = model(bluetooth, iPhone)
        sendIPhone.yield(.swept([Fleet.phone]))
        sendBluetooth.yield(.swept([Fleet.mouse]))
        _ = await list(of: model) { $0.devices.count == 2 }

        let failure = StandIn(reason: "the Bluetooth stand-in failed")
        sendBluetooth.finish(throwing: failure)
        let after = await list(of: model) { $0.unread(of: .bluetooth) == .ended }
        #expect(after.devices == [Fleet.phone])
        #expect(after.unread == nil)
        #expect(after.unread(of: .iPhone) == nil)
        #expect(try await log.logged("device source ended: bluetooth: \(String(describing: failure))"))

        // The surviving source is still followed.
        sendIPhone.yield(.reported(Fleet.tablet))
        #expect(await list(of: model) { $0.devices.count == 2 }.devices.map(\.id).contains(Fleet.tablet.id))
    }

    @Test func theOtherSourceFailingLikewiseLeavesBluetoothListed() async throws {
        let log = try BatteryLog(category: "devices")
        let (bluetooth, sendBluetooth) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let (iPhone, sendIPhone) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let model = model(bluetooth, iPhone)
        sendBluetooth.yield(.swept([Fleet.mouse]))
        sendIPhone.yield(.swept([Fleet.phone]))
        _ = await list(of: model) { $0.devices.count == 2 }

        let failure = StandIn(reason: "the iPhone stand-in failed")
        sendIPhone.finish(throwing: failure)
        let after = await list(of: model) { $0.unread(of: .iPhone) == .ended }
        #expect(after.devices == [Fleet.mouse])
        #expect(after.unread == nil)
        #expect(try await log.logged("device source ended: iphone: \(String(describing: failure))"))
    }

    @Test func everySourceEndedIsTheEndedListNotAFrozenOne() async {
        let (bluetooth, sendBluetooth) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let (iPhone, sendIPhone) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let model = model(bluetooth, iPhone)
        sendBluetooth.yield(.swept([Fleet.mouse]))
        sendIPhone.yield(.swept([Fleet.phone]))
        _ = await list(of: model) { $0.devices.count == 2 }
        sendBluetooth.finish(throwing: StandIn(reason: "both ended, the first"))
        sendIPhone.finish(throwing: StandIn(reason: "both ended, the second"))
        let ended = await list(of: model) { $0.unread == .ended }
        #expect(ended.devices.isEmpty)
    }

    @Test func aStreamReportingAnotherSourcesDeviceIsLoggedNamingBothSources() async throws {
        let log = try BatteryLog(category: "devices")
        let (bluetooth, sendBluetooth) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let (iPhone, _) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let model = model(bluetooth, iPhone)
        sendBluetooth.yield(.reported(Fleet.phone))
        _ = await list(of: model) { !$0.devices.isEmpty }
        #expect(try await log.logged("device source bluetooth reported a device of iphone"))
    }
}
