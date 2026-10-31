import SwiftUI

/// The settings window: the sidebar on the left, the chosen screen on the right.
struct SettingsView: View {
    let alerts: AlertCenter
    let appearance: NotificationAppearanceModel
    let look: AppAppearanceModel
    let language: AppLanguageModel
    let launchAtLogin: LaunchAtLogin
    let batteryNotifications: BatteryNotificationDismissal
    let shortcuts: ShortcutsController
    let menuBarIcon: MenuBarIconModel
    let devices: DevicesModel
    let deviceSettings: DeviceSettingsModel
    let chargeLimit: ChargeLimitModel
    let chargeHold: AppChargeHold
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
            ScreenView(screen: selection, alerts: alerts, appearance: appearance, look: look, language: language, launchAtLogin: launchAtLogin, batteryNotifications: batteryNotifications, shortcuts: shortcuts, menuBarIcon: menuBarIcon, devices: devices,
                       deviceSettings: deviceSettings, chargeLimit: chargeLimit, chargeHold: chargeHold, battery: battery, history: history, appEnergy: appEnergy, select: { selection = $0 })
        }
        .appLook(look, language)
        .frame(minWidth: 760, minHeight: 640)
    }
}

extension SettingsScreen {
    var tileColor: Color { Color(hue: tileHue / 360, saturation: 0.75, brightness: 0.9) }

    /// The glows behind the screen. Where its design doc has a "Background" line, they sit where that line puts them
    /// with the screen at rest.
    var backdrop: SettingsBackground {
        switch self {
        case .alerts: SettingsBackground(glows: [.standard, .init(color: .red, center: .center, opacity: 0.1, radius: 360)])
        case .devices: SettingsBackground(glows: [.init(color: .green, center: .top)])
        case .charging: SettingsBackground(glows: [.init(color: .green, center: .trailing)])
        case .battery: SettingsBackground(glows: [.init(color: .green, center: .top)])
        case .appUsage: SettingsBackground(glows: [.init(color: .indigo, center: .top)])
        case .general, .menuBar, .widgets, .shortcuts, .iphoneIpad: SettingsBackground()
        }
    }
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
    let launchAtLogin: LaunchAtLogin
    let batteryNotifications: BatteryNotificationDismissal
    let shortcuts: ShortcutsController
    let menuBarIcon: MenuBarIconModel
    let devices: DevicesModel
    let deviceSettings: DeviceSettingsModel
    let chargeLimit: ChargeLimitModel
    let chargeHold: AppChargeHold
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
                case .general: GeneralScreen(appearance: appearance, look: look, language: language, launchAtLogin: launchAtLogin, batteryNotifications: batteryNotifications)
                case .alerts: AlertsScreen(center: alerts)
                case .menuBar: MenuBarScreen(model: menuBarIcon, devices: devices, deviceSettings: deviceSettings)
                case .charging: ChargingScreen(limit: chargeLimit, hold: chargeHold)
                case .shortcuts: ShortcutsScreen(controller: shortcuts)
                case .devices: DevicesScreen(devices: devices, settings: deviceSettings, select: select)
                case .appUsage: AppUsageScreen(appEnergy: appEnergy)
                case .battery: BatteryScreen(battery: battery, history: history)
                default: EmptyState(screen: screen).padding(.top, 60)
                }
            }
        }
        // Each screen is its own scroll, so a newly chosen screen opens at its top, not at the last one's offset.
        .id(screen)
        // [LAW:decomposition] The backdrop is the pane's, not the content's: drawn behind the scroll view it
        // fills the pane however short the screen, and stays put while a tall one scrolls over it.
        .background(screen.backdrop)
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
