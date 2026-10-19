import AppKit
import SwiftUI

/// The coloured glow around the screen edges: light that fades inward from each edge.
struct GlowView: View {
    private static let reach: CGFloat = 36

    let severity: Alert.Severity

    var body: some View {
        // A band along the inside of the screen's edge, blurred: light that fades inward. The
        // panel covers the notch strip too, so the glow wraps the real edge.
        Rectangle()
            .strokeBorder(severity.color, lineWidth: Self.reach)
            .blur(radius: Self.reach / 2)
            .opacity(0.9)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

/// A borderless panel over a whole screen that floats over every app, full-screen ones included,
/// and lets every click through to what is beneath.
final class GlowPanel: NSPanel {
    init(severity: Alert.Severity, screen: NSScreen) {
        super.init(
            contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        level = .screenSaver
        contentView = NSHostingView(rootView: GlowView(severity: severity))
    }

    override var canBecomeKey: Bool { false }
}
