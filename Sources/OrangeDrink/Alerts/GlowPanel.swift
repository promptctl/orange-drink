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

/// A borderless panel over a whole screen that lets every click through to what is beneath.
final class GlowPanel: OverlayPanel {
    init(severity: Alert.Severity, screen: NSScreen) {
        super.init(frame: screen.frame, level: .glow, content: GlowView(severity: severity))
        ignoresMouseEvents = true
        hasShadow = false
    }
}
