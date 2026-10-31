import Foundation
import os

/// Where the shelf publishers log. Not generic, so every widget's publisher shares the one category.
enum ShelfLog {
    static let category = "widgets"
    static let log = Logger(subsystem: IOKitBattery.logSubsystem, category: category)
}

extension MacBattery {
    /// What the widget draws for the model's state. [LAW:one-source-of-truth] The widget derives from
    /// the one battery subscription, as every view does.
    init(_ state: BatteryModel.State) {
        self = switch state {
        case .unknown: .waiting
        case .known(nil): .noBattery
        case .known(let reading?): .level(percent: reading.chargePercent, charging: reading.power.isCharging)
        case .ended: .ended
        }
    }
}

extension WidgetDevice {
    init(_ row: DeviceRow) {
        self.init(address: row.id.address, name: row.name, kind: row.kind, level: row.level)
    }

    /// The devices the widgets can draw. [LAW:one-source-of-truth] Derived from the one ranking the panel
    /// reads, so a widget shows the level the panel shows.
    static func list(_ devices: DeviceList) -> [WidgetDevice] {
        DeviceRanking.rows(devices).map(WidgetDevice.init)
    }
}

/// Keeps one shelf file holding what its widgets should draw, and asks WidgetKit to redraw each of them
/// when it changes.
@MainActor final class ShelfPublisher<Value: Codable & Equatable & Sendable> {
    private let item: WidgetShelf.Item<Value>
    private let directory: URL
    private let reload: @MainActor (WidgetKind) -> Void

    /// [LAW:effects-at-boundaries] `reload` is the app's call into WidgetKit, asked once per reader of
    /// the file; a test passes a recorder.
    init(item: WidgetShelf.Item<Value>, directory: URL, reload: @escaping @MainActor (WidgetKind) -> Void) {
        self.item = item
        self.directory = directory
        self.reload = reload
    }

    func publish(_ value: Value) { put(.running(value)) }

    /// The app is ending normally: its widgets say so rather than keep drawing the last value.
    func publishQuit() { put(.appNotRunning) }

    /// [LAW:one-source-of-truth] The shelf is the memory of what was published: a value it already
    /// holds costs no write and no reload, and another copy of the app that wrote over it (a test
    /// host quitting beside the installed app) is corrected by this one's next state. A shelf that
    /// cannot be read does not hold the value, so it is written.
    private func put(_ shelved: Shelved<Value>) {
        let value = String(describing: shelved)
        let shelf = directory.path
        guard (try? WidgetShelf.read(item, from: directory).get()) != shelved else {
            ShelfLog.log.info("widget shelf unchanged: \(value, privacy: .public) in \(shelf, privacy: .public)")
            return
        }
        do {
            try WidgetShelf.write(shelved, as: item, to: directory)
            item.readers.forEach(reload)
            let readers = item.readers.map(\.rawValue).joined(separator: ", ")
            ShelfLog.log.info("widget shelf written, reload asked: \(value, privacy: .public) in \(shelf, privacy: .public) for \(readers, privacy: .public)")
        } catch {
            // [LAW:no-silent-failure] Logged; the shelf still differs, so the next state retries.
            ShelfLog.log.error("widget shelf write failed: \(value, privacy: .public) in \(shelf, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
