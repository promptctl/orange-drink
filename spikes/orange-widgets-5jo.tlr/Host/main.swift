import AppKit
import WidgetKit
import os

// A menu-bar-only host, like the app: it writes a level, asks WidgetKit to reload, and repeats
// `--times` writes `--every` seconds apart, then quits. Sequence numbers start at `--from`, so
// runs one after another put sequences on the screen that no earlier run showed.
let log = Logger(subsystem: Spike.subsystem, category: "host")

struct Schedule {
    let every: TimeInterval
    let times: Int
    let from: Int

    init(_ arguments: [String]) throws {
        func value(_ flag: String) throws -> String {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
                throw ScheduleError.missing(flag)
            }
            return arguments[index + 1]
        }
        func number<T: LosslessStringConvertible>(_ flag: String) throws -> T {
            let text = try value(flag)
            guard let parsed = T(text) else { throw ScheduleError.notANumber(flag, text) }
            return parsed
        }
        every = try number("--every")
        times = try number("--times")
        from = try number("--from")
    }
}

enum ScheduleError: Error {
    case missing(String)
    case notANumber(String, String)
}

@MainActor
func write(sequence: Int) throws {
    let level = Level(sequence: sequence, percent: 100 - sequence % 100, writtenAt: .now)
    let file = try levelFile()
    try JSONEncoder().encode(level).write(to: file, options: .atomic)
    log.info("wrote seq \(sequence, privacy: .public) percent \(level.percent, privacy: .public) to \(file.path, privacy: .public)")
    WidgetCenter.shared.reloadTimelines(ofKind: Spike.kind)
    log.info("reload seq \(sequence, privacy: .public)")
}

let schedule: Schedule
do {
    schedule = try Schedule(CommandLine.arguments)
} catch {
    log.error("bad arguments \(String(describing: error), privacy: .public): \(CommandLine.arguments, privacy: .public)")
    exit(64)
}

let app = NSApplication.shared
WidgetCenter.shared.getCurrentConfigurations { result in
    switch result {
    case .success(let widgets): log.info("placed widgets: \(widgets.count, privacy: .public)")
    case .failure(let error): log.error("placed widgets unknown: \(String(describing: error), privacy: .public)")
    }
}
Task { @MainActor in
    for step in 0..<schedule.times {
        do {
            try write(sequence: schedule.from + step)
        } catch {
            log.error("write failed: \(String(describing: error), privacy: .public)")
            exit(1)
        }
        try await Task.sleep(for: .seconds(schedule.every))
    }
    log.info("schedule done")
    exit(0)
}
app.run()
