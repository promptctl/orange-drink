import AppIntents
import Foundation

// Compiled into the app and its widget extension, because a widget's settings hold these.

/// A device, as Edit Widget lists it and the widget's configuration stores it.
struct DeviceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Device"
    static let defaultQuery = DeviceQuery()

    /// The device's address: the one thing a rename cannot change.
    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct DeviceQuery: EntityQuery {
    /// What Edit Widget calls a chosen device the app has never seen.
    static let unavailable: Phrase = "Unavailable device"

    /// The shelf: the group container, or a directory of a test's own.
    var directory: Swift.Result<URL, any Error> = Swift.Result { try WidgetShelf.groupContainer() }

    /// One result per id asked for, so a widget keeps its choice even of a device the app has never seen.
    func entities(for identifiers: [String]) async throws -> [DeviceEntity] {
        let names = seen().names
        return identifiers.map { DeviceEntity(id: $0, name: names[$0] ?? Self.unavailable.resolve(in: .matchSystem)) }
    }

    /// By name then address, so the choices keep their places as devices come and go.
    func suggestedEntities() async throws -> [DeviceEntity] {
        seen().names.map { DeviceEntity(id: $0.key, name: $0.value) }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    /// [LAW:no-silent-failure] A file that cannot be read offers no devices, and the log says why.
    private func seen() -> SeenDevices {
        switch WidgetShelf.load(.seenDevices, from: directory, log: ShelfLog.log) {
        case .success(let seen): seen
        case .failure: SeenDevices()
        }
    }
}
