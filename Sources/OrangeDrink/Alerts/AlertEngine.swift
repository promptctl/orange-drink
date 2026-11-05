import Foundation

/// Decides which alerts a new battery reading sets off: each once per crossing, never for hovering.
///
/// [LAW:effects-at-boundaries] Pure state in, crossings out; the clock, the battery, and the
/// screen are somebody else's. [LAW:one-source-of-truth] The engine holds only whether each alert
/// is armed; the alerts themselves belong to the caller and arrive with every level.
struct AlertEngine: Equatable, Sendable {
    /// What an alert was when it was last seen: an edit to its trigger makes it a new alert.
    private struct Tracked: Equatable, Sendable {
        var kind: Alert.Kind
        var threshold: Int
        /// An armed alert fires on its next crossing; a fired one waits to be re-armed by `isRearmed`.
        var armed: Bool
    }
    private var tracked: [Alert.ID: Tracked] = [:]
    /// The reading before this one: plug and unplug alerts are changes between two.
    private var previous: BatteryReading?
    /// Whether the next move out of Normal is announced. A fired warning, or a launch already out of
    /// Normal, waits to be re-armed by `TemperatureState.isRearmed`, as a threshold alert does.
    private var temperatureArmed = true

    /// Everything this reading sets off, thresholds first. The first reading has no change to
    /// announce, as a threshold already crossed at launch is not announced.
    ///
    /// [LAW:one-source-of-truth] Plug and unplug are `BatteryEvent`s and the hot state is the
    /// panel's `TemperatureState`; this only selects which of them the user asked to hear.
    /// The temperature is followed with its switch off too, as thresholds are, so switching it on
    /// while the battery is hot announces nothing until it has cooled and heated again.
    mutating func observe(_ reading: BatteryReading, alerts: [Alert], power: PowerSourceAlerts) -> ReadingAlerts {
        let thresholds = observe(level: reading.chargePercent, alerts: alerts).map(Firing.threshold)
        defer { previous = reading }
        // [LAW:one-source-of-truth] A `Heat` exists exactly when the reading is out of Normal.
        let heat = TemperatureState.Heat(TemperatureState(reading.temperature))
        // The first reading disarms a launch already out of Normal, but announces nothing.
        let wasArmed = temperatureArmed
        temperatureArmed = wasArmed ? heat == nil : TemperatureState.isRearmed(by: reading.temperature)
        guard let previous else { return ReadingAlerts(reading: reading, changes: [], firings: thresholds) }
        let changes = BatteryEvent.changes(from: previous, to: reading)
        let adapter: [Firing] = changes.compactMap {
            switch $0 {
            case .plugged: power.pluggedIn ? .pluggedIn(sound: power.sound) : nil
            case .unplugged: power.unplugged ? .unplugged(sound: power.sound) : nil
            case .levelChanged: nil
            }
        }
        let temperature: [Firing] = switch (wasArmed && power.temperature, heat) {
        case (true, let heat?): [.temperatureWarning(heat, sound: power.sound)]
        default: []
        }
        return ReadingAlerts(reading: reading, changes: changes, firings: thresholds + adapter + temperature)
    }

    /// The alerts this level crosses. An alert met for the first time, or whose kind or threshold
    /// was just edited, is armed unless the level is already past it: launching at 15% does not
    /// fire a 20% alert nobody watched being crossed. An alert gone from `alerts` is forgotten.
    ///
    /// [LAW:dataflow-not-control-flow] Every alert takes the same transitions on every level.
    mutating func observe(level: Int, alerts: [Alert]) -> [Alert] {
        var next: [Alert.ID: Tracked] = [:]
        var crossings: [Alert] = []
        for alert in alerts {
            let crossed = alert.isCrossed(by: level)
            let wasArmed = tracked[alert.id].flatMap {
                $0.kind == alert.kind && $0.threshold == alert.threshold ? $0.armed : nil
            } ?? !crossed
            if wasArmed && crossed { crossings.append(alert) }
            next[alert.id] = Tracked(
                kind: alert.kind, threshold: alert.threshold,
                armed: wasArmed ? !crossed : alert.isRearmed(by: level))
        }
        tracked = next
        return crossings
    }
}
