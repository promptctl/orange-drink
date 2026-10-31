import SwiftUI
import WidgetKit

// The All Batteries widget's timeline. [LAW:decomposition] Every decision is made by the Shared code a test
// reaches (`AllBatteries`, `RingGrid`, `AllBatteriesView`); this file only hands WidgetKit the types it asks for.

struct AllBatteriesProvider: TimelineProvider {
    func placeholder(in context: Context) -> AllBatteriesEntry {
        let devices = [
            WidgetDevice(address: "phone", name: "iPhone", kind: .phone, level: BatteryLevel(percent: 95, approximate: false)),
            WidgetDevice(address: "earbuds", name: "Earbuds", kind: .accessory, level: BatteryLevel(percent: 54, approximate: false)),
            WidgetDevice(address: "tablet", name: "iPad", kind: .tablet, level: BatteryLevel(percent: 62, approximate: false)),
        ]
        return AllBatteriesEntry(date: .now, mac: .success(.running(.level(percent: 80, charging: true))), devices: .success(.running(.connected(devices))))
    }

    func getSnapshot(in context: Context, completion: @escaping (AllBatteriesEntry) -> Void) {
        completion(entry())
    }

    // [LAW:dataflow-not-control-flow] Policy .never, as Mac Battery: every redraw follows a reload the app
    // asked for when either file changed.
    func getTimeline(in context: Context, completion: @escaping (Timeline<AllBatteriesEntry>) -> Void) {
        completion(Timeline(entries: [entry()], policy: .never))
    }

    private func entry() -> AllBatteriesEntry {
        AllBatteriesEntry(date: .now, directory: Result { try WidgetShelf.groupContainer() }, log: log)
    }
}

struct AllBatteriesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.allBatteries.rawValue, provider: AllBatteriesProvider()) { entry in
            FamilyReading { AllBatteriesView(entry: entry, appName: appName, family: $0) }
        }
        .configurationDisplayName("All Batteries")
        .description("Your Mac and all your devices in one widget.")
        .supportedFamilies(WidgetFamilies.allBatteries)
    }
}
