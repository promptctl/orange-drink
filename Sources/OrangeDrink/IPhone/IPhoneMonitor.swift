import Foundation
import os

// [LAW:one-source-of-truth] The handle map is the one record of what usbmuxd has attached. Whether a device is present,
// and which handle to read it over, are derived from it; every decision the monitor makes comes from the Steps it returns.
struct DeviceMap {
    enum Step: Equatable {
        /// Read the device now, then again every poll interval: its route has just changed, or it has just trusted this Mac.
        case pace(udid: String)
        /// Switch on the device's Wi-Fi sync: its route has just become this cable.
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

    /// A handle already known is skipped, so one attach seen in both the snapshot and Listen counts once.
    mutating func attach(_ device: AttachedDevice) -> [Step] {
        guard handles[device.handle] == nil else { return [] }
        return edit(device.connection.udid) { $0[device.handle] = device.connection }
    }

    /// A handle the map never saw is ignored: usbmuxd reports a detach for a device that attached before our Listen
    /// subscription and was already gone when the snapshot was taken. Pulling the cable of a device still on Wi-Fi moves
    /// its route to Wi-Fi, and a stale detach applied after the snapshot (unplug and replug between Listen and
    /// ListDevices) leaves its route alone.
    mutating func detach(handle: Int) -> [Step] {
        edit(handles[handle]?.udid) { $0.removeValue(forKey: handle) }
    }

    /// usbmuxd's Paired: the device on this handle has just trusted this Mac, so a read or a Wi-Fi sync switch that
    /// failed for want of a pair record can now succeed. Both go over the device's route, as they do on attach. Paired is the message libimobiledevice's usbmuxd sends on
    /// pairing; not yet observed from Apple's usbmuxd here, since no untrusted device was at hand.
    func paired(handle: Int) -> [Step] {
        guard let udid = handles[handle]?.udid, let route = route(udid) else { return [] }
        return [.pace(udid: udid)] + Self.pluggedIn(route, udid: udid)
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
    /// newest handle wins. usbmuxd numbers handles upward as devices attach, so a replug's fresh handle is read before a
    /// stale detach has removed the old one, and a stale attach replayed after the snapshot never takes the route.
    func route(_ udid: String) -> Route? {
        handles.compactMap { handle, connection -> Route? in
            guard case .device(udid, let transport) = connection else { return nil }
            return Route(handle: handle, transport: transport)
        }.max { ($0.transport.preference, $0.handle) < ($1.transport.preference, $1.handle) }
    }

    /// One decision as the log writes it: its steps in order, or "nothing".
    static func describe(_ steps: [Step]) -> String {
        steps.isEmpty ? "nothing" : steps.map { String(describing: $0) }.joined(separator: ", ")
    }

    /// [LAW:dataflow-not-control-flow] Every attach and detach is one edit to the handles, and its steps are what the
    /// edit did to the device's route: a new route is read now, a route onto a cable also switches on Wi-Fi sync, and no
    /// route is a disconnect.
    private mutating func edit(_ udid: String?, _ change: (inout [Int: DeviceConnection]) -> Void) -> [Step] {
        let before = udid.flatMap(route)
        change(&handles)
        guard let udid else { return [] }
        switch route(udid) {
        case before: return []
        case nil: return [.disconnected(udid: udid)]
        case let after?: return [.pace(udid: udid)] + Self.pluggedIn(after, udid: udid)
        }
    }

    /// Plugging a device in switches on its Wi-Fi sync, so it is still read once the cable is out.
    private static func pluggedIn(_ route: Route, udid: String) -> [Step] {
        switch route.transport {
        case .usb: [.enableWifiSync(handle: route.handle, udid: udid)]
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
            snapshot: usbmuxListDevices,
            read: readIPhoneBattery(handle:udid:),
            enableWifiSync: { handle, udid throws(IPhoneReadError) in try setIPhoneWifiSync(true, handle: handle, udid: udid) },
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

    /// [LAW:no-ambient-temporal-coupling] Whether steps may run is this state, owned on the queue. Ending the monitor
    /// cancels every pacer and moves to `stopped`, where a Listen frame still being drained is decided but not performed:
    /// it starts no read and writes nothing to the device.
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
            switch lifecycle {
            case .running(var pacers):
                for step in steps { perform(step, pacers: &pacers) }
                lifecycle = .running(pacers: pacers)
            case .stopped:
                IPhoneMonitor.log.info("iphone monitor stopped, not performed: \(DeviceMap.describe(steps), privacy: .public)")
            }
        }
    }

    /// A pace replaces (and cancels) the device's read loop with a new one.
    private func perform(_ step: DeviceMap.Step, pacers: inout [String: Pacer]) {
        switch step {
        case .pace(let udid):
            pacers[udid]?.task.cancel()
            let token = UUID()
            pacers[udid] = Pacer(token: token, task: Task { await self.pace(udid, token: token) })
        case .enableWifiSync(let handle, let udid): startWifiSync(handle: handle, udid: udid)
        case .disconnected(let udid):
            pacers.removeValue(forKey: udid)?.task.cancel()
            continuation.yield(.disconnected(udid: udid))
        }
    }

    /// Read, deliver, rest, and again, while this loop is the device's current pacer. The next read starts only after
    /// the last one finished, however long its deadlines let it run.
    private func pace(_ udid: String, token: UUID) async {
        while let route = queue.sync(execute: { isCurrent(udid, token) ? map.route(udid) : nil }) {
            let outcome = await read(over: route, udid: udid)
            queue.sync { deliver(outcome, udid: udid, over: route, token: token) }
            do { try await inputs.timekeeper.sleep(for: IPhoneMonitor.pollInterval) } catch { break }
        }
        IPhoneMonitor.log.info("iphone pacer ended: \(udid, privacy: .public): replaced, disconnected, or stopped")
    }

    /// [LAW:single-enforcer] The one test of whether a pacer may act, on the queue: it is the device's current pacer in a
    /// running monitor. A replacement, a disconnect, and a stop all fail it, before a read starts and when one is
    /// delivered; a handle that detaches mid-read changes the device's route, which replaces its pacer.
    private func isCurrent(_ udid: String, _ token: UUID) -> Bool {
        guard case .running(let pacers) = lifecycle else { return false }
        return pacers[udid]?.token == token
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

    /// An outcome reaches the stream only from the device's current pacer.
    private func deliver(_ outcome: Result<IPhoneBatteryReading, IPhoneReadError>, udid: String, over route: DeviceMap.Route,
                         token: UUID) {
        guard isCurrent(udid, token) else {
            IPhoneMonitor.log.info("iphone read dropped: \(udid, privacy: .public) handle \(route.handle): its pacer was replaced or stopped")
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

    /// Cancels every pacer; nothing starts another. Ending an ended monitor (a failure's finish, then its stream's
    /// termination) changes nothing.
    private func end() {
        switch lifecycle {
        case .running(let pacers):
            pacers.values.forEach { $0.task.cancel() }
            lifecycle = .stopped
            IPhoneMonitor.log.info("iphone monitor ended: \(pacers.count) pacers cancelled")
        case .stopped: break
        }
    }

    private func finish(with error: IPhoneReadError) {
        IPhoneMonitor.log.error("iphone monitor failed: \(String(describing: error), privacy: .public)")
        end()
        continuation.yield(.failed(error))
        continuation.finish()
    }
}
