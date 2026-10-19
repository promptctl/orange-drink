import Foundation

/// What a battery glyph shows for one reading: how full it is, the text that goes with it,
/// and its tint.
///
/// [LAW:one-source-of-truth] The image is drawn from these facts and nothing else, so what
/// the tests assert about them is what the menu bar shows.
struct BatteryIndicator: Equatable {
    enum Tint: Equatable { case neutral, green, orange, red }

    /// At or below these the battery is low or critical (PROJECT.md: "orange when low, red
    /// when critical"); the system's own warnings are at 10% and 5%, and the defaults for this
    /// app's alerts start at 20%.
    static let lowPercent = 20, criticalPercent = 5

    let fill: Double
    /// nil when the display is icon only.
    let text: String?
    let tint: Tint

    init(_ reading: BatteryReading, display: MenuBarIconConfig.Display = .percentage, statusColors: Bool = true) {
        fill = Double(reading.chargePercent) / 100
        text = switch display {
        case .percentage: String(reading.chargePercent)
        case .timeRemaining: Self.clock(reading.power)
        case .iconOnly: nil
        }
        tint = switch (reading.power, reading.chargePercent) {
        case (_, ...Self.criticalPercent) where !charging(reading.power): .red
        case _ where !statusColors: .neutral
        case (.adapter(_, .charging), _): .green
        case (_, ...Self.lowPercent): .orange
        default: .neutral
        }
    }

    /// The estimate as h:mm; an en dash while the system has none or there is nothing to count.
    private static func clock(_ power: PowerSource) -> String {
        let estimate: Duration? = switch power {
        case .battery(let timeToEmpty): timeToEmpty
        case .adapter(_, .charging(let timeToFull)): timeToFull
        case .adapter: nil
        }
        guard let minutes = estimate.map({ Int($0.components.seconds / 60) }) else { return "–" }
        return "\(minutes / 60):" + String(format: "%02d", minutes % 60)
    }
}

private func charging(_ power: PowerSource) -> Bool {
    if case .adapter(_, .charging) = power { true } else { false }
}
