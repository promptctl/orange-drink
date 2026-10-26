import Foundation
import os
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is the event stream, the log line each decision leaves, and how many relays
// the monitor opens, which is what a read costs (two TLS handshakes per relay). The Listen connection is one end of a
// socketpair the test writes usbmuxd frames to; the snapshot, the relay, and the Wi-Fi sync switch are stand-ins; time
// passes only when the test advances the clock.
@Suite(.serialized) struct IPhoneMonitorDecisions {
    private static let reading = IPhoneBatteryReading(level: 80, cycleCount: 312,
                                                      designCapacity: EntryCapacity(mAh: 3_274, place: .topLevel),
                                                      nominalChargeCapacity: EntryCapacity(mAh: 2_980, place: .topLevel),
                                                      storedMaximumCapacity: nil)

    private static func usb(_ handle: Int, _ udid: String) -> AttachedDevice {
        AttachedDevice(handle: handle, connection: .device(udid: udid, over: .usb))
    }

    private static func wifi(_ handle: Int, _ udid: String) -> AttachedDevice {
        AttachedDevice(handle: handle, connection: .device(udid: udid, over: .network))
    }

    private static func attachedFrame(_ handle: Int, _ udid: String, _ type: String) -> [String: Any] {
        ["MessageType": "Attached", "DeviceID": handle, "Properties": ["ConnectionType": type, "SerialNumber": udid]]
    }

    /// The log line the monitor writes for one decision.
    private static func decision(_ event: UsbmuxEvent, _ steps: [DeviceMap.Step]) -> String {
        "iphone \(String(describing: event)) → \(DeviceMap.describe(steps))"
    }

    typealias Read = @Sendable (_ handle: Int, _ udid: String) throws(IPhoneReadError) -> IPhoneBatteryReading

    /// A relay over one handle whose every read is the harness's read for that handle.
    private final class StandInRelay: BatteryRelay {
        let handle: Int, udid: String
        let reading: Read
        init(handle: Int, udid: String, read: @escaping Read) { self.handle = handle; self.udid = udid; reading = read }
        func read() throws(IPhoneReadError) -> IPhoneBatteryReading { try reading(handle, udid) }
    }

    private struct Harness {
        let peer: Int32
        let clock = ManualTimekeeper()
        let events: AsyncStream<IPhoneEvent>
        /// The handles relays were opened over, in order.
        let opened = OSAllocatedUnfairLock<[Int]>(initialState: [])

        init(snapshot: @escaping @Sendable () throws -> [AttachedDevice],
             enableWifiSync: @escaping MonitorInputs.EnableWifiSync = { _, _ throws(IPhoneReadError) in },
             connect: @escaping @Sendable (_ handle: Int) throws(IPhoneReadError) -> Void = { _ throws(IPhoneReadError) in },
             read: @escaping Read) throws {
            let (socket, peer) = try TimedSocketDeadline.pair()
            self.peer = peer
            let opened = opened
            events = IPhoneMonitor.events(from: MonitorInputs(
                listen: { socket }, snapshot: snapshot,
                connect: { handle, udid throws(IPhoneReadError) in
                    opened.withLock { $0.append(handle) }
                    try connect(handle)
                    return StandInRelay(handle: handle, udid: udid, read: read)
                },
                enableWifiSync: enableWifiSync, timekeeper: clock))
        }

        func send(_ body: [String: Any]) throws {
            let frame = try usbmuxEncode(body)
            let sent = frame.withUnsafeBytes { write(peer, $0.baseAddress, $0.count) }
            guard sent == frame.count else { throw IPhoneReadError.socket(errno: errno) }
        }

        /// Moves the clock one poll interval once a pacer is resting on it.
        func nextPoll() async {
            await clock.asleep()
            clock.advance(by: IPhoneMonitor.pollInterval)
        }
    }

