import Foundation
@preconcurrency import IOBluetooth
import os

/// Pushes every connected Bluetooth device's state to subscribers: when it connects, when it
/// disconnects, and once a minute while it is connected, because Bluetooth announces no level change.
enum BluetoothDevices {
    static let log = Logger(subsystem: IOKitBattery.logSubsystem, category: "devices")
    static let pollInterval = Duration.seconds(60)
    /// A device's battery arrives after it connects, with no event to say so, so a connect is
    /// followed by one more sweep once the first report has had time to land.
    static let settleInterval = Duration.seconds(5)

    /// [LAW:effects-at-boundaries] The one edge that talks to IOBluetooth. Spike
    /// orange-devices-bue.355 measured a sweep of every connected device at under a millisecond of
    /// CPU, so a sweep a minute is far inside PROJECT.md's 0.1% budget.
    ///
    /// [LAW:no-ambient-temporal-coupling] The registration, every sweep, and the unregistering are
    /// one task's business: IOBluetooth answers its first call with a synchronous XPC round trip
    /// and posts its notifications on a queue of its own, so none of it belongs on the main actor.
    static func events(
        timekeeper: any Timekeeper = SystemTimekeeper()
    ) -> AsyncThrowingStream<DeviceEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let watcher = Watcher(continuation: continuation, timekeeper: timekeeper)
                defer { watcher.stop() }
                do {
                    try watcher.start()
                    while true {
                        try await timekeeper.sleep(for: pollInterval)
                        watcher.sweep()
                    }
                } catch is CancellationError {
                    return
                } catch {
                    log.error("device subscription failed: \(String(describing: error), privacy: .public)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// [LAW:single-enforcer] The private selectors the edge reads, checked once at the border:
    /// a missing one is an OS this edge does not understand, which fails the subscription instead
    /// of reading as "no level" on every device.
    static let privateSelectors = [
        "getDisplayName", "batteryPercentSingle", "batteryPercentCombined",
        "batteryPercentLeft", "batteryPercentRight", "batteryPercentCase",
    ]

    /// Notifications arrive on IOBluetooth's queue while the task sweeps, so the registrations
    /// are held under a lock.
    private final class Watcher: NSObject, @unchecked Sendable {
        private let continuation: AsyncThrowingStream<DeviceEvent, any Error>.Continuation
        private struct Registrations {
            var connect: IOBluetoothUserNotification?
            /// Keyed by address: registering for a connect replays it for devices already connected.
            var disconnects: [String: IOBluetoothUserNotification] = [:]
        }
        private let registrations = OSAllocatedUnfairLock(uncheckedState: Registrations())

        private let timekeeper: any Timekeeper

        init(continuation: AsyncThrowingStream<DeviceEvent, any Error>.Continuation, timekeeper: any Timekeeper) {
            self.continuation = continuation
            self.timekeeper = timekeeper
        }

        func start() throws {
            for selector in BluetoothDevices.privateSelectors where !IOBluetoothDevice.instancesRespond(to: Selector(selector)) {
                throw BluetoothDevicesError.missingSelector(selector)
            }
            let connect = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
            guard let connect else { throw BluetoothDevicesError.registration }
            registrations.withLockUnchecked { $0.connect = connect }
            sweep()
        }

        func stop() {
            let held = registrations.withLockUnchecked { state in
                defer { state = Registrations() }
                return state
            }
            held.connect?.unregister()
            held.disconnects.values.forEach { $0.unregister() }
        }

        @objc private func connected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
            observe(device)
            // The stream's end makes this sweep's yield a no-op, so it needs no cancelling.
            Task { [timekeeper] in
                try? await timekeeper.sleep(for: BluetoothDevices.settleInterval)
                sweep()
            }
        }

        @objc private func disconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
            let id = DeviceID(address: device.addressString)
            registrations.withLockUnchecked { $0.disconnects.removeValue(forKey: id.address) }?.unregister()
            BluetoothDevices.log.info("device gone: \(id.address, privacy: .private)")
            continuation.yield(.gone(id))
        }

        func sweep() {
            let connected = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).filter { $0.isConnected() }
            connected.forEach(register)
            let devices = connected.map(Device.init)
            BluetoothDevices.log.info("device sweep: \(devices.count, privacy: .public) connected")
            continuation.yield(.swept(devices))
        }

        private func register(_ device: IOBluetoothDevice) {
            let address = device.addressString!
            guard registrations.withLockUnchecked({ $0.disconnects[address] == nil }),
                  let notification = device.register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:)))
            else { return }
            registrations.withLockUnchecked { $0.disconnects[address] = notification }
        }

        private func observe(_ device: IOBluetoothDevice) {
            register(device)
            let reading = Device(device)
            BluetoothDevices.log.info("device reported: \(String(describing: reading), privacy: .private)")
            continuation.yield(.reported(reading))
        }
    }
}

enum BluetoothDevicesError: Error, Equatable {
    case registration
    /// IOBluetooth no longer answers a private selector this edge reads (spike orange-devices-bue.355).
    case missingSelector(String)
}

private extension Device {
    /// [LAW:parse-dont-validate] The crossing from IOBluetooth's untyped device to a `Device`. The
    /// battery properties are private selectors, checked present at the border; a 0 means "not
    /// reported" and cannot be told from a drained battery, so it reads as no level.
    init(_ device: IOBluetoothDevice) {
        func level(_ key: String) -> BatteryLevel? {
            guard let percent = (device.value(forKey: key) as? NSNumber)?.intValue, percent > 0 else { return nil }
            return BatteryLevel(percent: percent, approximate: false)
        }
        // The name System Settings shows is the user's alias, which only the private getDisplayName
        // returns; `name` is the name the device broadcasts ("Beats Studio Buds +", not "Brandon’s Beats Studio Buds +").
        let name = device.perform(Selector(("getDisplayName")))?.takeUnretainedValue() as? String
            ?? device.name ?? device.addressString!
        let (left, right, `case`) = (level("batteryPercentLeft"), level("batteryPercentRight"), level("batteryPercentCase"))
        let levels: DeviceLevels
        if left != nil || right != nil || `case` != nil {
            levels = .earbuds(left: left, right: right, case: `case`)
        } else if let single = level("batteryPercentSingle") ?? level("batteryPercentCombined") {
            levels = .single(single)
        } else {
            levels = .none
        }
        self.init(
            // A paired device always has an address.
            id: DeviceID(address: device.addressString!),
            name: name,
            kind: .classify(majorClass: device.deviceClassMajor, name: name),
            levels: levels)
    }
}
