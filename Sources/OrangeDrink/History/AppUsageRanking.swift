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

/// What the App Usage screen ranks, for one range, from the stored intervals.
///
/// [LAW:one-source-of-truth] Every list on the screen is derived here from the one list of stored
/// intervals, so the cards, the insights, and the consumers list cannot disagree about who used what.
struct AppUsageRanking: Equatable, Sendable {
    static let shown = 5

    let range: AppUsageRange
    let now: Date
    /// The newest interval's top apps, each against that interval's total; empty before any interval.
    let rightNow: [AppShare]
    /// When the newest interval ended; nil before any.
    let lastSampleAt: Date?
    /// Apps by energy over the range, each against everything apps used in the range, most first.
    let drainers: [AppShare]
    let appsTracked: Int
    /// How long the oldest stored interval has been in the history; nil before any.
    let historyDepth: TimeInterval?

    /// `intervals` are oldest first and cover at least the range.
    init(intervals: [AppEnergyInterval], now: Date, range: AppUsageRange) {
        self.range = range
        self.now = now
        let inRange = intervals.filter { $0.at >= now.addingTimeInterval(-range.duration) }
        let latest = intervals.last
        lastSampleAt = latest?.at
        rightNow = latest.map { latest in
            latest.entries.prefix(Self.shown).map { AppShare(app: $0.app, nanojoules: $0.nanojoules, share: Self.fraction($0.nanojoules, of: latest.totalNanojoules)) }
        } ?? []
        var byApp: [AppIdentity: UInt64] = [:]
        for entry in inRange.flatMap(\.entries) { byApp[entry.app, default: 0] += entry.nanojoules }
        let total = inRange.reduce(0) { $0 + $1.totalNanojoules }
        drainers = byApp.sorted { ($0.value, $1.key.key) > ($1.value, $0.key.key) }.prefix(Self.shown)
            .map { AppShare(app: $0.key, nanojoules: $0.value, share: Self.fraction($0.value, of: total)) }
        appsTracked = byApp.count
        historyDepth = intervals.first.map { now.timeIntervalSince($0.at) }
    }

    private static func fraction(_ part: UInt64, of whole: UInt64) -> Double { whole == 0 ? 0 : Double(part) / Double(whole) }

    /// "Less than a day of history collected", "3 days of history collected".
    var historyText: Phrase {
        let days = Int((historyDepth ?? 0) / 86_400)
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
    static let paletteSize = 8

    /// FNV-1a; Swift's own hashing is seeded per launch, which would recolour every app each time.
    static func index(for app: AppIdentity) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in app.key.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return Int(hash % UInt64(paletteSize))
    }
}
