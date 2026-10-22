import Foundation
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is the event stream and the log line each decision leaves, driven
// through the monitor's two inputs with a stand-in read.
@Suite(.serialized) struct IPhoneMonitorDecisions {
    private static let reading = IPhoneBatteryReading(level: 80, health: 0.91, cycleCount: 312,
                                                      designCapacity: 3_274, appleRawMaxCapacity: 3_001)

    /// Polls the log until a line contains `fragment`: log entries reach OSLogStore shortly after they are written.
    private func logged(_ fragment: String, in log: BatteryLog) async throws -> Bool {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < end {
            if try log.messages().contains(where: { $0.contains(fragment) }) { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @Test func aReadFinishingAfterItsHandleDetachedIsDroppedAndLogged() async throws {
        let log = try BatteryLog(category: IPhoneMonitor.logCategory)
        let (stream, continuation) = AsyncStream.makeStream(of: IPhoneEvent.self)
        let staleReadMayFinish = DispatchSemaphore(value: 0)
        let state = MonitorState(continuation: continuation) { handle, _ throws(IPhoneReadError) in
            if handle == 4 { staleReadMayFinish.wait(); throw .closed }
            return Self.reading
        }
        var events = stream.makeAsyncIterator()

        // Unplug and replug between Listen and ListDevices: the snapshot holds handle 5, the queued Attached(4) and
        // Detached(4) follow it, and the read on handle 4 finishes only after its detach.
        state.receive(snapshot: [AttachedDevice(handle: 5, connection: .usb(udid: "B"))])
        guard case .reading(udid: "B", Self.reading)? = await events.next() else { Issue.record("no reading for B"); return }
        state.receive(.attached(AttachedDevice(handle: 4, connection: .usb(udid: "B"))))
        state.receive(.detached(handle: 4))
        staleReadMayFinish.signal()
        #expect(try await logged("iphone read dropped: B handle 4", in: log))

        state.receive(.detached(handle: 5))
        continuation.finish()
        var rest: [String] = []
        while let event = await events.next() { rest.append(String(describing: event)) }
        #expect(rest == [String(describing: IPhoneEvent.disconnected(udid: "B"))])
        #expect(try await logged("iphone attached: B handle 5, reading", in: log))
        #expect(try await logged("iphone disconnected: B", in: log))
    }

    // The real usbmuxd, which every Mac runs: a UDID it holds no pair record for is a typed failure and one log line.
    @available(macOS, deprecated: 10.15, message: "calls readIPhoneBattery, which uses SecureTransport; see lm3.8pk")
    @Test func aReadOfAnUntrustedDeviceFailsAsNoPairRecordAndIsLogged() async throws {
        let log = try BatteryLog(category: IPhoneMonitor.logCategory)
        let udid = "00000000-0000000000000000"  // UDID-shaped, so usbmuxd answers ENOENT rather than EINVAL
        #expect(throws: IPhoneReadError.usbmux(.noPairRecord)) { try readIPhoneBattery(handle: 1, udid: udid) }
        #expect(try await logged("iphone read failed: \(udid) handle 1: usbmux(", in: log))
    }
}
