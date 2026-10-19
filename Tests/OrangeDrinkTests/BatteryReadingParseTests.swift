import Foundation
import IOKit.ps
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is the reading each IOKit shape maps to.
// The power-source fixtures are the four shapes powerd publishes (PowerManagement,
// BatteryTimeRemaining.m, packageKernelPowerSource): "Is Charged" exists only on AC while not
// charging, a battery that is not present has neither estimate nor "Is Charged", and the
// estimate that does not apply is 0. Values are this Mac's, on AC held at 80%.
@Suite struct BatteryReadingParse {
    static var registry: [String: Any] { [
        "AppleRawCurrentCapacity": 4646, "AppleRawMaxCapacity": 5934, "DesignCapacity": 6249,
        "CycleCount": 103, "DesignCycleCount9C": 1000,
        "Temperature": 3093, "Voltage": 12510, "Amperage": -252,
    ] }
    static var adapter: [String: Any] { [kIOPSPowerAdapterWattsKey: 86] }
    static var eightySixWatts: Measurement<UnitPower> { .init(value: 86, unit: .watts) }

    static func onACNotCharging(charged: Bool) -> [String: Any] { [
        kIOPSCurrentCapacityKey: 80, kIOPSPowerSourceStateKey: kIOPSACPowerValue, kIOPSIsPresentKey: true,
        kIOPSIsChargingKey: false, kIOPSIsChargedKey: charged,
        kIOPSTimeToFullChargeKey: 0, kIOPSTimeToEmptyKey: 0,
    ] }
    static func charging(timeToFull: Int) -> [String: Any] { [
        kIOPSCurrentCapacityKey: 80, kIOPSPowerSourceStateKey: kIOPSACPowerValue, kIOPSIsPresentKey: true,
        kIOPSIsChargingKey: true, kIOPSIsFinishingChargeKey: false,
        kIOPSTimeToFullChargeKey: timeToFull, kIOPSTimeToEmptyKey: 0,
    ] }
    static func discharging(timeToEmpty: Int) -> [String: Any] { [
        kIOPSCurrentCapacityKey: 80, kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue, kIOPSIsPresentKey: true,
        kIOPSIsChargingKey: false,
        kIOPSTimeToFullChargeKey: 0, kIOPSTimeToEmptyKey: timeToEmpty,
    ] }
    static var notPresent: [String: Any] { [
        kIOPSCurrentCapacityKey: 0, kIOPSPowerSourceStateKey: kIOPSACPowerValue, kIOPSIsPresentKey: false,
        kIOPSIsChargingKey: false, kIOPSTimeToFullChargeKey: 0, kIOPSTimeToEmptyKey: 0,
    ] }

    static func parse(_ powerSource: [String: Any], adapter: [String: Any] = adapter) throws -> BatteryReading {
        try #require(try BatteryReading(registry: registry, powerSource: powerSource, adapter: adapter))
    }

    @Test func hardwareFactsCarryTheirUnits() throws {
        let reading = try Self.parse(Self.onACNotCharging(charged: false))
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
        let reading = try Self.parse(Self.onACNotCharging(charged: false))
        #expect(reading.power == .adapter(Self.eightySixWatts, .notCharging))
    }

    @Test func onACFull() throws {
        let reading = try Self.parse(Self.onACNotCharging(charged: true))
        #expect(reading.power == .adapter(Self.eightySixWatts, .full))
    }

    @Test func chargingWithEstimate() throws {
        let reading = try Self.parse(Self.charging(timeToFull: 82))
        #expect(reading.power == .adapter(Self.eightySixWatts, .charging(timeToFull: .seconds(82 * 60))))
    }

    @Test func chargingWhileStillCalculating() throws {
        let reading = try Self.parse(Self.charging(timeToFull: -1))
        #expect(reading.power == .adapter(Self.eightySixWatts, .charging(timeToFull: nil)))
    }

    @Test func dischargingWithEstimate() throws {
        let reading = try Self.parse(Self.discharging(timeToEmpty: 192), adapter: [:])
        #expect(reading.power == .battery(timeToEmpty: .seconds(192 * 60)))
    }

    @Test func dischargingWhileStillCalculating() throws {
        let reading = try Self.parse(Self.discharging(timeToEmpty: -1), adapter: [:])
        #expect(reading.power == .battery(timeToEmpty: nil))
    }

    @Test func adapterWithoutWattageReadsNone() throws {
        let reading = try Self.parse(Self.onACNotCharging(charged: false), adapter: [:])
        #expect(reading.power == .adapter(nil, .notCharging))
    }

    @Test func batteryNotPresentReadsNil() throws {
        #expect(try BatteryReading(registry: Self.registry, powerSource: Self.notPresent, adapter: Self.adapter) == nil)
    }

    @Test func percentOutsideItsDomainFails() {
        var source = Self.onACNotCharging(charged: false)
        source[kIOPSCurrentCapacityKey] = 250
        #expect(throws: BatteryReadError.invalid(key: kIOPSCurrentCapacityKey, source: "power source")) {
            try Self.parse(source)
        }
    }

    @Test func missingRegistryKeyFailsNamingIt() {
        var registry = Self.registry
        registry["Temperature"] = nil
        #expect(throws: BatteryReadError.invalid(key: "Temperature", source: "registry")) {
            try BatteryReading(registry: registry, powerSource: Self.onACNotCharging(charged: false), adapter: Self.adapter)
        }
    }

    @Test func wrongTypeFailsNamingTheKey() {
        #expect(throws: BatteryReadError.invalid(key: kIOPSPowerAdapterWattsKey, source: "adapter")) {
            try Self.parse(Self.onACNotCharging(charged: false), adapter: [kIOPSPowerAdapterWattsKey: "86"])
        }
    }
}
