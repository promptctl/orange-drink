import SwiftUI

/// The pinned devices that have an item in the menu bar, top to bottom as the items sit left to
/// right, each with the neighbours it can trade places with.
struct PinnedDevicesList: Equatable {
    struct Entry: Equatable, Identifiable {
        let row: DeviceRow
        let above: DeviceID?
        let below: DeviceID?
        var id: DeviceID { row.id }
    }

    let entries: [Entry]

    init(_ list: DeviceList, pinned: PinnedOrder) {
        let rows = PinnedItem.items(list, pinned: pinned).map(\.row)
        entries = rows.indices.map { index in
            Entry(row: rows[index], above: rows.indices.contains(index - 1) ? rows[index - 1].id : nil,
                  below: rows.indices.contains(index + 1) ? rows[index + 1].id : nil)
        }
    }
}

/// design-docs/devices.md's pin line sends the user here: the pinned devices in the order their
/// items sit in the menu bar, to rearrange.
struct PinnedDevicesCard: View {
    let devices: DevicesModel
    let settings: DeviceSettingsModel
    @Environment(\.appLanguage) private var language

    var body: some View {
        SettingEditor(settings) { edits in
            let list = PinnedDevicesList(devices.list, pinned: edits.value.pinned)
            SettingsSectionHeader(symbol: "pin.fill", color: .orange, title: "Pinned Devices")
            if list.entries.isEmpty {
                Text("Pin a connected device from the Devices screen to arrange it here.").foregroundStyle(.secondary)
            } else {
                SettingCard {
                    ForEach(list.entries) { entry in
                        HStack(spacing: 12) {
                            Image(systemName: entry.row.kind.symbol).font(.system(size: 18)).frame(width: 28)
                                .foregroundStyle(.secondary).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.row.name).fontWeight(.semibold)
                                Text(entry.row.percent).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 12)
                            moveButton("chevron.up", "Move \(entry.row.name) up, toward the left of the menu bar", entry.id, with: entry.above, edits)
                            moveButton("chevron.down", "Move \(entry.row.name) down, toward the right of the menu bar", entry.id, with: entry.below, edits)
                        }
                        .padding(12)
                        .accessibilityElement(children: .contain)
                    }
                }
                Text("The top device sits leftmost in the menu bar. Dragging an item in the menu bar is undone when a pinned device connects, disconnects, or is moved here.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// A button that trades places with a neighbour, and is off when there is none on that side.
    private func moveButton(_ symbol: String, _ label: Phrase, _ id: DeviceID, with neighbour: DeviceID?, _ edits: SettingEdits<DeviceSettings>) -> some View {
        Button { if let neighbour { edits.perform { $0.pinned.swap(id, with: neighbour) } } } label: {
            Image(systemName: symbol).frame(width: 32, height: 32).background(Color.veil(0.1), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(neighbour == nil)
        .accessibilityLabel(label.text(in: language))
    }
}
