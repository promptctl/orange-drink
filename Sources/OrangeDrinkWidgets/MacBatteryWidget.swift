import SwiftUI
import WidgetKit
import os

// [LAW:one-source-of-truth] project.yml fills both keys; absent, the extension is a broken build.
let log = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "widgets")
let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as! String

struct MacBatteryEntry: TimelineEntry {
    let date: Date
    /// What the app put on the shelf, or why there is nothing to read.
    let battery: Result<Shelved<MacBattery>, any Error>
}

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

struct MacBatteryView: View {
    let entry: MacBatteryEntry

    private static let glyph = "laptopcomputer"

    var body: some View {
        content.containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder private var content: some View {
        switch entry.battery {
        case .success(.running(.level(let percent, let charging))): BatteryRing(level: percent, charging: charging, glyph: Self.glyph)
        case .success(.running(.waiting)): BatteryRing(level: nil, charging: false, glyph: Self.glyph)
        case .success(.running(.noBattery)): Message(glyph: Self.glyph, text: "No battery")
        case .success(.running(.ended)): Message(glyph: Self.glyph, text: "Battery unavailable")
        case .success(.appNotRunning), .failure: Message(glyph: Self.glyph, text: "Open \(appName)")
        }
    }
}

struct MacBatteryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetShelf.Item.macBattery.kind, provider: MacBatteryProvider()) { entry in
            MacBatteryView(entry: entry)
        }
        .configurationDisplayName("Mac Battery")
        .description("Your Mac's battery at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct OrangeDrinkWidgets: WidgetBundle {
    var body: some Widget {
        MacBatteryWidget()
        DeviceBatteryWidget()
    }
}
