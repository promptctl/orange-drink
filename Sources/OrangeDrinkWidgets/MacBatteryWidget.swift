import SwiftUI
import WidgetKit
import os

// [LAW:one-source-of-truth] project.yml fills both keys; absent, the extension is a broken build.
let log = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "widgets")
let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as! String

struct MacBatteryEntry: TimelineEntry {
    let date: Date
    /// What the app put on the shelf, or why there is nothing to read.
    let battery: Result<MacBattery, any Error>
}

struct MacBatteryProvider: TimelineProvider {
    func placeholder(in context: Context) -> MacBatteryEntry {
        MacBatteryEntry(date: .now, battery: .success(.level(percent: 80, charging: true)))
    }

    func getSnapshot(in context: Context, completion: @escaping (MacBatteryEntry) -> Void) {
        completion(entry())
    }

    // [LAW:dataflow-not-control-flow] Policy .never: every redraw follows a reload the app asked for
    // when the shelf changed (spike orange-widgets-5jo.tlr: 43 of 43 reloads honoured, 22–53 ms).
    func getTimeline(in context: Context, completion: @escaping (Timeline<MacBatteryEntry>) -> Void) {
        completion(Timeline(entries: [entry()], policy: .never))
    }

    private func entry() -> MacBatteryEntry {
        let battery = Result { try WidgetShelf.groupContainer() }.flatMap(WidgetShelf.read(from:))
        if case .failure(let error) = battery {
            // [LAW:no-silent-failure] Drawn as "Open the app" and logged with its cause.
            log.error("widget shelf unreadable: \(String(describing: error), privacy: .public)")
        }
        return MacBatteryEntry(date: .now, battery: battery)
    }
}

struct MacBatteryView: View {
    let entry: MacBatteryEntry

    var body: some View {
        content.containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder private var content: some View {
        switch entry.battery {
        case .success(.level(let percent, let charging)): BatteryRing(level: percent, charging: charging)
        case .success(.waiting): BatteryRing(level: nil, charging: false)
        case .success(.noBattery): Message(text: "No battery")
        case .success(.ended): Message(text: "Battery unavailable")
        case .success(.appNotRunning), .failure: Message(text: "Open \(appName)")
        }
    }
}

/// The reference ring from design-docs/widgets.md: a dark track, an arc filled clockwise from the top
/// to the level, the laptop in the centre and the percentage below; green with a bolt while charging.
struct BatteryRing: View {
    /// nil while the app has no reading yet: the empty track.
    let level: Int?
    let charging: Bool

    private var tint: Color { charging ? .green : .primary }

    var body: some View {
        GeometryReader { space in
            let side = min(space.size.width, space.size.height) * 0.62
            let line = side * 0.1
            VStack(spacing: side * 0.1) {
                ZStack {
                    Circle().stroke(.gray.opacity(0.35), lineWidth: line)
                    Circle()
                        .trim(from: 0, to: Double(level ?? 0) / 100)
                        .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: side * 0.32))
                    Image(systemName: "bolt.fill")
                        .font(.system(size: side * 0.16))
                        .foregroundStyle(.green)
                        .offset(y: -side / 2)
                        .opacity(charging ? 1 : 0)
                }
                .frame(width: side, height: side)
                Text(level.map { "\($0)%" } ?? "–")
                    .font(.system(size: side * 0.2, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct Message: View {
    let text: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "laptopcomputer").font(.title)
            Text(text).font(.caption).multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
    }
}

struct MacBatteryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetShelf.macBatteryKind, provider: MacBatteryProvider()) { entry in
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
    }
}
