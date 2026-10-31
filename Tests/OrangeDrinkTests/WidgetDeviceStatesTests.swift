import AppKit
import Foundation
import SwiftUI
import Testing
import ViewInspector
import WidgetKit
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what each widget draws for each state of the device list: every state goes
// through a real model and the app's own publishing, into a shelf in a directory of the test's own, and comes back
// through the widgets' read path. A list the app could not read never says "No batteries" or "Not connected".
/// What a stream brought the app to.
struct DeviceState: Sendable, CustomTestStringConvertible {
    let name: String
    let events: [DeviceEvent]
    var ends = false
    /// What the widgets say; nil for a list that was read, which each test asserts for itself.
    let reason: String?

    var testDescription: String { name }
}

private let mouse = Device(id: DeviceID(address: "AA"), name: "Mouse", kind: .accessory,
                           levels: .single(BatteryLevel(percent: 54, approximate: false)))

private let unreadStates = [
    DeviceState(name: "launch, before any event", events: [], reason: "Reading devices…"),
    DeviceState(name: "the prompt is open", events: [.permission(.notDetermined)], reason: "Answer the Bluetooth prompt"),
    DeviceState(name: "refused", events: [.permission(.denied)], reason: "Allow Bluetooth in System Settings, then reopen the app"),
    DeviceState(name: "allowed, before the first sweep", events: [.permission(.allowed)], reason: "Reading devices…"),
    DeviceState(name: "a device reported before the first sweep", events: [.permission(.allowed), .reported(mouse)], reason: "Reading devices…"),
    DeviceState(name: "the stream ended", events: [.permission(.allowed), .swept([mouse])], ends: true, reason: "Devices unavailable"),
]

/// The content area of each size: WidgetKit keeps its margin inside a widget.
private let contents = allBatteriesSizes.map { family, size in
    (family, CGSize(width: size.width - 2 * AllBatteriesWidgetTests.margin, height: size.height - 2 * AllBatteriesWidgetTests.margin))
}

