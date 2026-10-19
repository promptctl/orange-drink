import AppKit

/// A key with no modifier held but Shift, as the panel's single-key shortcuts see it.
typealias PlainKey = Character

/// Where plain key presses come from while the panel is open.
///
/// [LAW:effects-at-boundaries] Which keys do what is decided by `PanelSections`; this is the one
/// place the system's key events are asked for.
@MainActor protocol KeyEvents {
    /// Calls `handle` for each plain key press this app receives until the listener is stopped. A press `handle`
    /// returns true for is consumed; any other goes on to whoever would have had it.
    func listen(_ handle: @escaping @MainActor (PlainKey) -> Bool) -> any KeyListening
}

@MainActor protocol KeyListening: AnyObject {
    func stop()
}

/// The panel's single-key shortcuts: listening exactly while the panel is open.
///
/// [LAW:no-ambient-temporal-coupling] The listener's life is the panel's: started as it opens, stopped as
/// it closes. The system delivers keys typed in other apps to those apps, so closed means untouched.
@MainActor final class PanelKeyboard {
    private let sections: PanelSections
    private let events: any KeyEvents
    private var listening: (any KeyListening)?

    init(sections: PanelSections, events: any KeyEvents) {
        self.sections = sections
        self.events = events
    }

    /// `shown` is asked at each press which sections the panel is drawing now.
    func panelDidOpen(shown: @escaping @MainActor () -> Set<PanelSections.Section>) {
        listening?.stop()
        listening = events.listen { [sections] key in sections.press(key, shown: shown()) }
    }

    func panelDidClose() {
        listening?.stop()
        listening = nil
    }
}

/// Key presses through an AppKit local monitor, which sees only the keys typed to this app's windows.
@MainActor struct NSKeyEvents: KeyEvents {
    func listen(_ handle: @escaping @MainActor (PlainKey) -> Bool) -> any KeyListening {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let held = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard held.isDisjoint(with: [.command, .control, .option]),
                  let typed = event.charactersIgnoringModifiers, typed.count == 1, let key = typed.first else { return event }
            return MainActor.assumeIsolated { handle(key) } ? nil : event
        }
        return Listener(monitor: monitor as Any)
    }

    private final class Listener: KeyListening {
        let monitor: Any
        init(monitor: Any) { self.monitor = monitor }
        func stop() { NSEvent.removeMonitor(monitor) }
    }
}
