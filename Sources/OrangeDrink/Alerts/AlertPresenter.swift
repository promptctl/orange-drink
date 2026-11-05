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
            if case .threshold(let alert) = firing, alert.position == .fullScreen { covers.append(alert) } else { rest.append(firing) }
        }
        // One cover per reading: a drop past 5% and 2% at once shows the 2% cover, once.
        covers.sort { Self.urgency($0) > Self.urgency($1) }
        if let alert = covers.first { show(alert, fired) }
        for outranked in covers.dropFirst() {
            log.info("full-screen alert outranked on its reading: \(Firing.threshold(outranked).description, privacy: .public)")
        }
        rest.forEach { deliver($0, reading: fired.reading) }
    }

    private func show(_ alert: Alert, _ fired: ReadingAlerts) {
        let firing = Firing.threshold(alert)
        if let answer = CoverEnd(answering: alert.kind, in: fired.changes) {
            log.info("full-screen alert answered by the reading that fired it, \(answer.rawValue, privacy: .public): \(firing.description, privacy: .public)")
            return
        }
        if let shown = pills.shownFiring, Self.yieldsToCover(shown) { pills.close(.covered) }
        cover.show(alert, reading: fired.reading)
        sounds.deliver(firing)
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
