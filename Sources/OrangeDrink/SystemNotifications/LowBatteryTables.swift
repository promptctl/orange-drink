import Foundation

/// The title and body of macOS's low battery notification, in one language.
struct LowBatteryWords: Hashable, Sendable {
    let title: String
    let body: String
}

/// [LAW:parse-dont-validate] The one reader of the tables macOS posts the notification from. They hold its words in every
/// language macOS speaks, so nothing here has to know which one NotificationCenter is showing, and a change to the words
/// arrives with the system that made it. A table that cannot give any is a failure, never an empty set of words.
enum LowBatteryTables {
    enum Failure: Error, Equatable, Sendable {
        case unreadable(table: String)
        case noWords

        var reason: String {
            switch self {
            case .unreadable(let table): "\(table) is missing or not a table"
            case .noWords: "the tables hold no title and body"
            }
        }
    }

    static let directory = URL(fileURLWithPath: "/System/Library/UserNotifications/Bundles/com.apple.controlcenter.notifications.low-battery.bundle/Contents/Resources")

    static func read(from directory: URL) -> Result<Set<LowBatteryWords>, Failure> {
        func table(_ name: String) -> Result<[String: Any], Failure> {
            guard let table = NSDictionary(contentsOf: directory.appendingPathComponent("\(name).loctable")) as? [String: Any]
            else { return .failure(.unreadable(table: name)) }
            return .success(table)
        }
        return table("InfoPlist").flatMap { names in table("Localizable").flatMap { parse(names: names, bodies: $0) } }
    }

    /// What shows as the title is the bundle's display name, not LOW_BATTERY_TITLE: it differs in 8 languages on macOS 26,
    /// and in Brazilian Portuguese and Polish the display name was on screen. Beside its languages each table has
    /// LocProvenance, with no words in it, which a language's dictionary of strings passes over.
    static func parse(names: [String: Any], bodies: [String: Any]) -> Result<Set<LowBatteryWords>, Failure> {
        let words = Set(names.flatMap { language, names -> [LowBatteryWords] in
            guard let title = (names as? [String: String])?["CFBundleDisplayName"], let bodies = bodies[language] as? [String: String] else { return [] }
            return ["LOW_BATTERY_BODY", "LOW_BATTERY_LOCKDOWN_BODY"].compactMap { bodies[$0].map { LowBatteryWords(title: title, body: $0) } }
        })
        return words.isEmpty ? .failure(.noWords) : .success(words)
    }
}
