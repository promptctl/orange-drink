import SwiftUI

/// [LAW:one-source-of-truth] What a helper-backed control shows under itself when the helper did not act: how to fix a
/// failure the user can (allow the helper, with the way to the setting), what went wrong otherwise. The control
/// supplies its own sentence and the action that opens the setting.
struct HelperFailureLine: View {
    let failure: HelperUseFailure
    let explanation: Phrase
    let openLoginItems: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let text = PhraseText(explanation)
            if failure.needsApproval {
                text.fixedSize(horizontal: false, vertical: true)
                Button { openLoginItems() } label: { PhraseText(LowPowerMode.openLoginItemsTitle) }
                    .buttonStyle(.link)
            } else {
                text.foregroundStyle(.red).lineLimit(3)
            }
        }
        .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
    }
}
