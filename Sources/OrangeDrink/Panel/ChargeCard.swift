import Foundation

/// What the panel's charge card says for one reading, as the words and the fraction it draws.
///
/// [LAW:one-source-of-truth] The view draws these and nothing else, so what the tests assert
/// about them is what the panel shows.
struct ChargeCard: Equatable {
    let percent: String
    let unit = "%"
    let status: ChargeStatus
    /// "1h 22m", or an en dash while the system has no estimate or nothing is being counted.
    let estimate: Phrase
    let progress: Double
    let tint: BatteryIndicator.Tint

    init(_ reading: BatteryReading) {
        percent = String(reading.chargePercent)
        progress = Double(reading.chargePercent) / 100
        status = ChargeStatus(reading.power)
        estimate = reading.power.estimate?.hoursAndMinutes ?? "–"
        tint = BatteryIndicator(reading).tint
    }

    var estimateCaption: Phrase { status.estimateCaption }
}
