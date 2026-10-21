import Foundation

// [LAW:types-are-the-program] iPhone and iPad report the same facts in different places. The layout is a typed
// choice made from lockdown's DeviceClass by the caller; the parser never guesses it from which keys are present.
enum IPhoneLayout: Equatable {
    /// iPhone: CycleCount top-level; CurrentCapacity, NominalChargeCapacity, DesignCapacity, AppleRawMaxCapacity in BatteryData.
    case inBatteryData
    /// iPad: CycleCount, CurrentCapacity, AppleRawMaxCapacity top-level; DesignCapacity in BatteryData.
    case topLevel

    init?(deviceClass: String) {
        switch deviceClass {
        case "iPhone": self = .inBatteryData
        case "iPad": self = .topLevel
        default: return nil
        }
    }
}

struct IPhoneBatteryReading: Equatable {
    /// Percent, from CurrentCapacity.
    let level: Int
    /// NominalChargeCapacity / DesignCapacity as a fraction. This is the figure Settings > Battery shows as
    /// Maximum Capacity on iPhone (cmt-a2f429b6). nil on the layout that records no nominal capacity.
    let health: Double?
    let cycleCount: Int
    let designCapacity: Int
    let appleRawMaxCapacity: Int
}

enum IPhoneParseError: Error, Equatable {
    case missingKey(String)
    case wrongType(String)
    case invalid(String)
}

/// Parses the IORegistry AppleSmartBattery entry (the Diagnostics.IORegistry dictionary) under the given layout.
/// Every key the layout needs must be present; a missing or wrong-typed key is an error, never a default.
func parseIPhoneBattery(_ entry: [String: Any], layout: IPhoneLayout) throws -> IPhoneBatteryReading {
    switch layout {
    case .inBatteryData:
        let battery = try dictionary(entry, "BatteryData")
        let nominal = try integer(battery, "NominalChargeCapacity")
        let design = try integer(battery, "DesignCapacity")
        guard design > 0 else { throw IPhoneParseError.invalid("DesignCapacity") }
        return IPhoneBatteryReading(
            level: try integer(battery, "CurrentCapacity"),
            health: Double(nominal) / Double(design),
            cycleCount: try integer(entry, "CycleCount"),
            designCapacity: design,
            appleRawMaxCapacity: try integer(battery, "AppleRawMaxCapacity"))
    case .topLevel:
        let battery = try dictionary(entry, "BatteryData")
        let design = try integer(battery, "DesignCapacity")
        guard design > 0 else { throw IPhoneParseError.invalid("DesignCapacity") }
        return IPhoneBatteryReading(
            level: try integer(entry, "CurrentCapacity"),
            health: nil,
            cycleCount: try integer(entry, "CycleCount"),
            designCapacity: design,
            appleRawMaxCapacity: try integer(entry, "AppleRawMaxCapacity"))
    }
}

private func integer(_ dict: [String: Any], _ key: String) throws -> Int {
    guard let value = dict[key] else { throw IPhoneParseError.missingKey(key) }
    guard let number = value as? Int else { throw IPhoneParseError.wrongType(key) }
    return number
}

private func dictionary(_ dict: [String: Any], _ key: String) throws -> [String: Any] {
    guard let value = dict[key] else { throw IPhoneParseError.missingKey(key) }
    guard let nested = value as? [String: Any] else { throw IPhoneParseError.wrongType(key) }
    return nested
}
