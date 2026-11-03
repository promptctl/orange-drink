import Foundation

/// The iPhone reader's events as a device source: what the device list is told of the iPhones and iPads usbmuxd lists.
///
/// [LAW:one-source-of-truth] `DeviceList` stores the devices. This holds only what the events alone cannot restate: the
/// device to repeat when usbmuxd's listing is done, the transport each device was last reachable over, and who each device said
/// it was.
///
/// A device is listed when it is reachable and its identity has been read: its name and kind come from the identity, and so
/// does the Bluetooth address that makes a phone one device with its Bluetooth twin (`SourceDevice.alsoBluetooth`). Every report of
/// a device is built from its identity, so the claim is on all of them and a device never changes identity between reports.
struct IPhoneDevices {
    /// A device usbmuxd lists now.
    private struct Reachable {
        /// The transport of the device's last `reachable` event. A read's own transport is where it started, and may
        /// be stale by the time it is delivered, so it never moves this.
        var over: Transport
        var levels = DeviceLevels.unread
    }

    private var reachable: [String: Reachable] = [:]
    /// Who each device said it was when last identified. It belongs to the device and not to its route, so it outlives a
    /// departure: the monitor's pacer rests through a short unplug and replug and reads the device again only when it wakes,
    /// and the device is listed again at once because its identity is still here.
    private var identities: [String: IPhoneIdentity] = [:]

    /// The device as the list is told of it: reachable and identified. The UDID names a device whose DeviceName is blank, as the
    /// address names a Bluetooth device whose name is (`Device.name`).
    private func device(_ udid: String) -> SourceDevice? {
        guard let route = reachable[udid], let identity = identities[udid] else { return nil }
        return SourceDevice(id: DeviceID(source: .iPhone, key: udid), name: Device.name(alias: nil, broadcast: identity.name, address: udid),
                            kind: identity.kind, levels: route.levels, alsoBluetooth: identity.bluetooth)
    }

    private func reported(_ udid: String) -> DeviceEvent? { device(udid).map(DeviceEvent.reported) }

    /// The device list's event for one reader event, or nil when it says nothing the list holds. A read, a failed read or an
    /// identity for a device that is not reachable, such as one that lands after the cable left, says nothing and does not
    /// bring the device back.
    ///
    /// usbmuxd relists an iPhone on Wi-Fi every few seconds to minutes (orange-iphone-watch-lm3.1tt), so a Wi-Fi
    /// `unreachable` is a drop and not a departure: the device stays, its level unknown, and `DeviceAlertEngine`, which forgets a
    /// device that leaves the list, does not re-arm and fire again at the relist. Only the cable leaving with no Wi-Fi route
    /// left (`unreachable` after the cable) is a departure. A phone that truly leaves Wi-Fi stays listed until the app quits;
    /// whether and when it leaves is orange-device-sources-rec.k69's.
    mutating func apply(_ event: IPhoneEvent) -> DeviceEvent? {
        switch event {
        case .reachable(let udid, let transport):
            // A change of route is not a change of level: a held device keeps the level it last read.
            reachable[udid, default: Reachable(over: transport)].over = transport
            return reported(udid)
        case .identified(let udid, let identity):
            identities[udid] = identity
            return reported(udid)
        case .unreachable(let udid):
            guard let known = reachable[udid] else { return nil }
            switch known.over {
            case .usb:
                let listed = device(udid)
                reachable[udid] = nil
                return listed.map { .gone($0.id) }
            case .network:
                reachable[udid]?.levels = .unread
                return reported(udid)
            }
        case .reading(let udid, _, let reading):
            reachable[udid]?.levels = .single(BatteryLevel(percent: reading.level, approximate: false))
            return reported(udid)
        case .readFailed(let udid, _, _):
            // Connected, level unknown: what power management not answering means for a Bluetooth device.
            reachable[udid]?.levels = .unread
            return reported(udid)
        case .listed: return .swept(reachable.keys.compactMap(device))
        case .wifiSyncOn, .wifiSyncFailed, .failed: return nil
        }
    }

    /// [LAW:composability] The device list's event stream for a reader's. The reader's terminal `failed` ends it by throwing
    /// the failure, so the list marks the source ended, as for any source. Ending the stream ends the reader: its consumer
    /// stops iterating.
    static func events(from reader: AsyncStream<IPhoneEvent>) -> AsyncThrowingStream<DeviceEvent, any Error> {
        AsyncThrowingStream { continuation in
            let pump = Task {
                var devices = IPhoneDevices()
                for await event in reader {
                    if case .failed(let error) = event {
                        continuation.finish(throwing: error)
                        return
                    }
                    if let mapped = devices.apply(event) { continuation.yield(mapped) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }
}
