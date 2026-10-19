import Foundation
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what the Battery screen's top half says for a reading
// and for a stored history: the tiles' words, the last charge, and which samples each range charts.
@MainActor @Suite struct BatteryScreenTests {
    static let now = BatteryHistoryTests.midnight.addingTimeInterval(12 * 3600)
    static func sample(hoursAgo: Double, level: Int, charging: Bool = false) -> HistorySample {
        HistorySample(at: now.addingTimeInterval(-hoursAgo * 3600), level: level, charging: charging, health: 0.95, temperature: .init(value: 30, unit: .celsius))
    }

    /// Two charge sessions, the second ending at 79% just after its last charging sample, with samples 3 days and 10 days back too.
    static let twoSessions = [
        sample(hoursAgo: 240, level: 40, charging: true), sample(hoursAgo: 239, level: 60),
        sample(hoursAgo: 72, level: 50),
        sample(hoursAgo: 30, level: 20, charging: true), sample(hoursAgo: 29, level: 90),
        sample(hoursAgo: 5, level: 30, charging: true), sample(hoursAgo: 4, level: 55, charging: true),
        sample(hoursAgo: 3.95, level: 79), sample(hoursAgo: 1, level: 77),
    ]

    @Test func theTimelineReportsWhereTheLastChargeSessionEnded() {
        let timeline = BatteryLevelTimeline(range: .day, now: Self.now, samples: Self.twoSessions)
        #expect(timeline.lastCharged?.level == 79)
        #expect(timeline.lastCharged?.at == Self.now.addingTimeInterval(-3.95 * 3600))
    }

    @Test func aSessionStillChargingEndsAtItsLatestSample() {
        let samples = [Self.sample(hoursAgo: 2, level: 50), Self.sample(hoursAgo: 1, level: 60, charging: true)]
        #expect(BatteryLevelTimeline.chargeEnd(in: samples)?.level == 60)
    }

    @Test func aChargeThatEndedWhileTheAppWasNotRunningEndsAtItsLastChargingSample() {
        let samples = [Self.sample(hoursAgo: 8, level: 99, charging: true), Self.sample(hoursAgo: 2, level: 92)]
        #expect(BatteryLevelTimeline.chargeEnd(in: samples)?.level == 99)
    }

    @Test func aSilenceBetweenSamplesBreaksTheLine() {
        let samples = [Self.sample(hoursAgo: 12, level: 90), Self.sample(hoursAgo: 11.95, level: 89), Self.sample(hoursAgo: 2, level: 40), Self.sample(hoursAgo: 1.95, level: 39)]
        #expect(BatteryLevelTimeline(range: .day, now: Self.now, samples: samples).runs.map(\.run) == [0, 0, 1, 1])
    }

    @Test func noChargingMeansNoLastCharge() {
        #expect(BatteryLevelTimeline.chargeEnd(in: [Self.sample(hoursAgo: 2, level: 50), Self.sample(hoursAgo: 1, level: 49)]) == nil)
    }

    @Test func eachRangeChartsOnlyItsOwnSamplesAndAllShareTheLastCharge() {
        let counts = HistoryRange.allCases.map { BatteryLevelTimeline(range: $0, now: Self.now, samples: Self.twoSessions) }
        #expect(counts.map(\.points.count) == [4, 7, 9])
        #expect(counts.map(\.lastCharged).dropFirst().allSatisfy { $0 == counts[0].lastCharged })
        for timeline in counts {
            #expect(timeline.points.allSatisfy { $0.at >= Self.now.addingTimeInterval(-timeline.range.duration) })
        }
    }

    @Test func fewerThanTwoPointsIsAHistoryStillBuilding() {
        #expect(BatteryLevelTimeline(range: .day, now: Self.now, samples: []).isBuilding)
        #expect(BatteryLevelTimeline(range: .day, now: Self.now, samples: [Self.sample(hoursAgo: 1, level: 50)]).isBuilding)
        #expect(!BatteryLevelTimeline(range: .day, now: Self.now, samples: Self.twoSessions).isBuilding)
    }

    @Test func aStoredHistoryChartsThroughTheScreensOwnQuery() throws {
        let store = try HistoryStore(url: BatteryHistoryTests.tempFile())
        for sample in Self.twoSessions { try store.apply(HistoryWrite(sample: sample)) }
        let history = BatteryHistory(store: store, timekeeper: BatteryHistoryTests.Clock(Self.now), calendar: BatteryHistoryTests.utc)
        #expect(try history.timeline(range: .day).points.map(\.level) == [30, 55, 79, 77])
        #expect(try history.timeline(range: .day).lastCharged?.level == 79)
        #expect(try history.timeline(range: .week).points.count == 7)
        #expect(try history.timeline(range: .fortnight).points.count == 9)
    }

    @Test func theWritesThatReachTheStoreAreCountedForTheScreenToReloadOn() throws {
        let history = BatteryHistory(store: try HistoryStore(url: BatteryHistoryTests.tempFile()), timekeeper: BatteryHistoryTests.Clock(Self.now), calendar: BatteryHistoryTests.utc)
        #expect(history.revision == 0)
        history.observe(try BatteryHistoryTests.onBattery(80))
        #expect(history.revision == 1)
    }

    @Test func theTilesSayWhatTheReferenceReadingSays() throws {
        var registry = BatteryReadingParse.registry
        registry.merge(["AppleRawMaxCapacity": 5942, "DesignCapacity": 6249, "CycleCount": 84, "DesignCycleCount9C": 1000, "Temperature": 3620]) { $1 }
        let tiles = StatTiles(try #require(try BatteryReading(
            registry: registry, powerSource: BatteryReadingParse.discharging(timeToEmpty: 192), adapter: BatteryReadingParse.adapter)))
        #expect(tiles.all.map(\.label) == ["HEALTH", "TEMPERATURE", "CYCLES"])
        #expect(tiles.all.map(\.value) == ["95%", "36.2°C", "84"])
        #expect(tiles.all.map(\.status.english) == ["Good", "Warm", "of 1,000 rated"])
        #expect(tiles.temperature.tone == .condition(.warning) && tiles.health.tone == .condition(.good) && tiles.cycles.tone == .info)
    }

    @Test func theLastChargeNamesItsDayRelativeToNow() {
        let at = { (hoursAgo: Double) in Self.now.addingTimeInterval(-hoursAgo * 3600) }
        func say(_ hoursAgo: Double) -> String {
            BatteryLevelTimeline.chargedAt(at(hoursAgo), now: Self.now, calendar: BatteryHistoryTests.utc, locale: Locale(identifier: "en_US")).english
                // The time format separates the period with a narrow no-break space.
                .replacingOccurrences(of: "\u{202F}", with: " ")
        }
        #expect(say(10) == "Today, 2:00 AM")
        #expect(say(16) == "Yesterday, 8:00 PM")
        #expect(say(60).hasSuffix(", 12:00 AM"))
    }
}
