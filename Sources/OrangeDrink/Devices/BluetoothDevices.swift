import CoreBluetooth
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

    /// The events the app subscribes to at launch. Every build is ad-hoc signed anew, so any launch
    /// that touches Bluetooth makes macOS ask for permission again, so the component gallery the
    /// UI tests launch hears no devices (and never finishes). A test host never builds the app (Main.swift).
    static func appEvents() -> AsyncThrowingStream<DeviceEvent, any Error> {
        #if DEBUG
        let forGallery = ProcessInfo.processInfo.arguments.contains(ComponentGallery.launchArgument)
        #else
        let forGallery = false
        #endif
        guard forGallery else { return events() }
        return AsyncThrowingStream { continuation in continuation.onTermination = { [continuation] _ in _ = continuation } }
    }

    /// [LAW:effects-at-boundaries] The one edge that talks to IOBluetooth, which says which devices are
    /// connected; their levels are power management's (`AccessoryPower`). Spike orange-devices-bue.355
    /// measured a sweep of every connected device at under a millisecond of CPU, and reading the accessory
    /// sources adds 0.1 ms (1e6), so a sweep a minute is far inside PROJECT.md's 0.1% budget.
    ///
    /// [LAW:no-ambient-temporal-coupling] The wait on the Bluetooth prompt, the registration, every timed
    /// sweep, and the unregistering are one loop's business, over one clock: each minute macOS is asked,
    /// and the answer decides. IOBluetooth's first call holds its thread until the prompt is answered, so
    /// nothing touches it before an answer of allowed. A prompt left open and a refusal both hold the list
    /// unread: nothing sweeps a Bluetooth that macOS refused, so a sweep means the list was read (`DeviceList`).
    /// Any answer but allowed stops the sweeps: an ask that went unanswered leaves the last answer standing.
    /// The registration runs on the main thread because that is the path shown to hear later connects:
    /// spike orange-distribution-kg2.73n registered from other threads too, but no device moved. Its
    /// notifications then post on a queue of its own, which is why the watcher is not main-actor isolated.
    static func events(
        timekeeper: any Timekeeper = SystemTimekeeper(),
        asks: @escaping @Sendable (any Timekeeper) -> AsyncStream<BluetoothPermission.Ask> = BluetoothPermission.asks(timekeeper:),
        log: Logger = BluetoothDevices.log,
        watcher: @escaping @Sendable (Events, any Timekeeper, Logger) throws -> any DeviceWatcher = { try liveWatcher($0, timekeeper: $1, log: $2) }
    ) -> AsyncThrowingStream<DeviceEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var state = Watching.held(nil)
                defer { if case .watching(let watcher) = state { watcher.stop() } }
                do {
                    for await ask in asks(timekeeper) {
                        state = try await state.advanced(by: ask, continuation, log: log) { try watcher(continuation, timekeeper, log) }
                    }
                } catch {
                    Watcher.fail(continuation, error, log: log)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    typealias Events = AsyncThrowingStream<DeviceEvent, any Error>.Continuation

    /// [LAW:one-source-of-truth] Whether reading is allowed and whether a watcher runs are one fact: this value.
    private enum Watching {
        /// No watcher, with the last permission the list was told, nil before the first.
        case held(BluetoothPermission?)
        case watching(any DeviceWatcher)

        /// A permission reaches the list only when it changes, because `.permission(.allowed)` means a sweep is awaited, and
        /// a minute must not say that of a list already read. A watcher stops before its refusal is reported, so no read follows it.
        func advanced(
            by ask: BluetoothPermission.Ask, _ continuation: Events, log: Logger, making watcher: () throws -> any DeviceWatcher
        ) async throws -> Watching {
            switch (self, ask) {
            case (.watching(let running), .heard(.allowed)), (.watching(let running), .stalled):
                running.sweep()
                return self
            case (.watching(let running), .heard(let permission)):
                running.stop()
                Self.report(permission, continuation, log: log)
                return .held(permission)
            case (.held, .heard(.allowed)):
                Self.report(.allowed, continuation, log: log)
                let started = try watcher()
                try await MainActor.run { try started.start() }
                log.notice("device watcher started")
                return .watching(started)
            case (.held(let reported), .heard(let permission)) where permission != reported:
                Self.report(permission, continuation, log: log)
                return .held(permission)
            case (.held, _):
                return self
            }
        }

        private static func report(_ permission: BluetoothPermission, _ continuation: Events, log: Logger) {
            if permission != .notDetermined {
                log.notice("bluetooth permission answered: \(String(describing: permission), privacy: .public)")
            }
            continuation.yield(.permission(permission))
        }
    }

    static func liveWatcher(_ continuation: Events, timekeeper: any Timekeeper, log: Logger) throws -> any DeviceWatcher {
        Watcher(continuation: continuation, timekeeper: timekeeper, reader: DeviceReader(sources: try AccessoryPower().read, log: log), log: log)
    }

    /// [LAW:single-enforcer] The private selectors the edge reads, checked once at the border:
    /// a missing one is an OS this edge does not understand, which fails the subscription instead
    /// of reading as the broadcast name on every device.
    static let privateSelectors = ["getDisplayName"]

    /// Notifications arrive on IOBluetooth's queue while the task sweeps, so the registrations
    /// are held under a lock.
    private final class Watcher: NSObject, DeviceWatcher, @unchecked Sendable {
        private let continuation: Events
        private struct Registrations {
            var connect: IOBluetoothUserNotification?
            /// Keyed by address: registering for a connect replays it for devices already connected.
            var disconnects: [String: IOBluetoothUserNotification] = [:]
            /// A settle sweep can outlive the stream; once stopped, nothing registers or sweeps again.
            var stopped = false
            /// One settle sweep serves every connect that arrives before it runs.
            var settlePending = false
        }
        private let registrations = OSAllocatedUnfairLock(uncheckedState: Registrations())
        /// [LAW:no-ambient-temporal-coupling] A sweep and a connect both read IOBluetooth and then
        /// yield, from different threads. Taking this around each whole read-register-yield keeps their
        /// events in the order the reads happened, and makes a registration check-then-set atomic.
        private let serial = NSLock()

        private let timekeeper: any Timekeeper
        private let reader: DeviceReader
        private let log: Logger

        init(continuation: Events, timekeeper: any Timekeeper, reader: DeviceReader, log: Logger) {
            self.log = log
            self.continuation = continuation
            self.timekeeper = timekeeper
            self.reader = reader
        }

        /// [LAW:no-silent-failure] An OS this edge does not understand ends the subscription, so the list
        /// goes `.ended`. A read powerd does not answer is a state of the levels, not an end (`DeviceReader`).
        static func fail(_ continuation: Events, _ error: any Error, log: Logger) {
            log.error("device subscription failed: \(String(describing: error), privacy: .public)")
            continuation.finish(throwing: error)
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

        /// [LAW:no-ambient-temporal-coupling] `serial` lets a read in flight finish, so no sweep or report follows this. The
        /// unregistering is outside it: a connect waits on `serial` on IOBluetooth's queue, and that queue may be what this waits on.
        func stop() {
            serial.lock()
            let held = registrations.withLockUnchecked { state in
                defer { state = Registrations(stopped: true) }
                return state
            }
            serial.unlock()
            held.connect?.unregister()
            held.disconnects.values.forEach { $0.unregister() }
            log.notice("device watcher stopped")
        }

        @objc private func connected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
            observe(device)
            let schedule = registrations.withLockUnchecked { state in
                defer { state.settlePending = true }
                return !state.settlePending && !state.stopped
            }
            guard schedule else { return }
            Task { [timekeeper] in
                try? await timekeeper.sleep(for: BluetoothDevices.settleInterval)
                registrations.withLockUnchecked { $0.settlePending = false }
                sweep()
            }
        }

        @objc private func disconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
            guard let id = DeviceID(device, log: log) else { return }
            registrations.withLockUnchecked { $0.disconnects.removeValue(forKey: id.key) }?.unregister()
            log.info("device gone: \(id.key, privacy: .private)")
            continuation.yield(.gone(id))
        }

        private var stopped: Bool { registrations.withLockUnchecked { $0.stopped } }

        func sweep() {
            serial.lock()
            defer { serial.unlock() }
            guard !stopped else { return }
            // nil is IOBluetooth's own answer for no paired devices (IOBluetoothDevice.h), not a read that failed.
            let connected = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).filter { $0.isConnected() }
            connected.forEach(register)
            continuation.yield(reader.sweep(connected.compactMap { BluetoothPeer($0, log: log) }))
        }

        private func register(_ device: IOBluetoothDevice) {
            guard let address = DeviceID(device, log: log)?.key else { return }
            guard registrations.withLockUnchecked({ $0.disconnects[address] == nil }),
                  let notification = device.register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:)))
            else { return }
            registrations.withLockUnchecked { $0.disconnects[address] = notification }
        }

        private func observe(_ device: IOBluetoothDevice) {
            serial.lock()
            defer { serial.unlock() }
            guard !stopped else { return }
            register(device)
            guard let peer = BluetoothPeer(device, log: log) else { return }
            continuation.yield(reader.report(peer))
        }
    }
}

