import SwiftUI

/// design-docs/shortcuts.md: the global shortcut that opens the panel, the letters that work in it, and
/// the button that puts them all back.
struct ShortcutsScreen: View {
    let controller: ShortcutsController
    @State private var failure: String?

    private var shortcuts: Shortcuts { controller.model.value }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionHeader(symbol: "command", color: .cyan, title: "Global Shortcut")
                SettingCard {
                    SettingRow(icon: ("tray.and.arrow.down.fill", .green), title: "Open \(appName)",
                               description: "Show or hide the \(appName) menu from anywhere.") {
                        KeyRecorder(display: shortcuts.openPanel.display, label: "Open \(appName)") { key in
                            attempt { try controller.record(openPanel: key.globalCombo()) }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionHeader(symbol: "keyboard", color: .purple, title: "Menu Shortcuts")
                SettingCard {
                    ForEach(MenuShortcut.allCases, id: \.self) { shortcut in
                        SettingRow(icon: shortcut.tile, title: shortcut.title, description: shortcut.summary) {
                            KeyRecorder(display: shortcuts.letter(for: shortcut).display, label: shortcut.title) { key in
                                attempt { try controller.record(key.menuLetter(), for: shortcut) }
                            }
                        }
                    }
                    Text("Single keys work while the \(appName) menu is open.")
                        .font(.caption).foregroundStyle(.secondary).padding(12)
                }
                HStack {
                    Spacer()
                    Button("Reset to default shortcuts") { attempt { try controller.reset() } }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        .background(SettingsBackground())
    }

    /// [LAW:no-silent-failure] A recording that cannot be kept is shown, and the old shortcut stays.
    private func attempt(_ body: () throws -> Void) {
        do {
            try body()
            failure = nil
        } catch {
            failure = "\(error)"
        }
    }
}

// The words and tiles of the Menu Shortcuts rows, as literal catalog keys.
extension MenuShortcut {
    var title: LocalizedStringKey {
        switch self {
        case .batteryInformation: "Battery Information"
        case .appsUsingSignificantEnergy: "Apps Using Significant Energy"
        case .connectedDevices: "Connected Devices"
        case .lowPowerMode: "Low Power Mode"
        }
    }

    var summary: LocalizedStringKey {
        switch self {
        case .batteryInformation, .appsUsingSignificantEnergy, .connectedDevices: "Show or hide this section in the menu."
        case .lowPowerMode: "Turn Low Power Mode on or off."
        }
    }

    var tile: (symbol: String, color: Color) {
        switch self {
        case .batteryInformation: ("info.circle.fill", .blue)
        case .appsUsingSignificantEnergy: ("bolt.circle.fill", .orange)
        case .connectedDevices: ("iphone.gen3.radiowaves.left.and.right", .teal)
        case .lowPowerMode: ("leaf.fill", .yellow)
        }
    }
}
