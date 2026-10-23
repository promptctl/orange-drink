import IOKit.ps
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is which events two consecutive readings
// produce. Readings come from the same powerd shapes BatteryReadingParse uses, with the
// percent varied where a level change is the point.
@Suite struct BatteryEvents {
    typealias Fixtures = BatteryReadingParse

    static func reading(_ powerSource: [String: Any], percent: Int = 80,
                        registry: [String: Any] = Fixtures.registry) throws -> BatteryReading {
        var source = powerSource
        source[kIOPSCurrentCapacityKey] = percent
        return try Fixtures.parse(source, registry: registry)
    }
    /// The reading the charged-80 alert fires on under an 80% Charge Limit: charging, powerd's
    /// estimate to 100%, and the charger reporting the limit in force.
    static func atTheLimit(percent: Int = 80) throws -> BatteryReading {
        try reading(Fixtures.charging(timeToFull: 48), percent: percent, registry: Fixtures.limitInForce)
    }
    static var onAdapter: BatteryReading { get throws { try reading(Fixtures.onACNotCharging(charged: false)) } }
    static var onBattery: BatteryReading { get throws { try reading(Fixtures.discharging(timeToEmpty: 192)) } }

    @Test func batteryToAdapterIsPlugged() throws {
        let adapter = try Self.onAdapter
        #expect(BatteryEvent.changes(from: try Self.onBattery, to: adapter) == [.plugged(adapter)])
    }

    @Test func adapterToBatteryIsUnplugged() throws {
        let battery = try Self.onBattery
        #expect(BatteryEvent.changes(from: try Self.onAdapter, to: battery) == [.unplugged(battery)])
    }

    @Test func percentChangeIsLevelChanged() throws {
        let lower = try Self.reading(Fixtures.discharging(timeToEmpty: 180), percent: 79)
        #expect(BatteryEvent.changes(from: try Self.onBattery, to: lower) == [.levelChanged(lower)])
    }

    @Test func unplugAndDropArriveAsTwoEventsPowerFirst() throws {
        let lower = try Self.reading(Fixtures.discharging(timeToEmpty: 180), percent: 79)
        #expect(BatteryEvent.changes(from: try Self.onAdapter, to: lower) == [.unplugged(lower), .levelChanged(lower)])
    }

    @Test func equalReadingsYieldNothing() throws {
        #expect(BatteryEvent.changes(from: try Self.onAdapter, to: try Self.onAdapter) == [])
    }

    @Test func aNewEstimateAloneIsNotAnEvent() throws {
        let later = try Self.reading(Fixtures.discharging(timeToEmpty: 150))
        #expect(BatteryEvent.changes(from: try Self.onBattery, to: later) == [])
    }

    @Test func chargingStateAloneIsNotAnEvent() throws {
        let charging = try Self.reading(Fixtures.charging(timeToFull: 82))
        #expect(BatteryEvent.changes(from: try Self.onAdapter, to: charging) == [])
    }

    /// The loop over a recorded stream: an absent battery and an unchanged reading are not
    /// states to compare, and every event it yields is also the log's.
    @Test func eventsDiffConsecutiveReadingsAndLogEach() async throws {
        let battery = try Self.onBattery, adapter = try Self.onAdapter
        let log = try BatteryLog()
        let recorded = AsyncStream<BatteryReading?> { continuation in
            for reading in [nil, battery, battery, adapter] { continuation.yield(reading) }
            continuation.finish()
        }
        var events: [BatteryEvent] = []
        for try await event in BatteryMonitor.events(from: recorded) { events.append(event) }
        #expect(events == [.plugged(adapter)])
        #expect(try log.messages().contains("battery event: \(String(describing: BatteryEvent.plugged(adapter)))"))
    }
}
