import AppKit
import Foundation
import SwiftUI
import Testing
import ViewInspector
import WidgetKit
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what each widget draws for each state of the device list: every state goes
// through a real model and the app's own publishing, into a shelf in a directory of the test's own, and comes back
// through the widgets' read path. A list the app could not read never says "No device batteries" or "Not connected".
/// What a stream brought the app to.
struct DeviceState: Sendable, CustomTestStringConvertible {
    let name: String
    let events: [DeviceEvent]
    var ends = false
    /// What the widgets say; nil for a list that was read, which each test asserts for itself.
    let reason: String?

    var testDescription: String { name }
}

private let unreadStates = [
    DeviceState(name: "launch, before any event", events: [], reason: "Reading devices…"),
    DeviceState(name: "the prompt is open", events: [.permission(.notDetermined)], reason: "Answer the Bluetooth prompt"),
    DeviceState(name: "refused", events: [.permission(.denied)], reason: "Allow Bluetooth in System Settings, then reopen the app"),
    DeviceState(name: "allowed, before the first sweep", events: [.permission(.allowed)], reason: "Reading devices…"),
    DeviceState(name: "a device reported before the first sweep", events: [.permission(.allowed), .reported(DeviceListTests.mouse)], reason: "Reading devices…"),
    DeviceState(name: "the stream ended", events: [.permission(.allowed), .swept([DeviceListTests.mouse])], ends: true, reason: "Devices unavailable"),
]

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
        let model = try DevicesModel(events: events, shelf: publisher, onChange: { _ in signal.yield() })
        for event in state.events {
            send.yield(event)
            _ = await next.next()
        }
        if state.ends {
            send.finish()
            _ = await next.next()
        }
        let reached = Shelved.running(WidgetDevices(model.list, pinned: []))
        #expect(await eventually { (try? WidgetShelf.read(.devices, from: shelf).get()) == reached })
        return model
    }

    func allBatteriesSays() throws -> [String] {
        try AllBatteriesWidgetTests.texts(AllBatteriesEntry(date: .now, directory: .success(shelf), log: ShelfLog.log, configuration: AllBatteriesIntent()))
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
        #expect(try allBatteriesSays() == ["No device batteries"])
        #expect(try deviceBatterySays(chosen: "AA") == ["Not connected"])
        #expect(try deviceBatterySays(chosen: nil) == ["Choose a device: right-click → Edit Widget"])
        _ = model
    }

    /// The list drops a connected device that reports no battery, so these words have to hold beside one, on any Mac.
    @Test(arguments: [MacBattery.noBattery, .level(percent: 79, charging: false)]) func withNothingToListTheWidgetSaysNoDeviceBatteries(mac: MacBattery) async throws {
        let silent = Device(id: DeviceID(address: "EE"), name: "Keyboard", kind: .accessory, levels: .none)
        let read = DeviceState(name: "read", events: [.permission(.allowed), .swept([silent])], reason: nil)
        let model = try await publish(read, mac: mac)
        let intent = AllBatteriesIntent()
        intent.includeMac = false
        let entry = AllBatteriesEntry(date: .now, directory: .success(shelf), log: ShelfLog.log, configuration: intent)
        #expect(try AllBatteriesWidgetTests.texts(entry) == ["No device batteries"])
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

    /// Every reason a widget can give, each reached the way a placed widget reaches it.
    static let reasons = UnreadDevices.allCases.map(NoDevicesListed.unread) + [.noneChosen, .nonePinned, .noneReporting]

    static func entry(_ reason: NoDevicesListed, mac: MacBattery, style: WidgetStyle = .rings) -> AllBatteriesEntry {
        let (devices, choice): (WidgetDevices, WidgetDeviceChoice) = switch reason {
        case .unread(let unread): (.unread(unread), .automatic)
        case .noneChosen: (.connected(AllBatteriesWidgetTests.three, pinned: []), .custom)
        case .nonePinned: (.connected(AllBatteriesWidgetTests.three, pinned: []), .sameAsMenuBar)
        case .noneReporting: (.connected(AllBatteriesWidgetTests.three, pinned: ["gone"]), .sameAsMenuBar)
        }
        return AllBatteriesEntry(date: .now, mac: .success(.running(mac)), devices: .success(.running(devices)), settings: AllBatteriesWidgetTests.settings(style: style) { $0.devices = choice })
    }

    @Test(arguments: WidgetStyle.allCases) func everyStyleSaysWhyAndKeepsTheMacBesideIt(style: WidgetStyle) throws {
        for reason in Self.reasons {
            #expect(try AllBatteriesWidgetTests.texts(Self.entry(reason, mac: .noBattery, style: style)) == [reason.text])
            #expect(try AllBatteriesWidgetTests.texts(Self.entry(reason, mac: .level(percent: 79, charging: false), style: style)) == ["79%", reason.text])
        }
    }

    @Test func theMacsBarKeepsItsPlaceBesideTheReason() throws {
        func start(_ entry: AllBatteriesEntry) throws -> Int {
            try AllBatteriesWidgetTests.pixels(entry, .systemMedium).row(0, of: 4).longestRun.start
        }
        let mac = AllBatteriesWidgetTests.onBattery
        let beside = try start(AllBatteriesWidgetTests.entry(mac, AllBatteriesWidgetTests.three, style: .bars))
        #expect(beside > 0)
        for reason in Self.reasons {
            #expect(try start(Self.entry(reason, mac: mac, style: .bars)) == beside, "\(reason)")
        }
    }

    /// A reason takes the row a second row of rings would, so the Mac's ring sits where it does in a list two rows long.
    @Test(arguments: WidgetFamilies.allBatteries) func theMacsRingKeepsItsRowBesideTheReason(family: WidgetFamily) throws {
        func top(_ entry: AllBatteriesEntry) throws -> Int? { try AllBatteriesWidgetTests.pixels(entry, family).top }
        let mac = AllBatteriesWidgetTests.onBattery
        let twoRows = Array(AllBatteriesWidgetTests.twenty.prefix(2 * BatteryGrid(family, .rings).columns - 1))
        let beside = try top(AllBatteriesWidgetTests.entry(mac, twoRows))
        for reason in Self.reasons {
            #expect(try top(Self.entry(reason, mac: mac)) == beside, "\(reason)")
        }
    }

    @Test(arguments: allBatteriesContents) func theMacsRingIsTheSizeItIsBesideItsDevices(family: WidgetFamily, content: CGSize) throws {
        func across(_ entry: AllBatteriesEntry) throws -> Double {
            try RingPixels(widgetImage(AllBatteriesWidgetTests.view(entry, family), size: content, scheme: .dark, scale: 2)).across
        }
        let beside = try across(AllBatteriesWidgetTests.entry(AllBatteriesWidgetTests.onBattery, AllBatteriesWidgetTests.three))
        for reason in Self.reasons {
            let alone = try across(Self.entry(reason, mac: AllBatteriesWidgetTests.onBattery))
            #expect(abs(alone - beside) < 2, "\(alone) px beside \(reason), \(beside) px beside devices")
        }
    }

    /// A sentence is measured because text clipped by its frame draws as if it fit: laid out at the widget's width, it
    /// takes the height it needs, and that has to be no more than the Mac's cell leaves.
    @Test(arguments: WidgetStyle.allCases, allBatteriesContents) func everyReasonFitsBeneathTheMac(style: WidgetStyle, size: (family: WidgetFamily, content: CGSize)) throws {
        let room = size.content.height - BatteryGrid(size.family, style).cell(in: size.content).height
        for reason in Self.reasons {
            let needed = ImageRenderer(content: Caption(text: reason.text).frame(width: size.content.width).fixedSize(horizontal: false, vertical: true))
            let image = try #require(needed.nsImage)
            #expect(image.size.height <= room, "\(reason) needs \(image.size.height) pt of \(room) pt")
        }
    }
}
