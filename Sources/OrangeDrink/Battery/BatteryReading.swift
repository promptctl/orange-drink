import Foundation
import IOKit.ps

/// One reading of the Mac's battery, in the units pmset and ioreg report.
///
/// [LAW:types-are-the-program] Plug state, charging, adapter wattage, and the two time
/// estimates are one nested union, not five independent fields: a wattage cannot exist while
/// discharging and a time-to-full cannot exist while not charging, so no reader ever sees them.
struct BatteryReading: Equatable, Sendable {
    /// The system's own charge figure, 0...100. Not derived from the capacities: the OS smooths it.
    let chargePercent: Int
    let power: PowerSource
    let capacity: Capacity
    let cycles: Cycles
    let temperature: Measurement<UnitTemperature>
    let voltage: Measurement<UnitElectricPotentialDifference>
    /// Positive while charge flows into the battery, negative while it flows out.
    let current: Measurement<UnitElectricCurrent>
}

enum PowerSource: Equatable, Sendable {
    /// `timeToEmpty` is nil while the system has no estimate yet; pmset prints "(no estimate)".
    case battery(timeToEmpty: Duration?)
    case adapter(Measurement<UnitPower>, Charging)
}

enum Charging: Equatable, Sendable {
    /// `timeToFull` is nil while the system has no estimate yet.
    case charging(timeToFull: Duration?)
    /// On an adapter with no charge flowing: held under a charge limit, or paused by the system.
    case notCharging
    case full
}

struct Capacity: Equatable, Sendable {
    let current: Measurement<UnitElectricCharge>
    /// What a full charge holds today. Over design capacity, this is battery health.
    let full: Measurement<UnitElectricCharge>
    let design: Measurement<UnitElectricCharge>
}

struct Cycles: Equatable, Sendable {
    let count: Int
    let rated: Int
}

struct BatteryReadError: Error, Equatable {
    /// The key the source lacked, or held a value of the wrong type or outside its domain.
    let key: String
    let source: String
}

extension BatteryReading {
    /// [LAW:parse-dont-validate] The one place IOKit's dictionaries become a reading. The
    /// registry entry holds the hardware facts; the power-source description and adapter
    /// details are the system's own view of state, estimates, and wattage, which is what
    /// pmset shows. Each fact has exactly one source.
    init(registry: [String: Any], powerSource: [String: Any], adapter: [String: Any]?) throws {
        chargePercent = try field(kIOPSCurrentCapacityKey, in: powerSource, "power source")
        power = try PowerSource(powerSource: powerSource, adapter: adapter)
        // The registry holds integers: mAh, hundredths of a degree, millivolts, milliamperes.
        func integer(_ key: String) throws -> Double { Double(try field(key, in: registry, "registry") as Int) }
        capacity = Capacity(
            current: .init(value: try integer("AppleRawCurrentCapacity"), unit: .milliampereHours),
            full: .init(value: try integer("AppleRawMaxCapacity"), unit: .milliampereHours),
            design: .init(value: try integer("DesignCapacity"), unit: .milliampereHours))
        cycles = Cycles(
            count: try field("CycleCount", in: registry, "registry"),
            rated: try field("DesignCycleCount9C", in: registry, "registry"))
        temperature = .init(value: try integer("Temperature") / 100, unit: .celsius)
        voltage = .init(value: try integer("Voltage") / 1000, unit: .volts)
        current = .init(value: try integer("Amperage"), unit: .milliamperes)
    }
}

private extension PowerSource {
    init(powerSource: [String: Any], adapter: [String: Any]?) throws {
        switch try field(kIOPSPowerSourceStateKey, in: powerSource, "power source") as String {
        case kIOPSBatteryPowerValue:
            self = .battery(timeToEmpty: estimate(try field(kIOPSTimeToEmptyKey, in: powerSource, "power source")))
        case kIOPSACPowerValue:
            guard let adapter else { throw BatteryReadError(key: kIOPSPowerAdapterWattsKey, source: "adapter") }
            let watts: Int = try field(kIOPSPowerAdapterWattsKey, in: adapter, "adapter")
            self = .adapter(.init(value: Double(watts), unit: .watts), try Charging(powerSource: powerSource))
        default:
            throw BatteryReadError(key: kIOPSPowerSourceStateKey, source: "power source")
        }
    }
}

private extension Charging {
    init(powerSource: [String: Any]) throws {
        let charged: Bool = try field(kIOPSIsChargedKey, in: powerSource, "power source")
        let charging: Bool = try field(kIOPSIsChargingKey, in: powerSource, "power source")
        switch (charged, charging) {
        case (true, _): self = .full
        case (false, true): self = .charging(timeToFull: estimate(try field(kIOPSTimeToFullChargeKey, in: powerSource, "power source")))
        case (false, false): self = .notCharging
        }
    }
}

/// IOPowerSources reports minutes, and `kIOPSTimeRemainingUnknown` while still calculating.
private func estimate(_ minutes: Int) -> Duration? {
    minutes == Int(kIOPSTimeRemainingUnknown) ? nil : .seconds(minutes * 60)
}

private func field<T>(_ key: String, in dictionary: [String: Any], _ source: String) throws -> T {
    guard let value = dictionary[key] as? T else { throw BatteryReadError(key: key, source: source) }
    return value
}
