import os

/// The sink an `AlertCenter` delivers each reading of the Mac's battery to: every firing goes to the
/// cover or the pill, with its sound.
///
/// [LAW:single-enforcer] The one place that decides which: a threshold alert set to Full Screen is
/// the cover; every other firing is a pill. A watched device's firing never reaches here, so it stays
/// a pill (design-docs/alerts.md). It is also the one place a cover holds a pill back: while the
/// cover is up, a low or charged pill for the Mac neither shows nor sounds, and one already up when
/// the cover appears is taken down. Plug, unplug and temperature pills show over the cover.
@MainActor struct AlertPresenter {
    let pills: PillController
    let cover: CoverController
    let sounds: AlertSounds
    let log: Logger

    /// [LAW:no-ambient-temporal-coupling] One reading is handed over whole, so the order within it is
    /// decided here and not by the user's list: the adapter change answers the cover up first, then
    /// the reading's most urgent full-screen alert shows, then its pills meet the cover they fired beside.
    func deliver(_ fired: ReadingAlerts) {
        cover.observe(fired.changes)
        var covers: [Alert] = []
        var rest: [Firing] = []
        for firing in fired.firings {
            switch firing {
            case .threshold(let alert) where alert.position == .fullScreen:
                // The adapter change on the reading that fired it has already answered it.
                if let answer = CoverEnd(answering: alert.kind, in: fired.changes) {
                    log.info("full-screen alert answered by its own reading, \(answer.rawValue, privacy: .public): \(firing.description, privacy: .public)")
                } else {
                    covers.append(alert)
                }
            default: rest.append(firing)
            }
        }
        // One cover per reading: a drop past 5% and 2% at once shows the 2% cover, once, and chimes
        // if any of the reading's full-screen alerts asked to be heard.
        if var alert = covers.max(by: { Self.urgency($0) < Self.urgency($1) }) {
            alert.sound = covers.contains(where: \.sound)
            show(alert, reading: fired.reading)
        }
        rest.forEach { deliver($0, reading: fired.reading) }
    }

    private func show(_ alert: Alert, reading: BatteryReading) {
        if let shown = pills.shownFiring, Self.yieldsToCover(shown) { pills.close(.covered) }
        cover.show(alert, reading: reading)
        sounds.deliver(.threshold(alert))
    }

    private func deliver(_ firing: Firing, reading: BatteryReading) {
        if cover.shown != nil && Self.yieldsToCover(firing) {
            log.info("pill held back by the full-screen alert: \(firing.description, privacy: .public)")
            return
        }
        pills.deliver(firing, reading: reading)
        sounds.deliver(firing)
    }

    /// How far past the safe range an alert's threshold sits: a lower low, or a higher charged.
    private static func urgency(_ alert: Alert) -> Int {
        switch alert.kind {
        case .low: -alert.threshold
        case .charged: alert.threshold
        }
    }

    /// A low or charged pill for the Mac, which says less than the cover does.
    private static func yieldsToCover(_ firing: Firing) -> Bool {
        if case .threshold = firing { true } else { false }
    }
}
