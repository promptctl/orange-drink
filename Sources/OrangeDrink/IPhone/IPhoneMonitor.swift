import Foundation
import os

// [LAW:one-source-of-truth] The handle map is the one record of what usbmuxd has attached. Whether a device is present,
// and which handle to read it over, are derived from it; every decision the monitor makes comes from the Steps it returns.
struct DeviceMap {
    enum Step: Equatable {
        /// Read the device now, then again every poll interval: it has just appeared, or has just trusted this Mac.
        case pace(udid: String)
        /// Switch on the device's Wi-Fi sync: it has just been plugged in.
        case enableWifiSync(handle: Int, udid: String)
        /// The device's last handle, cable or Wi-Fi, has gone.
        case disconnected(udid: String)
    }

    /// The handle a read goes over, and the transport behind it.
    struct Route: Equatable, Sendable {
        let handle: Int
        let transport: Transport
    }

    private(set) var handles: [Int: DeviceConnection] = [:]

    /// A handle already known is skipped, so one attach seen in both the snapshot and Listen counts once. A device's
    /// first handle starts its reads; a second (the cable beside Wi-Fi) only joins its routes.
    mutating func attach(_ device: AttachedDevice) -> [Step] {
        guard handles[device.handle] == nil else { return [] }
        handles[device.handle] = device.connection
        guard case .device(let udid, let transport) = device.connection else { return [] }
        let first = handles.values.filter { $0.udid == udid }.count == 1
        return (first ? [.pace(udid: udid)] : []) + Self.pluggedIn(handle: device.handle, udid: udid, over: transport)
    }

    /// A handle the map never saw is ignored: usbmuxd reports a detach for a device that attached before our Listen
    /// subscription and was already gone when the snapshot was taken. A device is disconnected when no handle holds it
    /// any more, so pulling the cable of a device still on Wi-Fi, or a stale detach applied after the snapshot (unplug and
    /// replug between Listen and ListDevices), leaves it present.
    mutating func detach(handle: Int) -> [Step] {
        guard let udid = handles.removeValue(forKey: handle)?.udid else { return [] }
        return route(udid) == nil ? [.disconnected(udid: udid)] : []
    }

    /// usbmuxd's Paired: the device on this handle has just trusted this Mac, so a read or a Wi-Fi sync switch that
    /// failed for want of a pair record can now succeed. Paired is the message libimobiledevice's usbmuxd sends on
    /// pairing; not yet observed from Apple's usbmuxd here, since no untrusted device was at hand.
    func paired(handle: Int) -> [Step] {
        guard case .device(let udid, let transport)? = handles[handle] else { return [] }
        return [.pace(udid: udid)] + Self.pluggedIn(handle: handle, udid: udid, over: transport)
    }

    /// Every Listen message, and every snapshot entry as an attach, comes through here.
    mutating func apply(_ event: UsbmuxEvent) -> [Step] {
        switch event {
        case .attached(let device): attach(device)
        case .detached(let handle): detach(handle: handle)
        case .paired(let handle): paired(handle: handle)
        case .other: []
        }
    }

    /// The handle to read a device over, or nil once it has gone. The cable wins over Wi-Fi; within one transport the
    /// newest handle wins, so a replug's fresh handle is read before a stale detach has removed the old one.
    func route(_ udid: String) -> Route? {
        handles.compactMap { handle, connection -> Route? in
            guard case .device(udid, let transport) = connection else { return nil }
            return Route(handle: handle, transport: transport)
        }.max { ($0.transport.preference, $0.handle) < ($1.transport.preference, $1.handle) }
    }

    /// True while the route's handle still belongs to this udid. A read over a handle that has since detached is stale.
    func holds(_ route: Route, udid: String) -> Bool { handles[route.handle] == .device(udid: udid, over: route.transport) }

    /// One decision as the log writes it: its steps in order, or "nothing".
    static func describe(_ steps: [Step]) -> String {
        steps.isEmpty ? "nothing" : steps.map { String(describing: $0) }.joined(separator: ", ")
    }

    /// Plugging a device in switches on its Wi-Fi sync, so it is still read once the cable is out.
    private static func pluggedIn(handle: Int, udid: String, over transport: Transport) -> [Step] {
        switch transport {
        case .usb: [.enableWifiSync(handle: handle, udid: udid)]
        case .network: []
        }
    }
}

private extension DeviceConnection {
    var udid: String? {
        switch self {
        case .device(let udid, _): udid
        case .other: nil
        }
    }
}

private extension Transport {
    /// The cable is preferred: it is faster, and it does not depend on the phone's Wi-Fi.
    var preference: Int {
        switch self {
        case .usb: 1
        case .network: 0
        }
    }
}

