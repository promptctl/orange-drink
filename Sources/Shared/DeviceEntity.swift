import AppIntents

// Compiled into the app and its widget extension, because a widget's settings hold these.

/// A device, as Edit Widget lists it and the widget's configuration stores it.
struct DeviceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Device"
    static let defaultQuery = DeviceQuery()

    /// The device's address: the one thing a rename cannot change.
    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(_ device: WidgetDevice) { self.init(id: device.address, name: device.name) }
    init(id: String, name: String) { (self.id, self.name) = (id, name) }
}

struct DeviceQuery: EntityQuery {
    /// What Edit Widget calls a chosen device that is not on the list.
    static let unavailable: Phrase = "Unavailable device"

    /// A device that is not connected resolves too, so a widget keeps its choice while the device is away.
    func entities(for identifiers: [String]) async throws -> [DeviceEntity] {
        WidgetDevices.resolve(identifiers, in: Self.shelf()).map { address, device in
            device.map(DeviceEntity.init) ?? DeviceEntity(id: address, name: Self.unavailable.resolve(in: .matchSystem))
        }
    }

    func suggestedEntities() async throws -> [DeviceEntity] {
        WidgetDevices.choices(in: Self.shelf()).map(DeviceEntity.init)
    }

    /// [LAW:no-silent-failure] A shelf that cannot be read offers no devices, and the log says why.
    private static func shelf() -> Shelved<WidgetDevices> {
        switch WidgetShelf.load(.devices, from: Swift.Result { try WidgetShelf.groupContainer() }, log: ShelfLog.log) {
        case .success(let shelved): shelved
        case .failure: .appNotRunning
        }
    }
}
