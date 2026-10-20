import Foundation

/// How far back the App Usage screen looks.
enum AppUsageRange: CaseIterable, Equatable, Sendable {
    case day, week, month

    var duration: TimeInterval {
        switch self {
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        }
    }

    var title: Phrase {
        switch self {
        case .day: "24h"
        case .week: "7d"
        case .month: "30d"
        }
    }

    /// The range as a card header spells it: "24H".
    var capitals: String {
        switch self {
        case .day: "24H"
        case .week: "7D"
        case .month: "30D"
        }
    }
}

/// An app and its share of the energy apps used.
struct AppShare: Equatable, Sendable {
    let app: AppIdentity
    let nanojoules: UInt64
    /// A fraction of the total: 0...1.
    let share: Double
}

/// An app's row in Top Energy Consumers: its share, and its energy across the range for the sparkline.
struct AppConsumer: Equatable, Sendable {
    /// Slices the range is cut into; every sparkline has this many points.
    static let points = 48

    let share: AppShare
    /// Nanojoules the app used in each of `points` equal slices, oldest first, the last ending now.
    let slices: [UInt64]
}

/// What the App Usage screen ranks, for one range, from the stored intervals.
///
/// [LAW:one-source-of-truth] Every list on the screen is derived here from the one list of stored
/// intervals, so the cards, the insights, and the consumers list cannot disagree about who used what.
struct AppUsageRanking: Equatable, Sendable {
    static let shown = 5

    let range: AppUsageRange
    /// Every app in the newest interval, each against that interval's total, most first; empty before any interval.
    let latest: [AppShare]
    /// When the newest interval ended; nil before any.
    let lastSampleAt: Date?
    /// Every app seen in the range by energy, each against everything apps used in the range and with its
    /// energy across the range, most first.
    let apps: [AppConsumer]
    let insights: [AppInsight]
    /// How long the oldest stored interval has been in the history, however old; nil before any.
    let historyDepth: TimeInterval?

    /// `intervals` are oldest first and cover at least the range; `firstInterval` is when the oldest stored
    /// interval ended, which may be older than any of `intervals`.
    init(intervals: [AppEnergyInterval], firstInterval: Date?, now: Date, range: AppUsageRange) {
        self.range = range
        let inRange = intervals.filter { $0.at >= now.addingTimeInterval(-range.duration) }
        let latest = intervals.last
        lastSampleAt = latest?.at
        self.latest = latest.map { latest in
            latest.entries.sorted { ($0.nanojoules, $1.app.key) > ($1.nanojoules, $0.app.key) }.map { AppShare(app: $0.app, nanojoules: $0.nanojoules, share: Self.fraction($0.nanojoules, of: latest.totalNanojoules)) }
        } ?? []
        var byApp: [AppIdentity: UInt64] = [:]
        for entry in inRange.flatMap(\.entries) { byApp[entry.app, default: 0] += entry.nanojoules }
        let total = inRange.reduce(0) { $0 + $1.totalNanojoules }
        let slices = Self.slices(of: inRange, now: now, range: range)
        apps = byApp.sorted { ($0.value, $1.key.key) > ($1.value, $0.key.key) }.map {
            AppConsumer(share: AppShare(app: $0.key, nanojoules: $0.value, share: Self.fraction($0.value, of: total)), slices: slices[$0.key] ?? [])
        }
        insights = AppInsight.find(inRange: inRange, apps: apps.map(\.share), latest: self.latest, now: now, range: range)
        historyDepth = firstInterval.map { now.timeIntervalSince($0) }
    }

    var rightNow: [AppShare] { Array(latest.prefix(Self.shown)) }
    var drainers: [AppShare] { apps.prefix(Self.shown).map(\.share) }
    var appsTracked: Int { apps.count }

    /// Each app's energy per equal slice of the range, oldest first. An interval lands in the slice holding its end;
    /// one ending exactly now, or stamped after it by a clock step back, is the newest slice's.
    private static func slices(of inRange: [AppEnergyInterval], now: Date, range: AppUsageRange) -> [AppIdentity: [UInt64]] {
        let start = now.addingTimeInterval(-range.duration)
        let width = range.duration / Double(AppConsumer.points)
        var slices: [AppIdentity: [UInt64]] = [:]
        for interval in inRange {
            let slice = min(max(Int(interval.at.timeIntervalSince(start) / width), 0), AppConsumer.points - 1)
            for entry in interval.entries { slices[entry.app, default: Array(repeating: 0, count: AppConsumer.points)][slice] += entry.nanojoules }
        }
        return slices
    }

    private static func fraction(_ part: UInt64, of whole: UInt64) -> Double { whole == 0 ? 0 : Double(part) / Double(whole) }

    /// "Less than a day of history collected", "3 days of history collected".
    var historyText: Phrase {
        let days = Int(max(historyDepth ?? 0, 0) / 86_400)
        switch days {
        case 0: return "Less than a day of history collected"
        case 1: return "1 day of history collected"
        default: return "\(days) days of history collected"
        }
    }

    /// "10 apps tracked in the last 24h".
    var trackedText: Phrase {
        appsTracked == 1 ? "1 app tracked in the last \(range.title)" : "\(appsTracked) apps tracked in the last \(range.title)"
    }

    var statusText: Phrase { "\(historyText) • \(trackedText)" }

    /// "2m ago": the age of the newest interval as of `now`, in whole minutes; nil before any.
    func rightNowAge(now: Date) -> Phrase? {
        lastSampleAt.map { at in
            let minutes = Int(max(now.timeIntervalSince(at), 0) / 60)
            return minutes == 0 ? "just now" : minutes < 60 ? "\(minutes)m ago" : "\(minutes / 60)h ago"
        }
    }
}

/// How a share reads: whole numbers from 10% up, two significant figures below.
enum ShareFormat {
    static func text(percent: Double, locale: Locale) -> String {
        let rounded = percent < 10 && percent > 0 ? Self.twoSignificant(percent) : percent.rounded()
        // Rounding to two significant figures can land on 10, which then reads as a whole number.
        let decimals = rounded >= 10 || rounded == 0 ? 0 : max(0, 1 - Int(floor(log10(rounded))))
        return rounded.formatted(.number.precision(.fractionLength(decimals)).locale(locale)) + "%"
    }

    private static func twoSignificant(_ value: Double) -> Double {
        let scale = pow(10, 1 - floor(log10(value)))
        return (value * scale).rounded() / scale
    }
}

/// An app's bar colour, the same wherever the app appears: a stable hash of its key picks from the palette.
enum AppColor {
    /// FNV-1a; Swift's own hashing is seeded per launch, which would recolour every app each time.
    static func index(for app: AppIdentity, of paletteSize: Int) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in app.key.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return Int(hash % UInt64(paletteSize))
    }
}
