import AppKit
import QuartzCore

/// The charging glow on the status item: one layer on the item's button. The halo's silhouette is cut
/// away, so it never covers the glyph. SwiftUI draws a `MenuBarExtra` label into the bar as a still
/// image, so an animation can live only here, where Core Animation composites it.
///
/// [LAW:no-ambient-temporal-coupling] The halo asked for is state: `show` keeps it, and every window update
/// reconciles the layer with it and with whichever button exists now, so a button made late, replaced, or
/// resized after the label changed still ends up carrying the halo, centred.
@MainActor final class StatusItemHalo {
    let layer = CALayer()
    private var wanted: Halo?
    private weak var button: NSStatusBarButton?
    /// What the layer's contents were drawn from; `Halo.image` draws anew on every read.
    private var drawn: (halo: Halo, scale: CGFloat)?
    private var breath: HaloBreath?
    // Removing an observer is thread-safe, so deinit may release these outside the main actor.
    nonisolated(unsafe) private var windowUpdates: (any NSObjectProtocol)?
    nonisolated(unsafe) private var motionChanges: (any NSObjectProtocol)?
    nonisolated(unsafe) private var frameChanges: (any NSObjectProtocol)?
    private let findButton: @MainActor () -> NSStatusBarButton?
    private let reduceMotion: @MainActor () -> Bool

    init(findButton: @escaping @MainActor () -> NSStatusBarButton? = StatusItemPanel.itemButton,
         reduceMotion: @escaping @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.findButton = findButton
        self.reduceMotion = reduceMotion
        layer.contentsGravity = .resizeAspect
        // A standalone layer animates every property change by default; the halo changes only by its breath.
        layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull(),
                         "opacity": NSNull(), "contentsScale": NSNull()]
        motionChanges = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
        windowUpdates = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
        // SwiftUI resizes the button after the label's onChange has run, so a resize re-centres the halo itself.
        frameChanges = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: nil, queue: .main) { [weak self] note in
            let view = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let button = self.button, view == ObjectIdentifier(button) else { return }
                self.apply()
            }
        }
    }

    deinit {
        windowUpdates.map(NotificationCenter.default.removeObserver)
        frameChanges.map(NotificationCenter.default.removeObserver)
        motionChanges.map(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    func show(_ halo: Halo?) {
        wanted = halo
        apply()
    }

    /// Writes only what differs, so the many window updates cost a comparison and never restart the breath.
    private func apply() {
        layer.isHidden = wanted == nil
        // A hidden halo has nothing to keep in step; show() brings it back the moment one is wanted.
        guard let wanted else {
            drawn = nil
            layer.contents = nil
            return
        }
        // The tree walk runs only while there is no button in a window to hold: at launch, or once the bar replaced it.
        if button?.window == nil, let found = findButton(), found !== button {
            found.wantsLayer = true
            if let host = found.layer {
                host.addSublayer(layer)
                button = found
                found.postsFrameChangedNotifications = true
                breath = nil
            }
        }
        let scale = button?.window?.backingScaleFactor ?? 2
        // The scale goes first and is part of what was drawn, so a move to another display redraws at its density.
        if layer.contentsScale != scale { layer.contentsScale = scale }
        if wanted != drawn?.halo || scale != drawn?.scale {
            drawn = (wanted, scale)
            layer.contents = wanted.image
        }
        let bounds = button?.bounds ?? .zero
        let side = wanted.side
        let frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        if layer.frame != frame { layer.frame = frame }
        let next = HaloBreath(reduceMotion: reduceMotion())
        if next != breath {
            breath = next
            next.apply(to: layer)
        }
    }
}
