import Foundation
import Testing
@testable import OrangeDrink

// [LAW:verifiable-goals] The iPhone reply recorded from the reference phone parses to the values Settings shows.
@Suite struct IPhoneBatteryParse {
    static func entry(_ xml: String) throws -> [String: Any] {
        let root = try plistDictionary(Data(xml.utf8))
        let diagnostics = try #require(root["Diagnostics"] as? [String: Any])
        return try #require(diagnostics["IORegistry"] as? [String: Any])
    }

    @Test func iPhoneReplyReadsLevelHealthCyclesAndLifetimeStats() throws {
        let reading = try parseIPhoneBattery(try Self.entry(iPhoneBatteryReplyXML), layout: .inBatteryData)
        #expect(reading == IPhoneBatteryReading(level: 55, health: 3761.0 / 4395.0, cycleCount: 584,
                                                designCapacity: 4395, appleRawMaxCapacity: 3908))
        // Settings > Battery > Maximum Capacity on this phone reads 86% (cmt-a2f429b6).
        let health = try #require(reading.health)
        #expect(Int((health * 100).rounded()) == 86)
    }

    @Test func iPadReplyReadsTheTopLevelLayout() throws {
        let reading = try parseIPhoneBattery(try Self.entry(iPadBatteryReplyXML), layout: .topLevel)
        #expect(reading == IPhoneBatteryReading(level: 87, health: nil, cycleCount: 395,
                                                designCapacity: 9633, appleRawMaxCapacity: 8506))
    }

    @Test func iPadReplyUnderTheiPhoneLayoutIsATypedErrorNotAGuess() throws {
        #expect(throws: IPhoneParseError.missingKey("NominalChargeCapacity")) {
            try parseIPhoneBattery(try Self.entry(iPadBatteryReplyXML), layout: .inBatteryData)
        }
    }

    @Test func missingNominalCapacityIsATypedErrorNotADefault() throws {
        var battery = try #require(try Self.entry(iPhoneBatteryReplyXML)["BatteryData"] as? [String: Any])
        battery.removeValue(forKey: "NominalChargeCapacity")
        #expect(throws: IPhoneParseError.missingKey("NominalChargeCapacity")) {
            try parseIPhoneBattery(["BatteryData": battery, "CycleCount": 584], layout: .inBatteryData)
        }
    }

    @Test func wrongTypeIsATypedError() throws {
        #expect(throws: IPhoneParseError.wrongType("CycleCount")) {
            try parseIPhoneBattery(["BatteryData": ["CurrentCapacity": 55, "NominalChargeCapacity": 1,
                                                    "DesignCapacity": 2, "AppleRawMaxCapacity": 3],
                                    "CycleCount": "584"], layout: .inBatteryData)
        }
    }

    @Test func zeroDesignCapacityIsRejectedNotDividedBy() throws {
        #expect(throws: IPhoneParseError.invalid("DesignCapacity")) {
            try parseIPhoneBattery(["BatteryData": ["CurrentCapacity": 55, "NominalChargeCapacity": 1,
                                                    "DesignCapacity": 0, "AppleRawMaxCapacity": 3],
                                    "CycleCount": 584], layout: .inBatteryData)
        }
    }

    @Test func layoutComesFromDeviceClassOnly() {
        #expect(IPhoneLayout(deviceClass: "iPhone") == .inBatteryData)
        #expect(IPhoneLayout(deviceClass: "iPad") == .topLevel)
        #expect(IPhoneLayout(deviceClass: "Mac") == nil)
    }
}
