import Foundation
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is how many times the app asks WidgetKit to redraw, which spends its daily budget,
// counted at the app's one call into WidgetKit (`reload`) while the real models feed the real publishers.
@MainActor @Suite final class WidgetReloadTests {
    final class Reloads {
        var asked: [WidgetKind] = []
        func count(_ kind: WidgetKind) -> Int { asked.filter { $0 == kind }.count }
    }

    let shelf = FileManager.default.temporaryDirectory.appending(path: "shelf-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: shelf)
    }

    /// Earbuds whose lowest bud is the level the widgets draw; the case's level is known to the app and drawn nowhere.
    static func earbuds(bud: Int, case caseLevel: Int) -> SourceDevice {
        SourceDevice(id: DeviceID.bluetooth("BB"), name: "Earbuds", kind: .accessory,
                     levels: .earbuds(left: BatteryLevel(percent: bud, approximate: false), right: nil, case: BatteryLevel(percent: caseLevel, approximate: false)))
    }

    /// The earbuds' level as the widgets read it off the shelf.
    static func budLevel(on shelf: URL) throws -> Int? {
        guard case .running(let list) = try WidgetShelf.read(.devices, from: shelf).get() else { return nil }
        return list.device(.bluetooth("BB"))?.level?.percent
    }

    /// The Done when of orange-widgets-5jo.2o3, for devices: events that change the app's model but not a level a widget draws cost no reload.
    @Test func aHundredDeviceEventsThatDrawTheSameLevelsAskForNoReloadAndARealChangeAsksForOne() async throws {
        let reloads = Reloads()
        let publisher = ShelfPublisher<Shelved<WidgetDeviceList>>(item: .devices, directory: shelf, log: .unread) { reloads.asked.append($0) }
        let (events, send) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let model = try DevicesModel(sources: [.bluetooth: events], shelf: publisher, log: .unread)

        send.yield(.swept([DeviceBatteryWidgetTests.iPhone, Self.earbuds(bud: 54, case: 80)]))
        // The baseline is taken once the sweep is on the shelf, so its own reload is not counted against the 100.
        #expect(try await eventually { try Self.budLevel(on: shelf) == 54 })
        let drawn = reloads.asked
        #expect(!drawn.isEmpty)

        for step in 1...100 {
            let device = Self.earbuds(bud: 54, case: step % 2 == 0 ? 20 + step / 2 : 80)
            send.yield(.reported(device))
            // Each event reaches the model, and the mirror that follows it has run, before the next one is sent.
            #expect(await eventually { model.list.devices.first { $0.id == device.id }?.levels == device.levels })
            await Task.yield()
        }
        #expect(reloads.asked == drawn)

        send.yield(.reported(Self.earbuds(bud: 50, case: 80)))
        #expect(try await eventually { try Self.budLevel(on: shelf) == 50 })
        #expect(Array(reloads.asked.dropFirst(drawn.count)).sorted { $0.rawValue < $1.rawValue } == [.allBatteries, .deviceBattery])
    }

    /// The same for the Mac: a reading whose percent and charging state are the ones drawn, whatever else in it moved.
    @Test func aHundredMacReadingsThatDrawTheSameLevelAskForNoReloadAndARealChangeAsksForOne() async throws {
        let reloads = Reloads()
        let widgets = ShelfPublisher<Shelved<MacBattery>>(item: .macBattery, directory: shelf, log: .unread) { reloads.asked.append($0) }
        let (readings, feed) = AsyncThrowingStream.makeStream(of: BatteryRead.self)
        let model = BatteryModel(readings: readings, read: { .success(nil) }, log: .unread, onState: { widgets.publish(.running(MacBattery($0))) })

        let first = try BatteryHistoryTests.onBattery(79, celsius: 30)
        feed.yield(first)
        _ = await model.state { if case .known(let held) = $0 { held == first } else { false } }
        let drawn = reloads.asked
        #expect(!drawn.isEmpty)

        for step in 1...100 {
            let reading = try BatteryHistoryTests.onBattery(79, celsius: 30 + Double(step) / 10)
            feed.yield(reading)
            _ = await model.state { if case .known(let held) = $0 { held == reading } else { false } }
        }
        #expect(reloads.asked == drawn)

        let lower = try BatteryHistoryTests.onBattery(78)
        feed.yield(lower)
        _ = await model.state { if case .known(let held) = $0 { held == lower } else { false } }
        #expect(Array(reloads.asked.dropFirst(drawn.count)).sorted { $0.rawValue < $1.rawValue } == [.allBatteries, .macBattery])
    }
}
