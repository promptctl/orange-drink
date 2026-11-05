import os

/// The sink an `AlertCenter` delivers the Mac's firings to: each goes to the cover or the pill, with its sound.
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

    func deliver(_ firing: Firing, reading: BatteryReading) {
        switch firing {
        case .threshold(let alert) where alert.position == .fullScreen:
            if let shown = pills.shownFiring, Self.yieldsToCover(shown) { pills.close(.covered) }
            cover.show(alert, reading: reading)
        case _ where cover.shown != nil && Self.yieldsToCover(firing):
            log.info("pill held back by the full-screen alert: \(firing.description, privacy: .public)")
            return
        default:
            pills.deliver(firing, reading: reading)
        }
        sounds.deliver(firing)
    }

    /// Every reading of the Mac's battery, before the alerts it fires are delivered: the adapter
    /// change that answers the cover takes it down first.
    func observe(_ reading: BatteryReading) { cover.observe(reading) }

    /// A low or charged pill for the Mac, which says less than the cover does.
    private static func yieldsToCover(_ firing: Firing) -> Bool {
        if case .threshold = firing { true } else { false }
    }
}
