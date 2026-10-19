import AppKit
import Observation

/// One pinned device's menu bar item: the same row the panel and the Devices screen show, so its
/// name, type glyph, and level text ("37%", "~50%" when approximate) are written once.
struct PinnedItem: Equatable, Identifiable {
    let row: DeviceRow
    var id: DeviceID { row.id }

    /// One item for each pinned device that is connected and reports a level, in the order the
    /// user arranged them on the Menu Bar screen.
    ///
    /// [LAW:one-source-of-truth] Derived from the live list and the pinned order on every call; no
    /// item outlives the facts it shows.
    static func items(_ list: DeviceList, pinned: PinnedOrder) -> [PinnedItem] {
        let rows = DeviceRanking.rows(list)
        return pinned.ids.compactMap { id in rows.first { $0.id == id } }.map(PinnedItem.init)
    }
}

/// One status item in the menu bar, as the controller drives it.
@MainActor protocol PinnedStatusItem: AnyObject {
    func show(_ item: PinnedItem)
    func remove()
}

/// The menu bar items of the pinned devices: one status item each, kept equal to `PinnedItem.items`.
///
/// [LAW:effects-at-boundaries] The diffing is here and asserted with a recording item; the one
/// `NSStatusItem` is behind `PinnedStatusItem`.
/// [LAW:no-ambient-temporal-coupling] Observation re-arms after every change to the list or the
/// pins, so the items follow both with no timer and no polling.
@MainActor final class PinnedItemsController {
    /// Makes the status item for a device. The bar places the first item made rightmost and each
    /// later one to its left, so the items are made right to left.
    private let makeItem: @MainActor (DeviceID) -> any PinnedStatusItem
    /// The items in the bar, left to right, each with what it last showed so an unchanged one is
    /// not redrawn.
    private var held: [(id: DeviceID, item: any PinnedStatusItem, shown: PinnedItem?)] = []

    init(makeItem: @escaping @MainActor (DeviceID) -> any PinnedStatusItem = { NSPinnedStatusItem(id: $0) }) {
        self.makeItem = makeItem
    }

    /// Makes the status items equal to `items`, in that order. A change in which devices have an
    /// item, or in their order, makes them all again, since the bar's order is the order they were
    /// made in; a change only in a level redraws that item.
    func apply(_ items: [PinnedItem]) {
        if items.map(\.id) != held.map(\.id) {
            held.forEach { $0.item.remove() }
            held = items.reversed().map { (id: $0.id, item: makeItem($0.id), shown: nil) }.reversed()
        }
        for index in held.indices where held[index].shown != items[index] {
            held[index].item.show(items[index])
            held[index].shown = items[index]
        }
    }

    /// Follows the model's list and the settings' pins from now on.
    func follow(devices: DevicesModel, settings: DeviceSettingsModel) {
        withObservationTracking {
            apply(PinnedItem.items(devices.list, pinned: settings.value.pinned))
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow(devices: devices, settings: settings) }
        }
    }
}

/// A pinned device's `NSStatusItem`: the type glyph beside the level.
@MainActor final class NSPinnedStatusItem: PinnedStatusItem {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    /// [LAW:one-source-of-truth] The order is the user's list. AppKit keeps a place for every item
    /// by its autosave name, written when the user ⌘-drags it, and that place beats the order the
    /// items are made in. A name per device makes the key known, and removing it from the settings
    /// AppKit reads (the standard ones) before the name is set leaves the list the only say. The
    /// same holds for the visibility a ⌘-drag out of the bar saves, which would hide the item for
    /// good. `make position-check` holds the order against the real bar.
    init(id: DeviceID) {
        let name = "pinned-device-\(id.address)"
        for key in ["Preferred Position", "Visible"] {
            UserDefaults.standard.removeObject(forKey: "NSStatusItem \(key) \(name)")
        }
        item.autosaveName = name
    }

    /// The text the item shows, for the check that it shows the device's level.
    var title: String { item.button?.title ?? "" }

    /// Where the item sits on screen, for the check that the bar follows the list.
    var left: CGFloat? { item.button?.window?.frame.minX }

    func show(_ pinned: PinnedItem) {
        guard let button = item.button else {
            BluetoothDevices.log.error("a pinned device's status item has no button")
            return
        }
        button.image = NSImage(systemSymbolName: pinned.row.kind.symbol, accessibilityDescription: pinned.row.name)
        button.imagePosition = .imageLeading
        button.title = pinned.row.percent
        button.toolTip = pinned.row.name
    }

    func remove() { NSStatusBar.system.removeStatusItem(item) }
}
