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

/// [LAW:one-type-per-behavior] Kept like every other setting; a first launch starts from the reference setup.
extension AlertSettings: Stored {
    static let storageKey = "alerts.settings"
    init() { self = .initial }
}

typealias AlertSettingsModel = StoredModel<AlertSettings>