@MainActor @Suite(.timeLimit(.minutes(1))) final class WidgetDeviceStatesTests {
    let shelf = FileManager.default.temporaryDirectory.appending(path: "shelf-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: shelf)
    }

    /// Publishes the mac and the state through the app's own wiring.
    func publish(_ state: DeviceState, mac: MacBattery) async throws -> DevicesModel {
        ShelfPublisher<MacBattery>(item: .macBattery, directory: shelf) { _ in }.publish(mac)
        let publisher = ShelfPublisher<WidgetDevices>(item: .devices, directory: shelf) { _ in }
        let (changed, signal) = AsyncStream.makeStream(of: Void.self)
        var next = changed.makeAsyncIterator()
        let (events, send) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let model = DevicesModel(events: events, shelf: publisher, onChange: { _ in signal.yield() })
        for event in state.events {
            send.yield(event)
            _ = await next.next()
        }
        if state.ends {
            send.finish()
            _ = await next.next()
        }
        return model
    }

    func allBatteriesSays(_ family: WidgetFamily = .systemSmall) throws -> [String] {
        let entry = AllBatteriesEntry(date: .now, directory: .success(shelf), log: ShelfLog.log)
        return try AllBatteriesView(entry: entry, appName: "Orange Drink", family: family).inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    func deviceBatterySays(chosen: String?) throws -> [String] {
        let entry = DeviceBatteryEntry(date: .now, shelf: WidgetShelf.load(.devices, from: .success(shelf), log: ShelfLog.log), chosen: chosen)
        return try DeviceBatteryView(entry: entry, appName: "Orange Drink", family: .systemSmall).inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    @Test(arguments: unreadStates) func aListTheAppCouldNotReadSaysWhyOnEveryWidget(state: DeviceState) async throws {
        let reason = try #require(state.reason)
        let model = try await publish(state, mac: .noBattery)
        #expect(try allBatteriesSays() == [reason])
        #expect(try deviceBatterySays(chosen: "AA") == [reason])
        #expect(try deviceBatterySays(chosen: nil) == [reason])
        _ = model
    }

    @Test(arguments: unreadStates) func aMacWithABatteryKeepsItsRingBesideTheReason(state: DeviceState) async throws {
        let reason = try #require(state.reason)
        let model = try await publish(state, mac: .level(percent: 79, charging: false))
        #expect(try allBatteriesSays() == ["79%", reason])
        _ = model
    }

    @Test func aListThatWasReadSaysWhatIsConnected() async throws {
        let read = DeviceState(name: "read", events: [.permission(.allowed), .swept([])], reason: nil)
        let model = try await publish(read, mac: .noBattery)
        #expect(try allBatteriesSays() == ["No batteries"])
        #expect(try deviceBatterySays(chosen: "AA") == ["Not connected"])
        #expect(try deviceBatterySays(chosen: nil) == ["Choose a device: right-click → Edit Widget"])
        _ = model
    }

    @Test func theReadLaptopListsItsMacAlone() async throws {
        let read = DeviceState(name: "read", events: [.permission(.allowed), .swept([])], reason: nil)
        let model = try await publish(read, mac: .level(percent: 79, charging: false))
        #expect(try allBatteriesSays() == ["79%"])
        _ = model
    }

    @Test func aFileInTheOldShapeDrawsOpenTheAppAndIsWrittenOver() throws {
        let old = #"{"running":{"_0":[]}}"#
        try Data(old.utf8).write(to: shelf.appending(path: WidgetShelf.Item<WidgetDevices>.devices.file))
        #expect(try deviceBatterySays(chosen: "AA") == ["Open Orange Drink"])

        var asked: [WidgetKind] = []
        let publisher = ShelfPublisher<WidgetDevices>(item: .devices, directory: shelf) { asked.append($0) }
        publisher.publish(.unread(.waiting))
        #expect(asked == [.deviceBattery, .allBatteries])
        #expect(try deviceBatterySays(chosen: "AA") == ["Reading devices…"])
    }

    @Test func theShelfLogsWhyThereIsNoList() {
        #expect(String(describing: Shelved.running(WidgetDevices.unread(.denied))).contains("denied"))
    }

    // MARK: the drawing

    static func entry(_ reason: UnreadDevices, mac: MacBattery) -> AllBatteriesEntry {
        AllBatteriesEntry(date: .now, mac: .success(.running(mac)), devices: .success(.running(.unread(reason))))
    }

    static let reasons: [UnreadDevices] = [.waiting, .unanswered, .denied, .ended]

    @Test(arguments: contents) func theMacsRingIsTheSizeItIsBesideItsDevices(family: WidgetFamily, content: CGSize) throws {
        func across(_ entry: AllBatteriesEntry) throws -> Double {
            try RingPixels(widgetImage(AllBatteriesWidgetTests.view(entry, family), size: content, scheme: .dark, scale: 2)).across
        }
        let beside = try across(AllBatteriesWidgetTests.entry(AllBatteriesWidgetTests.onBattery, AllBatteriesWidgetTests.three))
        for reason in Self.reasons {
            let alone = try across(Self.entry(reason, mac: AllBatteriesWidgetTests.onBattery))
            #expect(abs(alone - beside) < 2, "\(alone) px beside \(reason), \(beside) px beside devices")
        }
    }

    /// Text clipped by its frame draws as if it fit, so the sentence is measured: laid out at the cell's width, it
    /// takes the height it needs, and that has to be no more than the row it gets.
    @Test(arguments: contents) func everyReasonFitsTheRowBeneathTheRing(family: WidgetFamily, content: CGSize) throws {
        let height = RingGrid(family).cell(in: content).height
        for reason in Self.reasons {
            let text = Text(reason.text).font(.caption).multilineTextAlignment(.center)
            let needed = ImageRenderer(content: text.frame(width: content.width).fixedSize(horizontal: false, vertical: true))
            let image = try #require(needed.nsImage)
            #expect(image.size.height <= height, "\(reason) needs \(image.size.height) pt of \(height) pt")
        }
    }
}
