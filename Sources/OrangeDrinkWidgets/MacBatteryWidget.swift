import SwiftUI
import WidgetKit

struct MacBatteryProvider: TimelineProvider {
    func placeholder(in context: Context) -> MacBatteryEntry {
        MacBatteryEntry(date: .now, battery: .success(.running(.level(percent: 80, charging: true))))
    }

    func getSnapshot(in context: Context, completion: @escaping (MacBatteryEntry) -> Void) {
        completion(entry())
    }

    // [LAW:dataflow-not-control-flow] Policy .never: every redraw follows a reload the app asked for
    // when the shelf changed (spike orange-widgets-5jo.tlr: 43 of 43 reloads honoured, 22–53 ms; §5:
    // 150 of 150 budgeted reloads in 10 minutes, more than a day of 1% steps).
    func getTimeline(in context: Context, completion: @escaping (Timeline<MacBatteryEntry>) -> Void) {
        completion(Timeline(entries: [entry()], policy: .never))
    }

    private func entry() -> MacBatteryEntry {
        MacBatteryEntry(date: .now, battery: WidgetShelf.load(.macBattery, from: Result { try WidgetShelf.groupContainer() }, log: log))
    }
}

struct MacBatteryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.macBattery.rawValue, provider: MacBatteryProvider()) { entry in
            MacBatteryView(entry: entry, appName: appName)
        }
        .configurationDisplayName("Mac Battery")
        .description("Your Mac's battery at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
