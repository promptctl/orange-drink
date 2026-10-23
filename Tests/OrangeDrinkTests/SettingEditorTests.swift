import Foundation
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what one settings edit reports, kept or not, and what the
// value is afterwards: a change that cannot be kept is reported with why and leaves the value as it was.
@MainActor @Suite struct SettingEditorTests {
    struct Refused: LocalizedError { var errorDescription: String? { "the disk is full" } }

    /// A kept value whose store can be told to refuse, and what its edits reported.
    @MainActor final class Kept {
        var value = ChargeLimit()
        var refuses = false
        let events = SettingEvents()

        func update(_ edit: (inout ChargeLimit) -> Void) throws {
            if refuses { throw Refused() }
            edit(&value)
        }

        var edits: SettingEdits<ChargeLimit> {
            SettingEdits(setting: "charging.limit", read: { self.value }, update: update, record: events.record)
        }
    }

    @Test func aChangeThatCannotBeKeptReportsWhyAndLeavesTheValue() {
        let kept = Kept()
        kept.refuses = true
        kept.edits.perform { $0.isOn = true }
        #expect(kept.value == ChargeLimit())
        #expect(kept.events.all == [.notSaved(setting: "charging.limit", reason: "the disk is full")])
        #expect(kept.events.all.map(\.failure) == ["the disk is full"])
    }

    @Test func theNextChangeThatIsKeptClearsTheFailure() {
        let kept = Kept()
        kept.refuses = true
        kept.edits.perform { $0.isOn = true }
        kept.refuses = false
        kept.edits.perform { $0.isOn = true }
        #expect(kept.value.isOn)
        #expect(kept.events.all.last == .saved(setting: "charging.limit", value: "\(ChargeLimit(isOn: true, target: .standard))"))
        #expect(kept.events.all.last?.failure == nil)
    }

    /// The process reads its own private arguments back unredacted, so this sees the value the log hides.
    @Test func everyEditIsLoggedWithWhichSettingAndWhatCameOfIt() async throws {
        let log = try BatteryLog(category: SettingEvent.logCategory)
        let kept = Kept()
        kept.refuses = true
        kept.edits.perform { $0.isOn = true }
        kept.refuses = false
        kept.edits.perform { $0.isOn = true }
        #expect(try await log.logged("charging.limit not saved: the disk is full"))
        #expect(try await log.logged("charging.limit saved: \(ChargeLimit(isOn: true, target: .standard))"))
    }

    @Test func aBindingReadsTheCurrentValueAndSetsThroughTheSameEdit() {
        let kept = Kept()
        let isOn = kept.edits.binding(\.isOn)
        #expect(!isOn.wrappedValue)
        kept.refuses = true
        isOn.wrappedValue = true
        #expect(!kept.value.isOn && kept.events.all.map(\.failure) == ["the disk is full"])
        kept.refuses = false
        isOn.wrappedValue = true
        #expect(isOn.wrappedValue && kept.events.all.last?.failure == nil)
    }
}

/// What a settings view's edits reported, in order.
@MainActor final class SettingEvents {
    private(set) var all: [SettingEvent] = []
    func record(_ event: SettingEvent) { all.append(event) }
}
