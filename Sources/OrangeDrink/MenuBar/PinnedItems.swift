import AppKit
import Observation
import os

/// One pinned device's menu bar item: its type glyph and its level.
struct PinnedItem: Equatable, Identifiable {
    let id: DeviceID
    let name: String
    let kind: DeviceKind
    /// "37%", or "~50%" when the level is only approximate.
    let percent: String

    /// One item for each pinned device that is connected and reports a level, by name then address.
    /// The Menu Bar screen's ordering (orange-devices-bue.2af) replaces that order.
    ///
    /// [LAW:one-source-of-truth] Derived from the live list and the pinned set on every call; no
    /// item outlives the facts it shows.
    static func items(_ list: DeviceList, pinned: Set<DeviceID>) -> [PinnedItem] {
        let rows = Dictionary(DeviceRanking.rows(list).map { ($0.id, $0) }, uniquingKeysWith: { _, later in later })
        return list.devices.compactMap { device in
            pinned.contains(device.id) ? rows[device.id].map { PinnedItem(id: device.id, name: device.name, kind: device.kind, percent: $0.percent) } : nil
        }
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
    private let makeItem: @MainActor () -> any PinnedStatusItem
    private var statusItems: [DeviceID: any PinnedStatusItem] = [:]

    init(makeItem: @escaping @MainActor () -> any PinnedStatusItem = { NSPinnedStatusItem() }) {
        self.makeItem = makeItem
    }

    /// Makes the status items equal to `items`: the missing added, the rest updated, the stale removed.
    func apply(_ items: [PinnedItem]) {
        let wanted = Set(items.map(\.id))
        for (id, item) in statusItems where !wanted.contains(id) { item.remove() }
        statusItems = statusItems.filter { wanted.contains($0.key) }
        for item in items {
            let shown = statusItems[item.id] ?? makeItem()
            shown.show(item)
            statusItems[item.id] = shown
        }
    }

    /// Follows the model's list and the settings' pins from now on.
    func follow(devices: DevicesModel, settings: DeviceSettingsModel) {
        withObservationTracking {
            apply(PinnedItem.items(devices.list, pinned: settings.settings.pinned))
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow(devices: devices, settings: settings) }
        }
    }
}

/// A pinned device's `NSStatusItem`: the type glyph beside the level.
@MainActor final class NSPinnedStatusItem: PinnedStatusItem {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    /// The text the item shows, for the check that it shows the device's level.
    var title: String { item.button?.title ?? "" }

    func show(_ pinned: PinnedItem) {
        guard let button = item.button else {
            Logger(subsystem: IOKitBattery.logSubsystem, category: "devices").error("a pinned device's status item has no button")
            return
        }
        button.image = NSImage(systemSymbolName: pinned.kind.symbol, accessibilityDescription: pinned.name)
        button.imagePosition = .imageLeading
        button.title = pinned.percent
        button.toolTip = pinned.name
    }

    func remove() { NSStatusBar.system.removeStatusItem(item) }
}
