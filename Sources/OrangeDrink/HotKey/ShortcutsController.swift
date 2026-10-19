import Foundation
import SwiftUI

/// Why a recording was not kept.
enum ShortcutError: Error {
    case needsModifiers
    case notALetter
    case taken(Shortcuts.Conflict)
    case refused(HotKeyError)

    /// What the Shortcuts screen tells the user, as literal catalog keys.
    var message: LocalizedStringKey {
        switch self {
        case .needsModifiers: "Use a letter with at least two of Control, Option, and Command."
        case .notALetter: "Use a letter from A to Z."
        case .taken(let conflict): "\(conflict.letter.display) is already used by another shortcut."
        case .refused(let error): "\(error.combo?.display ?? "That shortcut") could not be used. Another app may be using it."
        }
    }
}

/// A key press the recorder caught: what was typed, before it is known to be a shortcut.
struct RecordedKey: Equatable {
    let keyCode: UInt32
    let character: Character?
    let modifiers: KeyCombo.Modifiers

    /// [LAW:parse-dont-validate] The global combination this press is, or why it is not one.
    func globalCombo() throws -> KeyCombo {
        guard KeyCombo.isSupportedKey(keyCode) else { throw ShortcutError.notALetter }
        guard let combo = KeyCombo(keyCode: keyCode, label: character.map(String.init), modifiers: modifiers) else { throw ShortcutError.needsModifiers }
        return combo
    }

    /// The menu letter this press is, or why it is not one: a letter on its own (Shift is the letter's case).
    func menuLetter() throws -> ShortcutLetter {
        guard modifiers.isDisjoint(with: [.control, .option, .command]), let character, let letter = ShortcutLetter(character) else {
            throw ShortcutError.notALetter
        }
        return letter
    }
}

/// Changes the user's shortcuts: the one place the stored shortcuts and the hot key the system holds are made to agree.
///
/// [LAW:single-enforcer] A global combination is registered with the system before it is saved, and the
/// one it replaces is let go only after both have happened, so a refusal leaves the old shortcut working.
@MainActor final class ShortcutsController {
    let model: ShortcutsModel
    private let hotKeys: any HotKeys
    private let panel: any Panel
    /// What the system holds for the global shortcut now; nil while it holds none (suspended, or refused at launch).
    private var openPanel: OpenPanelHotKey?

    init(model: ShortcutsModel, hotKeys: any HotKeys, panel: any Panel) {
        self.model = model
        self.hotKeys = hotKeys
        self.panel = panel
    }

    /// Registers the saved global combination, as at launch and when a recording ends.
    func start() throws {
        guard openPanel == nil else { return }
        openPanel = try OpenPanelHotKey(model.value.openPanel, hotKeys: hotKeys, panel: panel)
    }

    /// Lets go of the global combination while the user is recording one, so pressing it is a recording and not the shortcut.
    func suspend() {
        openPanel?.cancel()
        openPanel = nil
    }

    func record(openPanel combo: KeyCombo) throws {
        try change(registering: combo) { $0.set(openPanel: combo) }
    }

    func record(_ letter: ShortcutLetter, for shortcut: MenuShortcut) throws {
        try change(registering: nil) { try $0.assign(letter, to: shortcut) }
    }

    /// Reset to default shortcuts: ⌃⌥J and a letter per row as the screen first shows them, all or nothing.
    func reset() throws {
        let defaults = Shortcuts()
        try change(registering: defaults.openPanel) { $0 = defaults }
    }

    private func change(registering combo: KeyCombo?, _ edit: (inout Shortcuts) throws -> Void) throws {
        var next = model.value
        do { try edit(&next) } catch let conflict as Shortcuts.Conflict { throw ShortcutError.taken(conflict) }
        var registered: OpenPanelHotKey?
        if let combo, combo != openPanel?.combo {
            do { registered = try OpenPanelHotKey(combo, hotKeys: hotKeys, panel: panel) } catch let error as HotKeyError {
                throw ShortcutError.refused(error)
            }
        }
        do { try model.update { $0 = next } } catch {
            registered?.cancel()
            throw error
        }
        if let registered {
            openPanel?.cancel()
            openPanel = registered
        }
    }
}
