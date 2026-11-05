import AppKit
import SwiftUI

extension NSWindow.Level {
    /// [LAW:one-source-of-truth] The alert windows' stacking, in one place: the glow lies under the
    /// pill, and the full-screen cover under both, so a pill that shows over the cover (AlertPresenter
    /// says which) stays over it with its glow, whichever was ordered front last.
    static let pill = NSWindow.Level.screenSaver
    static let glow = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
    static let cover = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 2)
}

/// A borderless window that floats over every app, full-screen ones included, without taking focus.
class OverlayPanel: NSPanel {
    init(frame: CGRect, level: NSWindow.Level, hosting: NSView) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        // A full-screen app is its own Space: joining all Spaces as a full-screen auxiliary is what
        // lets a window of an accessory app appear there.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.level = level
        contentView = hosting
    }

    override var canBecomeKey: Bool { false }
}
