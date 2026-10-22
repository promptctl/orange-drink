import Foundation
import os

// [LAW:one-source-of-truth] The handle map is the one record of what usbmuxd has attached. Every decision the
// monitor makes (read, disconnect, ignore) comes from a Step the map returns.
struct DeviceMap {
    enum Step: Equatable {
        case read(handle: Int, udid: String)
        case disconnected(udid: String)
        case nothing
    }

    private(set) var handles: [Int: DeviceConnection] = [:]

    /// A handle already known is skipped, so one attach seen in both the snapshot and Listen counts once.
    /// A USB device is read on attach; a Wi-Fi entry is not, since it is not the cable.
    mutating func attach(_ device: AttachedDevice) -> Step {
        guard handles[device.handle] == nil else { return .nothing }
        handles[device.handle] = device.connection
        switch device.connection {
        case .usb(let udid): return .read(handle: device.handle, udid: udid)
        case .network, .other: return .nothing
        }
    }

    /// A Wi-Fi entry going away is not the cable. A handle the map never saw is ignored: usbmuxd reports a detach
    /// for a device that attached before our Listen subscription and was already gone when the snapshot was taken.
    /// A device is disconnected when no cable handle holds it any more, so a stale detach applied after the snapshot
    /// (unplug and replug between Listen and ListDevices) does not disconnect a device still attached on its new handle.
    mutating func detach(handle: Int) -> Step {
        guard case .usb(let udid)? = handles.removeValue(forKey: handle) else { return .nothing }
        return handles.values.contains(.usb(udid: udid)) ? .nothing : .disconnected(udid: udid)
    }

    /// usbmuxd's Paired: the device on this handle has just trusted this Mac, so a read that failed for want of a pair
    /// record can now succeed. Paired is the message libimobiledevice's usbmuxd sends on pairing; not yet observed from
    /// Apple's usbmuxd here, since no untrusted device was at hand.
    func paired(handle: Int) -> Step {
        guard case .usb(let udid)? = handles[handle] else { return .nothing }
        return .read(handle: handle, udid: udid)
    }

    /// Every Listen message, and every snapshot entry as an attach, comes through here.
    mutating func apply(_ event: UsbmuxEvent) -> Step {
        switch event {
        case .attached(let device): attach(device)
        case .detached(let handle): detach(handle: handle)
        case .paired(let handle): paired(handle: handle)
        case .other: .nothing
        }
    }

    /// True while the handle still belongs to this udid. A read that finishes after the cable came out is stale.
    func holds(handle: Int, udid: String) -> Bool { handles[handle] == .usb(udid: udid) }
}

enum IPhoneEvent: Equatable {
    case reading(udid: String, IPhoneBatteryReading)
    case disconnected(udid: String)
    /// Non-terminal: this device's read failed; the stream keeps going.
    case readFailed(udid: String, IPhoneReadError)
    /// Terminal: the stream ends after this event.
    case failed(IPhoneReadError)
}

/// Where the monitor's inputs come from: a connection already subscribed with Listen, the ListDevices snapshot, and
/// one battery read. [LAW:effects-at-boundaries] events() passes usbmuxd's; tests pass a socketpair and stand-ins.
struct MonitorInputs: Sendable {
    typealias Read = @Sendable (_ handle: Int, _ udid: String) throws(IPhoneReadError) -> IPhoneBatteryReading
    let listen: @Sendable () throws -> TimedSocket
    let snapshot: @Sendable () throws -> [AttachedDevice]
    let read: Read
}

enum IPhoneMonitor {
    static let logCategory = "iphone"
    static let log = Logger(subsystem: IOKitBattery.logSubsystem, category: logCategory)

    /// Events for every iPhone and iPad usbmuxd reports.
    @available(macOS, deprecated: 10.15, message: "lockdown TLS is SecureTransport, the only client-identity TLS that lockdown accepts here; see lm3.8pk")
    static func events() -> AsyncStream<IPhoneEvent> {
        events(from: MonitorInputs(
            listen: usbmuxListen,
            snapshot: { try usbmuxDeviceList(try usbmuxRequest(["MessageType": "ListDevices", "ClientVersionString": "orange-drink",
                                                                "ProgName": "orange-drink"])) },
            read: readIPhoneBattery(handle:udid:)))
    }

