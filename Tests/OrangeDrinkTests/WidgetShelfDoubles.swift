import Foundation
import os
@testable import OrangeDrink

/// Spins until `condition` holds or five seconds pass, so a failure fails instead of hanging the run.
@MainActor func eventually(_ condition: () throws -> Bool) async rethrows -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while try !condition() {
        guard ContinuousClock.now < deadline else { return false }
        await Task.yield()
    }
    return true
}

extension WidgetDeviceList {
    /// A fully read list for a test whose devices all rank. Only the test target has this: in the app every field is required.
    static func connected(_ ranked: [WidgetDevice], pinned: WidgetPins) -> WidgetDeviceList {
        WidgetDeviceList(ranked: ranked, pinned: pinned, unlevelled: [], unreadSources: [])
    }
}

extension WidgetDeviceList {
    /// A list with nothing to show and one source unread: what a widget draws when no device has been read yet.
    static func unread(_ source: UnreadSource) -> WidgetDeviceList {
        WidgetDeviceList(ranked: [], pinned: [], unlevelled: [], unreadSources: [source])
    }

    static func unread(_ reason: BluetoothNoList) -> WidgetDeviceList { unread(.bluetooth(reason)) }
}

extension UnreadSource {
    /// Every reason of every source, each source's own and no pair that is not one. A source's new reason is in it with no edit.
    static let all: [UnreadSource] = BluetoothNoList.allCases.map(UnreadSource.bluetooth) + IPhoneNoList.allCases.map(UnreadSource.iPhone)
        + IPhoneMissing.allCases.map(UnreadSource.iPhoneMissing)
}

extension ListNotes {
    /// What a card with no rows says when only these sources are unread: no "none connected", and each source's sentence.
    static func only(_ sources: UnreadSource...) -> ListNotes { ListNotes(empty: nil, unread: sources.map(\.explanation)) }
    /// What a fully read card with no rows says.
    static func none(_ phrase: Phrase) -> ListNotes { ListNotes(empty: phrase, unread: []) }
}

extension PinnedItem {
    /// The items in English, for a test that does not care what language they are said in.
    static func items(_ list: DeviceList, pinned: PinnedOrder) -> [PinnedItem] { items(list, pinned: pinned, language: AppLanguage(code: "en")) }
}

extension DevicesModel {
    /// The app's own wiring, for a test that does not care what the app has seen: a throwaway memory, mirrored beside `shelf`.
    convenience init(
        sources: [DeviceSource: AsyncThrowingStream<DeviceEvent, any Error>], shelf: ShelfPublisher<Shelved<WidgetDeviceList>>, settings: DeviceSettingsModel, language: AppLanguageModel? = nil, pinnedItems: PinnedItemsController, log: Logger,
        onChange: @escaping @MainActor (DeviceList) -> Void = { _ in }
    ) throws {
        let seen = try SeenDevicesModel(defaults: scratchDefaults())
        let seenShelf = ShelfPublisher<SeenDevices>(item: .seenDevices, directory: shelf.directory, log: log) { _ in }
        self.init(sources: sources, shelf: shelf, seenShelf: seenShelf, settings: settings, seen: seen,
                  language: try language ?? AppLanguageModel(defaults: scratchDefaults()), pinnedItems: pinnedItems, log: log, onChange: onChange)
    }

    /// The same, for a test that cares about neither the pins nor the menu bar: nothing pinned, in a throwaway suite.
    convenience init(
        sources: [DeviceSource: AsyncThrowingStream<DeviceEvent, any Error>], shelf: ShelfPublisher<Shelved<WidgetDeviceList>>, log: Logger, onChange: @escaping @MainActor (DeviceList) -> Void = { _ in }
    ) throws {
        let settings = try DeviceSettingsModel(defaults: scratchDefaults())
        let pinnedItems = PinnedItemsController(makeItem: { _ in PinnedItemsTests.RecordingItem() })
        try self.init(sources: sources, shelf: shelf, settings: settings, pinnedItems: pinnedItems, log: log, onChange: onChange)
    }
}
