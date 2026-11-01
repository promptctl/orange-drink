import SwiftUI

/// The expanded Connected Devices card: one row per device under inset hairlines.
struct ConnectedDevicesView: View {
    let connected: ConnectedDevices

    var body: some View {
        let rows = connected.rows
        if rows.isEmpty {
            note(connected.emptyNote)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().padding(.leading, 34) }
                    DeviceRowView(row: row)
                }
            }
        }
    }

    private func note(_ text: Phrase) -> some View {
        PhraseText(text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DeviceRowView: View {
    let row: DeviceRow

    private var tint: Color { row.tone == .nearlyFull ? .green : Color.veil(0.7) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: row.kind.symbol).frame(width: 24).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(spacing: 6) {
                HStack {
                    Text(row.name).lineLimit(1)
                    Spacer()
                    Text(row.percent).fontWeight(.bold).foregroundStyle(tint)
                }
                LevelBar(fraction: row.fraction, tint: tint)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}
