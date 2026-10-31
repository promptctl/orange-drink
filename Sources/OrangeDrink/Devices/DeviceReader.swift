import Foundation

/// A connected device before its levels: what IOBluetooth says about it, as a value.
struct BluetoothPeer: Equatable, Sendable {
    let id: DeviceID
    let name: String
    let kind: DeviceKind
}

/// Joins connected devices to power management's levels, by the name System Settings shows.
///
/// [LAW:single-enforcer] A sweep and a connect both read here, so a read powerd does not answer is logged
/// once, in `reading`, whichever asked. Neither can end the subscription: the next read may answer, and
/// until then a device it could not read is `.unread`.
struct DeviceReader {
    let sources: () throws(PowerSourcesError) -> [[String: Any]]

    func sweep(_ peers: [BluetoothPeer]) -> DeviceEvent {
        let reading = reading()
        let devices = peers.map { device($0, reading) }
        if case .answered(let levels) = reading {
            let attribution = levels.attribution(of: devices.map(\.name))
            // The counts are public and the names, the user's own, private.
            BluetoothDevices.log.info("""
                device sweep: \(devices.count, privacy: .public) connected, \(levels.byName.count, privacy: .public) \
                accessory batteries; no battery for \(attribution.unlevelled.count, privacy: .public) \
                \(attribution.unlevelled, privacy: .private), unclaimed \(attribution.unclaimed.count, privacy: .public) \
                \(attribution.unclaimed, privacy: .private), unattributed \(levels.unattributed.count, privacy: .public) \
                \(levels.unattributed, privacy: .private)
                """)
        }
        return .swept(devices)
    }

    func report(_ peer: BluetoothPeer) -> DeviceEvent {
        let reported = device(peer, reading())
        BluetoothDevices.log.info("device reported: \(String(describing: reported), privacy: .private)")
        return .reported(reported)
    }

    private func device(_ peer: BluetoothPeer, _ reading: AccessoryPower.Reading) -> Device {
        Device(id: peer.id, name: peer.name, kind: peer.kind, levels: reading.levels(of: peer.name))
    }

    private func reading() -> AccessoryPower.Reading {
        do {
            return .answered(AccessoryPower.levels(from: try sources()))
        } catch {
            BluetoothDevices.log.error("device levels unread: \(String(describing: error), privacy: .public)")
            return .unanswered
        }
    }
}
