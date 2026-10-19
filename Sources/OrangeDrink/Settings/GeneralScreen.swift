import SwiftUI

/// design-docs/general.md. Only Notification Appearance so far; the screen's other sections arrive with their features.
struct GeneralScreen: View {
    let appearance: NotificationAppearanceModel

    var body: some View {
        NotificationAppearanceSection(appearance: appearance)
            .padding(24)
            .background(SettingsBackground())
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
        let look = appearance.appearance
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(symbol: "sparkle", color: .pink, title: "Notification Appearance")
            if let saveFailure {
                Label("Could not save: \(saveFailure)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            SettingCard {
                SettingRow(title: "Alert Bubble Size", description: "Scales the alert pill") {
                    PopUpButton(selection: binding(\.bubbleSize), options: NotificationAppearance.BubbleSize.allCases, title: \.rawValue)
                }
                SettingRow(title: "Screen Edge Glow", description: "Strength of the glow around the screen edge") {
                    PopUpButton(selection: binding(\.glowStrength), options: NotificationAppearance.GlowStrength.allCases, title: \.rawValue)
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
        Binding(get: { appearance.appearance[keyPath: keyPath] }, set: { value in
            do {
                try appearance.update { $0[keyPath: keyPath] = value }
                saveFailure = nil
            } catch {
                saveFailure = error.localizedDescription
            }
        })
    }
}
