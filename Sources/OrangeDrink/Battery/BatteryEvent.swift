import Foundation

/// What changed between two consecutive battery readings, carrying the reading that fired it
/// so a subscriber never reads again to learn the new state.
///
/// [LAW:types-are-the-program] An event is exactly one of these; "nothing changed" is the
/// empty list `changes(from:to:)` returns, not a fourth case anyone has to guard.
enum BatteryEvent: Equatable, Sendable {
    /// The power source went from battery to adapter.
    case plugged(BatteryReading)
    /// The power source went from adapter to battery.
    case unplugged(BatteryReading)
    /// The charge percent changed.
    case levelChanged(BatteryReading)

    /// [LAW:effects-at-boundaries] The pure core of the event stream: two readings in, the
    /// events between them out, in a fixed order. A publish that moves only an estimate or a
    /// wattage yields nothing, which is what keeps subscribers quiet while the state is steady.
    static func changes(from previous: BatteryReading, to current: BatteryReading) -> [BatteryEvent] {
        let power: [BatteryEvent]
        switch (previous.power, current.power) {
        case (.battery, .adapter): power = [.plugged(current)]
        case (.adapter, .battery): power = [.unplugged(current)]
        case (.battery, .battery), (.adapter, .adapter): power = []
        }
        let level: [BatteryEvent] = previous.chargePercent == current.chargePercent ? [] : [.levelChanged(current)]
        return power + level
    }
}
