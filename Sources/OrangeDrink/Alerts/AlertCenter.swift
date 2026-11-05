import Foundation
import Observation
import os

/// The settings the user edited and the engine running over them, fed by the battery's readings.
///
/// [LAW:one-source-of-truth] `model` keeps the settings; the Alerts screen edits them through it, and
/// the engines read them from it.
@Observable @MainActor final class AlertCenter {
    @ObservationIgnored let model: AlertSettingsModel
    @ObservationIgnored private let log: Logger
    var settings: AlertSettings { model.value }
    @ObservationIgnored private var engine = AlertEngine()
    @ObservationIgnored private var deviceEngine = DeviceAlertEngine()
    /// Where each reading's firings go to be shown, with the adapter change it brought.
    @ObservationIgnored private let deliver: @MainActor (ReadingAlerts) -> Void
    /// Where a watched device's firing goes to be shown.
    @ObservationIgnored private let deliverDevice: @MainActor (DeviceFiring) -> Void

    /// [LAW:no-silent-failure] Stored settings that do not decode fail the launch loudly.
    init(
        defaults: UserDefaults, log: Logger, deliver: @escaping @MainActor (ReadingAlerts) -> Void,
        deliverDevice: @escaping @MainActor (DeviceFiring) -> Void = { _ in }
    ) throws {
        self.log = log
        self.deliver = deliver
        self.deliverDevice = deliverDevice
        model = try AlertSettingsModel(defaults: defaults)
    }

    /// A Mac with no battery has no level to cross.
    func observe(_ reading: BatteryReading?) {
        guard let reading else { return }
        let fired = engine.observe(reading, alerts: settings.alerts, power: settings.power)
        // [LAW:dataflow-not-control-flow] The engine tracks crossings with the switch off too, so
        // switching it on at 15% does not fire a stale 20% alert; the switch only empties the firings,
        // so the adapter change still reaches a full-screen alert already up.
        let delivered = settings.enabled ? fired.firings : []
        for firing in fired.firings {
            log.info("""
                alert \(delivered.isEmpty ? "suppressed by master switch" : "fired", privacy: .public): \
                \(firing.description, privacy: .public) at \(reading.chargePercent)%
                """)
        }
        deliver(ReadingAlerts(reading: reading, changes: fired.changes, firings: delivered))
    }

    /// The devices whose bell is on, held to the low alerts. [LAW:dataflow-not-control-flow] As with
    /// the battery, tracking runs with the master switch off too; the switch only empties delivery.
    func observe(devices: DeviceList, watching: Set<DeviceID>) {
        let fired = deviceEngine.observe(devices, watching: watching, alerts: settings.alerts)
        let delivered = settings.enabled ? fired : []
        for firing in fired {
            log.info("""
                device alert \(delivered.isEmpty ? "suppressed by master switch" : "fired", privacy: .public): \
                \(firing.description, privacy: .private)
                """)
        }
        for firing in delivered { deliverDevice(firing) }
    }
}
