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
    /// the reading's full-screen alerts show, then its pills meet the cover they fired beside.
    func deliver(_ fired: ReadingAlerts) {
        cover.observe(fired.changes)
        let covers = fired.firings.filter(Self.isCover)
        for firing in covers + fired.firings.filter({ !Self.isCover($0) }) { deliver(firing, fired) }
    }

    private func deliver(_ firing: Firing, _ fired: ReadingAlerts) {
        switch firing {
        case .threshold(let alert) where Self.isCover(firing) && alert.isAnswered(by: fired.changes):
            log.info("full-screen alert answered by the reading that fired it: \(firing.description, privacy: .public)")
            return
        case .threshold(let alert) where Self.isCover(firing):
            if let shown = pills.shownFiring, Self.yieldsToCover(shown) { pills.close(.covered) }
            cover.show(alert, reading: fired.reading)
        case _ where cover.shown != nil && Self.yieldsToCover(firing):
            log.info("pill held back by the full-screen alert: \(firing.description, privacy: .public)")
            return
        default:
            pills.deliver(firing, reading: fired.reading)
        }
        sounds.deliver(firing)
    }

    private static func isCover(_ firing: Firing) -> Bool {
        if case .threshold(let alert) = firing { alert.position == .fullScreen } else { false }
    }

    /// A low or charged pill for the Mac, which says less than the cover does.
    private static func yieldsToCover(_ firing: Firing) -> Bool {
        if case .threshold = firing { true } else { false }
    }
}
