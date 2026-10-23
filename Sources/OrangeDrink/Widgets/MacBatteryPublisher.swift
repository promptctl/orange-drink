import Foundation
import os

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

/// Keeps the widget shelf holding what the widgets should draw, and asks them to redraw when it changes.
@MainActor final class MacBatteryPublisher {
    static let logCategory = "widgets"
    static let log = Logger(subsystem: IOKitBattery.logSubsystem, category: logCategory)

    private let directory: URL
    private let reload: @MainActor () -> Void

    /// [LAW:effects-at-boundaries] `reload` is the app's call into WidgetKit; a test passes a recorder.
    init(directory: URL, reload: @escaping @MainActor () -> Void) {
        self.directory = directory
        self.reload = reload
    }

    /// [LAW:one-source-of-truth] The shelf is the memory of what was published: a value it already
    /// holds costs no write and no reload, and another copy of the app that wrote over it (a test
    /// host quitting beside the installed app) is corrected by this one's next state. A shelf that
    /// cannot be read does not hold the value, so it is written.
    func publish(_ battery: MacBattery) {
        let value = String(describing: battery)
        let shelf = directory.path
        guard (try? WidgetShelf.read(from: directory).get()) != battery else {
            Self.log.info("widget shelf unchanged: \(value, privacy: .public) in \(shelf, privacy: .public)")
            return
        }
        do {
            try WidgetShelf.write(battery, to: directory)
            reload()
            Self.log.info("widget shelf written, reload asked: \(value, privacy: .public) in \(shelf, privacy: .public)")
        } catch {
            // [LAW:no-silent-failure] Logged; the shelf still differs, so the next state retries.
            Self.log.error("widget shelf write failed: \(value, privacy: .public) in \(shelf, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
