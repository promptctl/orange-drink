import Foundation
import os
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is the event stream and the log line each decision leaves. The Listen
// connection is one end of a socketpair the test writes usbmuxd frames to; the snapshot and the read are stand-ins.
@Suite(.serialized) struct IPhoneMonitorDecisions {
    private static let reading = IPhoneBatteryReading(level: 80, health: 0.91, cycleCount: 312,
                                                      designCapacity: 3_274, appleRawMaxCapacity: 3_001)

    private static func usb(_ handle: Int, _ udid: String) -> AttachedDevice {
        AttachedDevice(handle: handle, connection: .usb(udid: udid))
    }

    private static func attachedFrame(_ handle: Int, _ udid: String) -> [String: Any] {
        ["MessageType": "Attached", "DeviceID": handle, "Properties": ["ConnectionType": "USB", "SerialNumber": udid]]
    }

    /// The log line the monitor writes for one decision.
    private static func decision(_ event: UsbmuxEvent, _ step: DeviceMap.Step) -> String {
        "iphone \(String(describing: event)) → \(String(describing: step))"
    }

    private struct Harness {
        let peer: Int32
        let events: AsyncStream<IPhoneEvent>

        init(snapshot: @escaping @Sendable () throws -> [AttachedDevice], read: @escaping MonitorInputs.Read) throws {
            let (socket, peer) = try TimedSocketDeadline.pair()
            self.peer = peer
            events = IPhoneMonitor.events(from: MonitorInputs(listen: { socket }, snapshot: snapshot, read: read))
        }

        func send(_ body: [String: Any]) throws {
            let frame = try usbmuxEncode(body)
            let sent = frame.withUnsafeBytes { write(peer, $0.baseAddress, $0.count) }
            guard sent == frame.count else { throw IPhoneReadError.socket(errno: errno) }
        }
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
    func aSnapshotEntryAndItsListenAttachReadOnceAndAFailedReadIsYielded() async throws {
        let log = try BatteryLog(category: IPhoneMonitor.logCategory)
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let harness = try Harness(snapshot: { [Self.usb(5, "B")] }) { _, _ throws(IPhoneReadError) in
            reads.withLock { $0 += 1 }
            throw .closed
        }
        defer { close(harness.peer) }
        var events = harness.events.makeAsyncIterator()

        #expect(await events.next() == .readFailed(udid: "B", .closed))
        try harness.send(Self.attachedFrame(5, "B"))
        try harness.send(["MessageType": "Detached", "DeviceID": 5])
        #expect(await events.next() == .disconnected(udid: "B"))
        #expect(reads.withLock { $0 } == 1)
        #expect(try await logged(Self.decision(.attached(Self.usb(5, "B")), .nothing), in: log))
    }

    @Test(.timeLimit(.minutes(1)))
    func pairedRereadsADeviceWhoseFirstReadHadNoPairRecord() async throws {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let harness = try Harness(snapshot: { [Self.usb(5, "B")] }) { _, _ throws(IPhoneReadError) in
            if reads.withLock({ $0 += 1; return $0 }) == 1 { throw .usbmux(.noPairRecord) }
            return Self.reading
        }
        defer { close(harness.peer) }
        var events = harness.events.makeAsyncIterator()

        #expect(await events.next() == .readFailed(udid: "B", .usbmux(.noPairRecord)))
        try harness.send(["MessageType": "Paired", "DeviceID": 5])
        #expect(await events.next() == .reading(udid: "B", Self.reading))
    }

    @Test(.timeLimit(.minutes(1)))
    func aReadFinishingAfterItsHandleDetachedIsDroppedAndLogged() async throws {
        let log = try BatteryLog(category: IPhoneMonitor.logCategory)
        let staleReadMayFinish = DispatchSemaphore(value: 0)
        let harness = try Harness(snapshot: { [Self.usb(5, "B")] }) { handle, _ throws(IPhoneReadError) in
            if handle == 4 { staleReadMayFinish.wait(); throw .closed }
            return Self.reading
        }
        defer { close(harness.peer) }
        var events = harness.events.makeAsyncIterator()

        // Unplug and replug between Listen and ListDevices: the snapshot holds handle 5, the queued Attached(4) and
        // Detached(4) follow it, and the read on handle 4 finishes only after its detach.
        #expect(await events.next() == .reading(udid: "B", Self.reading))
        try harness.send(Self.attachedFrame(4, "B"))
        try harness.send(["MessageType": "Detached", "DeviceID": 4])
        #expect(try await logged(Self.decision(.detached(handle: 4), .nothing), in: log))
        staleReadMayFinish.signal()
        #expect(try await logged("iphone read dropped: B handle 4", in: log))
        try harness.send(["MessageType": "Detached", "DeviceID": 5])
        #expect(await events.next() == .disconnected(udid: "B"))
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

    // The real usbmuxd, which every Mac runs: a UDID it holds no pair record for is a typed failure and one log line.
    @available(macOS 15.0, *)
    @available(macOS, deprecated: 10.15, message: "calls readIPhoneBattery, which uses SecureTransport; see lm3.8pk")
    @Test func aReadOfAnUntrustedDeviceFailsAsNoPairRecordAndIsLogged() async throws {
        let log = try BatteryLog(category: IPhoneMonitor.logCategory)
        let udid = "00000000-0000000000000000"  // UDID-shaped, so usbmuxd answers ENOENT rather than EINVAL
        #expect(throws: IPhoneReadError.usbmux(.noPairRecord)) { try readIPhoneBattery(handle: 1, udid: udid) }
        #expect(try await logged("iphone read failed: \(udid) handle 1: usbmux(", in: log))
    }
}
