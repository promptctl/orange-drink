import SwiftUI

/// What every card of devices says beside its rows: why it has none when that is true, then which sources have not delivered.
/// [LAW:single-enforcer] The one drawer of a `ListNotes`, so Connected Devices, Detected Devices and Pinned Devices cannot
/// differ about it, and a surface that lists devices from the same list inherits it by holding the notes.
struct ListNotesView: View {
    let rowsAreEmpty: Bool
    let notes: ListNotes
    var font: Font = .body

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if rowsAreEmpty, let empty = notes.empty { PhraseText(empty) }
            ForEach(Array(notes.unread.enumerated()), id: \.offset) { _, note in PhraseText(note) }
        }
        .font(font)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
