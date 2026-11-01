import SwiftUI
import WidgetKit

// The All Batteries widget's timeline. [LAW:decomposition] Every decision is made by the Shared code a test
// reaches (`AllBatteries`, `AllBatteriesIntent`, `BatteryGrid`, `AllBatteriesView`); this file only hands WidgetKit
// the types it asks for.

struct AllBatteriesProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> AllBatteriesEntry {
        let devices = [
            WidgetDevice(address: "phone", name: "iPhone", kind: .phone, level: BatteryLevel(percent: 95, approximate: false)),
            WidgetDevice(address: "earbuds", name: "Earbuds", kind: .accessory, level: BatteryLevel(percent: 54, approximate: false)),
            WidgetDevice(address: "tablet", name: "iPad", kind: .tablet, level: BatteryLevel(percent: 62, approximate: false)),
        ]
        return AllBatteriesEntry(date: .now, mac: .success(.running(.level(percent: 80, charging: true))), devices: .success(.running(.connected(devices, pinned: []))), settings: AllBatteriesSettings(AllBatteriesIntent()))
    }

    func snapshot(for configuration: AllBatteriesIntent, in context: Context) async -> AllBatteriesEntry {
        entry(configuration)
    }

    // [LAW:dataflow-not-control-flow] Policy .never, as Mac Battery: every redraw follows a reload the app
    // asked for when either file changed.
    func timeline(for configuration: AllBatteriesIntent, in context: Context) async -> Timeline<AllBatteriesEntry> {
        Timeline(entries: [entry(configuration)], policy: .never)
    }

    private func entry(_ configuration: AllBatteriesIntent) -> AllBatteriesEntry {
        AllBatteriesEntry(date: .now, directory: Result { try WidgetShelf.groupContainer() }, log: ShelfLog.log, configuration: configuration)
    }
}

struct AllBatteriesWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetKind.allBatteries.rawValue, intent: AllBatteriesIntent.self, provider: AllBatteriesProvider()) { entry in
            FamilyReading { AllBatteriesView(entry: entry, appName: appName, family: $0) }
        }
        .configurationDisplayName(WidgetKind.allBatteries.title)
        .description("Your Mac and all your devices in one widget.")
        .supportedFamilies(WidgetFamilies.allBatteries)
    }
}
