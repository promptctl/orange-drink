import Foundation
import Observation

/// Which of the panel's collapsible sections are open, remembered across launches.
///
/// [LAW:one-source-of-truth] UserDefaults holds what is remembered; `open` is the live copy
/// the views observe, loaded once and written through on every change, with this the only writer.
@Observable @MainActor final class PanelSections {
    enum Section: String, CaseIterable {
        case batteryInformation
        case connectedDevices

        /// The letter that flips this section while the panel is open (design-docs/shortcuts.md, Menu Shortcuts).
        var key: Character {
            switch self {
            case .batteryInformation: "i"
            case .connectedDevices: "d"
            }
        }
    }

    private(set) var open: Set<Section>
    @ObservationIgnored private let defaults: UserDefaults

    /// [LAW:composability] The store is whatever defaults it is given: the app passes the standard
    /// ones, a test a throwaway suite, so a "relaunch" is a second instance over the same suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        open = Set(Section.allCases.filter { defaults.bool(forKey: Self.key($0)) })
    }

    func isOpen(_ section: Section) -> Bool { open.contains(section) }

    /// A single key's shortcut: it flips its section as clicking the section's header does, when the panel is
    /// drawing that section. True when the key was a shortcut and was used.
    func press(_ key: Character, shown: Set<Section>) -> Bool {
        guard let section = Section.allCases.first(where: { $0.key == key.lowercased().first }), shown.contains(section) else { return false }
        toggle(section)
        return true
    }

    func toggle(_ section: Section) {
        if open.remove(section) == nil { open.insert(section) }
        defaults.set(open.contains(section), forKey: Self.key(section))
    }

    private static func key(_ section: Section) -> String { "panel.\(section.rawValue).open" }
}
