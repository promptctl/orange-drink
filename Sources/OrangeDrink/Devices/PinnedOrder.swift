import Foundation

/// The devices pinned into the menu bar, in the order their items sit there, left to right.
///
/// [LAW:types-are-the-program] Unique by construction: the only ways to change it are `toggle` and
/// `move`, and every way to make one drops repeats, so no edit of the settings can hold a device
/// twice or reorder it into a place it was not.
/// [LAW:one-source-of-truth] The one place the bar's order is kept; the Menu Bar screen edits it
/// and the status items are made from it.
struct PinnedOrder: Equatable, Codable, Sendable, ExpressibleByArrayLiteral {
    private(set) var ids: [DeviceID]

    init(_ ids: some Sequence<DeviceID> = []) {
        var seen = Set<DeviceID>()
        self.ids = ids.filter { seen.insert($0).inserted }
    }

    init(arrayLiteral ids: DeviceID...) { self.init(ids) }

    /// [LAW:parse-dont-validate] What older installs stored as a set is an array on disk; it loads
    /// as an order, repeats dropped.
    init(from decoder: any Decoder) throws {
        self.init(try decoder.singleValueContainer().decode([DeviceID].self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(ids)
    }

    func contains(_ id: DeviceID) -> Bool { ids.contains(id) }

    /// Pins a device at the end, or unpins it.
    mutating func toggle(_ id: DeviceID) {
        if let index = ids.firstIndex(of: id) { ids.remove(at: index) } else { ids.append(id) }
    }

    /// Swaps two pinned devices. Devices between them keep their places, so a pinned device that is
    /// not connected, and so not shown on the screen, is not shuffled by moving its neighbours.
    mutating func swap(_ id: DeviceID, with other: DeviceID) {
        guard let first = ids.firstIndex(of: id), let second = ids.firstIndex(of: other) else { return }
        ids.swapAt(first, second)
    }
}
