import AppKit
import SwiftUI
import os

/// Where a pill sits on a screen, as the alert's position says.
enum PillPlacement {
    /// design-docs/general.md: roughly 280 × 64 pt.
    nonisolated static let size = CGSize(width: 280, height: 64)
    private static let topGap: CGFloat = 12

    static func frame(_ position: Alert.Position, on screen: CGRect) -> CGRect {
        let size = Self.size
        let x = screen.midX - size.width / 2
        switch position {
        case .center: return CGRect(x: x, y: screen.midY - size.height / 2, width: size.width, height: size.height)
        case .top: return CGRect(x: x, y: screen.maxY - topGap - size.height, width: size.width, height: size.height)
        }
    }
}

/// A borderless panel that floats over every app, full-screen ones included, without taking focus.
private final class PillPanel: NSPanel {
    init(_ content: PillContent, screen: NSScreen, onClose: @escaping () -> Void) {
        super.init(
            contentRect: PillPlacement.frame(content.position, on: screen.visibleFrame),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        // A full-screen app is its own Space: joining all Spaces as a full-screen auxiliary is what
        // lets a window of an accessory app appear there.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        level = .screenSaver
        contentView = NSHostingView(rootView: PillView(content: content, onClose: onClose))
    }

    override var canBecomeKey: Bool { false }
}

/// The one pill on screen: a new alert replaces the one showing, and the close button clears it.
///
/// [LAW:single-enforcer] `shown` is the only record of whether a pill is up; the window follows it.
@MainActor final class PillController {
    private static let log = Logger(subsystem: IOKitBattery.logSubsystem, category: "alerts")

    private(set) var shown: PillContent?
    private var panel: PillPanel?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// The panel's frame in screen coordinates while a pill is up.
    var shownFrame: CGRect? { panel?.frame }

    /// The sink an `AlertCenter` delivers to. Only threshold alerts have a pill so far.
    func deliver(_ firing: Firing, reading: BatteryReading) {
        switch firing {
        case .threshold(let alert): show(PillContent(alert, reading: reading))
        case .pluggedIn, .unplugged, .temperatureWarning: break
        }
    }

    func show(_ content: PillContent) {
        dismiss()
        // [LAW:no-silent-failure] A Mac with every display gone is a state to live through, but the lost alert is logged.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            Self.log.error("no screen to show the pill on: \(content.headline, privacy: .public)")
            close()
            return
        }
        let panel = PillPanel(content, screen: screen, onClose: { [weak self] in self?.close() })
        panel.orderFrontRegardless()
        self.panel = panel
        shown = content
    }

    /// Takes down the pill showing, if any, without telling waiters: a replacement may follow.
    private func dismiss() {
        panel?.close()
        panel = nil
        shown = nil
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
