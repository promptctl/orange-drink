import OSLog
import SwiftUI

/// design-docs/shortcuts.md: the global shortcut that opens the panel, the letters that work in it, and
/// the button that puts them all back.
struct ShortcutsScreen: View {
    /// The recorder asking for a key press: at most one.
    private enum Target: Hashable {
        case global
        case menu(MenuShortcut)
    }

    private static let log = Logger(subsystem: IOKitBattery.logSubsystem, category: "hotkey")

    let controller: ShortcutsController
    @State private var recording: Target?
    @State private var failure: Text?

    private var shortcuts: Shortcuts { controller.model.value }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let failure {
                Label { failure } icon: { Image(systemName: "exclamationmark.triangle.fill") }.foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionHeader(symbol: "command", color: .cyan, title: "Global Shortcut")
                SettingCard {
                    SettingRow(icon: ("tray.and.arrow.down.fill", .green), title: "Open \(appName)",
                               description: "Show or hide the \(appName) menu from anywhere.") {
                        recorder(.global, display: shortcuts.openPanel.display, label: "Open \(appName)")
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionHeader(symbol: "keyboard", color: .purple, title: "Menu Shortcuts")
                SettingCard {
                    ForEach(MenuShortcut.allCases, id: \.self) { shortcut in
                        SettingRow(icon: shortcut.tile, title: shortcut.title, description: shortcut.summary) {
                            recorder(.menu(shortcut), display: shortcuts.letter(for: shortcut).display, label: shortcut.title)
                        }
                    }
                    Text("Single keys work while the \(appName) menu is open.")
                        .font(.caption).foregroundStyle(.secondary).padding(12)
                }
                HStack {
                    Spacer()
                    Button("Reset to default shortcuts") {
                        endRecording()
                        attempt { try controller.reset() }
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        .background(SettingsBackground())
        .keyCapture(isActive: recording != nil, onKey: capture, onCancel: endRecording)
        .onDisappear(perform: endRecording)
    }

    private func recorder(_ target: Target, display: String, label: LocalizedStringKey) -> some View {
        KeyRecorder(display: display, label: label, isRecording: recording == target) {
            if recording == target { endRecording() } else { beginRecording(target) }
        }
    }

    /// The global shortcut is let go while recording, so pressing the current combination is a recording and not the shortcut.
    private func beginRecording(_ target: Target) {
        controller.suspend()
        recording = target
    }

    /// Ends whatever recording there is and has the system hold the saved global shortcut again.
    private func endRecording() {
        recording = nil
        do { try controller.start() } catch {
            // The screen may be gone by now, so the failure is also logged.
            Self.log.error("the global shortcut could not be held again: \(error)")
            failure = failure ?? describe(error)
        }
    }

    private func capture(_ key: RecordedKey) {
        guard let target = recording else { return }
        attempt {
            switch target {
            case .global: try controller.record(openPanel: key.globalCombo())
            case .menu(let shortcut): try controller.record(key.menuLetter(), for: shortcut)
            }
        }
        endRecording()
    }

    /// [LAW:no-silent-failure] A recording that cannot be kept is shown, and the old shortcut stays.
    private func attempt(_ body: () throws -> Void) {
        do {
            try body()
            failure = nil
        } catch {
            failure = describe(error)
        }
    }

    private func describe(_ error: Error) -> Text {
        switch error {
        case let error as ShortcutError: Text(error.message)
        case let error as HotKeyError: Text(ShortcutError.refused(error).message)
        default: Text(verbatim: error.localizedDescription)
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
