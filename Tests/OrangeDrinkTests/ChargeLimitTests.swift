import Foundation
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what the Charging screen's switch and target come out as
// through the edits the screen makes, and what a relaunch loads back.
@MainActor @Suite struct ChargeLimitTests {
    static func model(_ defaults: UserDefaults) throws -> ChargeLimitModel { try ChargeLimitModel(defaults: defaults) }

    static func target(_ percent: Int) throws -> ChargeTarget { try #require(ChargeTarget.all.first { $0.percent == percent }) }

    @Test func aFirstLaunchHasTheLimitOffAndTheTargetAt80() throws {
        let limit = try Self.model(AlertSettingsPersistence.suite()).value
        #expect(!limit.isOn && limit.target.percent == 80)
    }

    @Test func theSwitchAndTargetComeBackAsSetWhenLoadedAsARelaunchWould() throws {
        let defaults = AlertSettingsPersistence.suite()
        let events = SettingEvents()
        let edits = SettingEdits(try Self.model(defaults), record: events.record)
        edits.binding(\.isOn).wrappedValue = true
        edits.binding(\.target).wrappedValue = try Self.target(90)
        #expect(try Self.model(defaults).value == ChargeLimit(isOn: true, target: try Self.target(90)))
        #expect(events.all == [
            .saved(setting: "charging.limit", value: "\(ChargeLimit(isOn: true, target: .standard))"),
            .saved(setting: "charging.limit", value: "\(ChargeLimit(isOn: true, target: try Self.target(90)))"),
        ])
    }

    @Test func turningTheLimitOffKeepsTheTargetForWhenItIsTurnedBackOn() throws {
        let edits = SettingEdits(try Self.model(AlertSettingsPersistence.suite()), record: SettingEvents().record)
        let ninety = try Self.target(90)
        edits.perform { $0.isOn = true; $0.target = ninety }
        edits.binding(\.isOn).wrappedValue = false
        edits.binding(\.isOn).wrappedValue = true
        #expect(edits.value.target.percent == 90)
    }

    @Test func theOfferedTargetsRunFromHalfTo95InFivesWithoutFull() {
        #expect(ChargeTarget.all.map(\.percent) == [50, 55, 60, 65, 70, 75, 80, 85, 90, 95])
        #expect(ChargeTarget.all.contains(.standard))
    }

    /// The bytes this release keeps, written out rather than encoded, so a field added without a default or a
    /// level no longer offered fails here instead of failing a user's next launch.
    @Test(arguments: [50, 55, 60, 65, 70, 75, 80, 85, 90, 95])
    func aLimitThisReleaseKeptStillLoads(percent: Int) throws {
        let defaults = AlertSettingsPersistence.suite()
        defaults.set(Data(#"{"isOn":true,"target":\#(percent)}"#.utf8), forKey: "charging.limit")
        #expect(try Self.model(defaults).value == ChargeLimit(isOn: true, target: try Self.target(percent)))
    }

    @Test(arguments: [100, 81, 0])
    func aStoredTargetTheScreenDoesNotOfferFailsTheLoadInsteadOfBeingReplaced(percent: Int) {
        let defaults = AlertSettingsPersistence.suite()
        defaults.set(Data(#"{"isOn":true,"target":\#(percent)}"#.utf8), forKey: ChargeLimit.storageKey)
        #expect(throws: DecodingError.self) { try Self.model(defaults) }
    }
}

