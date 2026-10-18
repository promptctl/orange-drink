import Foundation
import IOKit.ps
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is the reading each IOKit shape maps to.
// Fixtures are this Mac's dictionaries, captured on AC held at 80% and not charging.
@Suite struct BatteryReadingParse {
    static var registry: [String: Any] { [
        "AppleRawCurrentCapacity": 4646, "AppleRawMaxCapacity": 5934, "DesignCapacity": 6249,
        "CycleCount": 103, "DesignCycleCount9C": 1000,
        "Temperature": 3093, "Voltage": 12510, "Amperage": -252,
    ] }
    static var onAC: [String: Any] { [
        kIOPSCurrentCapacityKey: 80, kIOPSPowerSourceStateKey: kIOPSACPowerValue,
        kIOPSIsChargingKey: false, kIOPSIsChargedKey: false,
        kIOPSTimeToEmptyKey: 0, kIOPSTimeToFullChargeKey: 0,
    ] }
    static var adapter: [String: Any] { [kIOPSPowerAdapterWattsKey: 86] }

    static func powerSource(_ overrides: [String: Any]) -> [String: Any] {
        onAC.merging(overrides) { $1 }
    }

    @Test func hardwareFactsCarryTheirUnits() throws {
        let reading = try BatteryReading(registry: Self.registry, powerSource: Self.onAC, adapter: Self.adapter)
        #expect(reading.chargePercent == 80)
        #expect(reading.capacity == Capacity(
            current: .init(value: 4646, unit: .milliampereHours),
            full: .init(value: 5934, unit: .milliampereHours),
            design: .init(value: 6249, unit: .milliampereHours)))
        #expect(reading.cycles == Cycles(count: 103, rated: 1000))
        #expect(reading.temperature == .init(value: 30.93, unit: .celsius))
        #expect(reading.voltage == .init(value: 12.51, unit: .volts))
        #expect(reading.current == .init(value: -252, unit: .milliamperes))
    }

    @Test func onACNotCharging() throws {
        let reading = try BatteryReading(registry: Self.registry, powerSource: Self.onAC, adapter: Self.adapter)
        #expect(reading.power == .adapter(.init(value: 86, unit: .watts), .notCharging))
    }

    @Test func chargingWithEstimate() throws {
        let source = Self.powerSource([kIOPSIsChargingKey: true, kIOPSTimeToFullChargeKey: 82])
        let reading = try BatteryReading(registry: Self.registry, powerSource: source, adapter: Self.adapter)
        #expect(reading.power == .adapter(.init(value: 86, unit: .watts), .charging(timeToFull: .seconds(82 * 60))))
    }

    @Test func chargingWhileStillCalculating() throws {
        let source = Self.powerSource([kIOPSIsChargingKey: true, kIOPSTimeToFullChargeKey: -1])
        let reading = try BatteryReading(registry: Self.registry, powerSource: source, adapter: Self.adapter)
        #expect(reading.power == .adapter(.init(value: 86, unit: .watts), .charging(timeToFull: nil)))
    }

    @Test func fullWinsOverCharging() throws {
        let source = Self.powerSource([kIOPSIsChargingKey: true, kIOPSIsChargedKey: true])
        let reading = try BatteryReading(registry: Self.registry, powerSource: source, adapter: Self.adapter)
        #expect(reading.power == .adapter(.init(value: 86, unit: .watts), .full))
    }

    @Test func dischargingWithEstimate() throws {
        let source = Self.powerSource([kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue, kIOPSTimeToEmptyKey: 192])
        let reading = try BatteryReading(registry: Self.registry, powerSource: source, adapter: nil)
        #expect(reading.power == .battery(timeToEmpty: .seconds(192 * 60)))
    }

    @Test func dischargingWhileStillCalculating() throws {
        let source = Self.powerSource([kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue, kIOPSTimeToEmptyKey: -1])
        let reading = try BatteryReading(registry: Self.registry, powerSource: source, adapter: nil)
        #expect(reading.power == .battery(timeToEmpty: nil))
    }

    @Test func missingRegistryKeyFailsNamingIt() {
        var registry = Self.registry
        registry["Temperature"] = nil
        #expect(throws: BatteryReadError(key: "Temperature", source: "registry")) {
            try BatteryReading(registry: registry, powerSource: Self.onAC, adapter: Self.adapter)
        }
    }

    @Test func onACWithoutAdapterDetailsFails() {
        #expect(throws: BatteryReadError(key: kIOPSPowerAdapterWattsKey, source: "adapter")) {
            try BatteryReading(registry: Self.registry, powerSource: Self.onAC, adapter: nil)
        }
    }
}
