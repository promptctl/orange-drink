import Foundation

/// A watched device's level crossing one of the low alerts: what the pill and the chime are handed.
struct DeviceFiring: Equatable, Sendable, CustomStringConvertible {
    let alert: Alert
    let name: String
    let percent: Int

    var description: String { "\(name) \(percent)%: low \(alert.threshold)%" }
}

/// Decides which low alerts a device's new level sets off: each once per crossing, never for hovering.
///
/// [LAW:one-source-of-truth] A device is held to the same Low Battery alerts as the Mac's battery,
/// and the crossing, arming, and hysteresis rules are `AlertEngine`'s, once per device. This holds
/// only those engines; the alerts and which devices are watched arrive with every list.
/// [LAW:effects-at-boundaries] Pure state in, firings out.
struct DeviceAlertEngine: Equatable, Sendable {
    private var engines: [DeviceID: AlertEngine] = [:]

    /// Everything this list sets off. A device that is not watched, not connected, or reports no
    /// level is not observed, and one that is not watched or not connected is forgotten, so
    /// turning its bell on again at a low level is a first sighting, which announces nothing.
    mutating func observe(_ list: DeviceList, watching: Set<DeviceID>, alerts: [Alert]) -> [DeviceFiring] {
        let lows = alerts.filter { $0.kind == .low }
        let watched = list.devices.filter { watching.contains($0.id) }
        var next = engines.filter { id, _ in watched.contains { $0.id == id } }
        var firings: [DeviceFiring] = []
        for device in watched {
            guard let level = device.levels.lowest else { continue }
            var engine = next[device.id] ?? AlertEngine()
            firings += engine.observe(level: level.percent, alerts: lows)
                .map { DeviceFiring(alert: $0, name: device.name, percent: level.percent) }
            next[device.id] = engine
        }
        engines = next
        return firings
    }
}
