import Foundation

/// One device's line on a screen that lists batteries: what it is called, what kind it is, and its level.
struct DeviceRow: Equatable, Identifiable {
    enum Tone: Equatable { case normal, nearlyFull }

    let id: DeviceID
    let name: String
    let kind: DeviceKind
    /// "37%", or "~50%" when the level is only approximate.
    let percent: String
    let fraction: Double
    let tone: Tone
}

/// [LAW:one-source-of-truth] The one ranking of the live device list: every device that reports a
/// level, lowest first, so the one that needs charging is on top. The panel and the Devices screen
/// both read it, so the two lists cannot disagree about order.
enum DeviceRanking {
    /// From this level up a device is nearly full and its bar turns green.
    static let nearlyFull = 90

    /// Equal levels fall in name then address order, so a row never reshuffles between renders.
    static func rows(_ list: DeviceList) -> [DeviceRow] {
        list.devices
            .compactMap { device in device.levels.lowest.map { (device, $0) } }
            .sorted { ($0.1.percent, $0.0.name, $0.0.id.address) < ($1.1.percent, $1.0.name, $1.0.id.address) }
            .map { device, level in
                DeviceRow(id: device.id, name: device.name, kind: device.kind,
                          percent: "\(level.approximate ? "~" : "")\(level.percent)%",
                          fraction: Double(level.percent) / 100,
                          tone: level.percent >= nearlyFull ? .nearlyFull : .normal)
            }
    }
}

/// The panel's Connected Devices card: the ranked devices the user has not hidden, and whether the
/// card is there at all.
struct ConnectedDevices: Equatable {
    let isShown: Bool
    let rows: [DeviceRow]
    /// Devices that report a level but are hidden from this card, so an empty card can say why.
    let hiddenCount: Int

    init(_ list: DeviceList, settings: DeviceSettings) {
        isShown = settings.showConnectedDevices
        let ranked = DeviceRanking.rows(list)
        rows = ranked.filter { !settings.hidden.contains($0.id) }
        hiddenCount = ranked.count - rows.count
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
    }

    let entries: [Entry]

    init(_ list: DeviceList, settings: DeviceSettings) {
        entries = DeviceRanking.rows(list).map { Entry(row: $0, isHidden: settings.hidden.contains($0.id), isAlerting: settings.alerting.contains($0.id),
                      isPinned: settings.pinned.contains($0.id)) }
    }
}
