import Foundation
import IOKit.ps

/// One reading of the Mac's battery, in the units pmset and ioreg report.
///
/// [LAW:types-are-the-program] Plug state, charging, adapter wattage, and the two time
/// estimates are one nested union, not five independent fields: a wattage cannot exist while
/// discharging and a time-to-full cannot exist while not charging, so no reader ever sees them.
struct BatteryReading: Equatable, Sendable {
    /// The system's own charge figure, 0...100. Not derived from the capacities: the OS smooths it.
    /// powerd rounds it to a multiple of 5 for callers without com.apple.private.iokit.batterydataprecise
    /// while its privacy/ImprecisePowerData feature is on (BatteryTimeRemaining.m, envelopeBatteryInformation);
    /// macOS 26.5 ships no privacy feature-flag plist, so it is off, and pmset and this figure agree.
    let chargePercent: Int
    let power: PowerSource
    let capacity: Capacity
    let cycles: Cycles
    let temperature: Measurement<UnitTemperature>
    let voltage: Measurement<UnitElectricPotentialDifference>
    /// Positive while charge flows into the battery, negative while it flows out.
    let current: Measurement<UnitElectricCurrent>
    /// What the system takes in from the adapter, as the battery's power telemetry reports it;
    /// nil when this Mac publishes none, and while there is no adapter to take from.
    let systemPowerIn: Measurement<UnitPower>?
}

extension BatteryReading {
    /// Positive while power flows into the battery, negative while it flows out: voltage times current.
    var batteryPower: Measurement<UnitPower> {
        .init(value: voltage.converted(to: .volts).value * current.converted(to: .amperes).value, unit: .watts)
    }
}

enum PowerSource: Equatable, Sendable {
    /// `timeToEmpty` is nil while the system has no estimate yet; pmset prints "(no estimate)".
    case battery(timeToEmpty: Duration?)
    /// The wattage is nil when the adapter details carry none: IOPSKeys.h says the Watts key
    /// "might not be defined", and pmset -g ac then prints no Wattage line.
    case adapter(Measurement<UnitPower>?, Charging)
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

enum BatteryReadError: Error, Equatable {
    /// The source lacked the key, or held a value of another type or outside the key's domain.
    case invalid(key: String, source: String)
    /// The smart-battery registry entry's properties could not be copied.
    case registry(status: kern_return_t)
    /// powerd returned nothing from the named IOPowerSources call.
    case powerSources(call: String)
    /// powerd's list of power sources holds no internal battery.
    case noInternalBatterySource
}

extension BatteryReading {
    /// [LAW:parse-dont-validate] The one place IOKit's dictionaries become a reading. The
    /// registry entry holds the hardware facts; the power-source description and adapter
    /// details are the system's own view of state, estimates, and wattage, which is what
    /// pmset shows. Each fact has exactly one source.
    ///
    /// nil when powerd says no battery is present: a laptop whose battery is gone still has
    /// the registry entry and a power source, published with "Is Present" false.
    init?(registry: [String: Any], powerSource: [String: Any], adapter: [String: Any]) throws {
        guard try field(kIOPSIsPresentKey, in: powerSource, "power source") else { return nil }
        let percent: Int = try field(kIOPSCurrentCapacityKey, in: powerSource, "power source")
        guard (0...100).contains(percent) else {
            throw BatteryReadError.invalid(key: kIOPSCurrentCapacityKey, source: "power source")
        }
        chargePercent = percent
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
        // The telemetry is a dictionary of milliwatts, absent on Macs that do not publish it.
        let telemetry: [String: Any]? = try optionalField("PowerTelemetryData", in: registry, "registry")
        let milliwatts: Int? = try telemetry.flatMap { try optionalField("SystemPowerIn", in: $0, "power telemetry") }
        systemPowerIn = milliwatts.map { .init(value: Double($0) / 1000, unit: .watts) }
    }
}

private extension PowerSource {
    init(powerSource: [String: Any], adapter: [String: Any]) throws {
        switch try field(kIOPSPowerSourceStateKey, in: powerSource, "power source") as String {
        case kIOPSBatteryPowerValue:
            self = .battery(timeToEmpty: estimate(try field(kIOPSTimeToEmptyKey, in: powerSource, "power source")))
        case kIOPSACPowerValue:
            let watts: Int? = try optionalField(kIOPSPowerAdapterWattsKey, in: adapter, "adapter")
            self = .adapter(watts.map { .init(value: Double($0), unit: .watts) }, try Charging(powerSource: powerSource))
        default:
            throw BatteryReadError.invalid(key: kIOPSPowerSourceStateKey, source: "power source")
        }
    }
}

private extension Charging {
    /// powerd publishes "Is Charged" only while plugged in and not charging (PowerManagement,
    /// BatteryTimeRemaining.m, packageKernelPowerSource), so it is read only on that branch.
    init(powerSource: [String: Any]) throws {
        if try field(kIOPSIsChargingKey, in: powerSource, "power source") {
            self = .charging(timeToFull: estimate(try field(kIOPSTimeToFullChargeKey, in: powerSource, "power source")))
        } else if try field(kIOPSIsChargedKey, in: powerSource, "power source") {
            self = .full
        } else {
            self = .notCharging
        }
    }
}

/// IOPowerSources reports minutes, and `kIOPSTimeRemainingUnknown` while still calculating.
private func estimate(_ minutes: Int) -> Duration? {
    minutes == Int(kIOPSTimeRemainingUnknown) ? nil : .seconds(minutes * 60)
}

private func field<T>(_ key: String, in dictionary: [String: Any], _ source: String) throws -> T {
    guard let value: T = try optionalField(key, in: dictionary, source) else {
        throw BatteryReadError.invalid(key: key, source: source)
    }
    return value
}

/// nil when the key is absent; a value present under the key but of another type is an error.
private func optionalField<T>(_ key: String, in dictionary: [String: Any], _ source: String) throws -> T? {
    guard let raw = dictionary[key] else { return nil }
    guard let value = raw as? T else { throw BatteryReadError.invalid(key: key, source: source) }
    return value
}
