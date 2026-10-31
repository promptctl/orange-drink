import Foundation
import Testing
@testable import OrangeDrink

// [LAW:verifiable-goals] Accessory levels from power management's sources, recorded and hand-cut: no Bluetooth in the room.
struct AccessoryPowerTests {
    static func recorded() throws -> [[String: Any]] {
        try #require(try PropertyListSerialization.propertyList(from: Data(accessorySourcesXML.utf8), format: nil) as? [[String: Any]])
    }

    static func level(_ percent: Int) -> BatteryLevel { BatteryLevel(percent: percent, approximate: false) }

    static func source(_ name: String, _ part: String, _ percent: Int, group: String? = nil) -> [String: Any] {
        var source: [String: Any] = ["Type": "Accessory Source", "Name": name, "Part Identifier": part,
                                     "Current Capacity": percent, "Max Capacity": 100]
        source["Group Identifier"] = group
        return source
    }

    @Test func everyRecordedSetHasEachPartItReported() throws {
        let levels = AccessoryPower.levels(from: try Self.recorded())
        #expect(levels.byName == [
            "c-pods": .earbuds(left: Self.level(28), right: nil, case: Self.level(1)),
            "ear-pluggers": .earbuds(left: Self.level(100), right: Self.level(100), case: Self.level(100)),
            "FluffPods": .single(Self.level(47)),
            "CMF Buds": .single(Self.level(60)),
        ])
        #expect(levels.unattributed.isEmpty)
    }

    @Test func aSweepNamesTheDevicesWithNoBatteryAndTheSetsNoDeviceClaimed() throws {
        let levels = AccessoryPower.levels(from: try Self.recorded())
        // FluffPods and CMF Buds were the connected devices; a renamed one would miss its set.
        #expect(levels.attribution(of: ["FluffPods", "CMF Buds"])
                == .init(unlevelled: [], unclaimed: ["c-pods", "ear-pluggers"]))
        #expect(levels.attribution(of: ["FluffPods", "Brandon’s CMF Buds"])
                == .init(unlevelled: ["Brandon’s CMF Buds"], unclaimed: ["CMF Buds", "c-pods", "ear-pluggers"]))
    }

    @Test func aCopyPowerdDidNotAnswerNamesItsCall() {
        #expect(throws: PowerSourcesError.unanswered(call: "IOPSCopyPowerSourcesByType")) {
            try PowerSources.descriptions(nil, copiedBy: "IOPSCopyPowerSourcesByType")
        }
    }

    @Test func onlyAccessorySourcesAreRead() {
        let mac: [String: Any] = ["Type": "InternalBattery", "Name": "InternalBattery-0", "Current Capacity": 80, "Max Capacity": 100]
        #expect(AccessoryPower.levels(from: [mac]) == .init())
    }

    @Test func aCombinedSourceWithNoPartsIsOneLevel() {
        var combined = Self.source("headset", "Combined", 30)
        combined["Combined Parts"] = [[String: Any]]()
        #expect(AccessoryPower.levels(from: [combined]).byName == ["headset": .single(Self.level(30))])
    }

    @Test func aCombinedSourceIsReadFromItsParts() {
        var combined: [String: Any] = ["Type": "Accessory Source", "Name": "pods", "Part Identifier": "Combined", "Group Identifier": "G"]
        combined["Combined Parts"] = [Self.source("pods", "Left", 40), Self.source("pods", "Right", 45)]
        let levels = AccessoryPower.levels(from: [combined, Self.source("pods Case", "Case", 90, group: "G")])
        #expect(levels.byName == ["pods": .earbuds(left: Self.level(40), right: Self.level(45), case: Self.level(90))])
    }

    @Test func aCaseReportingAloneIsItsSetsCase() {
        let levels = AccessoryPower.levels(from: [Self.source("c-pods Case", "Case", 0, group: "G")])
        // 0 from power management is a reading: a drained case.
        #expect(levels.byName == ["c-pods": .earbuds(left: nil, right: nil, case: Self.level(0))])
    }

    // The join meets on `Device.name`'s text, so a source's name is cleaned as a device's is.
    @Test func aPaddedNameMeetsTheDeviceItNames() {
        let device = Device.name(alias: "pods ", broadcast: nil, address: "AA")
        let earbuds = AccessoryPower.levels(from: [Self.source("pods ", "Left", 40, group: "G"), Self.source("pods  Case", "Case", 90, group: "G")])
        #expect(earbuds.byName == [device: .earbuds(left: Self.level(40), right: nil, case: Self.level(90))])
        let caseAlone = AccessoryPower.levels(from: [Self.source("pods  Case", "Case", 90, group: "G")])
        #expect(caseAlone.byName == [device: .earbuds(left: nil, right: nil, case: Self.level(90))])
    }

    @Test func twoSetsWithOneNameHaveNoLevels() {
        let levels = AccessoryPower.levels(from: [Self.source("Magic Mouse", "Single", 100), Self.source("Magic Mouse", "Single", 40)])
        #expect(levels.byName.isEmpty)
        #expect(levels.unattributed == ["2 sets named Magic Mouse"])
    }

    @Test func aSetThatSaysTwoThingsAtOnceHasNoLevels() {
        let levels = AccessoryPower.levels(from: [
            Self.source("buds", "Single", 50, group: "A"), Self.source("buds Case", "Case", 70, group: "A"),
            Self.source("pods", "Left", 50, group: "B"), Self.source("pods", "Left", 60, group: "B"),
        ])
        #expect(levels.byName.isEmpty)
        #expect(levels.unattributed == ["buds: Single beside [\"Case\", \"Single\"]", "pods: [\"Left\", \"Left\"] repeats a part"])
    }

    @Test func aSourceWithNoCapacityOrAnUnknownPartIsNamed() {
        var unread = Self.source("pencil", "Single", 10)
        unread["Max Capacity"] = 0
        let levels = AccessoryPower.levels(from: [unread, Self.source("pods", "Middle", 50)])
        #expect(levels.byName.isEmpty)
        #expect(levels.unattributed == ["pencil: no capacity", "pods: part Middle"])
    }
}
