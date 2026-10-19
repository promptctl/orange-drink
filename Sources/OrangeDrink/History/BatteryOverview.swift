import Foundation

/// What the Daily Usage and Battery Health cards show: every stored day, and how fresh the history is.
struct BatteryOverview: Equatable, Sendable {
    /// Days charted before the empty state gives way, and at most how many are drawn.
    static let minimumUsageDays = 3
    static let usageDaysShown = 14
    static let minimumHealthDays = 2

    struct Day: Equatable, Sendable {
        let day: Date
        let usage: DayUsage
    }

    struct HealthPoint: Equatable, Sendable {
        let day: Date
        let health: Double
    }

    /// Oldest first, one per stored day.
    let days: [Day]
    /// Oldest first, one per day that has a sample.
    let health: [HealthPoint]
    let collectedAt: Date?

    /// `healthSamples` are oldest first; each day keeps the health of its latest one, the days being
    /// the calendar's, which are also the keys of `usage`.
    init(usage: [Date: DayUsage], healthSamples: [(at: Date, health: Double)], calendar: Calendar, collectedAt: Date?) {
        days = usage.sorted { $0.key < $1.key }.map { Day(day: $0.key, usage: $0.value) }
        let latestPerDay = Dictionary(healthSamples.map { (calendar.startOfDay(for: $0.at), $0.health) }) { _, later in later }
        health = latestPerDay.sorted { $0.key < $1.key }.map { HealthPoint(day: $0.key, health: $0.value) }
        self.collectedAt = collectedAt
    }

    var shownDays: [Day] { Array(days.suffix(Self.usageDaysShown)) }
    var isBuildingUsage: Bool { days.count < Self.minimumUsageDays }
    var isBuildingHealth: Bool { health.count < Self.minimumHealthDays }

    /// "1 day collected so far", "2 days collected so far".
    var daysCollected: Phrase { days.count == 1 ? "\(days.count) day collected so far" : "\(days.count) days collected so far" }

    /// "Collected 2m ago": the age of the newest sample as of `now`; nil before there is one.
    func collectedAge(now: Date) -> Phrase? { collectedAt.map { Self.age(now.timeIntervalSince($0)) } }

    static func age(_ seconds: TimeInterval) -> Phrase {
        let minutes = Int(max(seconds, 0) / 60)
        switch minutes {
        case 0: return "Collected just now"
        case ..<60: return "Collected \(minutes)m ago"
        case ..<(24 * 60): return "Collected \(minutes / 60)h ago"
        default: return "Collected \(minutes / (24 * 60))d ago"
        }
    }
}
