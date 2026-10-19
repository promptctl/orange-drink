import Foundation

/// One alert going off: what the pill, glow, and sound subscribers are handed to show.
///
/// [LAW:types-are-the-program] Each case carries exactly what its announcement needs, so a
/// subscriber never reads settings back to learn how to present it.
enum Firing: Equatable, Sendable {
    /// A charge level crossed a threshold the user set.
    case threshold(Alert)
    case pluggedIn(sound: Bool)
    case unplugged(sound: Bool)
    /// The battery left "Normal" for a warm or hot reading.
    case temperatureWarning
}
