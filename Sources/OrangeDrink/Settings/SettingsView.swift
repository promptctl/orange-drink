import SwiftUI

/// The settings window: the sidebar on the left, the chosen screen on the right.
struct SettingsView: View {
    let alerts: AlertCenter
    let appearance: NotificationAppearanceModel
    let look: AppAppearanceModel
    let language: AppLanguageModel
    let shortcuts: ShortcutsController
    let menuBarIcon: MenuBarIconModel
    let devices: DevicesModel
    let deviceSettings: DeviceSettingsModel
    let chargeLimit: ChargeLimitModel
    let battery: BatteryModel
    let history: Result<BatteryHistory, any Error>
    let appEnergy: Result<AppEnergyHistory, any Error>
    @State private var selection: SettingsScreen = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SettingsScreen.allCases.filter { $0.group == .settings }) { SidebarRow(screen: $0) }
                Section {
                    ForEach(SettingsScreen.allCases.filter { $0.group == .insights }) { SidebarRow(screen: $0) }
                } header: {
                    Text("Insights").font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 12)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            ScreenView(screen: selection, alerts: alerts, appearance: appearance, look: look, language: language, shortcuts: shortcuts, menuBarIcon: menuBarIcon, devices: devices,
                       deviceSettings: deviceSettings, chargeLimit: chargeLimit, battery: battery, history: history, appEnergy: appEnergy, select: { selection = $0 })
        }
        .appLook(look, language)
        .frame(minWidth: 760, minHeight: 640)
    }
}

extension SettingsScreen {
    var tileColor: Color { Color(hue: tileHue / 360, saturation: 0.75, brightness: 0.9) }
}

/// A rounded square in the screen's colour with its white glyph.
struct ScreenTile: View {
    let screen: SettingsScreen
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25).fill(screen.tileColor)
            .frame(width: size, height: size)
            .overlay { Image(systemName: screen.glyph).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white) }
    }
}

private struct SidebarRow: View {
    let screen: SettingsScreen

    var body: some View {
        Label { PhraseText(screen.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary) } icon: { ScreenTile(screen: screen, size: 28) }
            .padding(.vertical, 6)
            .tag(screen)
    }
}

/// One screen: its header, its subtitle, and, until its epic fills it, the empty state.
private struct ScreenView: View {
    let screen: SettingsScreen
    let alerts: AlertCenter
    let appearance: NotificationAppearanceModel
    let look: AppAppearanceModel
    let language: AppLanguageModel
    let shortcuts: ShortcutsController
    let menuBarIcon: MenuBarIconModel
    let devices: DevicesModel
    let deviceSettings: DeviceSettingsModel
    let chargeLimit: ChargeLimitModel
    let battery: BatteryModel
    let history: Result<BatteryHistory, any Error>
    let appEnergy: Result<AppEnergyHistory, any Error>
    let select: (SettingsScreen) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    ScreenTile(screen: screen, size: 32)
                    PhraseText(screen.title).font(.system(size: 20, weight: .bold))
                }
                .padding(.horizontal, 24).padding(.vertical, 16)
                Divider()
                if let subtitle = screen.subtitle(appName: appName) {
                    PhraseText(subtitle).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.top, 12)
                }
                switch screen {
                case .general: GeneralScreen(appearance: appearance, look: look, language: language)
                case .alerts: AlertsScreen(center: alerts)
                case .menuBar: MenuBarScreen(model: menuBarIcon, devices: devices, deviceSettings: deviceSettings)
                case .charging: ChargingScreen(limit: chargeLimit)
                case .shortcuts: ShortcutsScreen(controller: shortcuts)
                case .devices: DevicesScreen(devices: devices, settings: deviceSettings, select: select)
                case .appUsage: AppUsageScreen(appEnergy: appEnergy)
                case .battery: BatteryScreen(battery: battery, history: history)
                default: EmptyState(screen: screen).padding(.top, 60)
                }
            }
        }
    }
}

private struct EmptyState: View {
    let screen: SettingsScreen

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: screen.glyph).font(.system(size: 40)).foregroundStyle(screen.tileColor)
            Text("Nothing here yet").font(.title3.bold())
            PhraseText(screen.comingSoon).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
