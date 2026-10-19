import Foundation

/// The rows of the panel's actions card, in the order the card lists them.
///
/// [LAW:one-source-of-truth] Order, labels, and glyphs live here; the view draws them and the
/// tests read them.
enum PanelAction: CaseIterable {
    case settings, batterySettings, lowPowerMode, checkForUpdates, quit

    func title(appName: String) -> String {
        switch self {
        case .settings: "Settings…"
        case .batterySettings: "Battery Settings…"
        case .lowPowerMode: "Low Power Mode"
        case .checkForUpdates: "Check for Updates…"
        case .quit: "Quit \(appName)"
        }
    }

    var symbol: String {
        switch self {
        case .settings: "gearshape"
        case .batterySettings: "battery.100"
        case .lowPowerMode: "leaf"
        case .checkForUpdates: "arrow.triangle.2.circlepath"
        case .quit: "power"
        }
    }

    /// The pane Battery Settings… opens: System Settings at Battery.
    static let batteryPane = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!

    /// "v1.2.0": the bundle's short version string, in the form the Quit row prints it.
    static func versionText(of bundle: Bundle) -> String {
        versionText(shortVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String)
    }

    static func versionText(shortVersion: String) -> String { "v" + shortVersion }
}
