import Foundation

/// The Power Source Alerts card: which adapter and battery-heat events announce themselves, and whether they make a sound.
struct PowerSourceAlerts: Codable, Equatable, Sendable {
    /// "Notify when power adapter is connected".
    var pluggedIn: Bool
    var unplugged: Bool
    /// "Notify when the battery runs warm or hot".
    var temperature: Bool
    /// One sound option for the card, shared by every event.
    var sound: Bool
}

extension PowerSourceAlerts {
    /// [LAW:parse-dont-validate] The Temperature switch is absent from what a release before it
    /// stored, and reads as on; a stored value of the wrong type, `null` included, still fails the launch.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pluggedIn = try values.decode(Bool.self, forKey: .pluggedIn)
        unplugged = try values.decode(Bool.self, forKey: .unplugged)
        temperature = values.contains(.temperature) ? try values.decode(Bool.self, forKey: .temperature) : true
        sound = try values.decode(Bool.self, forKey: .sound)
    }
}
