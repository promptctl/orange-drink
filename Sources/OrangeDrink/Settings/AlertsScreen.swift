import SwiftUI

/// design-docs/alerts.md: the master switch, the two threshold lists, and the power source alerts.
/// Every change goes through the `AlertCenter`, which keeps it and survives a restart with it.
struct AlertsScreen: View {
    private static let tint = Color.green

    let center: AlertCenter
    @State private var saveFailure: String?

    var body: some View {
        let settings = center.settings
        VStack(alignment: .leading, spacing: 24) {
            if let saveFailure {
                Label("Could not save: \(saveFailure)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionHeader(symbol: "gearshape", color: .secondary, title: "General")
                SettingCard {
                    SettingRow(icon: ("bell.fill", .blue), title: "Enable Notifications",
                               description: "Show battery alerts and notifications") {
                        AccentSwitch(isOn: binding(\.enabled), tint: Self.tint, label: "Enable Notifications")
                    }
                }
            }
            ThresholdSection(
                kind: .low, header: (Alert.Kind.low.symbol, .red, "Low Battery Alerts"),
                info: "Notify when battery goes below percentage", addTitle: "Add Low Battery Alert",
                alerts: settings.alerts(.low), perform: perform)
            ThresholdSection(
                kind: .charged, header: (Alert.Kind.charged.symbol, .green, "Charged Alerts"),
                info: "Notify when battery reaches percentage", addTitle: "Add Charged Alert",
                alerts: settings.alerts(.charged), perform: perform)
            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionHeader(symbol: "powerplug.fill", color: .orange, title: "Power Source Alerts")
                SettingCard {
                    SettingRow(icon: ("bolt.fill", .yellow), title: "Plugged In",
                               description: "Notify when power adapter is connected") {
                        AccentSwitch(isOn: binding(\.power.pluggedIn), tint: Self.tint, label: "Plugged In")
                    }
                    SettingRow(icon: ("bolt.slash.fill", .orange), title: "Unplugged",
                               description: "Notify when power adapter is disconnected") {
                        AccentSwitch(isOn: binding(\.power.unplugged), tint: Self.tint, label: "Unplugged")
                    }
                    SettingRow(title: "Sound", description: "Play a sound for these alerts") {
                        AccentSwitch(isOn: binding(\.power.sound), tint: Self.tint, label: "Power Source Sound")
                    }
                }
            }
        }
        .padding(24)
        .background {
            ZStack {
                SettingsBackground()
                RadialGradient(colors: [.red.opacity(0.1), .clear], center: .center, startRadius: 0, endRadius: 360)
            }
        }
    }

    /// [LAW:no-silent-failure] A change that cannot be kept is shown, not dropped.
    private func perform(_ edit: (inout AlertSettings) -> Void) {
        do {
            try center.update(edit)
            saveFailure = nil
        } catch {
            saveFailure = error.localizedDescription
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AlertSettings, Value>) -> Binding<Value> {
        Binding(get: { center.settings[keyPath: keyPath] }, set: { value in perform { $0[keyPath: keyPath] = value } })
    }
}

/// One kind's section: its cards, lowest threshold first, and the button that adds another.
private struct ThresholdSection: View {
    let kind: Alert.Kind
    let header: (symbol: String, color: Color, title: String)
    let info: String
    let addTitle: String
    let alerts: [Alert]
    let perform: (@escaping (inout AlertSettings) -> Void) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(symbol: header.symbol, color: header.color, title: header.title, info: info)
            ForEach(alerts) { alert in
                AlertCard(alert: alert, onEdit: { change in perform { $0.edit(alert.id, change) } }) {
                    perform { $0.remove(alert.id) }
                }
            }
            Button { perform { $0.add(kind) } } label: {
                Text("＋ \(addTitle)").fontWeight(.semibold)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(addTitle)
            .frame(maxWidth: .infinity)
        }
    }
}

/// One alert: a battery in its severity colour, its threshold chip, its summary, and a delete button.
private struct AlertCard: View {
    let alert: Alert
    let onEdit: (@escaping (inout Alert) -> Void) -> Void
    let onDelete: () -> Void
    @State private var editing = false
    /// The threshold the editor's stepper shows while it is open. Landing a threshold re-sorts the
    /// card, and the popover rides its card, so it is kept here and lands when the popover closes.
    @State private var draftThreshold: Int?

    var body: some View {
        let color = alert.severity.color
        SettingCard {
            HStack(spacing: 12) {
                Image(systemName: alert.kind.symbol)
                    .font(.system(size: 22)).foregroundStyle(color).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(alert.threshold)%").fontWeight(.bold).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 2)
                        .background(color.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                    Text(alert.summary).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button { editing = true } label: {
                    Image(systemName: "gearshape.fill").foregroundStyle(.secondary)
                        .frame(width: 30, height: 30).background(Circle().fill(.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit \(alert.kind.rawValue) \(alert.threshold)% alert")
                .popover(isPresented: $editing) {
                    AlertEditor(alert: alert, draftThreshold: $draftThreshold, onEdit: onEdit)
                }
                .onChange(of: editing) { _, isEditing in
                    if !isEditing, let threshold = draftThreshold {
                        draftThreshold = nil
                        onEdit { $0.threshold = threshold }
                    }
                }
                Button(action: onDelete) {
                    Image(systemName: "trash.fill").foregroundStyle(.red)
                        .frame(width: 30, height: 30).background(Circle().fill(.red.opacity(0.2)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete \(alert.kind.rawValue) \(alert.threshold)% alert")
            }
            .padding(12)
            .accessibilityElement(children: .contain)
        }
    }
}

/// The editor behind a card's gear: the alert's threshold, position, Border Glow, and Sound.
/// Each control changes its one field and the card follows; the threshold waits for the popover to close.
private struct AlertEditor: View {
    let alert: Alert
    @Binding var draftThreshold: Int?
    let onEdit: (@escaping (inout Alert) -> Void) -> Void

    var body: some View {
        SettingCard {
            SettingRow(title: "Threshold", description: alert.kind == .low ? "Below this level" : "At or above this level") {
                Stepper("\(threshold.wrappedValue)%", value: threshold, in: 1...100)
            }
            SettingRow(title: "Position") {
                SegmentedPills(selection: binding(\.position), options: Alert.Position.allCases, accent: .green, title: \.title)
            }
            SettingRow(title: "Border Glow", description: "Light the screen edges") {
                AccentSwitch(isOn: binding(\.glow), tint: .green, label: "Border Glow")
            }
            SettingRow(title: "Sound", description: "Play a sound") {
                AccentSwitch(isOn: binding(\.sound), tint: .green, label: "Sound")
            }
        }
        .frame(width: 400)
        .padding(12)
    }

    private var threshold: Binding<Int> {
        Binding(get: { draftThreshold ?? alert.threshold }, set: { draftThreshold = $0 })
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<Alert, Value>) -> Binding<Value> {
        Binding(get: { alert[keyPath: keyPath] }, set: { value in onEdit { $0[keyPath: keyPath] = value } })
    }
}
