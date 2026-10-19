import SwiftUI

/// The expanded Connected Devices card: one row per device under inset hairlines.
struct ConnectedDevicesView: View {
    let devices: DevicesModel

    var body: some View {
        if devices.failure != nil {
            note("Device readings stopped. Quit and reopen the app.")
        } else {
            let rows = ConnectedDevices(devices.list).rows
            if rows.isEmpty {
                note("No connected Bluetooth devices to show.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().padding(.leading, 34) }
                        DeviceRow(row: row)
                    }
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DeviceRow: View {
    let row: ConnectedDevices.Row

    private var tint: Color { row.tone == .nearlyFull ? .green : .white.opacity(0.7) }

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

extension DeviceKind {
    /// An outline icon per kind: a phone, a tablet, or concentric arcs around a dot for audio and
    /// every other wireless accessory.
    var symbol: String {
        switch self {
        case .phone: "iphone"
        case .tablet: "ipad"
        case .accessory: "dot.radiowaves.left.and.right"
        }
    }
}
