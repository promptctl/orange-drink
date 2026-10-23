import Foundation
import os
import Testing
@testable import OrangeDrink

// [LAW:verifiable-goals] The ticket's hardware step: plugging in a trusted iPhone switches on its Wi-Fi sync and reads it
// over the cable; once the cable is pulled, every window brings a Wi-Fi reading or a typed Wi-Fi read failure, never
// nothing, and the app reading it stays under PROJECT.md's 0.1% CPU bar. Run by make iphone-check with the iPhone cabled
// and a person at the cable.
@Suite(.serialized) struct IPhoneLive {
    /// The longest a device on Wi-Fi may go without an event: one rest, then one read at its worst.
    private static let window = IPhoneMonitor.pollInterval + readWorstCase
    /// Consecutive windows the Wi-Fi phase is held to, after its first event.
    private static let wifiWindows = 3

    @available(macOS, deprecated: 10.15, message: "drives IPhoneMonitor, which uses SecureTransport; see lm3.8pk")
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IPHONE_CHECK"] != nil, "run by make iphone-check with a cabled iPhone"),
          .timeLimit(.minutes(20)))
    func switchesOnWifiSyncThenKeepsReadingOverWifiOnceTheCableIsPulled() async throws {
        let log = try BatteryLog(category: IPhoneMonitor.logCategory)
        // The one cabled device's Wi-Fi sync is switched off before the monitor starts, so the monitor is what switches it on.
        let cabled = try usbmuxListDevices().compactMap { device -> (handle: Int, udid: String)? in
            guard case .device(let udid, .usb) = device.connection else { return nil }
            return (device.handle, udid)
        }
        try #require(cabled.count == 1, "this check needs exactly one cabled iPhone; usbmuxd lists \(cabled.count)")
        let (handle, udid) = cabled[0]
        try setIPhoneWifiSync(false, handle: handle, udid: udid)
        printForTheRecord("wifi sync off: \(udid)")

        let arrivals = Arrivals()
        let consumer = Task { for await event in IPhoneMonitor.events() { arrivals.append(event) } }
        defer { consumer.cancel() }
        var cursor = 0

        // The cable: one reading over USB and the Wi-Fi sync switch, for that device.
        var read = false
        var synced = false
        while !read || !synced {
            let event = try #require(try await arrivals.event(at: cursor, within: .seconds(120)),
                                     "no cable reading and Wi-Fi sync within two minutes; is the iPhone trusted and unlocked?")
            cursor += 1
            switch event {
            case .reading(udid, .usb, let value):
                read = true
                printForTheRecord("cable reading: level \(value.level)%, cycles \(value.cycleCount), design \(value.designCapacity.value) mAh (\(value.designCapacity.place)), nominal \(value.nominalChargeCapacity.value) mAh (\(value.nominalChargeCapacity.place)), stored max capacity \(value.storedMaximumCapacity.map { "\($0)%" } ?? "none"), max capacity \(value.maximumCapacityPercent)%")
            case .wifiSyncOn(udid):
                synced = true
                printForTheRecord("wifi sync on: check that Finder now ticks \"Show this iPhone when on Wi-Fi\"")
            case .wifiSyncFailed(udid, let error), .readFailed(udid, _, let error), .failed(let error):
                Issue.record("cable phase: \(event) (\(error))")
                return
            default:
                continue
            }
        }
        #expect(try log.messages().contains { $0.hasPrefix("iphone wifi sync on: \(udid) ") })
        print("pull the cable now")

        // Wi-Fi: pulling the cable moves the route to Wi-Fi, which is read at once, so every event, the first included,
        // arrives within one window. Until the person pulls, each cable reading restarts the wait.
        var wifiEvents = 0
        var wifiReadings = 0
        var cpuFrom: (cpu: Duration, at: ContinuousClock.Instant)?
        while wifiEvents <= Self.wifiWindows {
            let event = try #require(try await arrivals.event(at: cursor, within: Self.window),
                                     "no event for \(udid) within \(Self.window): the device went silent on Wi-Fi")
            cursor += 1
            switch event {
            case .reading(udid, .network, let value):
                wifiReadings += 1
                printForTheRecord("wifi reading: level \(value.level)%: compare with the phone")
            case .readFailed(udid, .network, let error):
                printForTheRecord("wifi read failed: \(error)")
            case .reading(udid, .usb, _):
                print("still on the cable: pull it")
                continue
            case .disconnected(udid):
                Issue.record("\(udid) disconnected: Wi-Fi sync did not keep it")
                return
            case .failed(let error):
                Issue.record("monitor failed: \(error)")
                return
            default:
                continue
            }
            wifiEvents += 1
            cpuFrom = cpuFrom ?? (processCPU(), .now)
        }

        let from = try #require(cpuFrom)
        let percent = (processCPU() - from.cpu) / (ContinuousClock.now - from.at) * 100
        printForTheRecord(String(format: "wifi phase CPU: %.3f%% over %d windows", percent, Self.wifiWindows))
        #expect(percent < 0.1, "the app over Wi-Fi is over PROJECT.md's 0.1% CPU bar")
        #expect(wifiReadings > 0, "every Wi-Fi read failed")
    }

    /// User plus system time charged to this process, which is the app: the test bundle runs inside it.
    private func processCPU() -> Duration {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func duration(_ t: timeval) -> Duration { .seconds(t.tv_sec) + .microseconds(t.tv_usec) }
        return duration(usage.ru_utime) + duration(usage.ru_stime)
    }
}

/// Events in arrival order, for a test that waits on each against a window. It checks once a second, so its own cost
/// in the measured process is small, and it counts against the bar rather than hiding anything under it.
private final class Arrivals: Sendable {
    private let events = OSAllocatedUnfairLock<[IPhoneEvent]>(initialState: [])

    func append(_ event: IPhoneEvent) { events.withLock { $0.append(event) } }

    /// The event at `index` once it has arrived, or nil if `limit` passes first.
    func event(at index: Int, within limit: Duration) async throws -> IPhoneEvent? {
        let end = ContinuousClock.now.advanced(by: limit)
        while ContinuousClock.now < end {
            if let event = events.withLock({ index < $0.count ? $0[index] : nil }) { return event }
            try await Task.sleep(for: .seconds(1))
        }
        return nil
    }
}
