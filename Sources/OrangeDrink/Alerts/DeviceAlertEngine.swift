import Foundation

/// A watched device's level crossing one of the low alerts: what the pill and the chime are handed.
struct DeviceFiring: Equatable, Sendable, CustomStringConvertible {
    let alert: Alert
    let name: String
    let level: BatteryLevel

    var description: String { "\(name) \(BatteryLevel.text(level)): low \(alert.threshold)%" }
}

/// Decides which low alerts a device's new level sets off: each once per crossing, never for hovering.
///
/// [LAW:one-source-of-truth] A device is held to the same Low Battery alerts as the Mac's battery,
/// and the crossing, arming, and hysteresis rules are `AlertEngine`'s, once per device. This holds
/// only those engines; the alerts and which devices are watched arrive with every list.
/// [LAW:effects-at-boundaries] Pure state in, firings out.
struct DeviceAlertEngine: Equatable, Sendable {
    private var engines: [DeviceID: AlertEngine] = [:]

    /// What this list sets off for the devices being watched. Every connected device that reports a
    /// level is tracked, watched or not, as the battery is tracked with the master switch off, so
    /// turning a bell on at 21% still announces the fall to 19%; the bell only decides who is
    /// announced. A device that is not connected is forgotten.
    ///
    /// [LAW:dataflow-not-control-flow] Every device takes the same transitions on every list.
    mutating func observe(_ list: DeviceList, watching: Set<DeviceID>, alerts: [Alert]) -> [DeviceFiring] {
        let lows = alerts.filter { $0.kind == .low }
        let present = Set(list.devices.map(\.id))
        var next = engines.filter { present.contains($0.key) }
        var firings: [DeviceFiring] = []
        for device in list.devices {
            guard let level = device.levels.alertLevel else { continue }
            var engine = next[device.id] ?? AlertEngine()
            let crossed = engine.observe(level: level.percent, alerts: lows)
            next[device.id] = engine
            if watching.contains(device.id) {
                firings += crossed.map { DeviceFiring(alert: $0, name: device.name, level: level) }
            }
        }
        engines = next
        return firings
    }
}
