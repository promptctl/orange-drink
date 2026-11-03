import AppKit
import QuartzCore

/// The charging glow on the status item: one layer on the item's button. The halo's silhouette is cut
/// away, so it never covers the glyph. SwiftUI draws a `MenuBarExtra` label into the bar as a still
/// image, so an animation can live only here, where Core Animation composites it.
///
/// [LAW:no-ambient-temporal-coupling] The halo asked for is state: `show` keeps it, and it reaches the button
/// whenever the button exists, whether the label asked before the status bar window was made or after.
@MainActor final class StatusItemHalo {
    let layer = CALayer()
    private var wanted: Halo?
    private var button: NSStatusBarButton?
    private var windowUpdates: (any NSObjectProtocol)?
    private var motionChanges: (any NSObjectProtocol)?
    private let findButton: @MainActor () -> NSStatusBarButton?
    private let reduceMotion: @MainActor () -> Bool

    init(findButton: @escaping @MainActor () -> NSStatusBarButton? = StatusItemPanel.itemButton,
         reduceMotion: @escaping @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.findButton = findButton
        self.reduceMotion = reduceMotion
        layer.contentsGravity = .resizeAspect
        motionChanges = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
        // Each window update looks for the button until it exists; attaching stops the looking.
        windowUpdates = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.attach() }
        }
    }

    func show(_ halo: Halo?) {
        wanted = halo
        attach()
        apply()
    }

    private func attach() {
        guard button == nil, let found = findButton() else { return }
        button = found
        found.wantsLayer = true
        found.layer?.addSublayer(layer)
        windowUpdates.map(NotificationCenter.default.removeObserver)
        windowUpdates = nil
        apply()
    }

    private func apply() {
        layer.isHidden = wanted == nil
        layer.contents = wanted?.image
        let side = wanted?.side ?? 0
        let bounds = button?.bounds ?? .zero
        layer.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        layer.contentsScale = button?.window?.backingScaleFactor ?? 2
        HaloBreath(reduceMotion: reduceMotion()).apply(to: layer)
    }
}
