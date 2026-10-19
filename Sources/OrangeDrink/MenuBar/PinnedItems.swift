import AppKit
import Observation

/// One pinned device's menu bar item: the same row the panel and the Devices screen show, so its
/// name, type glyph, and level text ("37%", "~50%" when approximate) are written once.
struct PinnedItem: Equatable, Identifiable {
    let row: DeviceRow
    var id: DeviceID { row.id }

    /// One item for each pinned device that is connected and reports a level, by name then address
    /// so an item never reshuffles as levels change. The Menu Bar screen's ordering
    /// (orange-devices-bue.2af) replaces that order.
    ///
    /// [LAW:one-source-of-truth] Derived from the live list and the pinned set on every call; no
    /// item outlives the facts it shows.
    static func items(_ list: DeviceList, pinned: Set<DeviceID>) -> [PinnedItem] {
        DeviceRanking.rows(list)
            .filter { pinned.contains($0.id) }
            .sorted { ($0.name, $0.id.address) < ($1.name, $1.id.address) }
            .map(PinnedItem.init)
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
    /// Makes the status item for a device; the same device always gets the same place in the bar.
    private let makeItem: @MainActor (DeviceID) -> any PinnedStatusItem
    /// Each item with what it last showed, so an unchanged one is not redrawn.
    private var statusItems: [DeviceID: (item: any PinnedStatusItem, shown: PinnedItem)] = [:]

    init(makeItem: @escaping @MainActor (DeviceID) -> any PinnedStatusItem = { NSPinnedStatusItem(id: $0) }) {
        self.makeItem = makeItem
    }

    /// Makes the status items equal to `items`: the missing added, the rest updated, the stale removed.
    func apply(_ items: [PinnedItem]) {
        let wanted = Set(items.map(\.id))
        for (id, held) in statusItems where !wanted.contains(id) { held.item.remove() }
        statusItems = statusItems.filter { wanted.contains($0.key) }
        for pinned in items {
            let item = statusItems[pinned.id]?.item ?? makeItem(pinned.id)
            if statusItems[pinned.id]?.shown != pinned { item.show(pinned) }
            statusItems[pinned.id] = (item, pinned)
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

    /// [LAW:one-source-of-truth] AppKit keys an item's remembered place in the bar by its autosave
    /// name, so one name per device lets a device that returns be given the place it had. Not yet
    /// checked against a running app.
    init(id: DeviceID) { item.autosaveName = "pinned-device-\(id.address)" }

    /// The text the item shows, for the check that it shows the device's level.
    var title: String { item.button?.title ?? "" }

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
