import SwiftUI

/// design-docs/charging.md: the Charge Limit switch, its explanation, and, while it is on, the target.
/// Holding the battery at the target is the job of whatever reads `ChargeLimitModel`, not this screen's.
struct ChargingScreen: View {
    let limit: ChargeLimitModel

    static let limitHelp: Phrase = "When the battery reaches your target, charging pauses and your Mac runs on the charger. Charging resumes once the level drops below the target. Turn the limit off, or quit \(appName), and your Mac charges normally."

    var body: some View {
        SettingEditor(limit) { edits in
            SettingCard {
                SettingRow(icon: ("bolt.heart.fill", .green), title: "Charge Limit",
                           description: "Pause charging at your target so the battery sits in a healthier range.") {
                    InfoButton(text: Self.limitHelp)
                    AccentSwitch(isOn: edits.binding(\.isOn), tint: .green, label: "Charge Limit")
                }
                if edits.value.isOn {
                    SettingRow(title: "Target", description: "Charging pauses at this level") {
                        PopUpButton(selection: edits.binding(\.target), options: ChargeTarget.all, title: { Text("\($0.percent)%") })
                    }
                }
            }
        }
        .padding(24)
    }
}
