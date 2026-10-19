import Foundation

/// The Power Source Alerts card: which adapter events announce themselves, and whether they make a sound.
struct PowerSourceAlerts: Codable, Equatable, Sendable {
    /// "Notify when power adapter is connected".
    var pluggedIn: Bool
    var unplugged: Bool
    /// One sound option for the card, shared by both events.
    var sound: Bool
}
