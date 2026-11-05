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
    /// Where a pill sits. Narrower than `Alert.Position`, so no pill is full screen.
    enum Position: String, Equatable, Sendable {
        case center, top
    }

    let headline: Phrase
    /// nil while the system has no estimate to give or nothing is being counted.
    let subline: Phrase?
    let severity: Alert.Severity
    /// The share of the border the severity stroke covers: the remaining charge, 0...1.
    let progress: Double
    let position: Position
    /// The alert's Border Glow: light the screen edges alongside the pill.
    let glow: Bool

    init(headline: Phrase, subline: Phrase?, severity: Alert.Severity, progress: Double,
         position: Position, glow: Bool) {
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
        (position, glow) = Self.placement(alert)
    }

    /// The pill for a watched device: its name and level, in the alert's severity, position, and glow.
    init(_ firing: DeviceFiring) {
        let (position, glow) = Self.placement(firing.alert)
        self.init(headline: "\(firing.name): \(BatteryLevel.text(firing.level)) Remaining", subline: nil, severity: firing.alert.severity,
                  progress: BatteryLevel.fraction(firing.level), position: position, glow: glow)
    }

    /// The pill for a power source alert: it has no threshold or position of its own, so it sits at
    /// the top, tells the event, and counts down or up as the reading does.
    static func power(_ headline: Phrase, severity: Alert.Severity, reading: BatteryReading) -> PillContent {
        PillContent(headline: headline, subline: subline(reading), severity: severity,
                    progress: Double(reading.chargePercent) / 100, position: .top, glow: false)
    }

    /// The pill for a temperature warning: at the top like the power pills, with the reading in the
    /// panel's words where they carry the time estimate. `heat` and `reading` are the same reading's
    /// state and value, which the engine's firing and `deliver` hand over together.
    static func temperature(_ heat: TemperatureState.Heat, reading: BatteryReading) -> PillContent {
        let words = BatteryInformation(reading).temperature
        let (headline, severity): (Phrase, Alert.Severity) = switch heat {
        case .warm: ("Battery Warm", .orange)
        case .hot: ("Battery Hot", .red)
        }
        return PillContent(headline: headline, subline: "\(words.celsius) / \(words.fahrenheit)", severity: severity,
                           progress: Double(reading.chargePercent) / 100, position: .top, glow: false)
    }

    /// Where an alert's pill sits and whether it glows. A full-screen alert shown as a pill sits at
    /// the centre. Every full-screen firing, the Mac's own included, comes here until the Mac's are
    /// routed to the cover.
    static func placement(_ alert: Alert) -> (position: Position, glow: Bool) {
        (alert.position == .top ? .top : .center, alert.showsGlow)
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
