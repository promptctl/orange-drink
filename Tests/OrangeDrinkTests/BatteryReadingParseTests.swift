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
    /// The registry as the charger reports a charge limit in force: this Mac at its 80% Charge
    /// Limit, where ChargerData's NotChargingReason read 16777216 (bit 24).
    static func charger(reason: Any) -> [String: Any] {
        registry.merging(["ChargerData": ["NotChargingReason": reason, "ChargingCurrent": 3539]]) { $1 }
    }
    static var limitInForce: [String: Any] { charger(reason: 16_777_216) }
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

    static func parse(_ powerSource: [String: Any], adapter: [String: Any] = adapter,
                      registry: [String: Any] = registry) throws -> BatteryReading {
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
        #expect(reading.power == .adapter(Self.eightySixWatts, .charging(.toFull(in: .seconds(82 * 60)))))
    }

    @Test func chargingWhileStillCalculating() throws {
        let reading = try Self.parse(Self.charging(timeToFull: -1))
        #expect(reading.power == .adapter(Self.eightySixWatts, .charging(.toFull(in: nil))))
    }

    // The reported moment, captured live: at 80%, IOPS still says charging with 48 min to full
    // (its estimate is to 100%) while the charger already reports the limit in force.
    @Test func chargingWithTheLimitInForceHasNoEstimate() throws {
        let reading = try Self.parse(Self.charging(timeToFull: 48), registry: Self.limitInForce)
        #expect(reading.power == .adapter(Self.eightySixWatts, .charging(.limited)))
        #expect(reading.power.estimate == nil)
        // What the "battery read:" log line carries for this reading.
        #expect(String(describing: reading.power).contains("limited"))
    }

    // The charger's report alone decides, whatever the level: the parse claims no more than it.
    @Test func theLimitReportDecidesAtAnyLevel() throws {
        var source = Self.charging(timeToFull: 55)
        source[kIOPSCurrentCapacityKey] = 76
        #expect(try Self.parse(source, registry: Self.limitInForce).power == .adapter(Self.eightySixWatts, .charging(.limited)))
    }

    // Every charging reading below the limit on this Mac: the charger data present, the reason 0.
    @Test func chargingWithNoReasonKeepsTheEstimate() throws {
        let reading = try Self.parse(Self.charging(timeToFull: 48), registry: Self.charger(reason: 0))
        #expect(reading.power == .adapter(Self.eightySixWatts, .charging(.toFull(in: .seconds(48 * 60)))))
    }

    @Test func theLimitReportDoesNotExcuseAMissingEstimate() {
        var source = Self.charging(timeToFull: 48)
        source[kIOPSTimeToFullChargeKey] = nil
        #expect(throws: BatteryReadError.invalid(key: kIOPSTimeToFullChargeKey, source: "power source")) {
            try Self.parse(source, registry: Self.limitInForce)
        }
    }

    @Test func onlyTheLimitBitIsRead() throws {
        let reading = try Self.parse(Self.charging(timeToFull: 82), registry: Self.charger(reason: 128))
        #expect(reading.power == .adapter(Self.eightySixWatts, .charging(.toFull(in: .seconds(82 * 60)))))
    }

    @Test func theHoldAtTheLimitIsNotCharging() throws {
        let reading = try Self.parse(Self.onACNotCharging(charged: false), registry: Self.limitInForce)
        #expect(reading.power == .adapter(Self.eightySixWatts, .notCharging))
    }

    @Test func aMistypedChargerReasonFailsNamingIt() {
        #expect(throws: BatteryReadError.invalid(key: "NotChargingReason", source: "charger data")) {
            try Self.parse(Self.charging(timeToFull: 48), registry: Self.charger(reason: "16777216"))
        }
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

extension BatteryReadingParse {
    @Test func aRegistryWithoutADesignCapacityFailsNamingIt() {
        var registry = Self.registry
        registry["DesignCapacity"] = 0
        #expect(throws: BatteryReadError.invalid(key: "DesignCapacity", source: "registry")) {
            try BatteryReading(registry: registry, powerSource: Self.onACNotCharging(charged: false), adapter: Self.adapter)
        }
    }
}
