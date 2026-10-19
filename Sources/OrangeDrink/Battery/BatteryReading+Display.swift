import Foundation

extension BatteryReading {
    /// The estimate the system is counting toward: empty on battery, full while charging. nil
    /// while it has no estimate yet, and when nothing is being counted (held or full on the adapter).
    var estimate: Duration? {
        switch power {
        case .battery(let timeToEmpty): timeToEmpty
        case .adapter(_, .charging(let timeToFull)): timeToFull
        case .adapter: nil
        }
    }
}

extension Duration {
    /// Whole minutes, floored, as pmset's are.
    var wholeMinutes: Int { Int(components.seconds / 60) }

    /// "1h 22m": the panel's form for an estimate.
    var hoursAndMinutes: String {
        let minutes = wholeMinutes
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}
