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

    enum Position: String, Codable, CaseIterable, Sendable {
        case center, top
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

    /// The level is on the firing side of the threshold.
    func isCrossed(by level: Int) -> Bool {
        switch kind {
        case .low: level < threshold
        case .charged: level >= threshold
        }
    }

    /// The level has come far enough back from the threshold that crossing it again is news.
    func isRearmed(by level: Int) -> Bool {
        switch kind {
        case .low: level >= threshold + Self.hysteresis
        case .charged: level <= threshold - Self.hysteresis
        }
    }
}
