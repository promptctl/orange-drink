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
        #expect(list.unread(of: .iPhone) == .iPhone(.waiting))
        list.apply(.swept([Fleet.mouse]), from: .bluetooth)
        #expect(list.unread(of: .bluetooth) == nil)
        #expect(list.unread(of: .iPhone) == .iPhone(.waiting))
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
        #expect(ended.unread(of: .bluetooth) == .bluetooth(.ended))
        #expect(ended.unread(of: .iPhone) == nil)

        var denied = both()
        denied.apply(.permission(.denied), from: .bluetooth)
        #expect(Set(denied.devices.map(\.id)) == [Fleet.phone.id, Fleet.tablet.id])
        #expect(denied.unread(of: .bluetooth) == .bluetooth(.denied))
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

    // What a list says is missing: each source that has not swept, with its own reason, in `DeviceSource.allCases` order, and
    // nothing for a source that has. Only Bluetooth has a permission, so only it is ever denied.
    static let reasons: [(bluetooth: BluetoothNoList?, iPhone: IPhoneNoList?)] = [
        (nil, nil),
        (nil, .ended),
        (.denied, nil),
        (.waiting, .ended),
        (.denied, .ended),
        (.ended, .waiting),
        (.waiting, .waiting),
        (nil, .waiting),
        (.unanswered, nil),
    ]

    @Test(arguments: reasons)
    func eachSourceNotYetSweptIsListedWithItsOwnReason(bluetooth: BluetoothNoList?, iPhone: IPhoneNoList?) {
        var list = DeviceList(sources: DeviceSource.allCases)
        switch bluetooth {
        case nil: list.apply(.swept([]), from: .bluetooth)
        case .denied?: list.apply(.permission(.denied), from: .bluetooth)
        case .ended?: list.end(.bluetooth)
        case .unanswered?: list.apply(.permission(.notDetermined), from: .bluetooth)
        case .waiting?: break
        }
        switch iPhone {
        case nil: list.apply(.swept([]), from: .iPhone)
        case .ended?: list.end(.iPhone)
        case .waiting?: break
        }
        #expect(list.unreadSources == [bluetooth.map(UnreadSource.bluetooth), iPhone.map(UnreadSource.iPhone)].compactMap(\.self))
    }

    /// A device a source reported ahead of its first sweep is listed with the rest, as the panel has always listed it, and its
    /// source stays unread until it sweeps: a device beside a missing list is shown beside the word that it is missing.
    @Test func aDeviceAheadOfItsSourcesSweepIsListedAndItsSourceStaysUnread() {
        var list = DeviceList(sources: DeviceSource.allCases)
        list.apply(.permission(.denied), from: .bluetooth)
        list.apply(.reported(Fleet.mouse), from: .bluetooth)
        #expect(list.devices.map(\.id) == [Fleet.mouse.id])
        #expect(list.unreadSources == [.bluetooth(.denied), .iPhone(.waiting)])

        list.apply(.swept([Fleet.phone]), from: .iPhone)
        #expect(list.devices.count == 2)
        #expect(list.unreadSources == [.bluetooth(.denied)])
    }

    @Test func aSourceTheListWasNotBuiltForIsNotWaitingForEver() {
        var list = DeviceList(sources: [.bluetooth])
        #expect(list.unreadSources == [.bluetooth(.waiting)])
        #expect(list.unread(of: .iPhone) == nil)
        list.apply(.swept([]), from: .bluetooth)
        #expect(list.unreadSources.isEmpty)
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
        #expect(merged.unreadSources.isEmpty)

        // A sweep of one source replaces its devices and leaves the other's.
        sendBluetooth.yield(.swept([Fleet.mouse]))
        let swept = await list(of: model) { $0.devices.count == 3 }
        #expect(DeviceRanking.rows(swept).map(\.id) == [Fleet.tablet.id, Fleet.mouse.id, Fleet.phone.id])
    }

    @Test func aSourceFailingLeavesTheOthersDevicesListedAndLogsWhichEnded() async throws {
        let log = try await TestLog()
        let (bluetooth, sendBluetooth) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let (iPhone, sendIPhone) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let model = model(bluetooth, iPhone, log: log.logger)
        sendIPhone.yield(.swept([Fleet.phone]))
        sendBluetooth.yield(.swept([Fleet.mouse]))
        _ = await list(of: model) { $0.devices.count == 2 }

        let failure = StandIn(reason: "the Bluetooth stand-in failed")
        sendBluetooth.finish(throwing: failure)
        let after = await list(of: model) { $0.unread(of: .bluetooth) == .bluetooth(.ended) }
        #expect(after.devices == [Fleet.phone.device])
        #expect(after.unreadSources == [.bluetooth(.ended)])
        #expect(after.unread(of: .iPhone) == nil)
        #expect(try await log.logged("device source ended: bluetooth: \(String(describing: failure))"))

        // The surviving source is still followed.
        sendIPhone.yield(.reported(Fleet.tablet))
        #expect(await list(of: model) { $0.devices.count == 2 }.devices.map(\.id).contains(Fleet.tablet.id))
    }

    @Test func theOtherSourceFailingLikewiseLeavesBluetoothListed() async throws {
        let log = try await TestLog()
        let (bluetooth, sendBluetooth) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let (iPhone, sendIPhone) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let model = model(bluetooth, iPhone, log: log.logger)
        sendBluetooth.yield(.swept([Fleet.mouse]))
        sendIPhone.yield(.swept([Fleet.phone]))
        _ = await list(of: model) { $0.devices.count == 2 }

        let failure = StandIn(reason: "the iPhone stand-in failed")
        sendIPhone.finish(throwing: failure)
        let after = await list(of: model) { $0.unread(of: .iPhone) == .iPhone(.ended) }
        #expect(after.devices == [Fleet.mouse.device])
        #expect(after.unreadSources == [.iPhone(.ended)])
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
        let ended = await list(of: model) { $0.unreadSources == [.bluetooth(.ended), .iPhone(.ended)] }
        #expect(ended.devices.isEmpty)
    }

    @Test func aStreamReportingAnotherSourcesDeviceIsIgnoredAndLoggedNamingBothSources() async throws {
        let log = try await TestLog()
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

    // A permission is Bluetooth's. One on another source's stream changes no reading, and is said in the log.
    @Test func aPermissionOnAnotherSourcesStreamIsIgnoredAndLogged() async throws {
        let log = try await TestLog()
        let (bluetooth, _) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let (iPhone, sendIPhone) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let model = model(bluetooth, iPhone, log: log.logger)
        sendIPhone.yield(.permission(.denied))
        sendIPhone.yield(.swept([Fleet.phone]))
        let list = await list(of: model) { !$0.devices.isEmpty }
        #expect(list.unreadSources == [.bluetooth(.waiting)])
        #expect(list.devices == [Fleet.phone.device])
        #expect(try await log.logged("device source iphone reported a Bluetooth permission; ignored"))
    }
}
