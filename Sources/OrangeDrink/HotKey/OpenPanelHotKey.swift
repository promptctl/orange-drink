import AppKit
import OSLog

/// The menu bar panel, as the hot key sees it.
@MainActor protocol Panel {
    var isOpen: Bool { get }
    func open()
    func close()
}

/// The global shortcut that shows the menu bar panel when it is closed and hides it when it is open.
@MainActor final class OpenPanelHotKey {
    let combo: KeyCombo
    private let registration: any HotKeyRegistration

    init(_ combo: KeyCombo = .openPanel, hotKeys: any HotKeys, panel: any Panel) throws {
        self.combo = combo
        registration = try hotKeys.register(combo) {
            if panel.isOpen { panel.close() } else { panel.open() }
        }
    }

    func cancel() { registration.cancel() }
}

/// The panel of the app's `MenuBarExtra`, driven the way a click on its menu bar item drives it:
/// SwiftUI offers no way to present a `MenuBarExtra` from code.
///
/// Found on a Mac by the spike for orange-settings-7du.o5v: the panel is the visible
/// `MenuBarExtraWindow<…>` among `NSApp.windows`, and the item's own `NSStatusBarButton` is the one
/// button there that is not a pinned device's (those are tagged `NSPinnedStatusItem.buttonID`).
@MainActor struct StatusItemPanel: Panel {
    private static let log = Logger(subsystem: IOKitBattery.logSubsystem, category: "hotkey")

    var isOpen: Bool { NSApp.windows.contains { Self.isPanelWindow($0) && $0.isVisible } }

    /// [LAW:one-source-of-truth] What the panel's window is, for everything that must tell it from the app's other windows.
    static func isPanelWindow(_ window: NSWindow?) -> Bool {
        window.map { String(describing: type(of: $0)).hasPrefix("MenuBarExtraWindow") } ?? false
    }

    func open() { click() }
    func close() { click() }

    private func click() {
        guard let button = Self.itemButton() else {
            Self.log.error("the panel's menu bar item has no button to click")
            return
        }
        button.performClick(nil)
    }

    private static func itemButton() -> NSStatusBarButton? {
        func buttons(in view: NSView) -> [NSStatusBarButton] {
            (view as? NSStatusBarButton).map { [$0] } ?? view.subviews.flatMap(buttons(in:))
        }
        return NSApp.windows
            .filter { String(describing: type(of: $0)).contains("StatusBarWindow") }
            .compactMap { $0.contentView }
            .flatMap(buttons(in:))
            .first { $0.identifier != NSPinnedStatusItem.buttonID }
    }
}
