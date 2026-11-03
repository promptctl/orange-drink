import Foundation

/// The iPhone reader's events as a device source: what the device list is told of the iPhones and iPads usbmuxd lists.
///
/// [LAW:one-source-of-truth] `DeviceList` stores the devices. This holds only what the events alone cannot restate: the
/// device to repeat when usbmuxd's listing is done, and the transport each device was last reachable over.
///
/// A device is named by its UDID and called a phone: the reader reads neither a name nor a model yet
/// (orange-device-sources-rec.0ex, which blocks the ticket that starts this source in the app).
struct IPhoneDevices {
    private struct Held {
        var device: SourceDevice
        /// The transport of the device's last `reachable` event. A read's own transport is where it started, and may
        /// be stale by the time it is delivered, so it never moves this.
        var over: Transport
    }

    private var held: [String: Held] = [:]

    /// The device list's event for one reader event, or nil when it says nothing the list holds.
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
            let levels = held[udid]?.device.levels ?? .unread
            return update(udid, over: transport, levels: levels)
        case .unreachable(let udid):
            guard let known = held[udid] else { return nil }
            switch known.over {
            case .usb:
                held[udid] = nil
                return .gone(known.device.id)
            case .network: return update(udid, over: known.over, levels: .unread)
            }
        case .reading(let udid, _, let reading):
            guard let known = held[udid] else { return nil }
            return update(udid, over: known.over, levels: .single(BatteryLevel(percent: reading.level, approximate: false)))
        case .readFailed(let udid, _, _):
            // Connected, level unknown: what power management not answering means for a Bluetooth device.
            guard let known = held[udid] else { return nil }
            return update(udid, over: known.over, levels: .unread)
        case .listed: return .swept(held.values.map(\.device))
        case .wifiSyncOn, .wifiSyncFailed, .failed: return nil
        }
    }

    private mutating func update(_ udid: String, over transport: Transport, levels: DeviceLevels) -> DeviceEvent {
        let device = SourceDevice(id: DeviceID(source: .iPhone, key: udid), name: udid, kind: .phone, levels: levels)
        held[udid] = Held(device: device, over: transport)
        return .reported(device)
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
