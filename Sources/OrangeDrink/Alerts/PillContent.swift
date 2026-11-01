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
    let headline: Phrase
    /// nil while the system has no estimate to give or nothing is being counted.
    let subline: Phrase?
    let severity: Alert.Severity
    /// The share of the border the severity stroke covers: the remaining charge, 0...1.
    let progress: Double
    let position: Alert.Position
    /// The alert's Border Glow: light the screen edges alongside the pill.
    let glow: Bool

    init(headline: Phrase, subline: Phrase?, severity: Alert.Severity, progress: Double,
         position: Alert.Position, glow: Bool) {
        self.headline = headline; self.subline = subline; self.severity = severity
        self.progress = progress; self.position = position; self.glow = glow
    }

    init(_ alert: Alert, reading: BatteryReading) {
        let percent = reading.chargePercent
        switch alert.kind {
        case .low: headline = Self.remaining(percent)
        case .charged: headline = "\(percent)% Charged"
        }
        subline = Self.subline(reading)
        severity = alert.severity
        progress = Double(percent) / 100
        position = alert.position
        glow = alert.glow
    }

    /// The pill for a watched device: its name and level, in the alert's severity, position, and glow.
    init(_ firing: DeviceFiring) {
        // design-docs/devices.md: an approximate level is "~" wherever it appears.
        let percent = firing.level.percent
        let level: Phrase = firing.level.approximate ? "~\(percent)%" : "\(percent)%"
        self.init(headline: "\(firing.name): \(level) Remaining", subline: nil, severity: firing.alert.severity,
                  progress: BatteryLevel.fraction(firing.level), position: firing.alert.position, glow: firing.alert.glow)
    }

    /// The pill for a power source alert: it has no threshold or position of its own, so it sits at
    /// the top, tells the event, and counts down or up as the reading does.
    static func power(_ headline: Phrase, severity: Alert.Severity, reading: BatteryReading) -> PillContent {
        PillContent(headline: headline, subline: subline(reading), severity: severity,
                    progress: Double(reading.chargePercent) / 100, position: .top, glow: false)
    }

    // [LAW:one-source-of-truth] The pill's sentences are said here once; the real pill and the
    // General screen's sample both build theirs from these, so the sample is translated as the pill is.
    static func remaining(_ percent: Int) -> Phrase { "\(percent)% Remaining" }
    static func untilEmpty(_ amount: Phrase) -> Phrase { "\(amount) until empty" }
    static func untilFull(_ amount: Phrase) -> Phrase { "\(amount) until full" }

    /// The sample alert of design-docs/general.md: 15% remaining with 9 minutes to go.
    static let sample = PillContent(
        headline: remaining(15), subline: untilEmpty("\(9)min"), severity: .orange, progress: 0.15,
        position: .top, glow: false)

    private static func subline(_ reading: BatteryReading) -> Phrase? {
        guard let estimate = reading.power.estimate else { return nil }
        let minutes = estimate.wholeMinutes
        let amount: Phrase = minutes < 60 ? "\(minutes)min" : estimate.hoursAndMinutes
        switch reading.power {
        case .battery: return untilEmpty(amount)
        case .adapter: return untilFull(amount)
        }
    }
}
