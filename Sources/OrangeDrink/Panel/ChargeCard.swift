import Foundation

/// What the panel's charge card says for one reading, as the words and the fraction it draws.
///
/// [LAW:one-source-of-truth] The view draws these and nothing else, so what the tests assert
/// about them is what the panel shows.
struct ChargeCard: Equatable {
    enum Status: Equatable {
        case charging, onBattery, notCharging, charged
        var title: String {
            switch self {
            case .charging: "Charging"
            case .onBattery: "On Battery"
            case .notCharging: "Not Charging"
            case .charged: "Charged"
            }
        }
    }

    let percent: String
    let unit = "%"
    let status: Status
    /// Names the estimate under it: time until full while charging, until empty on battery.
    let estimateCaption: String
    /// "1h 22m", or an en dash while the system has no estimate or nothing is being counted.
    let estimate: String
    let progress: Double
    let tint: BatteryIndicator.Tint

    init(_ reading: BatteryReading) {
        percent = String(reading.chargePercent)
        progress = Double(reading.chargePercent) / 100
        (status, estimateCaption) = switch reading.power {
        case .battery: (.onBattery, "UNTIL EMPTY")
        case .adapter(_, .charging): (.charging, "UNTIL FULL")
        case .adapter(_, .notCharging): (.notCharging, "UNTIL FULL")
        case .adapter(_, .full): (.charged, "UNTIL FULL")
        }
        estimate = reading.estimate?.hoursAndMinutes ?? "–"
        tint = BatteryIndicator(reading).tint
    }
}
