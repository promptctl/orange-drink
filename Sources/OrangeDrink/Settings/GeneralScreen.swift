import SwiftUI

/// design-docs/general.md.
struct GeneralScreen: View {
    let appearance: NotificationAppearanceModel
    let look: AppAppearanceModel
    let language: AppLanguageModel
    let launchAtLogin: LaunchAtLogin
    let batteryNotifications: BatteryNotificationDismissal

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            LanguageSection(language: language)
            AppAppearanceSection(look: look)
            SystemIntegrationSection(login: launchAtLogin)
            SystemNotificationsSection(dismissal: batteryNotifications)
            NotificationAppearanceSection(appearance: appearance)
        }
        .padding(24)
    }
}

/// Match System or a language the app carries, applied as it is chosen.
private struct LanguageSection: View {
    let language: AppLanguageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(symbol: "globe", color: .blue, title: "Language")
            SettingEditor(language) { edits in
                SettingCard {
                    SettingRow(icon: ("globe", .blue), title: "App Language", description: "Choose the language \(appName) uses. Changes apply immediately.") {
                        PopUpButton(selection: edits.binding(\.self), options: AppLanguage.choices(), title: { Text(verbatim: $0.menuTitle(speaking: edits.value)) })
                    }
                }
            }
        }
    }
}

/// Auto, Light, or Dark for the settings window and the panel, applied as it is chosen.
private struct AppAppearanceSection: View {
    let look: AppAppearanceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(symbol: "circle.lefthalf.filled", color: .purple, title: "Appearance")
            SettingEditor(look) { edits in
                SettingCard {
                    SettingRow(icon: ("circle.lefthalf.filled", .purple), title: "App Appearance", description: "Auto follows your Mac's system appearance") {
                        PopUpButton(selection: edits.binding(\.self), options: AppAppearance.allCases, title: { Text($0.label) })
                    }
                }
            }
        }
    }
}

/// Launch at Login. The switch shows the system's state and asks it for the other, is busy while any call is unanswered,
/// which covers the first, and a press that did not take says why under the row.
private struct SystemIntegrationSection: View {
    let login: LaunchAtLogin

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(symbol: "power", color: .green, title: "System Integration")
            SettingCard {
                SettingRow(icon: ("power", .green), title: "Launch at Login", description: "Start \(appName) automatically when you log in") {
                    AccentSwitch(isOn: Binding(get: { login.isOn }, set: { login.set($0) }), tint: .green, label: "Launch at Login")
                        .disabled(login.asking != nil)
                }
                if let refusal = login.refusal {
                    SystemSettingFailureLine(explanation: refusal.explanation(appName: appName),
                                             fix: refusal == .needsApproval ? .loginItems { login.openLoginItems() } : nil)
                        .padding(.horizontal, 16).padding(.bottom, 10)
                }
            }
        }
    }
}

/// Dismiss macOS Battery Notifications. The switch is the user's choice, kept whether or not macOS has allowed what it needs,
/// so the line under it says when it cannot act.
private struct SystemNotificationsSection: View {
    let dismissal: BatteryNotificationDismissal

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(symbol: "app.badge", color: .orange, title: "System Notifications")
            SettingEditor(dismissal.settings) { edits in
                SettingCard {
                    SettingRow(icon: ("bell.slash", .red), title: "Dismiss macOS Battery Notifications",
                               description: "Automatically closes system battery notification on the top right so you don't have to click it away.") {
                        AccentSwitch(isOn: edits.binding(\.dismissBatteryNotifications), tint: .green, label: "Dismiss macOS Battery Notifications")
                    }
                    if dismissal.needsAccessibility {
                        SystemSettingFailureLine(explanation: BatteryNotificationDismissal.accessibilityExplanation(appName: appName),
                                                 fix: .accessibility { dismissal.openAccessibility() })
                            .padding(.horizontal, 16).padding(.bottom, 10)
                    }
                }
            }
        }
    }
}

/// The two settings that shape every alert, and a live sample of the alert they shape.
private struct NotificationAppearanceSection: View {
    let appearance: NotificationAppearanceModel
    @State private var showGlow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(symbol: "sparkle", color: .pink, title: "Notification Appearance")
            SettingEditor(appearance) { edits in
                let look = edits.value
                SettingCard {
                    SettingRow(title: "Alert Bubble Size", description: "Scales the alert pill") {
                        PopUpButton(selection: edits.binding(\.bubbleSize), options: NotificationAppearance.BubbleSize.allCases, title: { Text($0.label) })
                    }
                    SettingRow(title: "Screen Edge Glow", description: "Strength of the glow around the screen edge") {
                        PopUpButton(selection: edits.binding(\.glowStrength), options: NotificationAppearance.GlowStrength.allCases, title: { Text($0.label) })
                    }
                    SettingRow(title: "Preview") {
                        AccentSwitch(isOn: $showGlow, tint: .green, label: "Show Glow")
                    }
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.03))
                    if showGlow { GlowView(severity: PillContent.sample.severity, strength: look.glowStrength) }
                    PillView(content: PillContent.sample, scale: look.bubbleSize.scale, onClose: {})
                }
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

// The pop-ups' words, as literal catalog keys: the raw values are what is stored, and a key built from one
// at runtime would be invisible to the catalog's extraction.
extension AppAppearance {
    var label: LocalizedStringKey {
        switch self {
        case .auto: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

extension NotificationAppearance.BubbleSize {
    var label: LocalizedStringKey {
        switch self {
        case .small: "Small"
        case .default: "Default"
        case .large: "Large"
        }
    }
}

extension NotificationAppearance.GlowStrength {
    var label: LocalizedStringKey {
        switch self {
        case .subtle: "Subtle"
        case .default: "Default"
        case .strong: "Strong"
        }
    }
}
