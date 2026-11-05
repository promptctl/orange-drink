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

    /// The Done when of orange-widgets-5jo.2o3, for devices: events that change the app's model but not a level a widget draws cost no reload.
    @Test func aHundredDeviceEventsThatDrawTheSameLevelsAskForNoReloadAndARealChangeAsksForOne() async throws {
        let reloads = Reloads()
        let publisher = ShelfPublisher<Shelved<WidgetDeviceList>>(item: .devices, directory: shelf, log: .unread) { reloads.asked.append($0) }
        let (events, send) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let model = try DevicesModel(sources: [.bluetooth: events], shelf: publisher, log: .unread)

        send.yield(.swept([DeviceBatteryWidgetTests.iPhone, DeviceBatteryWidgetTests.earbuds(54, case: 100)]))
        // The baseline is taken once the sweep is on the shelf, so its own reload is not counted against the 100.
        #expect(try await eventually { try deviceLevel("BB", on: shelf) == 54 })
        let drawn = reloads.asked
        let onShelf = try WidgetShelf.read(.devices, from: shelf).get()
        #expect(!drawn.isEmpty)

        // The case's level falls 99, 98 … 0: never the sweep's 100 and never the same twice, so every event is a change the app sees
        // and each wait is for that event, not for a state already held.
        for step in 1...100 {
            let device = DeviceBatteryWidgetTests.earbuds(54, case: 100 - step)
            send.yield(.reported(device))
            // Each event reaches the model, and the mirror that follows it has had a turn, before the next one is sent.
            #expect(await eventually { model.list.devices.first { $0.id == device.id }?.levels == device.levels })
            await Task.yield()
        }
        // A mirror that lags is caught by the exact list below as well: its reload would be in it.
        #expect(reloads.asked == drawn)
        #expect(try WidgetShelf.read(.devices, from: shelf).get() == onShelf)

        send.yield(.reported(DeviceBatteryWidgetTests.earbuds(50, case: 0)))
        #expect(try await eventually { try deviceLevel("BB", on: shelf) == 50 })
        #expect(Array(reloads.asked.dropFirst(drawn.count)).sorted { $0.rawValue < $1.rawValue } == [.allBatteries, .deviceBattery])
    }

    /// The same for the Mac: a reading whose percent and charging state are the ones drawn, whatever else in it moved.
    @Test func aHundredMacReadingsThatDrawTheSameLevelAskForNoReloadAndARealChangeAsksForOne() async throws {
        let reloads = Reloads()
        let widgets = ShelfPublisher<Shelved<MacBattery>>(item: .macBattery, directory: shelf, log: .unread) { reloads.asked.append($0) }
        let (readings, feed) = AsyncThrowingStream.makeStream(of: BatteryRead.self)
        let model = BatteryModel(readings: readings, read: { .success(nil) }, log: .unread, onState: { widgets.publish(.running(MacBattery($0))) })

        func holds(_ reading: BatteryReading) -> Bool { if case .known(let held) = model.state { held == reading } else { false } }
        // The full-charge capacity is the field that moves: the temperature is parsed to whole degrees, so a tenth of one makes no new reading.
        func reading(percent: Int, fullCapacity: Int) throws -> BatteryReading {
            try BatteryHistoryTests.reading(BatteryReadingParse.discharging(timeToEmpty: 192), percent: percent, full: fullCapacity)
        }

        let first = try reading(percent: 79, fullCapacity: 5_900)
        feed.yield(first)
        #expect(await eventually { holds(first) })
        let drawn = reloads.asked
        #expect(!drawn.isEmpty)

        for step in 1...100 {
            let next = try reading(percent: 79, fullCapacity: 5_900 + step)
            feed.yield(next)
            #expect(await eventually { holds(next) })
        }
        #expect(reloads.asked == drawn)

        let lower = try reading(percent: 78, fullCapacity: 5_900)
        feed.yield(lower)
        #expect(await eventually { holds(lower) })
        #expect(Array(reloads.asked.dropFirst(drawn.count)).sorted { $0.rawValue < $1.rawValue } == [.allBatteries, .macBattery])
    }
}