    /// The next `count` events, in the order their descriptions sort: reads and Wi-Fi sync switches finish on
    /// different threads, so the order between them is not part of the contract.
    private static func next(_ count: Int, of events: inout AsyncStream<IPhoneEvent>.Iterator) async -> [String] {
        var taken: [String] = []
        for _ in 0..<count { taken.append(String(describing: await events.next())) }
        return taken.sorted()
    }

    private static func described(_ events: [IPhoneEvent]) -> [String] {
        events.map { String(describing: Optional($0)) }.sorted()
    }

    /// Waits until the counter reaches `count`: a read stand-in counts itself in before it blocks.
    private func reached(_ count: Int, _ counter: OSAllocatedUnfairLock<Int>) async throws {
        while counter.withLock({ $0 }) < count { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// How many log lines since `log` began contain `fragment`.
    @Test(.timeLimit(.minutes(1)))
    func pluggingInSwitchesOnWifiSyncOnceAndReadsOverTheCableEachPollInterval() async throws {
        let log = try BatteryLog(category: IPhoneMonitor.logCategory)
        let syncs = OSAllocatedUnfairLock(initialState: 0)
        let harness = try Harness(snapshot: { [Self.usb(5, "B")] },
                                  enableWifiSync: { _, _ throws(IPhoneReadError) in syncs.withLock { $0 += 1 } }) { _, _ throws(IPhoneReadError) in
            Self.reading
        }
        defer { close(harness.peer) }
        var events = harness.events.makeAsyncIterator()

        #expect(await events.next() == .reachable(udid: "B", over: .usb))
        #expect(await Self.next(2, of: &events) == Self.described([.reading(udid: "B", over: .usb, Self.reading), .wifiSyncOn(udid: "B")]))
        await harness.nextPoll()
        #expect(await events.next() == .reading(udid: "B", over: .usb, Self.reading))
        #expect(syncs.withLock { $0 } == 1)
        #expect(try await log.logged("iphone pacer started: B"))
        #expect(try await log.logged("iphone read delivered: B over usb, relay opened; resting \(IPhoneMonitor.pollInterval)"))
        #expect(try await log.logged("iphone read delivered: B over usb, relay held; resting \(IPhoneMonitor.pollInterval)"))
        #expect(harness.opened.withLock { $0 } == [5])
    }

    @Test(.timeLimit(.minutes(1)))
    func aSnapshotEntryAndItsListenAttachReadOnceAndFailuresAreYielded() async throws {
        let log = try BatteryLog(category: IPhoneMonitor.logCategory)
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let harness = try Harness(snapshot: { [Self.usb(5, "B")] },
                                  enableWifiSync: { _, _ throws(IPhoneReadError) in throw .usbmux(.noPairRecord) }) { _, _ throws(IPhoneReadError) in
            reads.withLock { $0 += 1 }
            throw .closed
        }
        defer { close(harness.peer) }
        var events = harness.events.makeAsyncIterator()

        #expect(await events.next() == .reachable(udid: "B", over: .usb))
        #expect(await Self.next(2, of: &events) == Self.described([.readFailed(udid: "B", over: .usb, .closed),
                                                                   .wifiSyncFailed(udid: "B", .usbmux(.noPairRecord))]))
        try harness.send(Self.attachedFrame(5, "B", "USB"))
        try harness.send(["MessageType": "Detached", "DeviceID": 5])
        #expect(await events.next() == .unreachable(udid: "B"))
        #expect(reads.withLock { $0 } == 1)
        #expect(try await log.logged(Self.decision(.attached(Self.usb(5, "B")), [])))
    }

    @Test(.timeLimit(.minutes(1)))
    func aDeviceThatDropsOffWifiAndReturnsDuringItsRestIsReadAtThePollAndNotBefore() async throws {
        let log = try BatteryLog(category: IPhoneMonitor.logCategory)
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let harness = try Harness(snapshot: { [Self.wifi(6, "E")] }) { _, _ throws(IPhoneReadError) in
            reads.withLock { $0 += 1 }
            return Self.reading
        }
        defer { close(harness.peer) }
        var events = harness.events.makeAsyncIterator()

        #expect(await events.next() == .reachable(udid: "E", over: .network))
        #expect(await events.next() == .reading(udid: "E", over: .network, Self.reading))
        await harness.clock.asleep()
        try harness.send(["MessageType": "Detached", "DeviceID": 6])
        #expect(await events.next() == .unreachable(udid: "E"))
        try harness.send(Self.attachedFrame(7, "E", "Network"))
        #expect(await events.next() == .reachable(udid: "E", over: .network))
        #expect(reads.withLock { $0 } == 1)
        harness.clock.advance(by: IPhoneMonitor.pollInterval)
        #expect(await events.next() == .reading(udid: "E", over: .network, Self.reading))
        #expect(reads.withLock { $0 } == 2)
        #expect(try await log.count("iphone pacer started: E", awaiting: 1) == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func aDeviceGoneAtThePollIsReadOnItsNextAttach() async throws {
        let log = try BatteryLog(category: IPhoneMonitor.logCategory)
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let harness = try Harness(snapshot: { [Self.wifi(6, "F")] }) { _, _ throws(IPhoneReadError) in
            reads.withLock { $0 += 1 }
            return Self.reading
        }
        defer { close(harness.peer) }
        var events = harness.events.makeAsyncIterator()

        #expect(await events.next() == .reachable(udid: "F", over: .network))
        #expect(await events.next() == .reading(udid: "F", over: .network, Self.reading))
        await harness.clock.asleep()
        try harness.send(["MessageType": "Detached", "DeviceID": 6])
        #expect(await events.next() == .unreachable(udid: "F"))
        harness.clock.advance(by: IPhoneMonitor.pollInterval)
        #expect(try await log.logged("iphone pacer ended: F: unreachable when due; its next attach reads it"))
        #expect(reads.withLock { $0 } == 1)
        // No advance: the device has been due since the poll, so the attach that lists it again reads it.
        try harness.send(Self.attachedFrame(7, "F", "Network"))
        #expect(await events.next() == .reachable(udid: "F", over: .network))
        #expect(await events.next() == .reading(udid: "F", over: .network, Self.reading))
        #expect(reads.withLock { $0 } == 2)
        #expect(try await log.count("iphone pacer started: F", awaiting: 2) == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func pullingTheCableOfADeviceOnWifiWhileItRestsReadsItOverWifiAtThePoll() async throws {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let harness = try Harness(snapshot: { [Self.usb(5, "B"), Self.wifi(6, "B")] }) { _, _ throws(IPhoneReadError) in
            reads.withLock { $0 += 1 }
            return Self.reading
        }
        defer { close(harness.peer) }
        var events = harness.events.makeAsyncIterator()

        #expect(await events.next() == .reachable(udid: "B", over: .usb))
        #expect(await Self.next(2, of: &events) == Self.described([.reading(udid: "B", over: .usb, Self.reading), .wifiSyncOn(udid: "B")]))
        await harness.clock.asleep()
        try harness.send(["MessageType": "Detached", "DeviceID": 5])
        #expect(await events.next() == .reachable(udid: "B", over: .network))
        #expect(reads.withLock { $0 } == 1)
        harness.clock.advance(by: IPhoneMonitor.pollInterval)
        #expect(await events.next() == .reading(udid: "B", over: .network, Self.reading))
        #expect(reads.withLock { $0 } == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func aReadWhoseCableIsPulledMidReadFailsOverTheCableAndTheNextGoesOverWifiAtThePoll() async throws {
        let cableReads = OSAllocatedUnfairLock(initialState: 0)
        let cableReadMayFinish = DispatchSemaphore(value: 0)
        let harness = try Harness(snapshot: { [Self.usb(5, "B"), Self.wifi(6, "B")] }) { handle, _ throws(IPhoneReadError) in
            if handle == 5 { cableReads.withLock { $0 += 1 }; cableReadMayFinish.wait(); throw .closed }
            return Self.reading
        }
        defer { close(harness.peer) }
        var events = harness.events.makeAsyncIterator()

        #expect(await Self.next(2, of: &events) == Self.described([.reachable(udid: "B", over: .usb), .wifiSyncOn(udid: "B")]))
        try await reached(1, cableReads)
        try harness.send(["MessageType": "Detached", "DeviceID": 5])
        #expect(await events.next() == .reachable(udid: "B", over: .network))
        cableReadMayFinish.signal()
        #expect(await events.next() == .readFailed(udid: "B", over: .usb, .closed))
        await harness.nextPoll()
        #expect(await events.next() == .reading(udid: "B", over: .network, Self.reading))
        #expect(cableReads.withLock { $0 } == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func pairingAfterAFailedReadAddsNoReadAndTheNextComesAtThePoll() async throws {
        let log = try BatteryLog(category: IPhoneMonitor.logCategory)
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let harness = try Harness(snapshot: { [Self.wifi(6, "G")] }) { _, _ throws(IPhoneReadError) in
            if reads.withLock({ $0 += 1; return $0 }) == 1 { throw .usbmux(.noPairRecord) }
            return Self.reading
        }
        defer { close(harness.peer) }
        var events = harness.events.makeAsyncIterator()

        #expect(await events.next() == .reachable(udid: "G", over: .network))
        #expect(await events.next() == .readFailed(udid: "G", over: .network, .usbmux(.noPairRecord)))
        await harness.clock.asleep()
        try harness.send(["MessageType": "Paired", "DeviceID": 6])
        #expect(try await log.logged(Self.decision(.paired(handle: 6), [])))
        #expect(reads.withLock { $0 } == 1)
        harness.clock.advance(by: IPhoneMonitor.pollInterval)
        #expect(await events.next() == .reading(udid: "G", over: .network, Self.reading))
    }

    // A read over a held relay is one request; opening one is two TLS handshakes. While usbmuxd keeps the handle, every
    // poll reads over the one relay.
    @Test(.timeLimit(.minutes(1)))
    func aDeviceUsbmuxdKeepsListedIsReadOverOneRelayEveryPoll() async throws {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let harness = try Harness(snapshot: { [Self.wifi(6, "R")] }) { _, _ throws(IPhoneReadError) in
            reads.withLock { $0 += 1 }
            return Self.reading
        }
        defer { close(harness.peer) }
        var events = harness.events.makeAsyncIterator()

        #expect(await events.next() == .reachable(udid: "R", over: .network))
        for _ in 0..<3 {
            #expect(await events.next() == .reading(udid: "R", over: .network, Self.reading))
            await harness.nextPoll()
        }
        #expect(await events.next() == .reading(udid: "R", over: .network, Self.reading))
        #expect(reads.withLock { $0 } == 4)
        #expect(harness.opened.withLock { $0 } == [6])
    }

    // usbmuxd drops a Wi-Fi device's handle and lists it again under another; the relay went with the old handle.
    @Test(.timeLimit(.minutes(1)))
    func aDeviceListedAgainUnderANewHandleIsReadOverANewRelay() async throws {
        let harness = try Harness(snapshot: { [Self.wifi(6, "S")] }) { _, _ throws(IPhoneReadError) in Self.reading }
        defer { close(harness.peer) }
        var events = harness.events.makeAsyncIterator()

        #expect(await events.next() == .reachable(udid: "S", over: .network))
        #expect(await events.next() == .reading(udid: "S", over: .network, Self.reading))
        await harness.clock.asleep()
        try harness.send(["MessageType": "Detached", "DeviceID": 6])
        #expect(await events.next() == .unreachable(udid: "S"))
        try harness.send(Self.attachedFrame(9, "S", "Network"))
        #expect(await events.next() == .reachable(udid: "S", over: .network))
        harness.clock.advance(by: IPhoneMonitor.pollInterval)
        #expect(await events.next() == .reading(udid: "S", over: .network, Self.reading))
        #expect(harness.opened.withLock { $0 } == [6, 9])
    }

    // A relay that fails is not read again: the failure is yielded, and the next poll opens a new relay. A relay that
    // cannot be opened is a failed read too.
    @Test(.timeLimit(.minutes(1)))
    func aFailedReadOrOpenIsYieldedAndTheNextPollOpensANewRelay() async throws {
        let log = try BatteryLog(category: IPhoneMonitor.logCategory)
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let opens = OSAllocatedUnfairLock(initialState: 0)
        let harness = try Harness(snapshot: { [Self.wifi(6, "T")] },
                                  connect: { _ throws(IPhoneReadError) in
                                      if opens.withLock({ $0 += 1; return $0 }) == 2 { throw .tls(-9806) }
                                  }) { _, _ throws(IPhoneReadError) in
            if reads.withLock({ $0 += 1; return $0 }) == 2 { throw .closed }
            return Self.reading
        }
        defer { close(harness.peer) }
        var events = harness.events.makeAsyncIterator()

        #expect(await events.next() == .reachable(udid: "T", over: .network))
        #expect(await events.next() == .reading(udid: "T", over: .network, Self.reading))
        await harness.nextPoll()
        #expect(await events.next() == .readFailed(udid: "T", over: .network, .closed))
        await harness.nextPoll()
        #expect(await events.next() == .readFailed(udid: "T", over: .network, .tls(-9806)))
        await harness.nextPoll()
        #expect(await events.next() == .reading(udid: "T", over: .network, Self.reading))
        #expect(harness.opened.withLock { $0 } == [6, 6, 6])
        #expect(reads.withLock { $0 } == 3)
        #expect(try await log.count("iphone read delivered: T over network, relay opened", awaiting: 3) == 3)
        #expect(try await log.count("iphone read delivered: T over network, relay held", awaiting: 1) == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func endingTheStreamCancelsEveryPacer() async throws {
        let log = try BatteryLog(category: IPhoneMonitor.logCategory)
        let harness = try Harness(snapshot: { [Self.wifi(6, "B"), Self.wifi(7, "C")] }) { _, _ throws(IPhoneReadError) in Self.reading }
        defer { close(harness.peer) }
        let seen = OSAllocatedUnfairLock(initialState: 0)
        let consumer = Task { for await _ in harness.events { seen.withLock { $0 += 1 } } }
        // Each device's reachable and its first reading: both pacers have started.
        try await reached(4, seen)
        consumer.cancel()
        #expect(try await log.logged("iphone monitor ended: 2 pacers cancelled"))
        #expect(try await log.logged("iphone pacer ended: B: monitor stopped"))
        #expect(try await log.logged("iphone pacer ended: C: monitor stopped"))
    }

    @Test(.timeLimit(.minutes(1)))
    func aReadInFlightWhenTheStreamEndsIsDroppedAndItsPacerEnds() async throws {
        let log = try BatteryLog(category: IPhoneMonitor.logCategory)
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let readMayFinish = DispatchSemaphore(value: 0)
        let harness = try Harness(snapshot: { [Self.wifi(6, "H")] }) { _, _ throws(IPhoneReadError) in
            reads.withLock { $0 += 1 }
            readMayFinish.wait()
            return Self.reading
        }
        defer { close(harness.peer) }
        let consumer = Task { for await _ in harness.events {} }
        try await reached(1, reads)
        consumer.cancel()
        #expect(try await log.logged("iphone monitor ended: 1 pacers cancelled"))
        readMayFinish.signal()
        #expect(try await log.logged("iphone read dropped: H handle 6: monitor stopped"))
        #expect(try await log.logged("iphone pacer ended: H: monitor stopped"))
        #expect(reads.withLock { $0 } == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func aDeviceSeenAfterTheMonitorEndedIsNeitherReadNorWrittenTo() async throws {
        let log = try BatteryLog(category: IPhoneMonitor.logCategory)
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let syncs = OSAllocatedUnfairLock(initialState: 0)
        let ended = DispatchSemaphore(value: 0)
        let harness = try Harness(snapshot: { ended.wait(); return [Self.usb(6, "D")] },
                                  enableWifiSync: { _, _ throws(IPhoneReadError) in syncs.withLock { $0 += 1 } }) { _, _ throws(IPhoneReadError) in
            reads.withLock { $0 += 1 }
            return Self.reading
        }
        defer { close(harness.peer) }
        let consumer = Task { for await _ in harness.events {} }
        consumer.cancel()
        #expect(try await log.logged("iphone monitor ended: 0 pacers cancelled"))
        ended.signal()
        #expect(try await log.logged("iphone monitor stopped, not performed: \(DeviceMap.describe([.reachability(udid: "D", over: .usb), .enableWifiSync(handle: 6, udid: "D")]))"))
        #expect(reads.withLock { $0 } == 0)
        #expect(syncs.withLock { $0 } == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func aClosedListenConnectionEndsTheStream() async throws {
        let log = try BatteryLog(category: IPhoneMonitor.logCategory)
        let harness = try Harness(snapshot: { [] }) { _, _ throws(IPhoneReadError) in Self.reading }
        close(harness.peer)
        var events: [IPhoneEvent] = []
        for await event in harness.events { events.append(event) }
        #expect(events == [.failed(.closed)])
        #expect(try await log.logged("iphone monitor failed: closed"))
    }

    @Test(.timeLimit(.minutes(1)))
    func aMalformedStartupSnapshotEndsTheStream() async throws {
        let harness = try Harness(snapshot: { try usbmuxDeviceList(["DeviceList": "not a list"]) }) { _, _ throws(IPhoneReadError) in
            Self.reading
        }
        defer { close(harness.peer) }
        var events: [IPhoneEvent] = []
        for await event in harness.events { events.append(event) }
        #expect(events == [.failed(.usbmux(.missingKey("DeviceList")))])
    }

    @Test(.timeLimit(.minutes(1)))
    func aConsumerThatStopsListeningStopsTheMonitor() async throws {
        let log = try BatteryLog(category: IPhoneMonitor.logCategory)
        let harness = try Harness(snapshot: { [] }) { _, _ throws(IPhoneReadError) in Self.reading }
        defer { close(harness.peer) }
        let consumer = Task { for await _ in harness.events {} }
        consumer.cancel()
        #expect(try await log.logged("iphone monitor stopped"))
    }

    // The real usbmuxd, which every Mac runs: a UDID it holds no pair record for is a typed failure and one log line,
    // for a relay and for the Wi-Fi sync switch alike.
    @available(macOS 15.0, *)
    @available(macOS, deprecated: 10.15, message: "opens DiagnosticsRelay, which uses SecureTransport; see lm3.8pk")
    @Test func anUntrustedDeviceFailsAsNoPairRecordAndIsLogged() async throws {
        let log = try BatteryLog(category: IPhoneMonitor.logCategory)
        let udid = "00000000-0000000000000000"  // UDID-shaped, so usbmuxd answers ENOENT rather than EINVAL
        let identities = PairIdentities()
        #expect(throws: IPhoneReadError.usbmux(.noPairRecord)) { try DiagnosticsRelay(handle: 1, udid: udid, identities: identities) }
        #expect(throws: IPhoneReadError.usbmux(.noPairRecord)) { try setIPhoneWifiSync(true, handle: 1, udid: udid, identities: identities) }
        #expect(throws: IPhoneReadError.usbmux(.noPairRecord)) { try setIPhoneWifiSync(false, handle: 1, udid: udid, identities: identities) }
        #expect(try await log.logged("iphone relay open failed: \(udid) handle 1: usbmux("))
        #expect(try await log.logged("iphone wifi sync on failed: \(udid) handle 1: usbmux("))
        #expect(try await log.logged("iphone wifi sync off failed: \(udid) handle 1: usbmux("))
    }
}
