import Foundation

extension PowerSource {
    /// The estimate the system is counting toward: empty on battery, full while charging. nil
    /// while it has no estimate yet, and when nothing is being counted (held or full on the
    /// adapter, or a charge a limit will stop short of full).
    var estimate: Duration? {
        switch self {
        case .battery(let timeToEmpty): timeToEmpty
        case .adapter(_, .charging(.toFull(let timeToFull))): timeToFull
        case .adapter: nil
        }
    }
}

extension Duration {
    /// Whole minutes, floored, as pmset's are.
    var wholeMinutes: Int { Int(components.seconds / 60) }

    /// "1h 22m": the panel's form for an estimate.
    var hoursAndMinutes: Phrase {
        let minutes = wholeMinutes
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}
