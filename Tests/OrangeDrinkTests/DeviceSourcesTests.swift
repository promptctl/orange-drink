import Foundation
import Observation
import os
import Testing
@testable import OrangeDrink

// [LAW:verifiable-goals] The list fed by more than one source, each a stand-in stream: no Bluetooth and no usbmuxd in the room.
private enum Fleet {
    static let mouse = DeviceListTests.mouse.source
    static let pods = DeviceListTests.pods.source
    static let phone = SourceDevice(id: DeviceID(source: .iPhone, key: "00008110-A"), name: "Brandon's iPhone", kind: .phone,
                              levels: .single(BatteryLevel(percent: 62, approximate: false)))
    static let tablet = SourceDevice(id: DeviceID(source: .iPhone, key: "00008110-B"), name: "Brandon's iPad", kind: .tablet,
                               levels: .single(BatteryLevel(percent: 12, approximate: false)))
}

// [LAW:no-silent-failure] `list(of:once:)` awaits a list that a regression may never produce; the limit makes that a failure, not a stalled run.
@Suite(.timeLimit(.minutes(1)))
struct DeviceSourcesListTests {
    private func both() -> DeviceList {
        var list = DeviceList(sources: DeviceSource.allCases)
        list.apply(.swept([Fleet.mouse, Fleet.pods]), from: .bluetooth)
        list.apply(.swept([Fleet.phone, Fleet.tablet]), from: .iPhone)
        return list
    }

    @Test func aSourceThatHasNotSpokenIsWaitingNotRead() {
        var list = DeviceList(sources: DeviceSource.allCases)
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
        #expect(list.devices == [Fleet.mouse.device])
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

    @Test func aSourceCannotAddRemoveOrKeepAnotherSourcesDevice() {
        var list = both()
        list.apply(.reported(Fleet.phone), from: .bluetooth)
        list.apply(.gone(Fleet.phone.id), from: .bluetooth)
        #expect(Set(list.devices.map(\.id)) == Set(both().devices.map(\.id)))

        list.apply(.swept([Fleet.mouse, Fleet.tablet]), from: .bluetooth)
        // Its own device is read; the other source's is ignored, and the other source's reading stands.
        #expect(Set(list.devices.map(\.id)) == [Fleet.mouse.id, Fleet.phone.id, Fleet.tablet.id])
        #expect(list.unread(of: .bluetooth) == nil)
    }

    // The list-wide reason, for a list with no device to show: nil when every source has swept, else the first source in
    // `DeviceSource.allCases` order that is not merely waiting, else waiting.
    static let reasons: [(bluetooth: UnreadDevices?, iPhone: UnreadDevices?, expected: UnreadDevices?)] = [
        (nil, nil, nil),
        (nil, .ended, .ended),
        (.denied, nil, .denied),
        (.waiting, .denied, .denied),
        (.waiting, .ended, .ended),
        (.denied, .ended, .denied),
        (.ended, .waiting, .ended),
        (.waiting, .waiting, .waiting),
        (nil, .waiting, .waiting),
    ]

    @Test(arguments: reasons)
    func anEmptyListsReasonIsTheFirstSettledOneOfTheSourcesNotYetSwept(bluetooth: UnreadDevices?, iPhone: UnreadDevices?, expected: UnreadDevices?) {
        var list = DeviceList(sources: DeviceSource.allCases)
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

    /// A device of a source that has swept is something to show, so the list is no longer a reason; one reported ahead of its
    /// source's first sweep is not the list yet. The reason a listed device hides is orange-device-sources-rec.k69's.
    @Test func aListedDeviceOfASweptSourceIsNotAnEmptyListButOneAheadOfItsSweepIs() {
        var list = DeviceList(sources: DeviceSource.allCases)
        list.apply(.permission(.denied), from: .bluetooth)
        list.apply(.reported(Fleet.mouse), from: .bluetooth)
        #expect(list.unread == .denied)

        list.apply(.swept([Fleet.phone]), from: .iPhone)
        #expect(list.unread == nil)
        list.apply(.swept([]), from: .iPhone)
        #expect(list.unread == .denied)
    }

    @Test func aSourceTheListWasNotBuiltForIsNotWaitingForEver() {
        var list = DeviceList(sources: [.bluetooth])
        #expect(list.unread == .waiting)
        #expect(list.unread(of: .iPhone) == nil)
        list.apply(.swept([]), from: .bluetooth)
        #expect(list.unread == nil)
    }
}

@MainActor struct DeviceSourcesModelTests {
    private struct StandIn: Error { let reason: String }

    private func model(_ bluetooth: AsyncThrowingStream<DeviceEvent, any Error>, _ iPhone: AsyncThrowingStream<DeviceEvent, any Error>,
                       log: Logger = BluetoothDevices.log) -> DevicesModel {
        DevicesModel(sources: [.bluetooth: bluetooth, .iPhone: iPhone], log: log)
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
        let log = try await BatteryLog()
        let (bluetooth, sendBluetooth) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let (iPhone, sendIPhone) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let model = model(bluetooth, iPhone, log: log.logger)
        sendIPhone.yield(.swept([Fleet.phone]))
        sendBluetooth.yield(.swept([Fleet.mouse]))
        _ = await list(of: model) { $0.devices.count == 2 }

        let failure = StandIn(reason: "the Bluetooth stand-in failed")
        sendBluetooth.finish(throwing: failure)
        let after = await list(of: model) { $0.unread(of: .bluetooth) == .ended }
        #expect(after.devices == [Fleet.phone.device])
        #expect(after.unread == nil)
        #expect(after.unread(of: .iPhone) == nil)
        #expect(try await log.logged("device source ended: bluetooth: \(String(describing: failure))"))

        // The surviving source is still followed.
        sendIPhone.yield(.reported(Fleet.tablet))
        #expect(await list(of: model) { $0.devices.count == 2 }.devices.map(\.id).contains(Fleet.tablet.id))
    }

    @Test func theOtherSourceFailingLikewiseLeavesBluetoothListed() async throws {
        let log = try await BatteryLog()
        let (bluetooth, sendBluetooth) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let (iPhone, sendIPhone) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let model = model(bluetooth, iPhone, log: log.logger)
        sendBluetooth.yield(.swept([Fleet.mouse]))
        sendIPhone.yield(.swept([Fleet.phone]))
        _ = await list(of: model) { $0.devices.count == 2 }

        let failure = StandIn(reason: "the iPhone stand-in failed")
        sendIPhone.finish(throwing: failure)
        let after = await list(of: model) { $0.unread(of: .iPhone) == .ended }
        #expect(after.devices == [Fleet.mouse.device])
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

    @Test func aStreamReportingAnotherSourcesDeviceIsIgnoredAndLoggedNamingBothSources() async throws {
        let log = try await BatteryLog()
        let (bluetooth, sendBluetooth) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let (iPhone, _) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let model = model(bluetooth, iPhone, log: log.logger)
        sendBluetooth.yield(.reported(Fleet.phone))
        // A stream is followed in order, so the sweep is applied only after the foreign event was handled. Bluetooth's sweep
        // would not remove an iPhone device, so one stored would still be listed.
        sendBluetooth.yield(.swept([Fleet.mouse]))
        let list = await list(of: model) { !$0.devices.isEmpty }
        #expect(list.devices == [Fleet.mouse.device])
        #expect(try await log.logged("device source bluetooth reported a device of iphone; ignored"))
    }
}
