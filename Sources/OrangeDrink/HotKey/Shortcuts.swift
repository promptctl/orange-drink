import Foundation

/// One letter, a to z: what a menu shortcut is pressed as.
struct ShortcutLetter: Hashable, Codable, Sendable, ExpressibleByUnicodeScalarLiteral {
    let character: Character

    /// [LAW:parse-dont-validate] Letters only, whatever the case it was typed in.
    init?(_ typed: Character) {
        guard typed.isASCII, typed.isLetter, let lower = typed.lowercased().first else { return nil }
        character = lower
    }

    /// A literal in the source is a programmer's letter: anything else is a bug, not input.
    init(unicodeScalarLiteral scalar: Character) {
        guard let letter = ShortcutLetter(scalar) else { preconditionFailure("\(scalar) is not a letter a to z") }
        self = letter
    }

    var display: String { character.uppercased() }

    static let all = "abcdefghijklmnopqrstuvwxyz".map { ShortcutLetter($0)! }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard text.count == 1, let letter = ShortcutLetter(text.first!) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not one letter a to z"))
        }
        self = letter
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(character))
    }
}

/// The rows of the Shortcuts screen's Menu Shortcuts card, in the order it lists them.
enum MenuShortcut: String, CaseIterable, Codable, Sendable, CodingKeyRepresentable {
    case batteryInformation, appsUsingSignificantEnergy, connectedDevices, lowPowerMode

    var defaultLetter: ShortcutLetter {
        switch self {
        case .batteryInformation: "i"
        case .appsUsingSignificantEnergy: "u"
        case .connectedDevices: "d"
        case .lowPowerMode: "l"
        }
    }

    /// The panel section the letter expands or collapses; nil for a row whose target does not exist yet
    /// (orange-admin-helper-b2q.0ld).
    var section: PanelSections.Section? {
        switch self {
        case .batteryInformation: .batteryInformation
        case .appsUsingSignificantEnergy: .appsUsingSignificantEnergy
        case .connectedDevices: .connectedDevices
        case .lowPowerMode: nil
        }
    }
}

/// Every keyboard shortcut the user can set: the global one that opens the panel and a letter per menu row.
///
/// [LAW:one-source-of-truth] This is the only place a shortcut's key is kept; the hot key, the panel's
/// keyboard, and the Shortcuts screen all read it.
struct Shortcuts: Stored {
    static let storageKey = "shortcuts"

    struct Conflict: Error, Equatable {
        let letter: ShortcutLetter
        let heldBy: MenuShortcut
    }

    private(set) var openPanel: KeyCombo
    private(set) var letters: [MenuShortcut: ShortcutLetter]

    init() {
        openPanel = .openPanel
        letters = Dictionary(uniqueKeysWithValues: MenuShortcut.allCases.map { ($0, $0.defaultLetter) })
    }

    func letter(for shortcut: MenuShortcut) -> ShortcutLetter { letters[shortcut]! }

    func shortcut(for letter: ShortcutLetter) -> MenuShortcut? { letters.first { $0.value == letter }?.key }

    mutating func set(openPanel combo: KeyCombo) { openPanel = combo }

    /// A letter belongs to one row: taking one another row holds is refused rather than leaving two rows to race for it.
    mutating func assign(_ letter: ShortcutLetter, to shortcut: MenuShortcut) throws {
        if let holder = self.shortcut(for: letter), holder != shortcut { throw Conflict(letter: letter, heldBy: holder) }
        letters[shortcut] = letter
    }

    private enum CodingKeys: String, CodingKey { case openPanel, letters }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        openPanel = try values.decode(KeyCombo.self, forKey: .openPanel)
        // A row added by a later release has no stored letter yet and starts at its default; a row since removed is dropped.
        // If its default is another row's letter now, it takes the first letter nobody holds.
        let stored = try values.decode([String: ShortcutLetter].self, forKey: .letters)
        var kept = MenuShortcut.allCases.compactMap { row in stored[row.rawValue].map { (row, $0) } }
        guard Set(kept.map(\.1)).count == kept.count else {
            throw DecodingError.dataCorruptedError(forKey: .letters, in: values, debugDescription: "every row needs its own letter")
        }
        for row in MenuShortcut.allCases where stored[row.rawValue] == nil {
            let held = Set(kept.map(\.1))
            let free = held.contains(row.defaultLetter) ? ShortcutLetter.all.first { !held.contains($0) }! : row.defaultLetter
            kept.append((row, free))
        }
        letters = Dictionary(uniqueKeysWithValues: kept)
    }
}

typealias ShortcutsModel = StoredModel<Shortcuts>
