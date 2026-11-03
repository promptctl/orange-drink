import AppIntents
import Foundation

// Compiled into the app and its widget extension, because a widget's settings hold these.

/// A device, as Edit Widget lists it and the widget's configuration stores it.
struct DeviceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Device"
    static let defaultQuery = DeviceQuery()

    /// The device's identity in its wire form (`DeviceID.wire`): the one thing a rename cannot change. A String because a
    /// placed widget's settings hold it, including from releases before sources, when it was a bare Bluetooth address.
    let id: String
    let name: String

    /// nil for an id this release cannot read: a setting naming a source it does not know.
    var identity: DeviceID? { DeviceID(wire: id) }

    /// The devices a widget's choices name, in the user's order, each once. [LAW:no-silent-failure] A choice this release
    /// cannot read is left out and logged.
    static func identities(of entities: [DeviceEntity]) -> [DeviceID] {
        let read = entities.compactMap(\.identity)
        if read.count < entities.count {
            ShelfLog.log.error("widget choices unreadable: \(entities.count - read.count, privacy: .public)")
        }
        var seen = Set<DeviceID>()
        return read.filter { seen.insert($0).inserted }
    }

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
        return identifiers.map { id in
            DeviceEntity(id: id, name: DeviceID(wire: id).flatMap { names[$0] } ?? Self.unavailable.resolve(in: .matchSystem))
        }
    }

    /// In a person's alphabetical order then by identity, so the choices keep their places as devices come and go.
    func suggestedEntities() async throws -> [DeviceEntity] {
        seen().names.map { DeviceEntity(id: $0.key.wire, name: $0.value) }
            .sorted(using: [KeyPathComparator(\.name, comparator: .localizedStandard), KeyPathComparator(\.id)])
    }

    /// [LAW:no-silent-failure] A file that cannot be read offers no devices, and the log says why.
    private func seen() -> SeenDevices {
        switch WidgetShelf.load(.seenDevices, from: directory, log: ShelfLog.log) {
        case .success(let seen): seen
        case .failure: SeenDevices()
        }
    }
}
