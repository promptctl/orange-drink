import AppKit

/// What the Battery Indicator status item shows for one reading: how full the outline is,
/// the number printed in it, and its colour.
///
/// [LAW:one-source-of-truth] The image is drawn from these three facts and nothing else, so
/// what the tests assert about them is what the menu bar shows.
struct BatteryIndicator: Equatable {
    enum Tint: Equatable { case neutral, green, orange, red }

    /// At or below these the battery is low or critical (PROJECT.md: "orange when low, red
    /// when critical"); the system's own warnings are at 10% and 5%, and the defaults for this
    /// app's alerts start at 20%.
    static let lowPercent = 20, criticalPercent = 5

    let fill: Double
    let label: String
    let tint: Tint

    init(_ reading: BatteryReading) {
        fill = Double(reading.chargePercent) / 100
        label = String(reading.chargePercent)
        // Charging is green whatever the level; otherwise the level decides.
        tint = switch reading.power {
        case .adapter(_, .charging): .green
        default:
            switch reading.chargePercent {
            case ...Self.criticalPercent: .red
            case ...Self.lowPercent: .orange
            default: .neutral
            }
        }
    }
}
