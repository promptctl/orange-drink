import Foundation
import os
import Testing
@testable import OrangeDrink

// [LAW:verifiable-goals] The ticket's hardware step: plugging in a trusted iPhone switches on its Wi-Fi sync and reads it
// over the cable; once the cable is pulled, every window brings a Wi-Fi reading or a typed Wi-Fi read failure, never
// nothing, and the app reading it stays under PROJECT.md's 0.1% CPU bar. Run by make iphone-check with the iPhone cabled,
// Finder's "Show this iPhone when on Wi-Fi" box unticked, and a person at the cable.
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
        let arrivals = Arrivals()
        let consumer = Task { for await event in IPhoneMonitor.events() { arrivals.append(event) } }
        defer { consumer.cancel() }
        var cursor = 0

        // The cable: one reading over USB and the Wi-Fi sync switch, for the same device.
        var cabled: String?
        var synced: String?
        while cabled == nil || synced == nil {
            let event = try #require(try await arrivals.event(at: cursor, within: .seconds(120)),
                                     "no cable reading and Wi-Fi sync within two minutes; is the iPhone trusted, unlocked, and plugged in?")
            cursor += 1
            switch event {
            case .reading(let udid, .usb, let value):
                cabled = udid
                print("cable reading: level \(value.level)%, health \(value.health.map { String(format: "%.1f%%", $0 * 100) } ?? "not reported"), cycles \(value.cycleCount)")
            case .wifiSyncOn(let udid):
                synced = udid
                print("wifi sync on: check that Finder now ticks \"Show this iPhone when on Wi-Fi\"")
            case .wifiSyncFailed(_, let error), .readFailed(_, _, let error), .failed(let error):
                Issue.record("cable phase: \(event) (\(error))")
                return
            default:
                continue
            }
        }
        let udid = try #require(cabled)
        #expect(synced == udid, "Wi-Fi sync was switched on for another device")
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
                print("wifi reading: level \(value.level)%: compare with the phone")
            case .readFailed(udid, .network, let error):
                print("wifi read failed: \(error)")
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
        print(String(format: "wifi phase CPU: %.3f%% over %d windows", percent, Self.wifiWindows))
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
