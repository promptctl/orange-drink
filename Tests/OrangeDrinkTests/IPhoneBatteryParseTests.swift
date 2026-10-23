import Foundation
import Testing
@testable import OrangeDrink

// [LAW:verifiable-goals] Every recorded reply parses to the values its fixture header names, whichever place the device
// keeps its capacities in; anything the parser cannot stand behind is a typed error.
@Suite struct IPhoneBatteryParse {
    static func entry(_ xml: String) throws -> [String: Any] {
        let root = try plistDictionary(Data(xml.utf8))
        let diagnostics = try #require(root["Diagnostics"] as? [String: Any])
        return try #require(diagnostics["IORegistry"] as? [String: Any])
    }

    static func reading(level: Int, cycles: Int, design: Int, nominal: Int, from place: EntryPlace,
                        stored: Int? = nil) -> IPhoneBatteryReading {
        IPhoneBatteryReading(level: level, cycleCount: cycles, designCapacity: Located(value: design, place: place),
                             nominalChargeCapacity: Located(value: nominal, place: place), storedMaximumCapacity: stored)
    }

    @Test func iPhoneOniOS27ReadsCapacitiesFromBatteryData() throws {
        let reading = try parseIPhoneBattery(try Self.entry(iPhone16_2_iOS27ReplyXML))
        #expect(reading == Self.reading(level: 25, cycles: 584, design: 4395, nominal: 3761, from: .batteryData))
        #expect(reading.maximumCapacityPercent == 86)
    }

    @Test func iPhoneOniOS18ReadsCapacitiesFromTheTopLevelAndCapsHealthAt100() throws {
        let reading = try parseIPhoneBattery(try Self.entry(iPhone17_1_iOS18ReplyXML))
        #expect(reading == Self.reading(level: 8, cycles: 16, design: 3544, nominal: 3637, from: .topLevel))
        #expect(reading.maximumCapacityPercent == 100)
    }

    @Test func olderIPadReadsCapacitiesFromTheTopLevel() throws {
        let reading = try parseIPhoneBattery(try Self.entry(iPadOlderReplyXML))
        #expect(reading == Self.reading(level: 87, cycles: 395, design: 9633, nominal: 8648, from: .topLevel))
        #expect(reading.maximumCapacityPercent == 90)
    }

    @Test func iPadOniPadOS27ReadsCapacitiesFromBatteryData() throws {
        let reading = try parseIPhoneBattery(try Self.entry(iPad13_4_iPadOS27ReplyXML))
        #expect(reading == Self.reading(level: 32, cycles: 580, design: 7596, nominal: 6891, from: .batteryData))
        #expect(reading.maximumCapacityPercent == 91)
    }

    @Test func visionProReadsPercentFromTheTopLevelAndShowsItsStoredHealth() throws {
        let entry = try Self.entry(visionPro_visionOS27ReplyXML)
        // The trap the level rule exists for: the same key name holds mAh inside BatteryData.
        #expect((entry["BatteryData"] as? [String: Any])?["CurrentCapacity"] as? Int == 2730)
        let reading = try parseIPhoneBattery(entry)
        #expect(reading == Self.reading(level: 100, cycles: 209, design: 3060, nominal: 2700, from: .topLevel, stored: 93))
        #expect(reading.maximumCapacityPercent == 93)
    }

    @Test func theReadsLogLineNamesWhereEachCapacityCameFrom() throws {
        // readIPhoneBattery logs String(describing: reading); the place each capacity came from is on that line.
        let line = String(describing: try parseIPhoneBattery(try Self.entry(iPhone16_2_iOS27ReplyXML)))
        #expect(line.contains("value: 4395, place: OrangeDrink.EntryPlace.batteryData"))
        #expect(line.contains("value: 3761, place: OrangeDrink.EntryPlace.batteryData"))
        #expect(line.contains("storedMaximumCapacity: nil"))
    }

    @Test func aCapacityInNeitherPlaceIsATypedError() throws {
        var entry = try Self.entry(iPhone17_1_iOS18ReplyXML)
        entry.removeValue(forKey: "NominalChargeCapacity")
        #expect(throws: IPhoneParseError.missingKey("NominalChargeCapacity")) { try parseIPhoneBattery(entry) }
    }

    @Test func wrongTypeIsATypedError() throws {
        var entry = try Self.entry(iPhone17_1_iOS18ReplyXML)
        entry["CycleCount"] = "16"
        #expect(throws: IPhoneParseError.wrongType("CycleCount")) { try parseIPhoneBattery(entry) }
    }

    @Test func zeroDesignCapacityIsRejectedNotDividedBy() throws {
        var entry = try Self.entry(iPhone17_1_iOS18ReplyXML)
        entry["DesignCapacity"] = 0
        #expect(throws: IPhoneParseError.invalid("DesignCapacity")) { try parseIPhoneBattery(entry) }
    }

    @Test func zeroMaxCapacityIsRejected() throws {
        var entry = try Self.entry(iPhone17_1_iOS18ReplyXML)
        entry["MaxCapacity"] = 0
        #expect(throws: IPhoneParseError.invalid("MaxCapacity")) { try parseIPhoneBattery(entry) }
    }

    @Test func aLevelAboveMaxCapacityIsRejectedNotShownAsAPercent() throws {
        var entry = try Self.entry(iPhone17_1_iOS18ReplyXML)
        entry["CurrentCapacity"] = 2730
        #expect(throws: IPhoneParseError.invalid("CurrentCapacity")) { try parseIPhoneBattery(entry) }
    }

    @Test func twoBatteryPacksAreATypedErrorNotOneReading() throws {
        var entry = try Self.entry(iPhone16_2_iOS27ReplyXML)
        entry["BatteryPackCount"] = 2
        #expect(throws: IPhoneParseError.multiplePacks(2)) { try parseIPhoneBattery(entry) }
    }
}
