/// The sink an `AlertCenter` delivers the Mac's firings to: each goes to the cover or the pill.
///
/// [LAW:single-enforcer] The one place that decides which: a threshold alert set to Full Screen is
/// the cover; every other firing is a pill. A watched device's firing never reaches here, so it stays
/// a pill (design-docs/alerts.md).
@MainActor struct AlertPresenter {
    let pills: PillController
    let cover: CoverController

    func deliver(_ firing: Firing, reading: BatteryReading) {
        switch firing {
        case .threshold(let alert) where alert.position == .fullScreen: cover.show(CoverContent(alert, reading: reading))
        default: pills.deliver(firing, reading: reading)
        }
    }
}
