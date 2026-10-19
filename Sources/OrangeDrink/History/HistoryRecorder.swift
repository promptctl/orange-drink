import Foundation

/// One point on the battery's timeline.
struct HistorySample: Equatable, Sendable {
    let at: Date
    let level: Int
    /// Whether charge was flowing in, not merely whether an adapter was attached.
    let charging: Bool
    /// Full-charge capacity over design capacity, as a fraction.
    let health: Double
    let temperature: Measurement<UnitTemperature>

    init(_ reading: BatteryReading, at: Date) {
        self.at = at
        level = reading.chargePercent
        if case .adapter(_, .charging) = reading.power { charging = true } else { charging = false }
        health = reading.capacity.full.value / reading.capacity.design.value
        temperature = reading.temperature
    }

    init(at: Date, level: Int, charging: Bool, health: Double, temperature: Measurement<UnitTemperature>) {
        (self.at, self.level, self.charging, self.health, self.temperature) = (at, level, charging, health, temperature)
    }
}

/// What one calendar day of use added up to.
struct DayUsage: Equatable, Sendable {
    /// Percentage points of charge the battery lost while unplugged.
    var dischargedPercent = 0
    /// Seconds the display was awake.
    var screenOn: TimeInterval = 0

    static func += (lhs: inout Self, rhs: Self) {
        lhs.dischargedPercent += rhs.dischargedPercent
        lhs.screenOn += rhs.screenOn
    }
}

/// What the store is to add: a description of the write, performed at the edge.
struct HistoryWrite: Equatable, Sendable {
    var sample: HistorySample?
    /// Increments, keyed by the start of the local day they belong to.
    var days: [Date: DayUsage] = [:]

    var isEmpty: Bool { sample == nil && days.isEmpty }
}

/// Turns readings and screen changes into the writes that keep the history, with no clock, no
/// database, and no screen in the room.
///
/// [LAW:effects-at-boundaries] Every instant arrives as an argument, so a simulated day is a
/// list of calls. Nothing is timed here: a sample is due when a reading shows the level or the
/// charging state moved, or when `sampleInterval` has passed since the last one, which holds the
/// store to a few writes an hour however often powerd publishes.
struct HistoryRecorder {
    static let sampleInterval: TimeInterval = 600

    private let calendar: Calendar
    private var lastSample: HistorySample?
    private var lastLevel: Int?
    /// When the display was last known awake and not yet credited; nil while it is asleep.
    private var screenOnSince: Date?
    private var pending: [Date: DayUsage] = [:]

    /// A launched app has a user in front of it, so the display starts awake.
    init(calendar: Calendar, launchedAt: Date) {
        self.calendar = calendar
        screenOnSince = launchedAt
    }

    mutating func observe(_ reading: BatteryReading, at: Date) -> HistoryWrite {
        if case .battery = reading.power, let lastLevel, reading.chargePercent < lastLevel {
            credit(DayUsage(dischargedPercent: lastLevel - reading.chargePercent), on: at)
        }
        lastLevel = reading.chargePercent
        let sample = HistorySample(reading, at: at)
        guard isDue(sample) else { return HistoryWrite() }
        lastSample = sample
        return drain(at: at, sample: sample)
    }

    mutating func screen(on: Bool, at: Date) -> HistoryWrite {
        let write = drain(at: at, sample: nil)
        screenOnSince = on ? at : nil
        return write
    }

    /// Takes back a write the store refused, so its counts go out with the next one instead of vanishing.
    mutating func restore(_ write: HistoryWrite) {
        for (day, usage) in write.days { pending[day, default: DayUsage()] += usage }
    }

    /// Everything counted so far, for a quit: the open screen interval is credited up to `at`.
    mutating func flush(at: Date) -> HistoryWrite { drain(at: at, sample: nil) }

    private func isDue(_ sample: HistorySample) -> Bool {
        guard let last = lastSample else { return true }
        return sample.level != last.level || sample.charging != last.charging
            || sample.at.timeIntervalSince(last.at) >= Self.sampleInterval
    }

    /// Credits the screen time up to `at` and hands over everything pending.
    private mutating func drain(at: Date, sample: HistorySample?) -> HistoryWrite {
        if let since = screenOnSince {
            creditScreen(from: since, to: at)
            screenOnSince = at
        }
        defer { pending = [:] }
        return HistoryWrite(sample: sample, days: pending)
    }

    private mutating func credit(_ usage: DayUsage, on instant: Date) {
        pending[calendar.startOfDay(for: instant), default: DayUsage()] += usage
    }

    /// An interval that crosses midnight is split there, each part going to its own day.
    private mutating func creditScreen(from start: Date, to end: Date) {
        var cursor = start
        while cursor < end {
            let nextMidnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: cursor))!
            let stop = min(end, nextMidnight)
            credit(DayUsage(screenOn: stop.timeIntervalSince(cursor)), on: cursor)
            cursor = stop
        }
    }
}
