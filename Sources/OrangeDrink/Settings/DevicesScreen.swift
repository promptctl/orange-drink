import SwiftUI

/// One of the Devices screen's help lines: a coloured icon tile and grey text, which may end in a
/// link to another screen.
struct DevicesHelpLine: Equatable, Identifiable {
    struct Link: Equatable {
        let title: Phrase
        let screen: SettingsScreen
    }

    /// Each line has its own icon, so the icon names it.
    var id: String { symbol }

    let symbol: String
    let color: Color
    let text: Phrase
    let link: Link?

    /// The text with its link as a run that opens `screen` inside the app.
    func attributed(in language: AppLanguage) -> AttributedString {
        var text = AttributedString(self.text.resolve(in: language))
        guard let link else { return text }
        var title = AttributedString(link.title.resolve(in: language))
        title.link = Self.url(for: link.screen)
        text.append(title)
        return text
    }

    private static let scheme = "orangedrink-screen"
    static func url(for screen: SettingsScreen) -> URL { URL(string: "\(scheme):///\(screen.rawValue)")! }
    static func screen(for url: URL) -> SettingsScreen? {
        url.scheme == scheme ? SettingsScreen(rawValue: url.lastPathComponent) : nil
    }

    /// design-docs/devices.md's Help list, in its order.
    static let all = [
        DevicesHelpLine(symbol: "bell.fill", color: .orange,
                        text: "Tap the notification icon on any device to set battery alerts.", link: nil),
        DevicesHelpLine(symbol: "pin.fill", color: .cyan,
                        text: "Tap the pin icon to show a device's battery right in the menu bar. Arrange the order in the ",
                        link: Link(title: "Menu Bar settings", screen: .menuBar)),
        DevicesHelpLine(symbol: "eye.slash.fill", color: .blue,
                        text: "Tap the eye icon to hide a device from the dropdown.", link: nil),
        DevicesHelpLine(symbol: "arrow.up.arrow.down", color: .gray,
                        text: "Devices are ranked by battery level, lowest first, so the one that needs charging is always at the top.", link: nil),
        DevicesHelpLine(symbol: "iphone", color: .blue,
                        text: "To see your iPhone or iPad battery, make sure it's Bluetooth-paired with this Mac via System Settings → Bluetooth.", link: nil),
        DevicesHelpLine(symbol: "checkmark.seal.fill", color: .green,
                        text: "Most devices provide exact battery levels. For some devices, we use approximate values prefixed with a tilde (~).", link: nil),
    ]
}

/// design-docs/devices.md: the switch for the panel's Connected Devices card, every detected device
/// with its bell, pin, and eye buttons, and the help list. The Apple Watch section comes with its
/// own feature.
struct DevicesScreen: View {
    let devices: DevicesModel
    let settings: DeviceSettingsModel
    /// Switches the settings window to another screen.
    let select: (SettingsScreen) -> Void
    @Environment(\.appLanguage) private var language

    var body: some View {
        SettingEditor(settings) { edits in
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsSectionHeader(symbol: "wave.3.right", color: .blue, title: "Bluetooth Devices")
                    SettingCard {
                        SettingRow(icon: ("ipad.and.iphone", .gray), title: "Show Connected Devices",
                                   description: "Display battery levels for paired Bluetooth devices in the menu bar dropdown") {
                            AccentSwitch(isOn: edits.binding(\.showConnectedDevices), tint: .blue, label: "Show Connected Devices")
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    SettingsSectionHeader(symbol: "antenna.radiowaves.left.and.right", color: .primary, title: "Detected Devices")
                    detectedCard(DetectedDevices(devices.list, settings: edits.value), edits)
                }
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(DevicesHelpLine.all) { helpLine($0) }
                }
            }
        }
        .padding(24)
    }

    @ViewBuilder private func detectedCard(_ detected: DetectedDevices, _ edits: SettingEdits<DeviceSettings>) -> some View {
        if devices.failure != nil {
            Text("Device readings stopped. Quit and reopen the app.").foregroundStyle(.secondary)
        } else if detected.entries.isEmpty {
            Text(devices.list.levelsUnread ? "Device batteries can't be read right now." : "No connected Bluetooth devices report a battery.")
                .foregroundStyle(.secondary)
        } else {
            SettingCard {
                ForEach(detected.entries) { entry in
                    HStack(spacing: 12) {
                        Image(systemName: entry.row.kind.symbol).font(.system(size: 18)).frame(width: 28)
                            .foregroundStyle(.secondary).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.row.name).fontWeight(.semibold)
                            Text(entry.row.percent).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Button { edits.perform { $0.toggleAlerting(entry.id) } } label: {
                            Image(systemName: entry.isAlerting ? "bell.fill" : "bell.slash").frame(width: 32, height: 32)
                                .background(Color.veil(0.1), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(entry.alertingLabel.text(in: language))
                        Button { edits.perform { $0.togglePinned(entry.id) } } label: {
                            Image(systemName: entry.isPinned ? "pin.fill" : "pin").frame(width: 32, height: 32)
                                .background(Color.veil(0.1), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(entry.pinnedLabel.text(in: language))
                        Button { edits.perform { $0.toggleHidden(entry.id) } } label: {
                            Image(systemName: entry.isHidden ? "eye.slash" : "eye").frame(width: 32, height: 32)
                                .background(Color.veil(0.1), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(entry.hiddenLabel.text(in: language))
                    }
                    .padding(12)
                    .accessibilityElement(children: .contain)
                }
            }
        }
    }

    private func helpLine(_ line: DevicesHelpLine) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 6).fill(line.color.opacity(0.9)).frame(width: 24, height: 24)
                .overlay { Image(systemName: line.symbol).font(.system(size: 12)).foregroundStyle(.white) }
                .accessibilityHidden(true)
            Text(line.attributed(in: language)).font(.callout).foregroundStyle(.secondary)
                .environment(\.openURL, OpenURLAction { url in
                    guard let screen = DevicesHelpLine.screen(for: url) else { return .systemAction }
                    select(screen)
                    return .handled
                })
        }
    }
}
