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

    func toggle(_ section: Section) {
        if open.remove(section) == nil { open.insert(section) }
        defaults.set(open.contains(section), forKey: Self.key(section))
    }

    private static func key(_ section: Section) -> String { "panel.\(section.rawValue).open" }
}