enum IPhoneEvent: Equatable {
    case reading(udid: String, over: Transport, IPhoneBatteryReading)
    /// The device's last handle, cable or Wi-Fi, has gone.
    case disconnected(udid: String)
    /// Non-terminal: this read failed; the device is read again after the poll interval.
    case readFailed(udid: String, over: Transport, IPhoneReadError)
    case wifiSyncOn(udid: String)
    /// Non-terminal: switching on Wi-Fi sync failed; it is tried again on the next plug-in.
    case wifiSyncFailed(udid: String, IPhoneReadError)
    /// Terminal: the stream ends after this event.
    case failed(IPhoneReadError)
}

/// Where the monitor's inputs come from: a connection already subscribed with Listen, the ListDevices snapshot, one
/// battery read, the Wi-Fi sync switch, and the clock reads are paced by. [LAW:effects-at-boundaries] events() passes
/// usbmuxd's and the system clock; tests pass a socketpair, stand-ins, and a clock they advance by hand.
struct MonitorInputs: Sendable {
    typealias Read = @Sendable (_ handle: Int, _ udid: String) throws(IPhoneReadError) -> IPhoneBatteryReading
    typealias EnableWifiSync = @Sendable (_ handle: Int, _ udid: String) throws(IPhoneReadError) -> Void
    let listen: @Sendable () throws -> TimedSocket
    let snapshot: @Sendable () throws -> [AttachedDevice]
    let read: Read
    let enableWifiSync: EnableWifiSync
    let timekeeper: any Timekeeper
}

enum IPhoneMonitor {
    static let logCategory = "iphone"
    static let log = Logger(subsystem: IOKitBattery.logSubsystem, category: logCategory)
    /// How long a device rests between the end of one read and the start of the next.
    static let pollInterval = Duration.seconds(60)

    /// Events for every iPhone and iPad usbmuxd reports, over the cable or over Wi-Fi.
    @available(macOS, deprecated: 10.15, message: "lockdown TLS is SecureTransport, the only client-identity TLS that lockdown accepts here; see lm3.8pk")
    static func events() -> AsyncStream<IPhoneEvent> {
        events(from: MonitorInputs(
            listen: usbmuxListen,
            snapshot: { try usbmuxDeviceList(try usbmuxRequest(["MessageType": "ListDevices", "ClientVersionString": "orange-drink",
                                                                "ProgName": "orange-drink"])) },
            read: readIPhoneBattery(handle:udid:),
            enableWifiSync: enableIPhoneWifiSync(handle:udid:),
            timekeeper: SystemTimekeeper()))
    }

    /// The stream ends after a `.failed` event, or when its consumer stops iterating.
    static func events(from inputs: MonitorInputs) -> AsyncStream<IPhoneEvent> {
        AsyncStream { continuation in
            let state = MonitorState(continuation: continuation, inputs: inputs)
            continuation.onTermination = { _ in state.stop() }
            Thread { state.run() }.start()
        }
    }
}

/// Map, pacers, and the output stream. Every method runs on `queue`, so the Listen thread, the pacers, and the
/// Wi-Fi sync completions see one ordered history of attaches, detaches, and reads. Every decision leaves one log line.
private final class MonitorState: @unchecked Sendable {
    /// One device's read loop. The token tells its outcomes from those of a pacer that replaced it.
    private struct Pacer {
        let token: UUID
        let task: Task<Void, Never>
    }

    /// [LAW:no-ambient-temporal-coupling] Whether read loops may run is this state, owned on the queue. Ending the
    /// monitor cancels every pacer and moves to `stopped`, where a Listen frame still being drained starts none.
    private enum Lifecycle {
        case running(pacers: [String: Pacer])
        case stopped
    }

    private let queue = DispatchQueue(label: "dev.orangedrink.iphone-monitor")
    private let continuation: AsyncStream<IPhoneEvent>.Continuation
    private let inputs: MonitorInputs
    private var map = DeviceMap()
    private var lifecycle = Lifecycle.running(pacers: [:])

    init(continuation: AsyncStream<IPhoneEvent>.Continuation, inputs: MonitorInputs) {
        self.continuation = continuation
        self.inputs = inputs
    }

    func stop() { queue.async { self.end() } }

