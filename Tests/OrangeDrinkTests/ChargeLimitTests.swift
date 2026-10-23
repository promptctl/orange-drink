import Foundation
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what the Charging screen's switch and target come out as
// through the edits the screen makes, and what a relaunch loads back.
@MainActor @Suite struct ChargeLimitTests {
    static func model(_ defaults: UserDefaults) throws -> ChargeLimitModel { try ChargeLimitModel(defaults: defaults) }

    /// The edits the screen makes to `model`, with what they reported.
    static func edits(_ model: ChargeLimitModel, events: SettingEvents) -> SettingEdits<ChargeLimit> {
        SettingEdits(setting: ChargeLimit.storageKey, read: { model.value }, update: model.update, record: events.record)
    }

    static func target(_ percent: Int) throws -> ChargeTarget { try #require(ChargeTarget.all.first { $0.percent == percent }) }

    @Test func aFirstLaunchHasTheLimitOffAndTheTargetAt80() throws {
        let limit = try Self.model(AlertSettingsPersistence.suite()).value
        #expect(!limit.isOn && limit.target.percent == 80)
    }

    @Test func theSwitchAndTargetComeBackAsSetWhenLoadedAsARelaunchWould() throws {
        let defaults = AlertSettingsPersistence.suite()
        let events = SettingEvents()
        let edits = Self.edits(try Self.model(defaults), events: events)
        edits.binding(\.isOn).wrappedValue = true
        edits.binding(\.target).wrappedValue = try Self.target(90)
        #expect(try Self.model(defaults).value == ChargeLimit(isOn: true, target: try Self.target(90)))
        #expect(events.all == [
            .saved(setting: "charging.limit", value: "\(ChargeLimit(isOn: true, target: .standard))"),
            .saved(setting: "charging.limit", value: "\(ChargeLimit(isOn: true, target: try Self.target(90)))"),
        ])
    }

    @Test func turningTheLimitOffKeepsTheTargetForWhenItIsTurnedBackOn() throws {
        let edits = Self.edits(try Self.model(AlertSettingsPersistence.suite()), events: SettingEvents())
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

    @Test(arguments: [100, 81, 0])
    func aStoredTargetTheScreenDoesNotOfferFailsTheLoadInsteadOfBeingReplaced(percent: Int) {
        let defaults = AlertSettingsPersistence.suite()
        defaults.set(Data(#"{"isOn":true,"target":\#(percent)}"#.utf8), forKey: ChargeLimit.storageKey)
        #expect(throws: DecodingError.self) { try Self.model(defaults) }
    }
}

