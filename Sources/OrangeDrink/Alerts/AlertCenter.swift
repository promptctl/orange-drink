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
    /// Where a firing goes to be shown; the pill, glow, and sound subscribe here.
    @ObservationIgnored private let deliver: @MainActor (Alert) -> Void

    /// [LAW:no-silent-failure] Stored settings that do not decode fail the launch loudly.
    init(store: AlertSettingsStore, deliver: @escaping @MainActor (Alert) -> Void) throws {
        self.store = store
        self.deliver = deliver
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
        let crossed = engine.observe(level: reading.chargePercent, alerts: settings.alerts)
        // [LAW:dataflow-not-control-flow] The engine tracks crossings with the switch off too, so
        // switching it on at 15% does not fire a stale 20% alert; the switch only empties delivery.
        let delivered = settings.enabled ? crossed : []
        for alert in crossed {
            Self.log.info("""
                alert \(delivered.isEmpty ? "suppressed by master switch" : "fired", privacy: .public): \
                \(alert.kind.rawValue, privacy: .public) \(alert.threshold)% at \(reading.chargePercent)% \
                position \(alert.position.rawValue, privacy: .public) glow \(alert.glow) sound \(alert.sound)
                """)
        }
        for alert in delivered { deliver(alert) }
    }
}
