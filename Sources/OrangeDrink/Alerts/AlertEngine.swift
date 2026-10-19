import Foundation

/// Decides which alerts a new charge level fires: each once per crossing, never for hovering.
///
/// [LAW:effects-at-boundaries] Pure state in, firings out; the clock, the battery, and the
/// screen are somebody else's. [LAW:one-source-of-truth] The engine holds only whether each alert
/// is armed; the alerts themselves belong to the caller and arrive with every level.
struct AlertEngine: Equatable, Sendable {
    /// An armed alert fires on its next crossing; a fired one waits to be re-armed by `isRearmed`.
    private var armed: [Alert.ID: Bool] = [:]

    /// The alerts this level fires. An alert met for the first time is armed unless the level is
    /// already past it: launching at 15% does not fire a 20% alert nobody watched being crossed.
    /// An alert gone from `alerts` is forgotten.
    ///
    /// [LAW:dataflow-not-control-flow] Every alert takes the same transitions on every level; the
    /// master switch is a value that empties the result, not a reason to skip tracking, so
    /// switching it on at 15% does not fire a stale 20% alert.
    mutating func observe(level: Int, alerts: [Alert], enabled: Bool) -> [Alert] {
        var next: [Alert.ID: Bool] = [:]
        var fired: [Alert] = []
        for alert in alerts {
            let crossed = alert.isCrossed(by: level)
            let wasArmed = armed[alert.id] ?? !crossed
            if wasArmed && crossed { fired.append(alert) }
            next[alert.id] = wasArmed ? !crossed : alert.isRearmed(by: level)
        }
        armed = next
        return enabled ? fired : []
    }
}