    /// The stream ends after a `.failed` event, or when its consumer stops iterating.
    static func events(from inputs: MonitorInputs) -> AsyncStream<IPhoneEvent> {
        AsyncStream { continuation in
            let state = MonitorState(continuation: continuation, read: inputs.read)
            continuation.onTermination = { _ in state.stop() }
            Thread { state.run(inputs) }.start()
        }
    }
}

/// Map, reads, and the output stream. Every method runs on `queue`, so the Listen thread and the read completions
/// see one ordered history of attaches, detaches, and reads. Every decision leaves one line in the log.
private final class MonitorState: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.orangedrink.iphone-monitor")
    private let continuation: AsyncStream<IPhoneEvent>.Continuation
    private let read: MonitorInputs.Read
    private var map = DeviceMap()
    private var stopped = false

    init(continuation: AsyncStream<IPhoneEvent>.Continuation, read: @escaping MonitorInputs.Read) {
        self.continuation = continuation
        self.read = read
    }

    func stop() { queue.async { self.stopped = true } }

    /// Subscribe first, then the snapshot. Listen events queue on the socket until the snapshot is applied, so an
    /// attach that lands in between is seen once: the snapshot entry and the Listen attach share a handle.
    func run(_ inputs: MonitorInputs) {
        do {
            try typedReadErrors {
                let socket = try inputs.listen()
                try inputs.snapshot().forEach { receive(.attached($0)) }
                var reader = UsbmuxFrameReader()
                while !isStopped() {
                    guard let bytes = try socket.receiveSome(max: 4096) else { continue }
                    reader.append(bytes)
                    while let body = try reader.next() { receive(try usbmuxEvent(body)) }
                }
                IPhoneMonitor.log.info("iphone monitor stopped")
            }
        } catch {
            queue.sync { self.finish(with: error) }
        }
    }

    private func isStopped() -> Bool { queue.sync { stopped } }

    private func receive(_ event: UsbmuxEvent) {
        queue.sync {
            let step = map.apply(event)
            IPhoneMonitor.log.info("iphone \(String(describing: event), privacy: .public) → \(String(describing: step), privacy: .public)")
            switch step {
            case .read(let handle, let udid): startRead(handle: handle, udid: udid)
            case .disconnected(let udid): continuation.yield(.disconnected(udid: udid))
            case .nothing: break
            }
        }
    }

    /// The read is a blocking call of up to several deadlines, so it runs off the queue. Its result comes back on
    /// the queue, where the map can say whether the device is still attached.
    private func startRead(handle: Int, udid: String) {
        DispatchQueue.global(qos: .utility).async {
            let outcome: Result<IPhoneBatteryReading, IPhoneReadError>
            do throws(IPhoneReadError) {
                let reading = try self.read(handle, udid)
                outcome = .success(reading)
            } catch {
                outcome = .failure(error)
            }
            self.queue.async { self.finishRead(handle: handle, udid: udid, outcome: outcome) }
        }
    }

    private func finishRead(handle: Int, udid: String, outcome: Result<IPhoneBatteryReading, IPhoneReadError>) {
        guard map.holds(handle: handle, udid: udid) else {
            IPhoneMonitor.log.info("iphone read dropped: \(udid, privacy: .public) handle \(handle) detached before it finished")
            return
        }
        switch outcome {
        case .success(let reading): continuation.yield(.reading(udid: udid, reading))
        case .failure(let error): continuation.yield(.readFailed(udid: udid, error))
        }
    }

    private func finish(with error: IPhoneReadError) {
        IPhoneMonitor.log.error("iphone monitor failed: \(String(describing: error), privacy: .public)")
        stopped = true
        continuation.yield(.failed(error))
        continuation.finish()
    }
}
