import Foundation

/// Everything the user configures about alerts: the master switch, the power source alerts, and the threshold list.
struct AlertSettings: Codable, Equatable, Sendable {
    /// "Enable Notifications": off, no alert fires.
    var enabled: Bool
    var power: PowerSourceAlerts
    var alerts: [Alert]

    /// The Alerts screen's reference setup, which a first launch starts from. A constant, so the
    /// ids are the same every time it is read.
    static let initial = {
        AlertSettings(enabled: true, power: PowerSourceAlerts(pluggedIn: true, unplugged: true, sound: true), alerts: [
            Alert(kind: .low, threshold: 3, position: .center, glow: true, sound: true),
            Alert(kind: .low, threshold: 5, position: .center, glow: false, sound: true),
            Alert(kind: .low, threshold: 15, position: .top, glow: false, sound: false),
            Alert(kind: .charged, threshold: 80, position: .top, glow: false, sound: true),
        ])
    }()
}

/// The settings as UserDefaults keeps them across launches.
///
/// [LAW:composability] The store is whatever defaults it is given: the app passes the standard
/// ones, a test a throwaway suite, so a "relaunch" is a second store over the same suite.
struct AlertSettingsStore {
    private static let key = "alerts.settings"
    let defaults: UserDefaults

    /// [LAW:parse-dont-validate] The one place stored bytes become settings. Nothing stored is a
    /// first launch; something stored that does not decode throws, rather than being replaced.
    func load() throws -> AlertSettings {
        guard let data = defaults.data(forKey: Self.key) else { return .initial }
        return try JSONDecoder().decode(AlertSettings.self, from: data)
    }

    func save(_ settings: AlertSettings) throws {
        defaults.set(try JSONEncoder().encode(settings), forKey: Self.key)
    }
}
