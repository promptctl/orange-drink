import SwiftUI

/// design-docs/charging.md: the Charge Limit switch, its explanation, and, while it is on, the target. `ChargeHold`
/// holds the battery at the target; this screen shows why it could not, while the switch is on.
struct ChargingScreen: View {
    let limit: ChargeLimitModel
    let hold: AppChargeHold
    @Environment(\.controlActiveState) private var window

    static let limitHelp: Phrase = "When the battery reaches your target, charging pauses and your Mac runs on the charger. Charging resumes once the level drops below the target. Turn the limit off, or quit \(appName), and your Mac charges normally."

    /// [LAW:one-source-of-truth] What the screen says under the switch about a failure, as it shows it and the catalog
    /// test reads it: how to fix one the user can fix, what went wrong otherwise.
    static func explanation(of failure: HelperUseFailure, appName: String) -> Phrase {
        switch failure.cause {
        case .needsApproval: "Allow \(appName) in the background to hold the charge limit."
        case .notRegistered, .notAnswering: "\(appName)'s helper isn't answering, so the charge limit isn't held."
        case .other: "Couldn't hold the charge limit: \(failure.call.description)"
        }
    }

    var body: some View {
        SettingEditor(limit) { edits in
            SettingCard {
                SettingRow(icon: ("bolt.heart.fill", .green), title: "Charge Limit",
                           description: "Pause charging at your target so the battery sits in a healthier range.") {
                    InfoButton(text: Self.limitHelp)
                    AccentSwitch(isOn: edits.binding(\.isOn), tint: .green, label: "Charge Limit")
                }
                if edits.value.isOn {
                    if let failure = hold.failure {
                        HelperFailureLine(failure: failure, explanation: Self.explanation(of: failure, appName: appName),
                                          openLoginItems: { hold.openLoginItems() })
                            .padding(.horizontal, 16).padding(.bottom, 10)
                    }
                    SettingRow(title: "Target", description: "Charging pauses at this level") {
                        PopUpButton(selection: edits.binding(\.target), options: ChargeTarget.all, title: { Text("\($0.percent)%") })
                    }
                }
            }
        }
        .padding(24)
        // The user may have allowed the helper in System Settings meanwhile: the screen appearing, or its own window
        // coming back to the front, asks again about a failure it holds.
        .onAppear { hold.recheck() }
        .onChange(of: window) { _, state in if state == .key { hold.recheck() } }
    }
}
