import Foundation

/// The Connected Devices card's rows, derived from the live device list.
///
/// [LAW:one-source-of-truth] Nothing here is stored: the rows are recomputed from `DeviceList` on
/// every render, so they cannot disagree with it.
struct ConnectedDevices: Equatable {
    struct Row: Equatable, Identifiable {
        enum Tone: Equatable { case normal, nearlyFull }

        let id: DeviceID
        let name: String
        let kind: DeviceKind
        /// "37%", or "~50%" when the level is only approximate.
        let percent: String
        let fraction: Double
        let tone: Tone
    }

    /// From this level up a device is nearly full and its bar turns green.
    static let nearlyFull = 90

    /// Lowest level first, so the device that needs charging is at the top; equal levels keep the
    /// list's stable name order.
    let rows: [Row]

    init(_ list: DeviceList) {
        rows = list.devices
            .compactMap { device in device.levels.lowest.map { (device, $0) } }
            .sorted { $0.1.percent < $1.1.percent }
            .map { device, level in
                Row(id: device.id, name: device.name, kind: device.kind,
                    percent: "\(level.approximate ? "~" : "")\(level.percent)%",
                    fraction: Double(level.percent) / 100,
                    tone: level.percent >= Self.nearlyFull ? .nearlyFull : .normal)
            }
    }
}
