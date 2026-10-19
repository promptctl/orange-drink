import Foundation

/// A value as UserDefaults keeps it across launches.
///
/// [LAW:composability] The store is whatever defaults it is given: the app passes the standard
/// ones, a test a throwaway suite, so a "relaunch" is a second store over the same suite.
struct DefaultsStore<Value: Codable & Sendable>: Sendable {
    let key: String
    /// What a first launch, with nothing stored, starts from.
    let initial: Value
    nonisolated(unsafe) let defaults: UserDefaults

    /// [LAW:parse-dont-validate] The one place stored bytes become the value. Nothing stored is a
    /// first launch; something stored that does not decode throws, rather than being replaced.
    func load() throws -> Value {
        guard let data = defaults.data(forKey: key) else { return initial }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    func save(_ value: Value) throws {
        defaults.set(try JSONEncoder().encode(value), forKey: key)
    }
}
