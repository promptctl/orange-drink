import Foundation

/// How far back the Battery Level card looks.
enum HistoryRange: CaseIterable, Equatable, Sendable {
    case day, week, fortnight

    var duration: TimeInterval {
        switch self {
        case .day: 86_400
        case .week: 7 * 86_400
        case .fortnight: 14 * 86_400
        }
    }

    var title: Phrase {
        switch self {
        case .day: "24h"
        case .week: "7d"
        case .fortnight: "14d"
        }
    }
}

/// What the Battery Level card shows for one range: the samples inside it, and where the last
/// charge session ended, which the range does not limit.
///
/// [LAW:one-source-of-truth] Built by one pure function from one list of samples, so every range
/// agrees on the last charge.
struct BatteryLevelTimeline: Equatable, Sendable {
    /// The longest range, which is also how far back the last charge is looked for.
    static let lookback = HistoryRange.fortnight.duration

    let range: HistoryRange
    let now: Date
    /// Oldest first, all at or after `now - range`.
    let points: [HistorySample]
    /// nil when nothing in the lookback was charging.
    let lastCharged: HistorySample?

    /// `samples` are oldest first and cover at least the range.
    init(range: HistoryRange, now: Date, samples: [HistorySample]) {
        self.range = range
        self.now = now
        points = samples.filter { $0.at >= now.addingTimeInterval(-range.duration) }
        lastCharged = Self.chargeEnd(in: samples)
    }

    /// A line needs two points; fewer is a history still being collected.
    var isBuilding: Bool { points.count < 2 }

    /// Where the latest charge session ended: the first sample after the last one that was charging,
    /// which is the unplug or the full battery, or that charging sample itself while the session goes on.
    static func chargeEnd(in samples: [HistorySample]) -> HistorySample? {
        guard let last = samples.lastIndex(where: \.charging) else { return nil }
        return samples.indices.contains(last + 1) ? samples[last + 1] : samples[last]
    }
}

extension BatteryLevelTimeline {
    /// "Today, 2:42 AM": the time of the last charge, named by day relative to `now`.
    static func chargedAt(_ at: Date, now: Date, calendar: Calendar, locale: Locale) -> Phrase {
        let time = at.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
        if calendar.isDate(at, inSameDayAs: now) { return "Today, \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(at, inSameDayAs: yesterday) {
            return "Yesterday, \(time)"
        }
        let day = at.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
        return "\(day), \(time)"
    }
}