/// What reads the connected devices while reading is allowed: the seam `BluetoothDevices.events` drives and a test stands in for.
protocol DeviceWatcher: Sendable {
    /// Registers for connects and sweeps once. Called on the main thread.
    func start() throws
    func sweep()
    /// Ends the watcher's reads: once this returns it sweeps and reports nothing more. A disconnect already in flight may
    /// still say `.gone`, which a list emptied by the refusal ignores.
    func stop()
}

enum BluetoothDevicesError: Error, Equatable {
    case registration
    /// IOBluetooth no longer answers a private selector this edge reads (spike orange-devices-bue.355).
    case missingSelector(String)
    /// IOKit no longer exports the private function `AccessoryPower` reads the accessories with.
    case missingSymbol(String)
}

private extension BluetoothPeer {
    /// [LAW:parse-dont-validate] The crossing from IOBluetooth's untyped device to a `BluetoothPeer`.
    ///
    /// [LAW:one-source-of-truth] IOBluetooth has battery properties of its own; they held one earbud of
    /// a set power management and system_profiler gave three parts for (1e6), so they are not read.
    init?(_ device: IOBluetoothDevice, log: Logger) {
        guard let id = DeviceID(device, log: log) else { return nil }
        // The name System Settings shows is the user's alias, which only the private getDisplayName
        // returns; `name` is the name the device broadcasts ("Beats Studio Buds +", not "Brandon’s Beats Studio Buds +").
        let name = Device.name(
            alias: device.perform(Selector(("getDisplayName")))?.takeUnretainedValue() as? String,
            broadcast: device.name, address: id.key)
        self.init(id: id, name: name, kind: .classify(majorClass: device.deviceClassMajor, name: name))
    }
}

private extension DeviceID {
    /// [LAW:parse-dont-validate] A connect notification can name a peer IOBluetooth has no address
    /// for yet ("No name or address"); such a peer cannot be told from another, so it is not a
    /// device. The next sweep sees it once it can be identified.
    init?(_ device: IOBluetoothDevice, log: Logger) {
        guard let address = device.addressString else {
            log.info("device skipped: no address yet")
            return nil
        }
        self.init(source: .bluetooth, key: address)
    }
}
