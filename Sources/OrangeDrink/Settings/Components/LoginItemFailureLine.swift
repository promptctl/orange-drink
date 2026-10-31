import SwiftUI

/// [LAW:one-source-of-truth] What a control that rests on a login item shows under itself when it did not act: how to fix a
/// failure the user can, with the way to the setting, what went wrong otherwise. The control supplies its own sentence, and
/// `openLoginItems` only when that setting is the fix.
struct LoginItemFailureLine: View {
    let explanation: Phrase
    let openLoginItems: (() -> Void)?

    /// The way to the setting that allows a login item.
    static let openLoginItemsTitle: Phrase = "Open Login Items & Extensions…"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let text = PhraseText(explanation)
            if let openLoginItems {
                text.fixedSize(horizontal: false, vertical: true)
                Button { openLoginItems() } label: { PhraseText(Self.openLoginItemsTitle) }
                    .buttonStyle(.link)
            } else {
                text.foregroundStyle(.red).lineLimit(3)
            }
        }
        .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
    }
}
