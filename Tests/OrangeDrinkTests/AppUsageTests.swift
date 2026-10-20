import Foundation
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what the App Usage screen ranks from stored energy: each
// range's top five in order, the shares as they read, and the words over them.
@MainActor @Suite struct AppUsageTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static func app(_ name: String) -> AppIdentity { AppIdentity(key: "com.example.\(name)", name: name, bundleID: "com.example.\(name)") }
    static func interval(hoursAgo: Double, total: Double, _ entries: [(String, Double)]) -> AppEnergyInterval {
        AppEnergyInterval(at: t0.addingTimeInterval(-hoursAgo * 3600), seconds: 120, totalNanojoules: UInt64(total * 1e9),
                          entries: entries.map { AppEnergyInterval.Entry(app: app($0.0), nanojoules: UInt64($0.1 * 1e9)) })
    }

    /// Yesterday's heavy hour belongs to a, b, c; today's last two intervals to d, e, f. a leads 7d, d leads 24h.
    static let intervals = [
        interval(hoursAgo: 100, total: 1000, [("a", 600), ("b", 250), ("c", 100)]),
        interval(hoursAgo: 90, total: 1000, [("a", 600), ("b", 250), ("c", 100)]),
        interval(hoursAgo: 5, total: 100, [("d", 50), ("e", 30), ("f", 10), ("g", 5), ("h", 3), ("i", 1)]),
        interval(hoursAgo: 0.01, total: 100, [("e", 60), ("d", 20), ("f", 10), ("g", 5), ("h", 3), ("i", 1)]),
    ]

    @Test func sharesReadWithTwoSignificantFiguresBelowTenAndWholeFromTen() {
        let us = Locale(identifier: "en_US")
        #expect([45, 9.1, 1.7, 0.95, 0.9].map { ShareFormat.text(percent: $0, locale: us) } == ["45%", "9.1%", "1.7%", "0.95%", "0.90%"])
        #expect(ShareFormat.text(percent: 9.96, locale: us) == "10%")
        #expect(ShareFormat.text(percent: 0, locale: us) == "0%")
    }

    @Test func topDrainersListsEachRangesTopFiveInOrderUnderItsHeader() {
        let day = AppUsageRanking(intervals: Self.intervals, firstInterval: Self.intervals.first?.at, now: Self.t0, range: .day)
        #expect(day.drainers.map(\.app.name) == ["e", "d", "f", "g", "h"])
        #expect(day.range.capitals == "24H")
        let week = AppUsageRanking(intervals: Self.intervals, firstInterval: Self.intervals.first?.at, now: Self.t0, range: .week)
        #expect(week.drainers.map(\.app.name) == ["a", "b", "c", "e", "d"])
        #expect(week.range.capitals == "7D")
        #expect(AppUsageRange.month.capitals == "30D")
        #expect(AppUsageRanking(intervals: Self.intervals, firstInterval: Self.intervals.first?.at, now: Self.t0, range: .month).drainers.first?.app.name == "a")
    }

    @Test func aShareIsAgainstEverythingAppsUsedIncludingAppsBelowTheCut() {
        let week = AppUsageRanking(intervals: Self.intervals, firstInterval: Self.intervals.first?.at, now: Self.t0, range: .week)
        #expect(abs(week.drainers[0].share - 1200.0 / 2200) < 1e-9)
    }

    @Test func rightNowIsTheNewestIntervalsTopFiveAgainstThatIntervalsTotal() {
        let ranking = AppUsageRanking(intervals: Self.intervals, firstInterval: Self.intervals.first?.at, now: Self.t0, range: .week)
        #expect(ranking.rightNow.map(\.app.name) == ["e", "d", "f", "g", "h"])
        #expect(ranking.rightNow.map(\.share) == [0.6, 0.2, 0.1, 0.05, 0.03])
        #expect(ranking.rightNowAge(now: Self.t0.addingTimeInterval(120))?.english == "2m ago")
        #expect(ranking.rightNowAge(now: Self.t0)?.english == "just now")
    }

    @Test func theStatusLineSaysHowMuchHistoryAndHowManyAppsInTheRange() {
        #expect(AppUsageRanking(intervals: Self.intervals, firstInterval: Self.intervals.first?.at, now: Self.t0, range: .day).statusText.english == "4 days of history collected • 6 apps tracked in the last 24h")
        let fresh = AppUsageRanking(intervals: [Self.intervals[3]], firstInterval: Self.intervals[3].at, now: Self.t0, range: .day)
        #expect(fresh.statusText.english == "Less than a day of history collected • 6 apps tracked in the last 24h")
    }

    @Test func theHistoryDepthIsFromTheOldestStoredIntervalNotTheOldestInTheWindow() {
        let old = Self.t0.addingTimeInterval(-45 * 86_400)
        let ranking = AppUsageRanking(intervals: [Self.intervals[3]], firstInterval: old, now: Self.t0, range: .day)
        #expect(ranking.historyText.english == "45 days of history collected")
    }

    @Test func noIntervalsYetIsAnEmptyRankingNotAnError() {
        let ranking = AppUsageRanking(intervals: [], firstInterval: nil, now: Self.t0, range: .day)
        #expect(ranking.rightNow.isEmpty && ranking.drainers.isEmpty && ranking.rightNowAge(now: Self.t0) == nil)
    }

    @Test func anAppKeepsItsColourAcrossLaunchesAndCards() {
        let a = Self.app("a")
        #expect(AppColor.index(for: a, of: 8) == AppColor.index(for: Self.app("a"), of: 8))
        #expect(AppColor.index(for: a, of: 8) < 8)
        #expect(Set(["a", "b", "c", "d", "e", "f"].map { AppColor.index(for: Self.app($0), of: 8) }).count > 2)
    }

    @Test func aStoredHistoryRanksTheSameAsTheIntervalsThatWereStored() throws {
        let store = try HistoryStore(url: BatteryHistoryTests.tempFile())
        for interval in Self.intervals { try store.record(interval) }
        let stored = AppUsageRanking(intervals: try store.appEnergy(since: Self.t0.addingTimeInterval(-AppUsageRange.month.duration)), firstInterval: try store.firstIntervalTime(), now: Self.t0, range: .week)
        #expect(stored == AppUsageRanking(intervals: Self.intervals, firstInterval: Self.intervals.first?.at, now: Self.t0, range: .week))
    }
}
