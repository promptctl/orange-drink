import Foundation
import Observation
import os

extension MacBattery {
    /// What the widget draws for the model's state. [LAW:one-source-of-truth] The widget derives from
    /// the one battery subscription, as every view does.
    init(_ state: BatteryModel.State) {
        self = switch state {
        case .unknown: .waiting
        case .known(nil): .noBattery
        case .known(let reading?): .level(percent: reading.chargePercent, charging: reading.power.isCharging)
        case .ended: .ended
        }
    }
}

extension WidgetDevice {
    init(_ row: DeviceRow) {
        self.init(id: row.id, name: row.name, kind: row.kind, level: row.level)
    }
}

extension WidgetDeviceList {
    /// What the widgets draw for the list. [LAW:one-source-of-truth] Derived from the one ranking the panel
    /// reads, so a widget shows the level the panel shows, from the list's one account of what was not read,
    /// and from the one order the menu bar's items are made in.
    init(_ list: DeviceList, pinned: PinnedOrder) {
        self.init(ranked: DeviceRanking.rows(list).map(WidgetDevice.init),
                  pinned: WidgetPins(ids: pinned.ids),
                  unlevelled: DeviceRanking.unlevelled(list).map(WidgetDevice.init),
                  unreadSources: list.unreadSources)
    }
}

extension DevicesModel {
    /// The one wiring of the list, the pins, the language and what has been seen to what mirrors them: the pinned menu bar items and the widgets' shelf. The
    /// list it starts from reaches the shelf before this returns, so a file a crashed run left behind is not drawn as current
    /// while the first Bluetooth sweep is still out.
    convenience init(
        sources: [DeviceSource: AsyncThrowingStream<DeviceEvent, any Error>], shelf: ShelfPublisher<Shelved<WidgetDeviceList>>, seenShelf: ShelfPublisher<SeenDevices>,
        settings: DeviceSettingsModel, seen: SeenDevicesModel, language: AppLanguageModel, pinnedItems: PinnedItemsController, log: Logger,
        onChange: @escaping @MainActor (DeviceList) -> Void = { _ in }
    ) {
        self.init(sources: sources, log: log, onChange: { list in
            do {
                try seen.update { $0.see(list) }
            } catch {
                // [LAW:no-silent-failure] Logged; the memory still lacks the list, so the next event saves it.
                log.error("seen devices not saved: \(String(describing: error), privacy: .public)")
            }
            onChange(list)
        })
        mirror(to: shelf, seenShelf: seenShelf, settings: settings, seen: seen, language: language, pinnedItems: pinnedItems)
    }

    /// [LAW:no-ambient-temporal-coupling] Observation re-arms after every change to the list, the pins, the language or what has been seen, with no timer
    /// and no polling. A mirror needs only the latest, so changes that land together reach it as one.
    private func mirror(to shelf: ShelfPublisher<Shelved<WidgetDeviceList>>, seenShelf: ShelfPublisher<SeenDevices>, settings: DeviceSettingsModel,
                        seen: SeenDevicesModel, language: AppLanguageModel, pinnedItems: PinnedItemsController) {
        withObservationTracking {
            pinnedItems.apply(PinnedItem.items(list, pinned: settings.value.pinned, language: language.value))
            shelf.publish(.running(WidgetDeviceList(list, pinned: settings.value.pinned)))
            seenShelf.publish(seen.value)
        } onChange: { [weak self] in
            Task { @MainActor in self?.mirror(to: shelf, seenShelf: seenShelf, settings: settings, seen: seen, language: language, pinnedItems: pinnedItems) }
        }
    }
}

/// Keeps one shelf file holding what the app hands its widgets, and asks WidgetKit to redraw each widget
/// that draws it when it changes.
@MainActor final class ShelfPublisher<Contents: Codable & Equatable & Sendable> {
    private let item: WidgetShelf.Item<Contents>
    let directory: URL
    private let reload: @MainActor (WidgetKind) -> Void
    private let log: Logger

    /// [LAW:effects-at-boundaries] `reload` is the app's call into WidgetKit, asked once per reader of
    /// the file; a test passes a recorder.
    init(item: WidgetShelf.Item<Contents>, directory: URL, log: Logger, reload: @escaping @MainActor (WidgetKind) -> Void) {
        self.log = log
        self.item = item
        self.directory = directory
        self.reload = reload
    }

    /// [LAW:one-source-of-truth] The shelf is the memory of what was published: a value it already
    /// holds costs no write and no reload, and another copy of the app that wrote over it (a test
    /// host quitting beside the installed app) is corrected by this one's next state, which a refused
    /// app does not have: nothing sweeps it. A shelf that cannot be read does not hold the value, so it is written.
    func publish(_ contents: Contents) {
        let value = String(describing: contents)
        let shelf = directory.path
        guard (try? WidgetShelf.read(item, from: directory).get()) != contents else {
            log.info("widget shelf unchanged: \(value, privacy: .public) in \(shelf, privacy: .public)")
            return
        }
        do {
            try WidgetShelf.write(contents, as: item, to: directory)
            item.readers.forEach(reload)
            let readers = item.readers.map(\.rawValue).joined(separator: ", ")
            log.info("widget shelf written: \(value, privacy: .public) in \(shelf, privacy: .public), reload asked of: \(readers, privacy: .public)")
        } catch {
            // [LAW:no-silent-failure] Logged; the shelf still differs, so the next state retries.
            log.error("widget shelf write failed: \(value, privacy: .public) in \(shelf, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
