import Foundation
import os
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is the event stream and the log line each decision leaves. The Listen
// connection is one end of a socketpair the test writes usbmuxd frames to; the snapshot, the read, and the Wi-Fi sync
// switch are stand-ins; time passes only when the test advances the clock.
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

    private struct Harness {
        let peer: Int32
        let clock = ManualTimekeeper()
        let events: AsyncStream<IPhoneEvent>

        init(snapshot: @escaping @Sendable () throws -> [AttachedDevice],
             enableWifiSync: @escaping MonitorInputs.EnableWifiSync = { _, _ throws(IPhoneReadError) in },
             read: @escaping MonitorInputs.Read) throws {
            let (socket, peer) = try TimedSocketDeadline.pair()
            self.peer = peer
            events = IPhoneMonitor.events(from: MonitorInputs(listen: { socket }, snapshot: snapshot, read: read,
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

    /// Polls the log until a line contains `fragment`: log entries reach OSLogStore shortly after they are written.
    private func logged(_ fragment: String, in log: BatteryLog) async throws -> Bool {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < end {
            if try log.messages().contains(where: { $0.contains(fragment) }) { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

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

        #expect(await Self.next(2, of: &events) == Self.described([.reading(udid: "B", over: .usb, Self.reading), .wifiSyncOn(udid: "B")]))
        await harness.nextPoll()
        #expect(await events.next() == .reading(udid: "B", over: .usb, Self.reading))
        #expect(syncs.withLock { $0 } == 1)
        #expect(try await logged("iphone read delivered: B over usb", in: log))
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

        #expect(await Self.next(2, of: &events) == Self.described([.readFailed(udid: "B", over: .usb, .closed),
                                                                   .wifiSyncFailed(udid: "B", .usbmux(.noPairRecord))]))
        try harness.send(Self.attachedFrame(5, "B", "USB"))
        try harness.send(["MessageType": "Detached", "DeviceID": 5])
        #expect(await events.next() == .disconnected(udid: "B"))
        #expect(reads.withLock { $0 } == 1)
        #expect(try await logged(Self.decision(.attached(Self.usb(5, "B")), []), in: log))
    }

    @Test(.timeLimit(.minutes(1)))
    func pullingTheCableOfADeviceOnWifiReadsItOverWifiWithoutWaitingAPoll() async throws {
        let log = try BatteryLog(category: IPhoneMonitor.logCategory)
        let harness = try Harness(snapshot: { [Self.usb(5, "B"), Self.wifi(6, "B")] }) { _, _ throws(IPhoneReadError) in Self.reading }
        defer { close(harness.peer) }
        var events = harness.events.makeAsyncIterator()

        #expect(await Self.next(2, of: &events) == Self.described([.reading(udid: "B", over: .usb, Self.reading), .wifiSyncOn(udid: "B")]))
        try harness.send(["MessageType": "Detached", "DeviceID": 5])
        #expect(try await logged(Self.decision(.detached(handle: 5), [.pace(udid: "B")]), in: log))
        #expect(await events.next() == .reading(udid: "B", over: .network, Self.reading))
    }

    @Test(.timeLimit(.minutes(1)))
    func aReadWhoseCableIsPulledMidReadIsDroppedAndTheNextGoesOverWifi() async throws {
        let log = try BatteryLog(category: IPhoneMonitor.logCategory)
        let cableReads = OSAllocatedUnfairLock(initialState: 0)
        let cableReadMayFinish = DispatchSemaphore(value: 0)
        let harness = try Harness(snapshot: { [Self.usb(5, "B"), Self.wifi(6, "B")] }) { handle, _ throws(IPhoneReadError) in
            if handle == 5 { cableReads.withLock { $0 += 1 }; cableReadMayFinish.wait(); throw .closed }
            return Self.reading
        }
        defer { close(harness.peer) }
        var events = harness.events.makeAsyncIterator()

        #expect(await events.next() == .wifiSyncOn(udid: "B"))
        try await reached(1, cableReads)
        try harness.send(["MessageType": "Detached", "DeviceID": 5])
        #expect(try await logged(Self.decision(.detached(handle: 5), [.pace(udid: "B")]), in: log))
        #expect(await events.next() == .reading(udid: "B", over: .network, Self.reading))
        cableReadMayFinish.signal()
        #expect(try await logged("iphone read dropped: B handle 5: its pacer was replaced or stopped", in: log))
    }

    @Test(.timeLimit(.minutes(1)))
    func pairedDuringAReadReplacesThePacerAndTheOldReadIsDropped() async throws {
        let log = try BatteryLog(category: IPhoneMonitor.logCategory)
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let firstReadMayFinish = DispatchSemaphore(value: 0)
        let harness = try Harness(snapshot: { [Self.wifi(6, "B")] }) { _, _ throws(IPhoneReadError) in
            if reads.withLock({ $0 += 1; return $0 }) == 1 { firstReadMayFinish.wait(); throw .usbmux(.noPairRecord) }
            return Self.reading
        }
        defer { close(harness.peer) }
        var events = harness.events.makeAsyncIterator()

        try await reached(1, reads)
        try harness.send(["MessageType": "Paired", "DeviceID": 6])
        #expect(await events.next() == .reading(udid: "B", over: .network, Self.reading))
        firstReadMayFinish.signal()
        #expect(try await logged("iphone read dropped: B handle 6: its pacer was replaced or stopped", in: log))
    }

    @Test(.timeLimit(.minutes(1)))
    func aDisconnectedDeviceIsNotReadAgain() async throws {
        let log = try BatteryLog(category: IPhoneMonitor.logCategory)
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let harness = try Harness(snapshot: { [Self.wifi(6, "E")] }) { _, _ throws(IPhoneReadError) in
            reads.withLock { $0 += 1 }
            return Self.reading
        }
        defer { close(harness.peer) }
        var events = harness.events.makeAsyncIterator()

        #expect(await events.next() == .reading(udid: "E", over: .network, Self.reading))
        await harness.clock.asleep()
        try harness.send(["MessageType": "Detached", "DeviceID": 6])
        #expect(await events.next() == .disconnected(udid: "E"))
        #expect(try await logged("iphone pacer ended: E: replaced, disconnected, or stopped", in: log))
        harness.clock.advance(by: IPhoneMonitor.pollInterval)
        // A pacer that outlived its device would read on that advance; the device's return is read once, by its new pacer.
        try harness.send(Self.attachedFrame(7, "E", "Network"))
        #expect(await events.next() == .reading(udid: "E", over: .network, Self.reading))
        #expect(reads.withLock { $0 } == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func endingTheStreamCancelsEveryPacer() async throws {
        let log = try BatteryLog(category: IPhoneMonitor.logCategory)
        let harness = try Harness(snapshot: { [Self.wifi(6, "B"), Self.wifi(7, "C")] }) { _, _ throws(IPhoneReadError) in Self.reading }
        defer { close(harness.peer) }
        let seen = OSAllocatedUnfairLock(initialState: 0)
        let consumer = Task { for await _ in harness.events { seen.withLock { $0 += 1 } } }
        try await reached(2, seen)
        consumer.cancel()
        #expect(try await logged("iphone monitor ended: 2 pacers cancelled", in: log))
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
        #expect(try await logged("iphone monitor ended: 0 pacers cancelled", in: log))
        ended.signal()
        #expect(try await logged("iphone monitor stopped, not performed: \(DeviceMap.describe([.pace(udid: "D"), .enableWifiSync(handle: 6, udid: "D")]))",
                                 in: log))
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
        #expect(try await logged("iphone monitor failed: closed", in: log))
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
        #expect(try await logged("iphone monitor stopped", in: log))
    }

    // The real usbmuxd, which every Mac runs: a UDID it holds no pair record for is a typed failure and one log line,
    // for a read and for the Wi-Fi sync switch alike.
    @available(macOS 15.0, *)
    @available(macOS, deprecated: 10.15, message: "calls readIPhoneBattery, which uses SecureTransport; see lm3.8pk")
    @Test func anUntrustedDeviceFailsAsNoPairRecordAndIsLogged() async throws {
        let log = try BatteryLog(category: IPhoneMonitor.logCategory)
        let udid = "00000000-0000000000000000"  // UDID-shaped, so usbmuxd answers ENOENT rather than EINVAL
        #expect(throws: IPhoneReadError.usbmux(.noPairRecord)) { try readIPhoneBattery(handle: 1, udid: udid) }
        #expect(throws: IPhoneReadError.usbmux(.noPairRecord)) { try setIPhoneWifiSync(true, handle: 1, udid: udid) }
        #expect(throws: IPhoneReadError.usbmux(.noPairRecord)) { try setIPhoneWifiSync(false, handle: 1, udid: udid) }
        #expect(try await logged("iphone read failed: \(udid) handle 1: usbmux(", in: log))
        #expect(try await logged("iphone wifi sync on failed: \(udid) handle 1: usbmux(", in: log))
        #expect(try await logged("iphone wifi sync off failed: \(udid) handle 1: usbmux(", in: log))
    }
}
