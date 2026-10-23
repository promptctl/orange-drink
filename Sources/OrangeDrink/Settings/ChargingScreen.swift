import AppKit
import SwiftUI

/// design-docs/charging.md: the Charge Limit switch, its explanation, and, while it is on, the target. `ChargeHold`
/// holds the battery at the target; this screen shows why it could not, while the switch is on.
struct ChargingScreen: View {
    let limit: ChargeLimitModel
    let hold: AppChargeHold

    static let limitHelp: Phrase = "When the battery reaches your target, charging pauses and your Mac runs on the charger. Charging resumes once the level drops below the target. Turn the limit off, or quit \(appName), and your Mac charges normally."

    /// [LAW:one-source-of-truth] What the screen says under the switch about a failure, as it shows it and the catalog
    /// test reads it: how to fix one the user can fix, what went wrong otherwise.
    static func explanation(of failure: HelperUseFailure, appName: String) -> Phrase {
        failure.needsApproval ? "Allow \(appName) in the background to hold the charge limit." : "Couldn't hold the charge limit: \(failure.call.description)"
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
                    if let failure = hold.failure { failureLine(failure) }
                    SettingRow(title: "Target", description: "Charging pauses at this level") {
                        PopUpButton(selection: edits.binding(\.target), options: ChargeTarget.all, title: { Text("\($0.percent)%") })
                    }
                }
            }
        }
        .padding(24)
        // The user may have allowed the helper in System Settings meanwhile: the screen appearing, or a window coming
        // back to the front while it shows, asks again about a failure it holds.
        .onAppear { hold.recheck() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in hold.recheck() }
    }

    /// A failure the user can fix says how; any other says what went wrong.
    private func failureLine(_ failure: HelperUseFailure) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            let explanation = PhraseText(Self.explanation(of: failure, appName: appName))
            if failure.needsApproval {
                explanation.fixedSize(horizontal: false, vertical: true)
                Button { hold.openLoginItems() } label: { PhraseText(LowPowerMode.openLoginItemsTitle) }
                    .buttonStyle(.link)
            } else {
                explanation.foregroundStyle(.red).lineLimit(3)
            }
        }
        .font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 10)
    }
}
