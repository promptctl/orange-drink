import SwiftUI

/// The panel the status item opens: stacked rounded cards on a dark ground.
struct PanelView: View {
    let battery: BatteryModel
    let devices: DevicesModel
    let deviceSettings: DeviceSettingsModel
    let sections: PanelSections
    let keyboard: PanelKeyboard
    let look: AppAppearanceModel
    let language: AppLanguageModel

    var body: some View {
        VStack(spacing: 10) {
            switch battery.state {
            case .known(let reading?): ChargeCardView(card: ChargeCard(reading))
            case .unknown: PanelNote("Reading the battery…")
            case .known(nil): PanelNote("This Mac has no battery.")
            case .ended: PanelNote("Battery readings stopped. Quit and reopen the app.")
            }
            CollapsibleCard(title: "Battery Information", symbol: "info.circle.fill", symbolColor: .blue,
                            section: .batteryInformation, sections: sections) {
                if case .known(let reading?) = battery.state { BatteryInformationView(info: BatteryInformation(reading), reading: reading, battery: battery) }
            }
            let connected = ConnectedDevices(devices.list, settings: deviceSettings.value)
            if connected.isShown {
                CollapsibleCard(title: "Connected Devices", symbol: "iphone.gen3.radiowaves.left.and.right", symbolColor: .cyan,
                                section: .connectedDevices, sections: sections) {
                    ConnectedDevicesView(connected: connected, failed: devices.failure != nil)
                }
            }
            ActionsCard()
        }
        .padding(12)
        .frame(width: 330)
        .background(AdaptiveColor(light: .white.opacity(0.85), dark: .black.opacity(0.85)))
        .appLook(look, language)
        .onAppear { keyboard.panelDidOpen(shown: { [devices, deviceSettings] in Self.shown(devices: devices, settings: deviceSettings) }) }
        .onDisappear { keyboard.panelDidClose() }
    }

    /// The collapsible sections the panel draws: Connected Devices only when there is something to say.
    private static func shown(devices: DevicesModel, settings: DeviceSettingsModel) -> Set<PanelSections.Section> {
        ConnectedDevices(devices.list, settings: settings.value).isShown ? [.batteryInformation, .connectedDevices] : [.batteryInformation]
    }
}

private struct PanelNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).card() }
}

extension View {
    /// The panel's card: a rounded surface with a thin border.
    func card() -> some View {
        padding(12)
            .background(Color.veil(0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.veil(0.1)))
    }
}

struct ChargeCardView: View {
    let card: ChargeCard

    private var tint: Color {
        switch card.tint {
        case .neutral, .green: .green
        case .orange: .orange
        case .red: .red
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(card.percent).font(.system(size: 40, weight: .bold))
                        Text(card.unit).font(.system(size: 20, weight: .semibold))
                    }
                    .foregroundStyle(tint)
                    HStack(spacing: 4) {
                        if card.status == .charging { Image(systemName: "bolt.fill").foregroundStyle(.yellow) }
                        Text(card.status.title)
                    }
                    .font(.callout)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(card.estimateCaption).font(.caption2).foregroundStyle(.secondary)
                    Text(card.estimate).font(.title3.bold())
                }
            }
            ProgressBar(fraction: card.progress, tint: tint)
        }
        .card()
    }
}

/// A full-width rounded bar on a dark track, with faint ticks at 25% and 50%.
private struct ProgressBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { bar in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.veil(0.12))
                Capsule().fill(tint).frame(width: bar.size.width * fraction)
                ForEach([0.25, 0.5], id: \.self) { mark in
                    Rectangle().fill(Color.veil(0.25)).frame(width: 1).offset(x: bar.size.width * mark)
                }
            }
        }
        .frame(height: 8)
        .clipShape(Capsule())
    }
}

struct CollapsibleCard<Content: View>: View {
    let title: LocalizedStringKey
    let symbol: String
    let symbolColor: Color
    let section: PanelSections.Section
    let sections: PanelSections
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 8) {
            Button { sections.toggle(section) } label: {
                HStack {
                    Image(systemName: symbol).foregroundStyle(symbolColor)
                    Text(title).fontWeight(.semibold)
                    Spacer()
                    Image(systemName: sections.isOpen(section) ? "chevron.up" : "chevron.down").foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if sections.isOpen(section) { content() }
        }
        .card()
    }
}

/// The actions card: one card of rows under hairlines, in `PanelAction` order.
private struct ActionsCard: View {
    @Environment(\.openWindow) private var openWindow
    @State private var lowPowerMode = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(PanelAction.allCases.enumerated()), id: \.element) { index, action in
                if index > 0 { Divider().padding(.leading, 40) }
                row(action)
            }
        }
        .card()
    }

    @ViewBuilder private func row(_ action: PanelAction) -> some View {
        switch action {
        case .settings:
            ActionRow(action: action) {
                // An accessory app is never frontmost on its own; the window would open behind.
                NSApplication.shared.activate()
                openWindow(id: SettingsWindow.id)
            } trailing: { Chevron() }
        case .batterySettings:
            ActionRow(action: action) { NSWorkspace.shared.open(PanelAction.batteryPane) } trailing: { Chevron() }
        case .lowPowerMode:
            // A placeholder until the admin helper epic can toggle it (orange-admin-helper-b2q.0ld).
            ActionRow(action: action, run: nil) { Toggle("Low Power Mode", isOn: $lowPowerMode).labelsHidden().toggleStyle(.switch).disabled(true) }
        case .checkForUpdates:
            // A placeholder until the update check exists (orange-distribution-kg2.l9x).
            ActionRow(action: action, run: nil) { EmptyView() }
        case .quit:
            ActionRow(action: action, tint: .red) { NSApplication.shared.terminate(nil) } trailing: {
                Text(PanelAction.versionText(of: .main)).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            .keyboardShortcut("q")
        }
    }
}

private struct Chevron: View {
    var body: some View { Image(systemName: "chevron.right").foregroundStyle(.secondary) }
}

private struct ActionRow<Trailing: View>: View {
    let action: PanelAction
    var tint: Color = .primary
    let run: (() -> Void)?
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        Button { run?() } label: {
            HStack(spacing: 10) {
                Image(systemName: action.symbol).foregroundStyle(tint).frame(width: 20)
                Text(action.title(appName: appName))
                Spacer()
                trailing()
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(run == nil)
    }
}
