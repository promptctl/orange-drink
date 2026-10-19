import Foundation
import Observation
import os

/// The settings the user edited and the engine running over them, fed by the battery's readings.
///
/// [LAW:one-source-of-truth] `settings` is the live copy views observe, written through to the
/// store on every change, with this the only writer.
@Observable @MainActor final class AlertCenter {
    private static let log = Logger(subsystem: IOKitBattery.logSubsystem, category: "alerts")

    private(set) var settings: AlertSettings
    @ObservationIgnored private let store: AlertSettingsStore
    @ObservationIgnored private var engine = AlertEngine()
    @ObservationIgnored private var deviceEngine = DeviceAlertEngine()
    /// Where a firing goes to be shown; the pill, glow, and sound subscribe here.
    @ObservationIgnored private let deliver: @MainActor (Firing, BatteryReading) -> Void
    /// Where a watched device's firing goes to be shown.
    @ObservationIgnored private let deliverDevice: @MainActor (DeviceFiring) -> Void

    /// [LAW:no-silent-failure] Stored settings that do not decode fail the launch loudly.
    init(
        store: AlertSettingsStore, deliver: @escaping @MainActor (Firing, BatteryReading) -> Void,
        deliverDevice: @escaping @MainActor (DeviceFiring) -> Void = { _ in }
    ) throws {
        self.store = store
        self.deliver = deliver
        self.deliverDevice = deliverDevice
        settings = try store.load()
    }

    func update(_ edit: (inout AlertSettings) -> Void) throws {
        var edited = settings
        edit(&edited)
        try store.save(edited)
        settings = edited
    }

    /// A Mac with no battery has no level to cross.
    func observe(_ reading: BatteryReading?) {
        guard let reading else { return }
        let fired = engine.observe(reading, alerts: settings.alerts, power: settings.power)
        // [LAW:dataflow-not-control-flow] The engine tracks crossings with the switch off too, so
        // switching it on at 15% does not fire a stale 20% alert; the switch only empties delivery.
        let delivered = settings.enabled ? fired : []
        for firing in fired {
            Self.log.info("""
                alert \(delivered.isEmpty ? "suppressed by master switch" : "fired", privacy: .public): \
                \(firing.description, privacy: .public) at \(reading.chargePercent)%
                """)
        }
        for firing in delivered { deliver(firing, reading) }
    }

    /// The devices whose bell is on, held to the low alerts. [LAW:dataflow-not-control-flow] As with
    /// the battery, tracking runs with the master switch off too; the switch only empties delivery.
    func observe(devices: DeviceList, watching: Set<DeviceID>) {
        let fired = deviceEngine.observe(devices, watching: watching, alerts: settings.alerts)
        let delivered = settings.enabled ? fired : []
        for firing in fired {
            Self.log.info("""
                device alert \(delivered.isEmpty ? "suppressed by master switch" : "fired", privacy: .public): \
                \(firing.description, privacy: .private)
                """)
        }
        for firing in delivered { deliverDevice(firing) }
    }
}
