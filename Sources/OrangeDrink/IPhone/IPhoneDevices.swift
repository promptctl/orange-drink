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
        /// Why the device's identity could not be read, from the latest failed read of a device with no identity. It is the
        /// device's reachability's, so it ends with it, and `identified` ends it.
        var unread: IPhoneMissing?
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

    /// The kinds of device this source reaches and cannot list: a reachable device whose identity read failed is not listed
    /// (it would be listed under its UDID, then under its Bluetooth claim, and lose a bell or pin in between), so the list is
    /// told of it here instead.
    private var missing: Set<IPhoneMissing> { Set(reachable.values.compactMap(\.unread)) }

    /// The device list's events for one reader event: the device's, then the whole of what is missing when the event changed it.
    /// [LAW:one-source-of-truth] This is the one owner of what the source cannot list, and it restates it whole, so the list
    /// holds the last thing said and no event of a device has to clear it. Derived from before and after, so no second copy of
    /// what was last said is kept.
    mutating func apply(_ event: IPhoneEvent) -> [DeviceEvent] {
        let before = missing
        let device = deviceEvent(event)
        return [device].compactMap { $0 } + (missing == before ? [] : [.missing(missing)])
    }

    /// The device's event for one reader event, or nil when it says nothing the list holds. A read, a failed read or an
    /// identity for a device that is not reachable, such as one that lands after the cable left, says nothing and does not
    /// bring the device back.
    ///
    /// usbmuxd relists an iPhone on Wi-Fi every few seconds to minutes (orange-iphone-watch-lm3.1tt), so a Wi-Fi
    /// `unreachable` is a drop and not a departure: the device stays, its level unknown, and `DeviceAlertEngine`, which forgets a
    /// device that leaves the list, does not re-arm and fire again at the relist. Only the cable leaving with no Wi-Fi route
    /// left (`unreachable` after the cable) is a departure. A phone that truly leaves Wi-Fi stays listed until the app quits;
    /// whether and when it leaves is orange-device-sources-rec.q4w's. A phone never identified is in `reachable` and no more,
    /// so its note (`missing`) stays and leaves exactly as a listed device does.
    private mutating func deviceEvent(_ event: IPhoneEvent) -> DeviceEvent? {
        switch event {
        case .reachable(let udid, let transport):
            // A change of route is not a change of level: a held device keeps the level it last read.
            reachable[udid, default: Reachable(over: transport)].over = transport
            return reported(udid)
        case .identified(let udid, let identity):
            identities[udid] = identity
            reachable[udid]?.unread = nil
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
        case .readFailed(let udid, _, let error):
            // Connected, level unknown: what power management not answering means for a Bluetooth device.
            reachable[udid]?.levels = .unread
            // Identifying is the first thing a read does, so a failure with no identity held is the identity read's.
            if identities[udid] == nil { reachable[udid]?.unread = IPhoneMissing(error) }
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
                    devices.apply(event).forEach { continuation.yield($0) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }
}

extension IPhoneMissing {
    /// [LAW:parse-dont-validate] The one place a reader's error becomes a kind. Lockdown answers PasswordProtected while the
    /// phone is locked and InvalidHostID once it no longer trusts this Mac; usbmuxd holds no pair record for a phone that never
    /// did (`IPhoneReadError.refused`, `UsbmuxFrameError.noPairRecord`). Anything else is a phone reached and not read. What the
    /// error carries (a code, a string the device sent) is dropped here, so none of it can reach a surface.
    init(_ error: IPhoneReadError) {
        self = switch error {
        case .refused("PasswordProtected"): .locked
        case .refused("InvalidHostID"), .usbmux(.noPairRecord): .notTrusted
        default: .unreadable
        }
    }
}
