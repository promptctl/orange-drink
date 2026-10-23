import AppKit
import SwiftUI
import os

/// Where a pill sits on a screen, as the alert's position says.
enum PillPlacement {
    /// design-docs/general.md: roughly 280 × 64 pt.
    nonisolated static let size = CGSize(width: 280, height: 64)
    private static let topGap: CGFloat = 12

    /// The pill's size at a multiple of the standard: the window and the drawn pill both read it.
    static func size(scale: Double) -> CGSize {
        CGSize(width: size.width * scale, height: size.height * scale)
    }

    static func frame(_ position: Alert.Position, on screen: CGRect, scale: Double) -> CGRect {
        let size = Self.size(scale: scale)
        let x = screen.midX - size.width / 2
        switch position {
        case .center: return CGRect(x: x, y: screen.midY - size.height / 2, width: size.width, height: size.height)
        case .top: return CGRect(x: x, y: screen.maxY - topGap - size.height, width: size.width, height: size.height)
        }
    }
}

/// The pill's window: it takes the close button's clicks without taking focus.
private final class PillPanel: OverlayPanel {
    let language: AppLanguage

    init(_ content: PillContent, scale: Double, language: AppLanguage, screen: NSScreen, onClose: @escaping () -> Void) {
        self.language = language
        super.init(
            frame: PillPlacement.frame(content.position, on: screen.visibleFrame, scale: scale), level: .pill,
            content: PillView(content: content, scale: scale, onClose: onClose).speaking(language))
    }
}

/// Why a pill came down, as its log line says it.
enum PillEnd {
    case closeButton
    case timedOut

    var said: String {
        switch self {
        case .closeButton: "×"
        case .timedOut: "timed out after \(PillController.shownFor)"
        }
    }
}

/// The one pill on screen, with the screen glow its alert asks for: a new alert replaces both, and
/// the close button or `shownFor` passing clears both.
///
/// [LAW:single-enforcer] `up` is the only record of whether a pill is up; its windows and its
/// countdown live and die together.
@MainActor final class PillController {
    private static let log = Logger(subsystem: IOKitBattery.logSubsystem, category: "alerts")
    /// How long a pill stays up unless its × or a newer alert takes it down first.
    nonisolated static let shownFor: Duration = .seconds(8)

    @MainActor private struct Up {
        let content: PillContent
        let panel: PillPanel
        /// nil when the alert has Border Glow off.
        let glow: GlowPanel?
        let expiry: Task<Void, any Error>

        func close() { expiry.cancel(); panel.close(); glow?.close() }
    }

    private let appearance: NotificationAppearanceModel
    private let language: AppLanguageModel
    private let timekeeper: any Timekeeper
    private var up: Up?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(appearance: NotificationAppearanceModel, language: AppLanguageModel, timekeeper: any Timekeeper = SystemTimekeeper()) {
        self.appearance = appearance
        self.language = language
        self.timekeeper = timekeeper
    }

    var shown: PillContent? { up?.content }
    /// The panel's frame in screen coordinates while a pill is up.
    var shownFrame: CGRect? { up?.panel.frame }
    /// The glow's frame in screen coordinates while the shown pill's alert has Border Glow on.
    var shownGlowFrame: CGRect? { up?.glow?.frame }
    /// The language the shown pill was handed: the app's at the moment it came up.
    var shownLanguage: AppLanguage? { up?.panel.language }
    /// The strength the shown glow was built at.
    var shownGlowStrength: NotificationAppearance.GlowStrength? { up?.glow?.strength }

    /// The sink an `AlertCenter` delivers to. The temperature warning has no pill so far.
    func deliver(_ firing: Firing, reading: BatteryReading) {
        switch firing {
        case .threshold(let alert): show(PillContent(alert, reading: reading))
        case .pluggedIn: show(.power("Plugged In", severity: .green, reading: reading))
        case .unplugged: show(.power("On Battery", severity: .orange, reading: reading))
        case .temperatureWarning: break
        }
    }

    /// The sink an `AlertCenter` delivers a watched device's firing to.
    func deliver(_ firing: DeviceFiring) { show(PillContent(firing)) }

    func show(_ content: PillContent) {
        dismiss("replaced")
        // [LAW:no-silent-failure] A Mac with every display gone is a state to live through, but the lost alert is logged.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            Self.log.error("no screen to show the pill on: \(content.headline.english, privacy: .private)")
            releaseWaiters()
            return
        }
        let look = appearance.value
        let panel = PillPanel(content, scale: look.bubbleSize.scale, language: language.value, screen: screen, onClose: { [weak self] in self?.close(.closeButton) })
        // [LAW:dataflow-not-control-flow] The glow is built from the content's flag, so a pill whose
        // alert has Border Glow off is a pill with no glow, whatever the pill before it had.
        let glow = content.glow ? GlowPanel(severity: content.severity, strength: look.glowStrength, screen: screen) : nil
        glow?.orderFrontRegardless()
        panel.orderFrontRegardless()
        // [LAW:no-ambient-temporal-coupling] The countdown belongs to this pill's `Up`, which cancels it
        // on any close or replacement. A replacement can land between the wake and this task's turn on
        // the main actor; it has cancelled the task by then, so the check after the sleep is that state.
        let expiry = Task { [weak self, timekeeper] in
            try await timekeeper.sleep(for: Self.shownFor)
            try Task.checkCancellation()
            self?.close(.timedOut)
        }
        up = Up(content: content, panel: panel, glow: glow, expiry: expiry)
    }

    /// Takes down the pill showing, if any, without telling waiters: a replacement may follow.
    private func dismiss(_ why: String) {
        if let up {
            // A device pill's headline holds the device's name, which AlertCenter logs as private too.
            Self.log.info("pill \(why, privacy: .public): \(up.content.headline.english, privacy: .private)")
            up.close()
        }
        up = nil
    }

    func close(_ end: PillEnd) {
        dismiss("closed: \(end.said)")
        releaseWaiters()
    }

    private func releaseWaiters() {
        let released = waiters
        waiters = []
        for waiter in released { waiter.resume() }
    }

    /// Returns once no pill is up.
    func untilClosed() async {
        guard shown != nil else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
