import Foundation

// [LAW:types-are-the-program] One parse for every device: where a capacity sits moves with the OS (top level on
// iOS 18, BatteryData on iOS 27, both on visionOS; orange-iphone-watch-lm3.7iy), so the parser never asks what kind of
// device answered. Each field is read from the place its meaning is fixed, and the reading says where it found it.

/// Where in the IORegistry battery entry a value was found, named as the entry names it.
enum EntryPlace: String, Equatable {
    case topLevel = "top level"
    case batteryData = "BatteryData"
}

struct EntryCapacity: Equatable, Sendable {
    let mAh: Int
    let place: EntryPlace
}

/// The health a screen shows, and which of the two derivations gave it.
enum MaximumCapacity: Equatable {
    /// BatteryHealthData.BatteryHealthMaxCapacity: the figure the device stores itself (seen on visionOS).
    case stored(Int)
    /// Nominal over design capacity, in percent: the ratio iPhone16,2's Settings matched (86%, cmt-a2f429b6).
    case ratio(Double)

    /// The cap at 100 is inferred from iPhone17,1, whose Settings reads 100% where the ratio is 102.6% (cmt-04c5ee7d);
    /// it is not a documented rule.
    var percent: Int {
        switch self {
        case .stored(let percent): percent
        case .ratio(let ratio): min(100, Int(ratio.rounded()))
        }
    }
}

extension MaximumCapacity: CustomStringConvertible {
    var description: String {
        switch self {
        case .stored: "\(percent)% (stored)"
        case .ratio(let ratio): "\(percent)% (" + String(format: "ratio %.1f%%", ratio) + ")"
        }
    }
}

struct IPhoneBatteryReading: Equatable {
    /// Percent: top-level CurrentCapacity over top-level MaxCapacity.
    let level: Int
    let cycleCount: Int
    let designCapacity: EntryCapacity
    let nominalChargeCapacity: EntryCapacity
    /// nil on devices that store no health figure of their own.
    let storedMaximumCapacity: Int?

    /// A device that stores its own figure is taken at its word; otherwise the ratio.
    var maximumCapacity: MaximumCapacity {
        storedMaximumCapacity.map(MaximumCapacity.stored)
            ?? .ratio(Double(nominalChargeCapacity.mAh) / Double(designCapacity.mAh) * 100)
    }
}

// [LAW:behavior-not-structure] The read's log line and the hardware check's record are this text, so its format is
// stated here rather than left to reflection.
extension IPhoneBatteryReading: CustomStringConvertible {
    var description: String {
        "level \(level)%, cycles \(cycleCount), design \(designCapacity.mAh) mAh (\(designCapacity.place.rawValue)), "
            + "nominal \(nominalChargeCapacity.mAh) mAh (\(nominalChargeCapacity.place.rawValue)), max capacity \(maximumCapacity)"
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
/// out-of-range value is an error, never a default; every integer read states its range.
func parseIPhoneBattery(_ entry: [String: Any]) throws -> IPhoneBatteryReading {
    // iOS 18 replies carry no BatteryPackCount; their devices have one battery.
    if let packs = try optional(entry, "BatteryPackCount", as: Int.self), packs != 1 {
        throw IPhoneParseError.multiplePacks(packs)
    }
    // BatteryData.CurrentCapacity is never read: on visionOS it is mAh (2730) where the top level is percent (100).
    let max = try integer(entry, "MaxCapacity", in: 1...)
    let current = try integer(entry, "CurrentCapacity", in: 0...max)
    let battery = try dictionary(entry, "BatteryData")
    let health = try optional(entry, "BatteryHealthData", as: [String: Any].self)
    return IPhoneBatteryReading(
        level: current * 100 / max,
        cycleCount: try integer(entry, "CycleCount", in: 0...),
        designCapacity: try capacity(entry, battery, "DesignCapacity"),
        nominalChargeCapacity: try capacity(entry, battery, "NominalChargeCapacity"),
        storedMaximumCapacity: try health.map { try integer($0, "BatteryHealthMaxCapacity", in: 1...100) })
}

/// A capacity in mAh: the top-level key if present, else the BatteryData key. The two places are separate snapshots
/// (Voltage differs between them within one reply), so a key's two values are never compared; the precedence is
/// fixed.
private func capacity(_ entry: [String: Any], _ battery: [String: Any], _ key: String) throws -> EntryCapacity {
    let place: EntryPlace = entry[key] == nil ? .batteryData : .topLevel
    return EntryCapacity(mAh: try integer(place == .topLevel ? entry : battery, key, in: 1...), place: place)
}

/// The value at key, which must be present, an integer, and within range.
private func integer(_ dict: [String: Any], _ key: String, in range: some RangeExpression<Int>) throws -> Int {
    guard let value = try optional(dict, key, as: Int.self) else { throw IPhoneParseError.missingKey(key) }
    guard range.contains(value) else { throw IPhoneParseError.invalid(key) }
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
