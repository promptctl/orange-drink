import Foundation

/// The settings window's screens, in sidebar order.
///
/// [LAW:one-source-of-truth] design-docs/README.md's sidebar table is this enum: order, group,
/// glyph, and tile colour live here, and the sidebar and every screen header read them.
enum SettingsScreen: String, CaseIterable, Identifiable {
    case general, alerts, menuBar, charging, devices, widgets, shortcuts, appUsage, battery, iphoneIpad

    enum Group: Equatable { case settings, insights }

    var id: String { rawValue }

    var title: Phrase {
        switch self {
        case .general: "General"
        case .alerts: "Alerts"
        case .menuBar: "Menu Bar"
        case .charging: "Charging"
        case .devices: "Devices"
        case .widgets: "Widgets"
        case .shortcuts: "Shortcuts"
        case .appUsage: "App Usage"
        case .battery: "Battery"
        case .iphoneIpad: "iPhone & iPad"
        }
    }

    var group: Group {
        switch self {
        case .appUsage, .battery, .iphoneIpad: .insights
        default: .settings
        }
    }

    /// An SF Symbol standing in for the design doc's glyph.
    var glyph: String {
        switch self {
        case .general: "gearshape.fill"
        case .alerts: "bell.fill"
        case .menuBar: "menubar.rectangle"
        case .charging: "bolt.heart.fill"
        case .devices: "ipad.and.iphone"
        case .widgets: "square.grid.2x2.fill"
        case .shortcuts: "command"
        case .appUsage: "square.3.layers.3d"
        case .battery: "battery.100.bolt"
        case .iphoneIpad: "laptopcomputer.and.iphone"
        }
    }

    /// The tile's colour, as a hue in degrees. The tiles step evenly from yellow-green to indigo
    /// so the sidebar reads as one gradient, which makes the hue a function of the position.
    var tileHue: Double {
        let index = Double(Self.allCases.firstIndex(of: self)!)
        return Self.firstHue + (Self.lastHue - Self.firstHue) * index / Double(Self.allCases.count - 1)
    }
    static let firstHue = 80.0, lastHue = 255.0

    /// The line under the header, from the screen's design doc; App Usage has none.
    func subtitle(appName: String) -> Phrase? {
        switch self {
        case .general: "Basic app settings and preferences"
        case .alerts: "Configure battery notifications and visual effects"
        case .menuBar: "Customize how \(appName) appears in your menu bar"
        case .charging: "Protect your battery's long-term health with a suite of safeguards."
        case .devices: "Monitor battery levels of your AirPods, Beats, Magic Mouse, Keyboard, Trackpad, and other paired Bluetooth devices."
        case .widgets: "Put your batteries on the desktop and in Notification Center"
        case .shortcuts: "Control \(appName) from your keyboard"
        case .appUsage: nil
        case .battery: "Daily usage, health, cycle, and temperature trends about your Mac over time"
        case .iphoneIpad: "Battery health, cycles, and lifetime stats for a connected iPhone or iPad."
        }
    }
}
