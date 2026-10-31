import SwiftUI

/// [LAW:one-source-of-truth] What a control that rests on a system setting shows under itself when it cannot act: how to fix
/// a failure the user can, with the way to the setting, what went wrong otherwise. The control supplies its own sentence,
/// and `fix` only when that setting is the fix.
struct SystemSettingFailureLine: View {
    /// The way to the setting.
    struct Fix {
        let title: Phrase
        let open: () -> Void

        static let loginItemsTitle: Phrase = "Open Login Items & Extensions…"
        static let accessibilityTitle: Phrase = "Open Accessibility Settings…"

        static func loginItems(_ open: @escaping () -> Void) -> Fix { Fix(title: loginItemsTitle, open: open) }
        static func accessibility(_ open: @escaping () -> Void) -> Fix { Fix(title: accessibilityTitle, open: open) }
    }

    let explanation: Phrase
    let fix: Fix?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let text = PhraseText(explanation)
            if let fix {
                text.fixedSize(horizontal: false, vertical: true)
                Button { fix.open() } label: { PhraseText(fix.title) }
                    .buttonStyle(.link)
            } else {
                text.foregroundStyle(.red).lineLimit(3)
            }
        }
        .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
    }
}
