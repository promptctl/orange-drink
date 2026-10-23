import Foundation

// [LAW:types-are-the-program] One parse for every device: where a capacity sits moves with the OS (top level on
// iOS 18, BatteryData on iOS 27, both on visionOS; orange-iphone-watch-lm3.7iy), so the parser never asks what kind of
// device answered. Each field is read from the place its meaning is fixed, and the reading says where it found it.

/// Where in the IORegistry battery entry a value was found.
enum EntryPlace: Equatable {
    case topLevel
    case batteryData
}

struct Located<Value: Equatable & Sendable>: Equatable, Sendable {
    let value: Value
    let place: EntryPlace
}

struct IPhoneBatteryReading: Equatable {
    /// Percent: top-level CurrentCapacity over top-level MaxCapacity.
    let level: Int
    let cycleCount: Int
    let designCapacity: Located<Int>
    let nominalChargeCapacity: Located<Int>
    /// BatteryHealthData.BatteryHealthMaxCapacity: the health figure the device stores itself (seen on visionOS); nil
    /// on devices that store none.
    let storedMaximumCapacity: Int?

    /// The health a screen shows. A device that stores its own figure is taken at its word. Otherwise nominal over design
    /// capacity: the ratio iPhone16,2's Settings matched (86%, cmt-a2f429b6). The cap at 100 is inferred from iPhone17,1,
    /// whose Settings reads 100% where the ratio is 102.6% (cmt-04c5ee7d); it is not a documented rule.
    var maximumCapacityPercent: Int {
        storedMaximumCapacity
            ?? min(100, Int((Double(nominalChargeCapacity.value) / Double(designCapacity.value) * 100).rounded()))
    }
}

enum IPhoneParseError: Error, Equatable {
    case missingKey(String)
    case wrongType(String)
    case invalid(String)
    /// The entry reports more than one battery pack. One reading cannot stand for two batteries.
    case multiplePacks(Int)
}

/// Parses the IORegistry IOPMPowerSource entry (the Diagnostics.IORegistry dictionary). A missing, wrong-typed or
/// out-of-range value is an error, never a default.
func parseIPhoneBattery(_ entry: [String: Any]) throws -> IPhoneBatteryReading {
    // iOS 18 replies carry no BatteryPackCount; their devices have one battery.
    if let packs = try optional(entry, "BatteryPackCount", as: Int.self), packs != 1 {
        throw IPhoneParseError.multiplePacks(packs)
    }
    // BatteryData.CurrentCapacity is never read: on visionOS it is mAh (2730) where the top level is percent (100).
    let current = try integer(entry, "CurrentCapacity")
    let max = try integer(entry, "MaxCapacity")
    guard max > 0 else { throw IPhoneParseError.invalid("MaxCapacity") }
    guard (0...max).contains(current) else { throw IPhoneParseError.invalid("CurrentCapacity") }

    let battery = try dictionary(entry, "BatteryData")
    let design = try capacity(entry, battery, "DesignCapacity")
    guard design.value > 0 else { throw IPhoneParseError.invalid("DesignCapacity") }
    let health = try optional(entry, "BatteryHealthData", as: [String: Any].self)
    return IPhoneBatteryReading(
        level: current * 100 / max,
        cycleCount: try integer(entry, "CycleCount"),
        designCapacity: design,
        nominalChargeCapacity: try capacity(entry, battery, "NominalChargeCapacity"),
        storedMaximumCapacity: try health.map { try integer($0, "BatteryHealthMaxCapacity") })
}

/// A capacity in mAh: the top-level key if present, else the BatteryData key. The two places are separate snapshots
/// (Voltage differs between them within one reply), so they are never compared; the precedence is fixed.
private func capacity(_ entry: [String: Any], _ battery: [String: Any], _ key: String) throws -> Located<Int> {
    if let value = try optional(entry, key, as: Int.self) { return Located(value: value, place: .topLevel) }
    if let value = try optional(battery, key, as: Int.self) { return Located(value: value, place: .batteryData) }
    throw IPhoneParseError.missingKey(key)
}

private func integer(_ dict: [String: Any], _ key: String) throws -> Int {
    guard let value = try optional(dict, key, as: Int.self) else { throw IPhoneParseError.missingKey(key) }
    return value
}

private func dictionary(_ dict: [String: Any], _ key: String) throws -> [String: Any] {
    guard let value = try optional(dict, key, as: [String: Any].self) else { throw IPhoneParseError.missingKey(key) }
    return value
}

/// nil when the key is absent; wrongType when it is present with another type.
private func optional<T>(_ dict: [String: Any], _ key: String, as _: T.Type) throws -> T? {
    guard let value = dict[key] else { return nil }
    guard let typed = value as? T else { throw IPhoneParseError.wrongType(key) }
    return typed
}
