import Foundation
@testable import OrangeDrink

@MainActor final class FakePanel: Panel {
    var isOpen = false
    func open() { isOpen = true }
    func close() { isOpen = false }
}

/// The system's hot keys, as the tests need them: what is held, what a press does, and what is refused.
@MainActor final class FakeHotKeys: HotKeys {
    private final class Held: HotKeyRegistration {
        let combo: KeyCombo
        let fire: @MainActor () -> Void
        var live = true
        init(_ combo: KeyCombo, _ fire: @escaping @MainActor () -> Void) { self.combo = combo; self.fire = fire }
        func cancel() { live = false }
    }

    private var held: [Held] = []
    var refused: [KeyCombo] = []

    /// The combinations the system holds now.
    var combos: [KeyCombo] { held.filter(\.live).map(\.combo) }

    func register(_ combo: KeyCombo, fire: @escaping @MainActor () -> Void) throws -> any HotKeyRegistration {
        if refused.contains(combo) || combos.contains(combo) { throw HotKeyError(combo: combo, status: -9878) }
        let registration = Held(combo, fire)
        held.append(registration)
        return registration
    }

    /// Presses a combination the way the system would deliver it: only a combination that is held fires.
    func press(_ combo: KeyCombo) { held.filter { $0.live && $0.combo == combo }.forEach { $0.fire() } }
}

@MainActor final class FakeKeyEvents: KeyEvents {
    private var handler: (@MainActor (KeyPress) -> Bool)?
    var listening: Bool { handler != nil }

    private final class Listener: KeyListening {
        let stopped: () -> Void
        init(_ stopped: @escaping () -> Void) { self.stopped = stopped }
        func stop() { stopped() }
    }

    func listen(_ handle: @escaping @MainActor (KeyPress) -> Bool) -> any KeyListening {
        handler = handle
        return Listener { [weak self] in self?.handler = nil }
    }

    /// A key typed to the app, or the system's repeat of one held: true when a shortcut used it, false when it
    /// goes on to whoever would have had it.
    func type(_ key: PlainKey, repeating: Bool = false) -> Bool { handler?(KeyPress(key: key, isRepeat: repeating)) ?? false }
}

func scratchDefaults() -> UserDefaults {
    let name = "shortcuts-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}
