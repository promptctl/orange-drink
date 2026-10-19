import Foundation
import Observation

/// A value the app keeps across launches under one defaults key, starting from `init()` on a first launch.
protocol Stored: Codable, Equatable, Sendable {
    static var storageKey: String { get }
    init()
}

/// A stored value as the settings screens edit it and the rest of the app reads it, written
/// through to the store on every change.
///
/// [LAW:one-source-of-truth] `value` is the live copy; this is its only writer.
/// [LAW:one-type-per-behavior] Every kept setting loads, updates, and saves the same way; they
/// differ in the value and its key, which the value's `Stored` conformance carries.
@Observable @MainActor final class StoredModel<Value: Stored> {
    private(set) var value: Value
    @ObservationIgnored private let store: DefaultsStore<Value>

    /// [LAW:no-silent-failure] Stored bytes that do not decode fail the launch loudly.
    init(defaults: UserDefaults) throws {
        store = DefaultsStore(key: Value.storageKey, initial: Value(), defaults: defaults)
        value = try store.load()
    }

    func update(_ edit: (inout Value) -> Void) throws {
        var edited = value
        edit(&edited)
        try store.save(edited)
        value = edited
    }
}
