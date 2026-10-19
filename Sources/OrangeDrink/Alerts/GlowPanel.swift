import AppKit
import SwiftUI

/// The coloured glow around the screen edges: light that fades inward from each edge.
struct GlowView: View {
    private static let reach: CGFloat = 36

    let severity: Alert.Severity

    var body: some View {
        // The stroke is centred on the screen's edge and blurred, so half of it falls off-screen
        // and what remains is brightest at the edge and fades inward.
        Rectangle()
            .strokeBorder(severity.color, lineWidth: Self.reach)
            .blur(radius: Self.reach / 2)
            .opacity(0.9)
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
