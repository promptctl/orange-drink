import SwiftUI

/// design-docs/general.md. App Language, App Appearance, and Notification Appearance so far; the screen's other sections arrive with their features.
struct GeneralScreen: View {
    let appearance: NotificationAppearanceModel
    let look: AppAppearanceModel
    let language: AppLanguageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            LanguageSection(language: language)
            AppAppearanceSection(look: look)
            NotificationAppearanceSection(appearance: appearance)
        }
        .padding(24)
        .background(SettingsBackground())
    }
}

/// Match System or a language the app carries, applied as it is chosen.
private struct LanguageSection: View {
    let language: AppLanguageModel
    @State private var saveFailure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(symbol: "globe", color: .blue, title: "Language")
            if let saveFailure {
                Label("Could not save: \(saveFailure)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            SettingCard {
                SettingRow(icon: ("globe", .blue), title: "App Language", description: "Choose the language \(appName) uses. Changes apply immediately.") {
                    PopUpButton(selection: Binding(get: { language.value }, set: { choice in
                        // [LAW:no-silent-failure] A change that cannot be kept is shown, not dropped.
                        do {
                            try language.update { $0 = choice }
                            saveFailure = nil
                        } catch {
                            saveFailure = error.localizedDescription
                        }
                    }), options: AppLanguage.choices(), title: { Text(verbatim: $0.menuTitle(speaking: language.value)) })
                }
            }
        }
    }
}

/// Auto, Light, or Dark for the settings window and the panel, applied as it is chosen.
private struct AppAppearanceSection: View {
    let look: AppAppearanceModel
    @State private var saveFailure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(symbol: "circle.lefthalf.filled", color: .purple, title: "Appearance")
            if let saveFailure {
                Label("Could not save: \(saveFailure)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            SettingCard {
                SettingRow(icon: ("circle.lefthalf.filled", .purple), title: "App Appearance", description: "Auto follows your Mac's system appearance") {
                    PopUpButton(selection: Binding(get: { look.value }, set: { choice in
                        // [LAW:no-silent-failure] A change that cannot be kept is shown, not dropped.
                        do {
                            try look.update { $0 = choice }
                            saveFailure = nil
                        } catch {
                            saveFailure = error.localizedDescription
                        }
                    }), options: AppAppearance.allCases, title: { Text($0.label) })
                }
            }
        }
    }
}

/// The two settings that shape every alert, and a live sample of the alert they shape.
private struct NotificationAppearanceSection: View {
    let appearance: NotificationAppearanceModel
    @State private var showGlow = false
    @State private var saveFailure: String?

    /// The sample alert of design-docs/general.md: 15% remaining with 9 minutes to go.
    private static let sample = PillContent(
        headline: "15% Remaining", subline: "9min until empty", severity: .orange, progress: 0.15,
        position: .top, glow: false)

    var body: some View {
        let look = appearance.value
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(symbol: "sparkle", color: .pink, title: "Notification Appearance")
            if let saveFailure {
                Label("Could not save: \(saveFailure)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            SettingCard {
                SettingRow(title: "Alert Bubble Size", description: "Scales the alert pill") {
                    PopUpButton(selection: binding(\.bubbleSize), options: NotificationAppearance.BubbleSize.allCases, title: { Text($0.label) })
                }
                SettingRow(title: "Screen Edge Glow", description: "Strength of the glow around the screen edge") {
                    PopUpButton(selection: binding(\.glowStrength), options: NotificationAppearance.GlowStrength.allCases, title: { Text($0.label) })
                }
                SettingRow(title: "Preview") {
                    AccentSwitch(isOn: $showGlow, tint: .green, label: "Show Glow")
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.03))
                if showGlow { GlowView(severity: Self.sample.severity, strength: look.glowStrength) }
                PillView(content: Self.sample, scale: look.bubbleSize.scale, onClose: {})
            }
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    /// [LAW:no-silent-failure] A change that cannot be kept is shown, not dropped.
    private func binding<Value>(_ keyPath: WritableKeyPath<NotificationAppearance, Value>) -> Binding<Value> {
        Binding(get: { appearance.value[keyPath: keyPath] }, set: { value in
            do {
                try appearance.update { $0[keyPath: keyPath] = value }
                saveFailure = nil
            } catch {
                saveFailure = error.localizedDescription
            }
        })
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