    /// Subscribe first, then the snapshot. Listen events queue on the socket until the snapshot is applied, so an
    /// attach that lands in between is seen once: the snapshot entry and the Listen attach share a handle.
    func run() {
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

    private func isStopped() -> Bool {
        queue.sync {
            guard case .stopped = lifecycle else { return false }
            return true
        }
    }

    private func receive(_ event: UsbmuxEvent) {
        queue.sync {
            let steps = map.apply(event)
            IPhoneMonitor.log.info("iphone \(String(describing: event), privacy: .public) → \(DeviceMap.describe(steps), privacy: .public)")
            steps.forEach(perform)
        }
    }

    private func perform(_ step: DeviceMap.Step) {
        switch step {
        case .pace(let udid): startPacer(udid)
        case .enableWifiSync(let handle, let udid): startWifiSync(handle: handle, udid: udid)
        case .disconnected(let udid):
            if case .running(var pacers) = lifecycle {
                pacers.removeValue(forKey: udid)?.task.cancel()
                lifecycle = .running(pacers: pacers)
            }
            continuation.yield(.disconnected(udid: udid))
        }
    }

    /// Starts the device's read loop, replacing (and cancelling) any loop it already has.
    private func startPacer(_ udid: String) {
        guard case .running(var pacers) = lifecycle else {
            IPhoneMonitor.log.info("iphone pacer not started: \(udid, privacy: .public): monitor stopped")
            return
        }
        pacers[udid]?.task.cancel()
        let token = UUID()
        pacers[udid] = Pacer(token: token, task: Task { await self.pace(udid, token: token) })
        lifecycle = .running(pacers: pacers)
    }

    /// Read, deliver, rest, and again, until the device has no route or the loop is cancelled. The next read starts
    /// only after the last one finished, however long its deadlines let it run.
    private func pace(_ udid: String, token: UUID) async {
        while !Task.isCancelled, let route = queue.sync(execute: { map.route(udid) }) {
            let outcome = await read(over: route, udid: udid)
            queue.sync { deliver(outcome, udid: udid, over: route, token: token) }
            do { try await inputs.timekeeper.sleep(for: IPhoneMonitor.pollInterval) } catch { return }
        }
    }

    /// The read is a blocking call of up to several deadlines, so it runs off the queue and off the task's thread.
    private func read(over route: DeviceMap.Route, udid: String) async -> Result<IPhoneBatteryReading, IPhoneReadError> {
        await withCheckedContinuation { done in
            DispatchQueue.global(qos: .utility).async {
                do throws(IPhoneReadError) {
                    done.resume(returning: .success(try self.inputs.read(route.handle, udid)))
                } catch {
                    done.resume(returning: .failure(error))
                }
            }
        }
    }

    /// An outcome reaches the stream only from the device's current pacer, over a handle still attached.
    private func deliver(_ outcome: Result<IPhoneBatteryReading, IPhoneReadError>, udid: String, over route: DeviceMap.Route,
                         token: UUID) {
        guard case .running(let pacers) = lifecycle, pacers[udid]?.token == token else {
            IPhoneMonitor.log.info("iphone read dropped: \(udid, privacy: .public) handle \(route.handle): its pacer was replaced or stopped")
            return
        }
        guard map.holds(route, udid: udid) else {
            IPhoneMonitor.log.info("iphone read dropped: \(udid, privacy: .public) handle \(route.handle) detached before it finished")
            return
        }
        IPhoneMonitor.log.info("iphone read delivered: \(udid, privacy: .public) over \(String(describing: route.transport), privacy: .public)")
        switch outcome {
        case .success(let reading): continuation.yield(.reading(udid: udid, over: route.transport, reading))
        case .failure(let error): continuation.yield(.readFailed(udid: udid, over: route.transport, error))
        }
    }

    private func startWifiSync(handle: Int, udid: String) {
        DispatchQueue.global(qos: .utility).async {
            let event: IPhoneEvent
            do throws(IPhoneReadError) {
                try self.inputs.enableWifiSync(handle, udid)
                event = .wifiSyncOn(udid: udid)
            } catch {
                event = .wifiSyncFailed(udid: udid, error)
            }
            self.queue.async { self.continuation.yield(event) }
        }
    }

    /// Cancels every pacer; nothing starts another.
    private func end() {
        let pacers: [Pacer] = switch lifecycle {
        case .running(let pacers): Array(pacers.values)
        case .stopped: []
        }
        pacers.forEach { $0.task.cancel() }
        lifecycle = .stopped
        IPhoneMonitor.log.info("iphone monitor ended: \(pacers.count) pacers cancelled")
    }

    private func finish(with error: IPhoneReadError) {
        IPhoneMonitor.log.error("iphone monitor failed: \(String(describing: error), privacy: .public)")
        end()
        continuation.yield(.failed(error))
        continuation.finish()
    }
}
