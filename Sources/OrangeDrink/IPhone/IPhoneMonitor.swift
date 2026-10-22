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

    /// True while the handle still belongs to this udid. A read that finishes after the cable came out is stale.
    func holds(handle: Int, udid: String) -> Bool { handles[handle] == .usb(udid: udid) }
}

enum IPhoneEvent {
    case reading(udid: String, IPhoneBatteryReading)
    case disconnected(udid: String)
    /// Non-terminal: this device's read failed; the stream keeps going.
    case readFailed(udid: String, IPhoneReadError)
    /// Terminal: the stream ends after this event.
    case failed(IPhoneReadError)
}

enum IPhoneMonitor {
    static let logCategory = "iphone"
    static let log = Logger(subsystem: IOKitBattery.logSubsystem, category: logCategory)

    /// Events for every iPhone and iPad usbmuxd reports. The stream ends after a `.failed` event.
    @available(macOS, deprecated: 10.15, message: "lockdown TLS is SecureTransport, the only client-identity TLS that lockdown accepts here; see lm3.8pk")
    static func events() -> AsyncStream<IPhoneEvent> {
        AsyncStream { continuation in
            let state = MonitorState(continuation: continuation, read: readIPhoneBattery(handle:udid:))
            continuation.onTermination = { _ in state.stop() }
            Thread { state.runListen() }.start()
        }
    }
}

/// Map, reads, and the output stream. Every method runs on `queue`, so the Listen thread and the read completions
/// see one ordered history of attaches, detaches, and reads. Every decision leaves one line in the log.
final class MonitorState: @unchecked Sendable {
    typealias Read = @Sendable (_ handle: Int, _ udid: String) throws(IPhoneReadError) -> IPhoneBatteryReading

    private let queue = DispatchQueue(label: "dev.orangedrink.iphone-monitor")
    private let continuation: AsyncStream<IPhoneEvent>.Continuation
    private let read: Read
    private var map = DeviceMap()
    private var stopped = false

    init(continuation: AsyncStream<IPhoneEvent>.Continuation, read: @escaping Read) {
        self.continuation = continuation
        self.read = read
    }

    func stop() { queue.async { self.stopped = true } }

    func runListen() {
        do {
            try typedReadErrors { try listen() }
        } catch {
            queue.sync { self.finish(with: error) }
        }
    }

    /// Subscribe first, then the snapshot. Listen events queue on the socket until the snapshot is applied, so an
    /// attach that lands in between is seen once: the snapshot entry and the Listen attach share a handle.
    private func listen() throws {
        let socket = try openUsbmux()
        let deadline = Deadline(after: callDeadline)
        try sendUsbmux(socket, ["MessageType": "Listen", "ClientVersionString": "orange-drink", "ProgName": "orange-drink"],
                       until: deadline)
        try usbmuxCheckResult(try readUsbmuxFrame(socket, until: deadline))

        let snapshot = try usbmuxDeviceList(try usbmuxRequest(["MessageType": "ListDevices",
                                                              "ClientVersionString": "orange-drink", "ProgName": "orange-drink"]))
        receive(snapshot: snapshot)

        var reader = UsbmuxFrameReader()
        while !isStopped() {
            guard let bytes = try socket.receiveSome(max: 4096) else { continue }
            reader.append(bytes)
            while let body = try reader.next() {
                receive(try usbmuxEvent(body))
            }
        }
    }

    /// The Listen thread's two inputs, each applied on the queue.
    func receive(snapshot: [AttachedDevice]) { queue.sync { snapshot.forEach { self.apply(attached: $0) } } }
    func receive(_ event: UsbmuxEvent) { queue.sync { self.apply(event) } }

    private func isStopped() -> Bool { queue.sync { stopped } }

    private func apply(_ event: UsbmuxEvent) {
        switch event {
        case .attached(let device): apply(attached: device)
        case .detached(let handle): apply(step: map.detach(handle: handle))
        case .other: break
        }
    }

    private func apply(attached device: AttachedDevice) { apply(step: map.attach(device)) }

    private func apply(step: DeviceMap.Step) {
        switch step {
        case .read(let handle, let udid):
            IPhoneMonitor.log.info("iphone attached: \(udid, privacy: .public) handle \(handle), reading")
            startRead(handle: handle, udid: udid)
        case .disconnected(let udid):
            IPhoneMonitor.log.info("iphone disconnected: \(udid, privacy: .public)")
            continuation.yield(.disconnected(udid: udid))
        case .nothing: break
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
