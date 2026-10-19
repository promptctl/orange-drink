import Foundation
import IOKit.ps
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what a day of readings and screen changes leaves
// in the store, read back through a second store opened on the same file.
@MainActor @Suite struct BatteryHistoryTests {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    static let midnight = Date(timeIntervalSince1970: 1_799_971_200)

    final class Clock: Timekeeper, @unchecked Sendable {
        var current: Date
        init(_ start: Date) { current = start }
        func now() -> Date { current }
        func sleep(for duration: Duration) async throws {}
    }

    static func reading(_ source: [String: Any], percent: Int, celsius: Double = 30, full: Int = 5_942) throws -> BatteryReading {
        var powerSource = source
        powerSource[kIOPSCurrentCapacityKey] = percent
        var registry = BatteryReadingParse.registry
        registry["Temperature"] = Int(celsius * 100)
        registry["AppleRawMaxCapacity"] = full
        registry["DesignCapacity"] = 6_249
        return try #require(try BatteryReading(registry: registry, powerSource: powerSource, adapter: BatteryReadingParse.adapter))
    }
    static func onBattery(_ percent: Int, celsius: Double = 30) throws -> BatteryReading {
        try reading(BatteryReadingParse.discharging(timeToEmpty: 192), percent: percent, celsius: celsius)
    }
    static func charging(_ percent: Int) throws -> BatteryReading {
        try reading(BatteryReadingParse.charging(timeToFull: 60), percent: percent)
    }
    static func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString)/history.sqlite")
    }

    @Test func aSimulatedDayIsAllThereAfterARelaunch() throws {
        let url = Self.tempFile()
        let clock = Clock(Self.midnight.addingTimeInterval(8 * 3600))
        let history = BatteryHistory(store: try HistoryStore(url: url), timekeeper: clock, calendar: Self.utc)
        func at(_ hour: Double, _ step: () -> Void) { clock.current = Self.midnight.addingTimeInterval(hour * 3600); step() }

        // 08:00 screen on at 90%; 10:00 screen off at 80%; 12:00 screen on at 78% and plugs in;
        // 13:00 charged to 100%; unplugs at 14:00; 16:00 at 70% with the screen on until 17:00.
        history.observe(try Self.onBattery(90))
        at(10) { history.observe(try! Self.onBattery(80)); history.screenChanged(on: false) }
        at(12) { history.observe(try! Self.onBattery(78)); history.screenChanged(on: true) }
        at(12.5) { history.observe(try! Self.charging(90)) }
        at(13) { history.observe(try! Self.charging(100)) }
        at(14) { history.observe(try! Self.onBattery(100, celsius: 36.2)) }
        at(16) { history.observe(try! Self.onBattery(70)) }
        at(17) { history.screenChanged(on: false) }

        let reopened = try HistoryStore(url: url)
        let samples = try reopened.samples(since: Self.midnight)
        #expect(samples.map(\.level) == [90, 80, 78, 90, 100, 100, 70])
        #expect(samples.map(\.charging) == [false, false, false, true, true, false, false])
        #expect(samples.allSatisfy { abs($0.health - 5_942.0 / 6_249) < 1e-9 })
        #expect(samples[5].temperature.value == 36.2)
        // Discharge: 10 + 2 + 30 points while unplugged; the climb back to 100% costs nothing.
        // Screen on: 08-10, 12-17.
        #expect(try reopened.dailyUsage() == [Self.midnight: DayUsage(dischargedPercent: 42, screenOn: 7 * 3600)])
    }

    @Test func screenTimeOverMidnightSplitsAtMidnight() throws {
        var recorder = HistoryRecorder(calendar: Self.utc, launchedAt: Self.midnight.addingTimeInterval(23 * 3600))
        let write = recorder.screen(on: false, at: Self.midnight.addingTimeInterval(26 * 3600))
        #expect(write.days == [
            Self.midnight: DayUsage(screenOn: 3600),
            Self.midnight.addingTimeInterval(86_400): DayUsage(screenOn: 2 * 3600)])
    }

    @Test func aWriteTheStoreRefusedIsCountedAgainAndItsSampleIsDueAgain() throws {
        var recorder = HistoryRecorder(calendar: Self.utc, launchedAt: Self.midnight)
        let reading = try Self.onBattery(80)
        recorder.restore(recorder.screen(on: false, at: Self.midnight.addingTimeInterval(3600)))
        let refused = recorder.observe(reading, at: Self.midnight.addingTimeInterval(3601))
        recorder.restore(refused)
        let retried = recorder.observe(reading, at: Self.midnight.addingTimeInterval(3602))
        #expect(retried.sample?.at == Self.midnight.addingTimeInterval(3602))
        #expect(retried.days == [Self.midnight: DayUsage(screenOn: 3600)])
    }

    @Test func steadyReadingsWriteAtMostOneSampleEveryTenMinutes() throws {
        var recorder = HistoryRecorder(calendar: Self.utc, launchedAt: Self.midnight)
        let steady = try Self.onBattery(80)
        let writes = (0..<30).map { recorder.observe(steady, at: Self.midnight.addingTimeInterval(Double($0) * 60)) }
        #expect(writes.filter { $0.sample != nil }.count == 3)
    }
}
