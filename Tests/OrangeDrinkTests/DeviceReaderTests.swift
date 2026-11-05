import Foundation
import os
import Testing
@testable import OrangeDrink

// [LAW:verifiable-goals] Reads powerd does and does not answer, from stand-in sources and peers: no Bluetooth in the room.
struct DeviceReaderTests {
    /// Sources that fail with `unanswered`'s error until it is cleared, then answer with FluffPods at 47%.
    final class Sources {
        var unanswered: PowerSourcesError?
        let log: Logger
        init(unanswered: PowerSourcesError?, log: Logger) { self.unanswered = unanswered; self.log = log }
        var reader: DeviceReader {
            DeviceReader(sources: { () throws(PowerSourcesError) in
                if let unanswered = self.unanswered { throw unanswered }
                return [AccessoryPowerTests.source("FluffPods", "Single", 47)]
            }, log: log)
        }
    }

    static let peer = BluetoothPeer(id: DeviceID.bluetooth("AA"), name: "FluffPods", kind: .accessory)
    static func device(_ levels: DeviceLevels) -> SourceDevice {
        SourceDevice(id: peer.id, name: peer.name, kind: peer.kind, levels: levels)
    }
    static let read = device(.single(BatteryLevel(percent: 47, approximate: false)))

    @Test func aSweepPowerdDidNotAnswerKeepsTheDeviceUnreadUntilOneDoes() {
        let sources = Sources(unanswered: .unanswered(call: "sweep unanswered"), log: .unread)
        #expect(sources.reader.sweep([Self.peer]) == .swept([Self.device(.unread)]))
        sources.unanswered = nil
        #expect(sources.reader.sweep([Self.peer]) == .swept([Self.read]))
    }

    @Test func aDeviceConnectingWhilePowerdIsSilentIsReportedUnread() {
        let sources = Sources(unanswered: .unanswered(call: "report unanswered"), log: .unread)
        #expect(sources.reader.report(Self.peer) == .reported(Self.device(.unread)))
        sources.unanswered = nil
        #expect(sources.reader.report(Self.peer) == .reported(Self.read))
    }

    @Test func aSourceReadThatAnsweredOmitsADeviceWithNoBattery() {
        let reader = Sources(unanswered: nil, log: .unread).reader
        let speaker = BluetoothPeer(id: DeviceID.bluetooth("BB"), name: "Speaker", kind: .accessory)
        #expect(reader.sweep([speaker]) == .swept([SourceDevice(id: speaker.id, name: "Speaker", kind: .accessory, levels: .none)]))
    }

    // Each logged line stands alone: a connect's read can be the only one powerd misses, with the settle sweep answered.
    @Test func anUnansweredSweepNamesTheCallInTheLog() async throws {
        let log = try await TestLog()
        _ = Sources(unanswered: .unanswered(call: "logged by a sweep"), log: log.logger).reader.sweep([Self.peer])
        #expect(try await log.logged("device levels unread: unanswered(call: \"logged by a sweep\")"))
    }

    @Test func anUnansweredReportNamesTheCallInTheLog() async throws {
        let log = try await TestLog()
        _ = Sources(unanswered: .unanswered(call: "logged by a report"), log: log.logger).reader.report(Self.peer)
        #expect(try await log.logged("device levels unread: unanswered(call: \"logged by a report\")"))
    }

    @Test func anOSWithoutTheSymbolEndsTheSubscription() async {
        let events = BluetoothDevices.events(log: .unread, asks: { _ in AsyncStream { $0.yield(.heard(.allowed)) } },
                                             watcher: { _, _ in throw BluetoothDevicesError.missingSymbol("IOPSCopyPowerSourcesByType") })
        await #expect(throws: BluetoothDevicesError.missingSymbol("IOPSCopyPowerSourcesByType")) {
            for try await _ in events {}
        }
    }
}
