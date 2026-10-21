import Foundation
import Testing
@testable import OrangeDrink

// [LAW:verifiable-goals] The ticket's hardware step: a trusted cabled iPhone's battery is read, and pulling the cable
// prints a disconnect. Run by make iphone-check with the iPhone cabled and a person at the cable.
@Suite(.serialized) struct IPhoneLive {
    @available(macOS, deprecated: 10.15, message: "drives IPhoneMonitor, which uses SecureTransport; see lm3.8pk")
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IPHONE_CHECK"] != nil, "run by make iphone-check with a cabled iPhone"),
          .timeLimit(.minutes(5)))
    func readsCabledIPhoneThenPrintsDisconnect() async throws {
        var reading: IPhoneBatteryReading?
        var disconnected = false
        events: for await event in IPhoneMonitor.events() {
            switch event {
            case .reading(_, let value) where reading == nil:
                reading = value
                print("reading: level \(value.level)%, health \(value.health.map { String(format: "%.1f%%", $0 * 100) } ?? "not reported"), cycles \(value.cycleCount), design \(value.designCapacity) mAh, raw max \(value.appleRawMaxCapacity) mAh")
                print("pull the cable now")
            case .disconnected where reading != nil:
                print("disconnected")
                disconnected = true
                break events
            case .readFailed(_, let error):
                Issue.record("read failed: \(error)")
            case .failed(let error):
                Issue.record("monitor failed: \(error)")
                break events
            default:
                continue
            }
        }
        let value = try #require(reading, "no cabled iPhone reading; is it trusted and plugged in with a cable?")
        #expect(value.cycleCount > 0)
        #expect(value.health != nil)
        #expect(disconnected, "pulling the cable should print a disconnect")
    }
}
