import Foundation

/// One alert going off: what the pill, glow, and sound subscribers are handed to show.
///
/// [LAW:types-are-the-program] Each case carries exactly what its announcement needs, so a
/// subscriber never reads settings back to learn how to present it.
enum Firing: Equatable, Sendable, CustomStringConvertible {
    /// A charge level crossed a threshold the user set.
    case threshold(Alert)
    case pluggedIn(sound: Bool)
    case unplugged(sound: Bool)
    /// The battery left "Normal" for a warm or hot reading.
    case temperatureWarning

    /// The log's wording for a firing: stable, and carrying every fact the subscribers present it by.
    var description: String {
        switch self {
        case .threshold(let alert):
            "\(alert.kind.rawValue) \(alert.threshold)% position \(alert.position.rawValue) glow \(alert.glow) sound \(alert.sound)"
        case .pluggedIn(let sound): "plugged in sound \(sound)"
        case .unplugged(let sound): "unplugged sound \(sound)"
        case .temperatureWarning: "temperature warning"
        }
    }
}
