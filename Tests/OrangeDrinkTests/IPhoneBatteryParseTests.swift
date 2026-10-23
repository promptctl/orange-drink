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
        IPhoneBatteryReading(level: level, cycleCount: cycles, designCapacity: EntryCapacity(mAh: design, place: place),
                             nominalChargeCapacity: EntryCapacity(mAh: nominal, place: place), storedMaximumCapacity: stored)
    }

    @Test func iPhoneOniOS27ReadsCapacitiesFromBatteryData() throws {
        let reading = try parseIPhoneBattery(try Self.entry(iPhone16_2_iOS27ReplyXML))
        #expect(reading == Self.reading(level: 25, cycles: 584, design: 4395, nominal: 3761, from: .batteryData))
        #expect(reading.maximumCapacity.percent == 86)
    }

    @Test func iPhoneOniOS18ReadsCapacitiesFromTheTopLevelAndCapsHealthAt100() throws {
        let reading = try parseIPhoneBattery(try Self.entry(iPhone17_1_iOS18ReplyXML))
        #expect(reading == Self.reading(level: 8, cycles: 16, design: 3544, nominal: 3637, from: .topLevel))
        #expect(reading.maximumCapacity.percent == 100)
    }

    @Test func olderIPadReadsCapacitiesFromTheTopLevel() throws {
        let reading = try parseIPhoneBattery(try Self.entry(iPadOlderReplyXML))
        #expect(reading == Self.reading(level: 87, cycles: 395, design: 9633, nominal: 8648, from: .topLevel))
        #expect(reading.maximumCapacity.percent == 90)
    }

    @Test func iPadOniPadOS27ReadsCapacitiesFromBatteryData() throws {
        let reading = try parseIPhoneBattery(try Self.entry(iPad13_4_iPadOS27ReplyXML))
        #expect(reading == Self.reading(level: 32, cycles: 580, design: 7596, nominal: 6891, from: .batteryData))
        #expect(reading.maximumCapacity.percent == 91)
    }

    @Test func visionProReadsPercentFromTheTopLevelAndShowsItsStoredHealth() throws {
        let entry = try Self.entry(visionPro_visionOS27ReplyXML)
        // The trap the level rule exists for: the same key name holds mAh inside BatteryData.
        #expect((entry["BatteryData"] as? [String: Any])?["CurrentCapacity"] as? Int == 2730)
        let reading = try parseIPhoneBattery(entry)
        #expect(reading == Self.reading(level: 100, cycles: 209, design: 3060, nominal: 2700, from: .topLevel, stored: 93))
        #expect(reading.maximumCapacity.percent == 93)
    }

    @Test func theReadsLogLineNamesWhereEachCapacityAndTheHealthFigureCameFrom() throws {
        // readIPhoneBattery logs, and the hardware check records, String(describing: reading).
        #expect(String(describing: try parseIPhoneBattery(try Self.entry(iPhone16_2_iOS27ReplyXML)))
            == "level 25%, cycles 584, design 4395 mAh (BatteryData), nominal 3761 mAh (BatteryData), max capacity 86% (ratio 85.6%)")
        #expect(String(describing: try parseIPhoneBattery(try Self.entry(iPhone17_1_iOS18ReplyXML)))
            == "level 8%, cycles 16, design 3544 mAh (top level), nominal 3637 mAh (top level), max capacity 100% (ratio 102.6%)")
        #expect(String(describing: try parseIPhoneBattery(try Self.entry(visionPro_visionOS27ReplyXML)))
            == "level 100%, cycles 209, design 3060 mAh (top level), nominal 2700 mAh (top level), max capacity 93% (stored)")
    }

    @Test(arguments: [("CycleCount", -1), ("NominalChargeCapacity", 0), ("DesignCapacity", 0), ("MaxCapacity", 0),
                      ("CurrentCapacity", -1)])
    func aValueOutOfRangeIsRejected(key: String, value: Int) throws {
        var entry = try Self.entry(iPhone17_1_iOS18ReplyXML)
        entry[key] = value
        #expect(throws: IPhoneParseError.invalid(key)) { try parseIPhoneBattery(entry) }
    }

    @Test(arguments: [0, 101, 255])
    func aStoredHealthFigureOutOfRangeIsRejected(value: Int) throws {
        var entry = try Self.entry(visionPro_visionOS27ReplyXML)
        entry["BatteryHealthData"] = ["BatteryHealthMaxCapacity": value]
        #expect(throws: IPhoneParseError.invalid("BatteryHealthMaxCapacity")) { try parseIPhoneBattery(entry) }
    }

    @Test func aRelaySuccessWithNoEntryIsNoPowerSourceNotAProtocolFault() throws {
        #expect(throws: IPhoneReadError.noPowerSource) { try powerSourceEntry(["Status": "Success"]) }
        #expect(throws: IPhoneReadError.lockdown("Diagnostics")) { try powerSourceEntry(["Status": "Failure"]) }
        #expect(throws: IPhoneReadError.lockdown("Diagnostics.IORegistry")) { try powerSourceEntry(["Diagnostics": [:]]) }
        let entry = try powerSourceEntry(try plistDictionary(Data(iPhone17_1_iOS18ReplyXML.utf8)))
        #expect(try parseIPhoneBattery(entry) == parseIPhoneBattery(try Self.entry(iPhone17_1_iOS18ReplyXML)))
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
