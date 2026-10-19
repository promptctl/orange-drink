import Foundation
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what the Daily Usage and Battery Health cards chart from a
// stored history: one entry per day, the stored health, and the pill's wording.
@MainActor @Suite struct BatteryOverviewTests {
    static let midnight = BatteryHistoryTests.midnight
    static func day(_ n: Int) -> Date { midnight.addingTimeInterval(Double(n) * 86_400) }

    /// Three days: discharge 30/20/10 percentage points, screen on 5/4/3 hours, and health samples
    /// 0.97 and 0.96 on the first day, 0.95 on the second, 0.94 on the third.
    static func storedThreeDays() throws -> BatteryHistory {
        let store = try HistoryStore(url: BatteryHistoryTests.tempFile())
        func sample(_ day: Int, hour: Double, health: Double) -> HistorySample {
            HistorySample(at: Self.day(day).addingTimeInterval(hour * 3600), level: 50, charging: false, health: health, temperature: .init(value: 30, unit: .celsius))
        }
        try store.apply(HistoryWrite(sample: sample(0, hour: 9, health: 0.97), days: [day(0): DayUsage(dischargedPercent: 30, screenOn: 5 * 3600)]))
        try store.apply(HistoryWrite(sample: sample(0, hour: 20, health: 0.96)))
        try store.apply(HistoryWrite(sample: sample(1, hour: 9, health: 0.95), days: [day(1): DayUsage(dischargedPercent: 20, screenOn: 4 * 3600)]))
        try store.apply(HistoryWrite(sample: sample(2, hour: 9, health: 0.94), days: [day(2): DayUsage(dischargedPercent: 10, screenOn: 3 * 3600)]))
        return BatteryHistory(store: store, timekeeper: BatteryHistoryTests.Clock(day(2).addingTimeInterval(9 * 3600 + 120)), calendar: BatteryHistoryTests.utc)
    }

    @Test func eachStoredDayIsOneEntryWithThatDaysDischargeAndScreenTime() throws {
        let overview = try Self.storedThreeDays().overview()
        #expect(overview.days.map(\.day) == [Self.day(0), Self.day(1), Self.day(2)])
        #expect(overview.days.map(\.usage.dischargedPercent) == [30, 20, 10])
        let hours: [TimeInterval] = [5, 4, 3].map { $0 * 3600 }
        #expect(overview.days.map(\.usage.screenOn) == hours)
        #expect(!overview.isBuildingUsage)
    }

    @Test func theHealthChartHoldsEachDaysLatestStoredHealth() throws {
        let overview = try Self.storedThreeDays().overview()
        let expected: [BatteryOverview.HealthPoint] = [
            .init(day: Self.day(0), health: 0.96), .init(day: Self.day(1), health: 0.95), .init(day: Self.day(2), health: 0.94)]
        #expect(overview.health == expected)
    }

    @Test func thePillCountsDaysWithTheRightPlural() {
        func pill(_ days: Int) -> String {
            var usage: [Date: DayUsage] = [:]
            for n in 0..<days { usage[Self.day(n)] = DayUsage() }
            return BatteryOverview(now: Self.day(days), usage: usage, healthSamples: [], calendar: BatteryHistoryTests.utc, collectedAt: nil).daysCollected.english
        }
        #expect(pill(1) == "1 day collected so far")
        #expect(pill(2) == "2 days collected so far")
    }

    @Test func usageIsBuildingUntilThreeDaysAndHealthUntilTwo() {
        let one = BatteryOverview(now: Self.day(1), usage: [Self.day(0): DayUsage()], healthSamples: [(Self.day(0), 0.9)], calendar: BatteryHistoryTests.utc, collectedAt: nil)
        #expect(one.isBuildingUsage && one.isBuildingHealth)
    }

    @Test func theCollectedAgeIsTheNewestSamplesAge() throws {
        let overview = try Self.storedThreeDays().overview()
        #expect(overview.collectedAge?.english == "Collected 2m ago")
        #expect(BatteryOverview.age(10).english == "Collected just now")
        #expect(BatteryOverview.age(3 * 3600).english == "Collected 3h ago")
        #expect(BatteryOverview.age(2 * 86_400).english == "Collected 2d ago")
    }

    @Test func theCapacityReadsFullOverDesign() throws {
        var registry = BatteryReadingParse.registry
        registry.merge(["AppleRawMaxCapacity": 5942, "DesignCapacity": 6249]) { $1 }
        let reading = try #require(try BatteryReading(registry: registry, powerSource: BatteryReadingParse.discharging(timeToEmpty: 192), adapter: BatteryReadingParse.adapter))
        #expect(reading.capacityText(locale: Locale(identifier: "en_US")) == "5,942 / 6,249 mAh")
    }
}
