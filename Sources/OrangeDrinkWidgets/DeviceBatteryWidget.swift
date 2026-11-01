import AppIntents
import SwiftUI
import WidgetKit

// The Device Battery widget's settings and timeline. [LAW:decomposition] Every decision is made by the Shared
// code a test reaches (`WidgetDevices`, `DeviceBatteryView`); this file only hands WidgetKit and AppIntents
// the types they ask for.

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
    /// A device that is not connected resolves too, so its widget keeps its choice and says "Not connected".
    func entities(for identifiers: [String]) async throws -> [DeviceEntity] {
        WidgetDevices.resolve(identifiers, in: Self.shelf()).map { address, device in
            device.map(DeviceEntity.init) ?? DeviceEntity(id: address, name: "Unavailable device")
        }
    }

    func suggestedEntities() async throws -> [DeviceEntity] {
        WidgetDevices.choices(in: Self.shelf()).map(DeviceEntity.init)
    }

    /// [LAW:no-silent-failure] A shelf that cannot be read offers no devices, and the log says why.
    private static func shelf() -> Shelved<WidgetDevices> {
        switch WidgetShelf.load(.devices, from: Swift.Result { try WidgetShelf.groupContainer() }, log: log) {
        case .success(let shelved): shelved
        case .failure: .appNotRunning
        }
    }
}

struct SelectDeviceIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Device"
    static let description = IntentDescription("The device whose battery this widget shows.")
    static let isDiscoverable = false

    @Parameter(title: "Device") var device: DeviceEntity?
}

struct DeviceBatteryProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> DeviceBatteryEntry {
        let phone = WidgetDevice(address: "placeholder", name: "iPhone", kind: .phone, level: BatteryLevel(percent: 80, approximate: false))
        return DeviceBatteryEntry(date: .now, shelf: .success(.running(.connected([phone]))), chosen: phone.address)
    }

    func snapshot(for configuration: SelectDeviceIntent, in context: Context) async -> DeviceBatteryEntry {
        entry(configuration)
    }

    // [LAW:dataflow-not-control-flow] Policy .never, as Mac Battery: every redraw follows a reload the app asked for.
    func timeline(for configuration: SelectDeviceIntent, in context: Context) async -> Timeline<DeviceBatteryEntry> {
        Timeline(entries: [entry(configuration)], policy: .never)
    }

    private func entry(_ configuration: SelectDeviceIntent) -> DeviceBatteryEntry {
        DeviceBatteryEntry(date: .now, shelf: WidgetShelf.load(.devices, from: Result { try WidgetShelf.groupContainer() }, log: log),
                           chosen: configuration.device?.id)
    }
}

struct DeviceBatteryWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetKind.deviceBattery.rawValue, intent: SelectDeviceIntent.self, provider: DeviceBatteryProvider()) { entry in
            FamilyReading { DeviceBatteryView(entry: entry, appName: appName, family: $0) }
        }
        .configurationDisplayName("Device Battery")
        .description("One device's battery at a glance.")
        .supportedFamilies(WidgetFamilies.deviceBattery)
    }
}
