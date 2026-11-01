import AppIntents
import SwiftUI
import WidgetKit

// The Device Battery widget's settings and timeline. [LAW:decomposition] Every decision is made by the Shared
// code a test reaches (`WidgetDevices`, `DeviceBatteryView`); this file only hands WidgetKit and AppIntents
// the types they ask for.

struct SelectDeviceIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Device"
    static let description = IntentDescription("The device whose battery this widget shows.")
    static let isDiscoverable = false

    @Parameter(title: "Device") var device: DeviceEntity?
}

struct DeviceBatteryProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> DeviceBatteryEntry {
        let phone = WidgetDevice(address: "placeholder", name: "iPhone", kind: .phone, level: BatteryLevel(percent: 80, approximate: false))
        return DeviceBatteryEntry(date: .now, shelf: .success(.running(.connected([phone], pinned: []))), chosen: phone.address)
    }

    func snapshot(for configuration: SelectDeviceIntent, in context: Context) async -> DeviceBatteryEntry {
        entry(configuration)
    }

    // [LAW:dataflow-not-control-flow] Policy .never, as Mac Battery: every redraw follows a reload the app asked for.
    func timeline(for configuration: SelectDeviceIntent, in context: Context) async -> Timeline<DeviceBatteryEntry> {
        Timeline(entries: [entry(configuration)], policy: .never)
    }

    private func entry(_ configuration: SelectDeviceIntent) -> DeviceBatteryEntry {
        DeviceBatteryEntry(date: .now, shelf: WidgetShelf.load(.devices, from: Result { try WidgetShelf.groupContainer() }, log: ShelfLog.log),
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
