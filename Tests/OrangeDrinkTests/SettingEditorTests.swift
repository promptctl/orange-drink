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
        var events: [SettingEdits<ChargeLimit>.Event] = []

        func update(_ edit: (inout ChargeLimit) -> Void) throws {
            if refuses { throw Refused() }
            edit(&value)
        }

        var edits: SettingEdits<ChargeLimit> {
            SettingEdits(setting: "charging.limit", read: { self.value }, update: update, record: { self.events.append($0) })
        }
    }

    @Test func aChangeThatCannotBeKeptReportsWhyAndLeavesTheValue() {
        let kept = Kept()
        kept.refuses = true
        kept.edits.perform { $0.isOn = true }
        #expect(kept.value == ChargeLimit())
        #expect(kept.events == [.notSaved(setting: "charging.limit", reason: "the disk is full")])
        #expect(kept.events.map(\.failure) == ["the disk is full"])
        #expect(kept.events.map(\.line) == ["charging.limit not saved: the disk is full"])
    }

    @Test func theNextChangeThatIsKeptClearsTheFailure() {
        let kept = Kept()
        kept.refuses = true
        kept.edits.perform { $0.isOn = true }
        kept.refuses = false
        kept.edits.perform { $0.isOn = true }
        #expect(kept.value.isOn)
        #expect(kept.events.last == .saved(setting: "charging.limit", value: "\(ChargeLimit(isOn: true, target: .standard))"))
        #expect(kept.events.last?.failure == nil)
    }

    @Test func aBindingReadsTheCurrentValueAndSetsThroughTheSameEdit() {
        let kept = Kept()
        let isOn = kept.edits.binding(\.isOn)
        #expect(!isOn.wrappedValue)
        kept.refuses = true
        isOn.wrappedValue = true
        #expect(!kept.value.isOn && kept.events.map(\.failure) == ["the disk is full"])
        kept.refuses = false
        isOn.wrappedValue = true
        #expect(isOn.wrappedValue && kept.events.last?.failure == nil)
    }
}
