import SwiftUI

/// What every card of devices says beside its rows: why it has none when that is true, then which sources have not delivered.
/// [LAW:single-enforcer] The one drawer of a `ListNotes`, so Connected Devices, Detected Devices and Pinned Devices cannot
/// differ about it, and a surface that lists devices from the same list inherits it by holding the notes.
struct ListNotesView: View {
    let rowsAreEmpty: Bool
    let notes: ListNotes
    var font: Font = .body

    /// With no line to say the view is absent, not an empty stack: the parent stack spaces an empty child as it spaces a full one.
    @ViewBuilder var body: some View {
        let lines = notes.lines(rowsAreEmpty: rowsAreEmpty)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in PhraseText(line) }
            }
            .font(font)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
