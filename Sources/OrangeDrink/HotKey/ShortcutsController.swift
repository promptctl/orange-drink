import Foundation

/// Why a recording was not kept.
enum ShortcutError: Error, CustomStringConvertible {
    case needsModifier
    case notALetter
    case taken(Shortcuts.Conflict)
    case refused(HotKeyError)

    var description: String {
        switch self {
        case .needsModifier: "Use a letter with Control, Option, or Command."
        case .notALetter: "Use a letter from A to Z."
        case .taken(let conflict): "\(conflict.letter.display) is already used by another shortcut."
        case .refused(let error): "\(error)."
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
        guard let combo = KeyCombo(keyCode: keyCode, modifiers: modifiers) else { throw ShortcutError.needsModifier }
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
    private var openPanel: OpenPanelHotKey?

    init(model: ShortcutsModel, hotKeys: any HotKeys, panel: any Panel) {
        self.model = model
        self.hotKeys = hotKeys
        self.panel = panel
    }

    /// Registers the saved global combination, as at launch.
    func start() throws {
        openPanel = try OpenPanelHotKey(model.value.openPanel, hotKeys: hotKeys, panel: panel)
    }

    func record(openPanel combo: KeyCombo) throws {
        try change { $0.set(openPanel: combo) }
    }

    func record(_ letter: ShortcutLetter, for shortcut: MenuShortcut) throws {
        try change { try $0.assign(letter, to: shortcut) }
    }

    /// Reset to default shortcuts: ⌃⌥J and a letter per row as the screen first shows them.
    func reset() throws {
        try change { $0 = Shortcuts() }
    }

    private func change(_ edit: (inout Shortcuts) throws -> Void) throws {
        var next = model.value
        do { try edit(&next) } catch let conflict as Shortcuts.Conflict { throw ShortcutError.taken(conflict) }
        var registered: OpenPanelHotKey?
        if next.openPanel != model.value.openPanel {
            do { registered = try OpenPanelHotKey(next.openPanel, hotKeys: hotKeys, panel: panel) } catch let error as HotKeyError {
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
