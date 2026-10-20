import Foundation

/// A plain-language finding about an app behaving badly, derived from the stored intervals.
///
/// [LAW:one-source-of-truth] The rules live here and nowhere else; the cards only render what was found.
enum AppInsight: Equatable, Sendable {
    /// One app holds `share` of everything apps used over `range`.
    case dominating(AppShare, range: AppUsageRange)
    /// An app draws `ratio` times its typical share right now.
    case unusuallyActive(AppShare, ratio: Double)

    /// The doc's reference figures.
    static let dominatingShare = 0.5
    static let unusualRatio = 1.5
    /// Below these a ratio is noise: a 0.1% app doubling is not news, and a typical share needs an hour behind it.
    static let unusualMinimumShare = 0.1
    static let typicalHistory: TimeInterval = 3600

    var app: AppIdentity {
        switch self {
        case .dominating(let share, _), .unusuallyActive(let share, _): share.app
        }
    }

    /// `apps` is the range's ranking and `latest` the newest interval's, both most first.
    static func find(inRange: [AppEnergyInterval], apps: [AppShare], latest: [AppShare], range: AppUsageRange) -> [AppInsight] {
        let dominating = apps.first.flatMap { $0.share >= dominatingShare ? AppInsight.dominating($0, range: range) : nil }
        // Typical = the share over the intervals before the newest one, so a spike does not excuse itself.
        let earlier = inRange.dropLast()
        let earlierTotal = earlier.reduce(0) { $0 + $1.totalNanojoules }
        var earlierByApp: [AppIdentity: UInt64] = [:]
        for entry in earlier.flatMap(\.entries) { earlierByApp[entry.app, default: 0] += entry.nanojoules }
        let enoughHistory = earlier.reduce(0) { $0 + $1.seconds } >= typicalHistory && earlierTotal > 0
        let unusual: [AppInsight] = latest.compactMap { current in
            guard enoughHistory, current.share >= unusualMinimumShare, let before = earlierByApp[current.app], before > 0 else { return nil }
            // Rounded to what the card shows, so the rule and the sentence cannot disagree.
            let ratio = (current.share / (Double(before) / Double(earlierTotal)) * 10).rounded() / 10
            return ratio >= unusualRatio ? .unusuallyActive(current, ratio: ratio) : nil
        }
        return (dominating.map { [$0] } ?? []) + unusual.sorted { ($0.ratio ?? 0) > ($1.ratio ?? 0) }
    }

    private var ratio: Double? {
        if case .unusuallyActive(_, let ratio) = self { ratio } else { nil }
    }

    func heading() -> Phrase {
        switch self {
        case .dominating: "\(app.name) is dominating your battery"
        case .unusuallyActive: "\(app.name) is unusually active right now"
        }
    }

    func text(locale: Locale) -> Phrase {
        switch self {
        case .dominating(let share, let range):
            "\(ShareFormat.text(percent: share.share * 100, locale: locale)) of your apps' total energy in the last \(range.title). If you're not actively using it, closing it could meaningfully extend battery life."
        case .unusuallyActive(_, let ratio):
            "It's drawing about \(ratio.formatted(.number.precision(.fractionLength(0...1)).locale(locale)))× more energy than its typical share. It may be stuck in a loop or doing background work. Restart it if you're not actively using it."
        }
    }
}

extension AppIdentity: Identifiable {
    var id: String { key }
}
