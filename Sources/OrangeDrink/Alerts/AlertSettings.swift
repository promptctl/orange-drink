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

typealias AlertSettingsStore = DefaultsStore<AlertSettings>

extension DefaultsStore where Value == AlertSettings {
    init(defaults: UserDefaults) { self.init(key: "alerts.settings", initial: .initial, defaults: defaults) }
}
