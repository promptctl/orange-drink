import Foundation
import os

// [LAW:one-source-of-truth] The handle map is the one record of what usbmuxd has attached. Whether a device is present,
// and which handle to read it over, are derived from it; every decision the monitor makes comes from the Steps it returns.
struct DeviceMap {
    enum Step: Equatable {
        /// The transport the device is reached over has just changed: it gained a route, moved between the cable and
        /// Wi-Fi, or (nil) lost its last handle.
        case reachability(udid: String, over: Transport?)
        /// Switch on the device's Wi-Fi sync: its route has just become this cable.
        case enableWifiSync(handle: Int, udid: String)
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

    /// usbmuxd's Paired: the device on this handle has just trusted this Mac, so a Wi-Fi sync switch that failed for want
    /// of a pair record can now succeed; it goes over the device's cable, as it does on plug-in. A read that failed the
    /// same way is not retried here: the device's pacer reads it again within a poll interval. Paired is the message
    /// libimobiledevice's usbmuxd sends on pairing; not yet observed from Apple's usbmuxd here, since no untrusted
    /// device was at hand.
    func paired(handle: Int) -> [Step] {
        guard let udid = handles[handle]?.udid, let route = route(udid) else { return [] }
        return Self.pluggedIn(route, udid: udid)
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
    /// edit did to the device's route: a change of transport is a reachability step, and a new route onto a cable,
    /// a replug's fresh handle included, also switches on Wi-Fi sync.
    private mutating func edit(_ udid: String?, _ change: (inout [Int: DeviceConnection]) -> Void) -> [Step] {
        let before = udid.flatMap(route)
        change(&handles)
        guard let udid else { return [] }
        let after = route(udid)
        let reachability = before?.transport == after?.transport ? [] : [Step.reachability(udid: udid, over: after?.transport)]
        let plugged = before == after ? [] : after.map { Self.pluggedIn($0, udid: udid) } ?? []
        return reachability + plugged
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
    /// usbmuxd lists the device, and this is the transport it is reached over now. Every change is yielded, unfiltered:
    /// usbmuxd drops an iPhone or iPad on Wi-Fi from its list every few seconds to minutes and lists it again (lm3.1tt
    /// cmt-9a8a2ba7), so a consumer decides what a drop means for what it shows.
    case reachable(udid: String, over: Transport)
    /// usbmuxd lists no handle for the device. Over Wi-Fi this is usually a drop it soon recovers from, not a departure.
    case unreachable(udid: String)
    case reading(udid: String, over: Transport, IPhoneBatteryReading)
    /// Non-terminal: this read failed; the device is read again a poll interval later, or on its next attach.
    case readFailed(udid: String, over: Transport, IPhoneReadError)
    case wifiSyncOn(udid: String)
    /// Non-terminal: switching on Wi-Fi sync failed; it is tried again on the next plug-in.
    case wifiSyncFailed(udid: String, IPhoneReadError)
    /// Terminal: the stream ends after this event.
    case failed(IPhoneReadError)
}

/// A device's battery, read over one usbmuxd handle as often as asked while the handle lives.
protocol BatteryRelay: AnyObject, Sendable {
    func read() throws(IPhoneReadError) -> IPhoneBatteryReading
}

/// Where the monitor's inputs come from: a connection already subscribed with Listen, the ListDevices snapshot, a
/// battery relay opened over a handle, the Wi-Fi sync switch, and the clock reads are paced by.
/// [LAW:effects-at-boundaries] events() passes usbmuxd's and the system clock; tests pass a socketpair, stand-ins, and a
/// clock they advance by hand.
struct MonitorInputs: Sendable {
    typealias Connect = @Sendable (_ handle: Int, _ udid: String) throws(IPhoneReadError) -> any BatteryRelay
    typealias EnableWifiSync = @Sendable (_ handle: Int, _ udid: String) throws(IPhoneReadError) -> Void
    let listen: @Sendable () throws -> TimedSocket
    let snapshot: @Sendable () throws -> [AttachedDevice]
    let connect: Connect
    let enableWifiSync: EnableWifiSync
    let timekeeper: any Timekeeper
}

enum IPhoneMonitor {
    static let logCategory = "iphone"
    static let log = Logger(subsystem: IOKitBattery.logSubsystem, category: logCategory)
    /// How long a device rests between the end of one read and the start of the next, however often usbmuxd relists it.
    static let pollInterval = Duration.seconds(60)

    /// Events for every iPhone and iPad usbmuxd reports, over the cable or over Wi-Fi.
    @available(macOS, deprecated: 10.15, message: "lockdown TLS is SecureTransport, the only client-identity TLS that lockdown accepts here; see lm3.8pk")
    static func events() -> AsyncStream<IPhoneEvent> {
        let identities = PairIdentities()
        return events(from: MonitorInputs(
            listen: usbmuxListen,
            snapshot: usbmuxListDevices,
            connect: { handle, udid throws(IPhoneReadError) in try DiagnosticsRelay(handle: handle, udid: udid, identities: identities) },
            enableWifiSync: { handle, udid throws(IPhoneReadError) in try setIPhoneWifiSync(true, handle: handle, udid: udid, identities: identities) },
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
    /// [LAW:no-ambient-temporal-coupling] Whether steps may run is this state, owned on the queue. Ending the monitor
    /// cancels every pacer and moves to `stopped`, where a Listen frame still being drained is decided but not performed:
    /// it starts no read and writes nothing to the device.
    ///
    /// [LAW:one-source-of-truth] A device's schedule is whether it has a pacer: present, it is being read or resting;
    /// absent, it is due, and the next route it gains reads it at once. A pacer is never replaced, so usbmuxd dropping
    /// and relisting a resting device costs no read.
    private enum Lifecycle {
        case running(pacers: [String: Task<Void, Never>])
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
                receive(try inputs.snapshot().map { .attached($0) })
                var reader = UsbmuxFrameReader()
                while !isStopped() {
                    guard let bytes = try socket.receiveSome(max: 4096) else { continue }
                    reader.append(bytes)
                    while let body = try reader.next() { receive([try usbmuxEvent(body)]) }
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

    /// [LAW:no-ambient-temporal-coupling] One listing, applied in one turn of the queue: the snapshot is every device
    /// usbmuxd lists at once, so a pacer it starts picks its route from all of it. A device the snapshot lists over Wi-Fi
    /// before its cable is read over the cable, not over a Wi-Fi handle usbmuxd may already be dropping.
    private func receive(_ events: [UsbmuxEvent]) {
        queue.sync {
            for event in events {
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
    }

    /// A reachability change is yielded as it is; a route also makes sure the device has a pacer, so a device that is due
    /// is read on the attach that gives it one, and a device that has a pacer is left to it.
    private func perform(_ step: DeviceMap.Step, pacers: inout [String: Task<Void, Never>]) {
        switch step {
        case .reachability(let udid, let transport?):
            continuation.yield(.reachable(udid: udid, over: transport))
            pacers[udid] = pacers[udid] ?? startPacer(udid)
        case .reachability(let udid, nil): continuation.yield(.unreachable(udid: udid))
        case .enableWifiSync(let handle, let udid): startWifiSync(handle: handle, udid: udid)
        }
    }

    private func startPacer(_ udid: String) -> Task<Void, Never> {
        IPhoneMonitor.log.info("iphone pacer started: \(udid, privacy: .public)")
        return Task { await self.pace(udid) }
    }

    /// Read over the device's route, deliver, rest a poll interval, and again, until `nextRoute` ends it. The next read
    /// starts only after the last one finished, however long its deadlines let it run. The pacer holds the relay its
    /// last read succeeded over, and reads over it again while the route keeps that handle.
    private func pace(_ udid: String) async {
        var held: HeldRelay?
        while let route = queue.sync(execute: { nextRoute(udid) }) {
            let read = await read(over: route, udid: udid, held: held)
            held = read.held
            queue.sync { deliver(read.outcome, udid: udid, over: route, relay: read.relay) }
            // Throws only when the monitor ends and cancels the pacer; nextRoute then finds it stopped and ends the loop.
            try? await inputs.timekeeper.sleep(for: IPhoneMonitor.pollInterval)
        }
    }

    /// [LAW:single-enforcer] The one decision of whether a pacer reads again, on the queue. A stopped monitor ends it. A
    /// device with no route ends it and leaves the pacers, so the device is due and its next attach reads it. Otherwise
    /// it reads over the route usbmuxd lists now, which may differ from the last read's.
    private func nextRoute(_ udid: String) -> DeviceMap.Route? {
        guard case .running(var pacers) = lifecycle else {
            IPhoneMonitor.log.info("iphone pacer ended: \(udid, privacy: .public): monitor stopped")
            return nil
        }
        guard let route = map.route(udid) else {
            pacers.removeValue(forKey: udid)
            lifecycle = .running(pacers: pacers)
            IPhoneMonitor.log.info("iphone pacer ended: \(udid, privacy: .public): unreachable when due; its next attach reads it")
            return nil
        }
        return route
    }

    /// Whether a read went over the relay held from the last one or a relay opened for it, as its log line says.
    private enum RelayUse: String {
        case held
        case opened
    }

    /// A relay and the usbmuxd handle it was opened over, the only handle it is good for.
    private struct HeldRelay {
        let handle: Int
        let relay: any BatteryRelay
    }

    /// One read and the relay to hold after it: the one it succeeded over, or none.
    private struct Read {
        let outcome: Result<IPhoneBatteryReading, IPhoneReadError>
        let held: HeldRelay?
        let relay: RelayUse
    }

    /// [LAW:dataflow-not-control-flow] A read goes over the relay held for the route's handle, or one opened for it; a
    /// relay is good only for the handle it was opened over, so a device usbmuxd lists again under a new handle gets a
    /// new relay. A failed read holds nothing, so the next one opens afresh. Opening and reading are blocking calls of
    /// up to several deadlines, so they run off the queue and off the task's thread.
    private func read(over route: DeviceMap.Route, udid: String, held: HeldRelay?) async -> Read {
        await withCheckedContinuation { done in
            DispatchQueue.global(qos: .utility).async {
                let reused = held.flatMap { $0.handle == route.handle ? $0.relay : nil }
                let relay = reused == nil ? RelayUse.opened : .held
                do throws(IPhoneReadError) {
                    let open: any BatteryRelay
                    switch reused {
                    case let held?: open = held
                    case nil: open = try self.inputs.connect(route.handle, udid)
                    }
                    done.resume(returning: Read(outcome: .success(try open.read()), held: HeldRelay(handle: route.handle, relay: open), relay: relay))
                } catch {
                    done.resume(returning: Read(outcome: .failure(error), held: nil, relay: relay))
                }
            }
        }
    }

    /// [LAW:no-silent-failure] Every outcome of a running monitor reaches the stream, a read whose handle detached
    /// mid-read included: that is a true failure over the route it was tried on.
    private func deliver(_ outcome: Result<IPhoneBatteryReading, IPhoneReadError>, udid: String, over route: DeviceMap.Route, relay: RelayUse) {
        guard case .running = lifecycle else {
            IPhoneMonitor.log.info("iphone read dropped: \(udid, privacy: .public) handle \(route.handle): monitor stopped")
            return
        }
        IPhoneMonitor.log.info("iphone read delivered: \(udid, privacy: .public) over \(String(describing: route.transport), privacy: .public), relay \(relay.rawValue, privacy: .public); resting \(IPhoneMonitor.pollInterval, privacy: .public)")
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
            pacers.values.forEach { $0.cancel() }
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
