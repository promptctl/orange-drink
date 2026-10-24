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
        self.init(percent: reading.chargePercent, power: reading.power, display: display, statusColors: statusColors)
    }

    /// What the glyph needs of a reading: the charge and where it is going. The Menu Bar screen's
    /// preview draws a sample from these without faking the rest of a reading.
    init(percent: Int, power: PowerSource, display: MenuBarIconConfig.Display = .percentage, statusColors: Bool = true) {
        fill = Double(percent) / 100
        text = switch display {
        case .percentage: String(percent)
        case .timeRemaining: Self.clock(power.estimate)
        case .iconOnly: nil
        }
        tint = switch (power, percent) {
        case (_, ...Self.criticalPercent) where !power.isCharging: .red
        case _ where !statusColors: .neutral
        case _ where power.isCharging: .green
        case (_, ...Self.lowPercent): .orange
        default: .neutral
        }
    }

    /// The estimate as h:mm; an en dash while the system has none or there is nothing to count.
    private static func clock(_ estimate: Duration?) -> String {
        guard let minutes = estimate?.wholeMinutes else { return "–" }
        return "\(minutes / 60):" + String(format: "%02d", minutes % 60)
    }
}
