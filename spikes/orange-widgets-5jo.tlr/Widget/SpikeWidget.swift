import SwiftUI
import WidgetKit
import os

let log = Logger(subsystem: Spike.subsystem, category: "widget")

// What the widget shows: the host's level, or why it has none. A failed read is drawn, not hidden.
enum Reading {
    case placeholder
    case level(Level)
    case failed(String)
}

struct Entry: TimelineEntry {
    let date: Date
    let reading: Reading
}

func read() -> Reading {
    do {
        let level = try JSONDecoder().decode(Level.self, from: Data(contentsOf: levelFile()))
        return .level(level)
    } catch {
        return .failed(String(describing: error))
    }
}

func describe(_ reading: Reading) -> String {
    switch reading {
    case .placeholder: "placeholder"
    case .level(let level): "seq \(level.sequence) percent \(level.percent) written \(level.writtenAt.timeIntervalSince1970)"
    case .failed(let reason): "failed: \(reason)"
    }
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        log.info("placeholder family \(String(describing: context.family), privacy: .public)")
        return Entry(date: .now, reading: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        let reading = read()
        log.info("getSnapshot preview \(context.isPreview, privacy: .public) \(describe(reading), privacy: .public)")
        completion(Entry(date: .now, reading: reading))
    }

    // [LAW:dataflow-not-control-flow] Policy .never: every redraw follows a reload the host asked for.
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let reading = read()
        log.info("getTimeline \(describe(reading), privacy: .public)")
        completion(Timeline(entries: [Entry(date: .now, reading: reading)], policy: .never))
    }
}

struct SpikeView: View {
    let entry: Entry

    var body: some View {
        VStack(spacing: 4) {
            switch entry.reading {
            case .placeholder:
                Text("SPIKE")
            case .level(let level):
                Text("SEQ \(level.sequence)").font(.title).monospacedDigit()
                Text("\(level.percent)%").monospacedDigit()
            case .failed(let reason):
                Text(reason).font(.caption)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

@main
struct SpikeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Spike.kind, provider: Provider()) { entry in
            SpikeView(entry: entry)
        }
        .configurationDisplayName("OrangeWidgetSpike")
        .description("orange-widgets-5jo.tlr")
        .supportedFamilies([.systemSmall])
    }
}
