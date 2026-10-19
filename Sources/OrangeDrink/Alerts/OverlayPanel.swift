import AppKit
import SwiftUI

extension NSWindow.Level {
    /// [LAW:one-source-of-truth] The alert windows' stacking, in one place: the glow lies under the pill.
    static let pill = NSWindow.Level.screenSaver
    static let glow = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
}

/// A borderless window that floats over every app, full-screen ones included, without taking focus.
class OverlayPanel: NSPanel {
    init(frame: CGRect, level: NSWindow.Level, content: some View) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        // A full-screen app is its own Space: joining all Spaces as a full-screen auxiliary is what
        // lets a window of an accessory app appear there.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.level = level
        contentView = NSHostingView(rootView: content)
    }

    override var canBecomeKey: Bool { false }
}
