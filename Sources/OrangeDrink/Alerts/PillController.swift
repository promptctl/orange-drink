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
    init(_ content: PillContent, scale: Double, screen: NSScreen, onClose: @escaping () -> Void) {
        super.init(
            frame: PillPlacement.frame(content.position, on: screen.visibleFrame, scale: scale), level: .pill,
            content: PillView(content: content, scale: scale, onClose: onClose))
    }
}

/// The one pill on screen, with the screen glow its alert asks for: a new alert replaces both, and
/// the close button clears both.
///
/// [LAW:single-enforcer] `up` is the only record of whether a pill is up; its windows live and die together.
@MainActor final class PillController {
    private static let log = Logger(subsystem: IOKitBattery.logSubsystem, category: "alerts")

    @MainActor private struct Up {
        let content: PillContent
        let panel: PillPanel
        /// nil when the alert has Border Glow off.
        let glow: GlowPanel?

        func close() { panel.close(); glow?.close() }
    }

    private let appearance: NotificationAppearanceModel
    private var up: Up?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(appearance: NotificationAppearanceModel) { self.appearance = appearance }

    var shown: PillContent? { up?.content }
    /// The panel's frame in screen coordinates while a pill is up.
    var shownFrame: CGRect? { up?.panel.frame }
    /// The glow's frame in screen coordinates while the shown pill's alert has Border Glow on.
    var shownGlowFrame: CGRect? { up?.glow?.frame }
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
        dismiss()
        // [LAW:no-silent-failure] A Mac with every display gone is a state to live through, but the lost alert is logged.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            Self.log.error("no screen to show the pill on: \(content.headline, privacy: .public)")
            close()
            return
        }
        let look = appearance.appearance
        let panel = PillPanel(content, scale: look.bubbleSize.scale, screen: screen, onClose: { [weak self] in self?.close() })
        // [LAW:dataflow-not-control-flow] The glow is built from the content's flag, so a pill whose
        // alert has Border Glow off is a pill with no glow, whatever the pill before it had.
        let glow = content.glow ? GlowPanel(severity: content.severity, strength: look.glowStrength, screen: screen) : nil
        glow?.orderFrontRegardless()
        panel.orderFrontRegardless()
        up = Up(content: content, panel: panel, glow: glow)
    }

    /// Takes down the pill showing, if any, without telling waiters: a replacement may follow.
    private func dismiss() {
        up?.close()
        up = nil
    }

    func close() {
        dismiss()
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
