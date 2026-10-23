import Foundation
import Security

// Compiled into the app and its widget extension: what the app hands its widgets, and where.

/// What the Mac Battery widget draws.
///
/// [LAW:types-are-the-program] The app's battery state plus the app's own lifetime, so the widget
/// can tell a level from "no more readings" from "the app is gone", and no failure is drawn as a
/// stale level.
enum MacBattery: Codable, Equatable, Sendable {
    case level(percent: Int, charging: Bool)
    case noBattery
    /// The app is running and has no reading yet.
    case waiting
    /// The app's readings stopped; its panel says why.
    case ended
    case appNotRunning
}

/// The one file the app writes and its widgets read. [LAW:one-source-of-truth] The file's name and
/// format live here alone; the directory is a parameter, the group container only at the two
/// composition roots, so a test reads exactly what the widget would from a directory of its own.
enum WidgetShelf {
    /// The Mac Battery widget's kind, which the app names when it asks WidgetKit to reload.
    static let macBatteryKind = "MacBattery"

    static func write(_ battery: MacBattery, to directory: URL) throws {
        try JSONEncoder().encode(battery).write(to: file(in: directory), options: .atomic)
    }

    static func read(from directory: URL) -> Result<MacBattery, any Error> {
        Result { try JSONDecoder().decode(MacBattery.self, from: Data(contentsOf: file(in: directory))) }
    }

    private static func file(in directory: URL) -> URL { directory.appending(path: "mac.json") }

    /// The container of the app group this process is signed into. [LAW:one-source-of-truth] The
    /// group is read off the process's own entitlement, which project.yml's APP_GROUP fills, so
    /// neither target spells it.
    static func groupContainer() throws -> URL {
        let entitlement = "com.apple.security.application-groups"
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil) as? [String],
              let group = groups.first else {
            throw ShelfError.noGroupEntitlement
        }
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw ShelfError.noContainer(group: group)
        }
        return container
    }
}

enum ShelfError: Error {
    /// The process is signed without an application group: a broken build.
    case noGroupEntitlement
    case noContainer(group: String)
}
