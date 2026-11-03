import Foundation

/// What the panel's charge card says for one reading, as the words and the fraction it draws.
///
/// [LAW:one-source-of-truth] The view draws these and nothing else, so what the tests assert
/// about them is what the panel shows.
struct ChargeCard: Equatable {
    enum Status: Equatable {
        case charging, onBattery, notCharging, charged
        var title: Phrase {
            switch self {
            case .charging: "Charging"
            case .onBattery: "On Battery"
            case .notCharging: "Not Charging"
            case .charged: "Charged"
            }
        }

        /// [LAW:one-source-of-truth] The one mapping from a power source to what the panel and the status
        /// item's accessibility label call it.
        init(_ power: PowerSource) {
            self = switch power {
            case .battery: .onBattery
            case .adapter(_, .charging): .charging
            case .adapter(_, .notCharging): .notCharging
            case .adapter(_, .full): .charged
            }
        }

        /// Names the estimate under the percentage: time until full while on an adapter, until empty on battery.
        var estimateCaption: Phrase { self == .onBattery ? "UNTIL EMPTY" : "UNTIL FULL" }
    }

    let percent: String
    let unit = "%"
    let status: Status
    /// Names the estimate under it: time until full while charging, until empty on battery.
    let estimateCaption: Phrase
    /// "1h 22m", or an en dash while the system has no estimate or nothing is being counted.
    let estimate: Phrase
    let progress: Double
    let tint: BatteryIndicator.Tint

    init(_ reading: BatteryReading) {
        percent = String(reading.chargePercent)
        progress = Double(reading.chargePercent) / 100
        status = Status(reading.power)
        estimateCaption = status.estimateCaption
        estimate = reading.power.estimate?.hoursAndMinutes ?? "–"
        tint = BatteryIndicator(reading).tint
    }
}
