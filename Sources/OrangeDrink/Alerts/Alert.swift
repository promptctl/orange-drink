import Foundation

/// One threshold alert the user set: a charge level to watch, and how to announce it.
///
/// [LAW:one-type-per-behavior] A low alert and a charged alert differ only in which side of the
/// threshold fires them, so they are one type with a `kind`, and the user's list is N values.
struct Alert: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        /// "Notify when battery goes below percentage".
        case low
        /// "Notify when battery reaches percentage".
        case charged
    }

    /// Where the alert shows: a pill at the centre or top, or the full-screen alert of design-docs/alerts.md.
    enum Position: String, Codable, CaseIterable, Sendable {
        case center, top, fullScreen

        /// Whether an alert here can show the Border Glow: design-docs/alerts.md leaves full screen
        /// nothing uncovered to glow.
        var glows: Bool { self != .fullScreen }
    }

    /// How far back across its threshold the level must go before a fired alert may fire again.
    /// A level hovering at the threshold wobbles by a point or two; this is wider than that.
    nonisolated static let hysteresis = 5

    var id = UUID()
    var kind: Kind
    var threshold: Int
    var position: Position
    var glow: Bool
    var sound: Bool

    /// Whether the alert shows the Border Glow. A full-screen alert keeps its stored `glow` for a
    /// return to a pill position but never shows it.
    var showsGlow: Bool { glow && position.glows }

    /// The level is on the firing side of the threshold.
    func isCrossed(by level: Int) -> Bool {
        switch kind {
        case .low: level < threshold
        case .charged: level >= threshold
        }
    }

    /// The level has come far enough back from the threshold that crossing it again is news.
    /// The distance stops at the ends of the scale, so an alert at 98% or 2% still re-arms.
    func isRearmed(by level: Int) -> Bool {
        switch kind {
        case .low: level >= min(threshold + Self.hysteresis, 100)
        case .charged: level <= max(threshold - Self.hysteresis, 0)
        }
    }

    /// Whether one of these adapter changes answers the alert: connecting the adapter answers a low
    /// alert, disconnecting it a charged one (design-docs/alerts.md).
    func isAnswered(by changes: [BatteryEvent]) -> Bool {
        changes.contains {
            switch ($0, kind) {
            case (.plugged, .low), (.unplugged, .charged): true
            case (.plugged, .charged), (.unplugged, .low), (.levelChanged, _): false
            }
        }
    }
}
