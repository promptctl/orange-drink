import Foundation

extension Alert {
    /// How alarming this alert's threshold is: the colour its pill is drawn in.
    enum Severity: Equatable, Sendable {
        case red, orange, green
    }

    /// Charged alerts are good news; a low alert is red at 5% and below, orange above.
    var severity: Severity {
        switch kind {
        case .charged: .green
        case .low: threshold <= 5 ? .red : .orange
        }
    }
}

/// Everything the pill shows, decided before any view exists.
///
/// [LAW:effects-at-boundaries] A pure function of the alert and the reading that fired it, so the
/// wording, the colour, and the progress are asserted without a window.
struct PillContent: Equatable, Sendable {
    let headline: String
    /// nil while the system has no estimate to give or nothing is being counted.
    let subline: String?
    let severity: Alert.Severity
    /// The share of the border the severity stroke covers: the remaining charge, 0...1.
    let progress: Double
    let position: Alert.Position

    init(headline: String, subline: String?, severity: Alert.Severity, progress: Double, position: Alert.Position) {
        self.headline = headline; self.subline = subline; self.severity = severity
        self.progress = progress; self.position = position
    }

    init(_ alert: Alert, reading: BatteryReading) {
        let percent = reading.chargePercent
        switch alert.kind {
        case .low: headline = "\(percent)% Remaining"
        case .charged: headline = "\(percent)% Charged"
        }
        subline = Self.subline(reading)
        severity = alert.severity
        progress = Double(percent) / 100
        position = alert.position
    }

    private static func subline(_ reading: BatteryReading) -> String? {
        guard let estimate = reading.estimate else { return nil }
        let minutes = estimate.wholeMinutes
        let amount = minutes < 60 ? "\(minutes)min" : estimate.hoursAndMinutes
        switch reading.power {
        case .battery: return "\(amount) until empty"
        case .adapter: return "\(amount) until full"
        }
    }
}
