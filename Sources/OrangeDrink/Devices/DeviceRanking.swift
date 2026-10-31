import Foundation

/// One device's line on a screen that lists batteries: what it is called, what kind it is, and its level.
struct DeviceRow: Equatable, Identifiable {
    enum Tone: Equatable { case normal, nearlyFull }

    let id: DeviceID
    let name: String
    let kind: DeviceKind
    /// nil when the device's levels are unknown this read.
    let level: BatteryLevel?

    var percent: String { BatteryLevel.text(level) }
    var fraction: Double { Double(level?.percent ?? 0) / 100 }
    var tone: Tone { level?.percent ?? 0 >= DeviceRanking.nearlyFull ? .nearlyFull : .normal }
}

/// [LAW:one-source-of-truth] The one ranking of the live device list: every device that reports a
/// level, lowest first, so the one that needs charging is on top, then every device whose levels are
/// unknown. The panel and the Devices screen both read it, so the two lists cannot disagree about order.
enum DeviceRanking {
    /// From this level up a device is nearly full and its bar turns green.
    static let nearlyFull = 90

    /// Equal levels fall in name then address order, so a row never reshuffles between renders. An
    /// unknown level keeps its row, below them: the device is still connected, and a pinned item keeps
    /// its place in the bar through an outage instead of showing a stale percent or leaving.
    static func rows(_ list: DeviceList) -> [DeviceRow] {
        list.devices
            .compactMap { device -> (Device, BatteryLevel?)? in
                switch device.levels {
                case .none: nil
                case .unread: (device, nil)
                case .single, .earbuds: device.levels.lowest.map { (device, $0) }
                }
            }
            .sorted { ($0.1?.percent ?? .max, $0.0.name, $0.0.id.address) < ($1.1?.percent ?? .max, $1.0.name, $1.0.id.address) }
            .map { device, level in
                DeviceRow(id: device.id, name: device.name, kind: device.kind, level: level)
            }
    }
}

/// The panel's Connected Devices card: the ranked devices the user has not hidden, and whether the
/// card is there at all.
struct ConnectedDevices: Equatable {
    let isShown: Bool
    let rows: [DeviceRow]
    /// [LAW:one-source-of-truth] Why the card has no rows.
    let emptyNote: Phrase

    init(_ list: DeviceList, settings: DeviceSettings) {
        isShown = settings.showConnectedDevices
        let ranked = DeviceRanking.rows(list)
        rows = ranked.filter { !settings.hidden.contains($0.id) }
        emptyNote = rows.count < ranked.count ? "Every device is hidden. Show them again in Settings → Devices."
            : list.permission.explanation ?? "No connected Bluetooth devices to show."
    }
}

/// The Devices screen's Detected Devices card: every ranked device, hidden or not.
struct DetectedDevices: Equatable {
    struct Entry: Equatable, Identifiable {
        let row: DeviceRow
        let isHidden: Bool
        let isAlerting: Bool
        let isPinned: Bool
        var id: DeviceID { row.id }

        /// What each of the row's toggle buttons does when pressed, said for the state the row is in.
        var alertingLabel: Phrase { isAlerting ? "Turn off battery alerts for \(row.name)" : "Turn on battery alerts for \(row.name)" }
        var pinnedLabel: Phrase { isPinned ? "Unpin \(row.name) from the menu bar" : "Pin \(row.name) to the menu bar" }
        var hiddenLabel: Phrase { isHidden ? "Show \(row.name) in the menu bar panel" : "Hide \(row.name) from the menu bar panel" }
    }

    let entries: [Entry]
    /// [LAW:one-source-of-truth] Why the card has no entries.
    let emptyNote: Phrase

    init(_ list: DeviceList, settings: DeviceSettings) {
        emptyNote = list.permission.explanation ?? "No connected Bluetooth devices report a battery."
        entries = DeviceRanking.rows(list).map { Entry(row: $0, isHidden: settings.hidden.contains($0.id), isAlerting: settings.alerting.contains($0.id),
                      isPinned: settings.pinned.contains($0.id)) }
    }
}
