import Carbon.HIToolbox

/// A key with the modifiers held down: what a hot key is pressed as, and what the Shortcuts screen shows.
struct KeyCombo: Equatable, Codable, Sendable {
    struct Modifiers: OptionSet, Codable, Sendable {
        let rawValue: UInt8
        static let control = Modifiers(rawValue: 1)
        static let option = Modifiers(rawValue: 2)
        static let shift = Modifiers(rawValue: 4)
        static let command = Modifiers(rawValue: 8)

        /// The Mac's own order for writing them.
        private static let glyphs: [(Modifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        var glyphs: String { Self.glyphs.filter { contains($0.0) }.map(\.1).joined() }

        /// The modifier mask Carbon's hot key registration takes.
        var carbon: UInt32 {
            [(Modifiers.control, controlKey), (.option, optionKey), (.shift, shiftKey), (.command, cmdKey)]
                .filter { contains($0.0) }.reduce(0) { $0 | UInt32($1.1) }
        }
    }

    /// The key's place on the keyboard (a virtual key code), which is what a hot key is registered by.
    let keyCode: UInt32
    /// The key as its keycap reads on the layout it was recorded on, which is how the Shortcuts screen shows it.
    let label: String
    let modifiers: Modifiers

    /// [LAW:parse-dont-validate] The one way a combination is made from what was pressed or stored: a letter
    /// held with at least two of Control, Option, and Command, so a global shortcut can never take a plain
    /// key, ⌘Q, or an Option-typed character from every app.
    init?(keyCode: UInt32, label: String? = nil, modifiers: Modifiers) {
        guard let letter = Self.letters[keyCode], Self.hasEnoughModifiers(modifiers) else { return nil }
        self.keyCode = keyCode
        // A keycap is one letter; anything else a layout reports (a control character, nothing) is the key's ANSI letter.
        self.label = label.flatMap { $0.count == 1 && $0.first!.isLetter ? $0.uppercased() : nil } ?? letter
        self.modifiers = modifiers
    }

    /// Whether a key can be a global shortcut at all, whatever it is held with.
    static func isSupportedKey(_ keyCode: UInt32) -> Bool { letters[keyCode] != nil }

    static func hasEnoughModifiers(_ modifiers: Modifiers) -> Bool {
        modifiers.intersection([.control, .option, .command]).rawValue.nonzeroBitCount >= 2
    }

    /// The same shortcut whatever its keycap says: the system knows a key by its code.
    static func == (a: KeyCombo, b: KeyCombo) -> Bool { a.keyCode == b.keyCode && a.modifiers == b.modifiers }

    /// Control-Option-J: the shortcut that opens the panel until the user records another.
    static let openPanel = KeyCombo(keyCode: UInt32(kVK_ANSI_J), modifiers: [.control, .option])!

    private enum CodingKeys: String, CodingKey { case keyCode, label, modifiers }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let keyCode = try values.decode(UInt32.self, forKey: .keyCode)
        let label = try values.decodeIfPresent(String.self, forKey: .label)
        let modifiers = try values.decode(Modifiers.self, forKey: .modifiers)
        guard let combo = KeyCombo(keyCode: keyCode, label: label, modifiers: modifiers) else {
            throw DecodingError.dataCorruptedError(forKey: .keyCode, in: values, debugDescription: "not a letter held with two of Control, Option, and Command")
        }
        self = combo
    }

    /// "⌃⌥J".
    var display: String { modifiers.glyphs + label }

    private static let letters: [UInt32: String] = Dictionary(uniqueKeysWithValues: [
        (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"), (kVK_ANSI_E, "E"), (kVK_ANSI_F, "F"),
        (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"), (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"), (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"),
        (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"), (kVK_ANSI_P, "P"), (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"),
        (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"), (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"),
        (kVK_ANSI_Y, "Y"), (kVK_ANSI_Z, "Z"),
    ].map { (UInt32($0.0), $0.1) })
}
