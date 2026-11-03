import Foundation
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

extension WidgetDevices {
    /// A read list for a test whose devices all rank. Only the test target has this: in the app every field is required.
    static func connected(_ ranked: [WidgetDevice], pinned: WidgetPins) -> WidgetDevices {
        .connected(WidgetDeviceList(ranked: ranked, pinned: pinned, unlevelled: []))
    }
}

extension PinnedItem {
    /// The items in English, for a test that does not care what language they are said in.
    static func items(_ list: DeviceList, pinned: PinnedOrder) -> [PinnedItem] { items(list, pinned: pinned, language: AppLanguage(code: "en")) }
}

extension DevicesModel {
    /// The app's own wiring, for a test that does not care what the app has seen: a throwaway memory, mirrored beside `shelf`.
    convenience init(
        events: AsyncThrowingStream<DeviceEvent, any Error>, shelf: ShelfPublisher<Shelved<WidgetDevices>>, settings: DeviceSettingsModel, language: AppLanguageModel? = nil, pinnedItems: PinnedItemsController,
        onChange: @escaping @MainActor (DeviceList) -> Void = { _ in }
    ) throws {
        let seen = try SeenDevicesModel(defaults: scratchDefaults())
        let seenShelf = ShelfPublisher<SeenDevices>(item: .seenDevices, directory: shelf.directory) { _ in }
        self.init(events: events, shelf: shelf, seenShelf: seenShelf, settings: settings, seen: seen,
                  language: try language ?? AppLanguageModel(defaults: scratchDefaults()), pinnedItems: pinnedItems, onChange: onChange)
    }

    /// The same, for a test that cares about neither the pins nor the menu bar: nothing pinned, in a throwaway suite.
    convenience init(
        events: AsyncThrowingStream<DeviceEvent, any Error>, shelf: ShelfPublisher<Shelved<WidgetDevices>>, onChange: @escaping @MainActor (DeviceList) -> Void = { _ in }
    ) throws {
        let settings = try DeviceSettingsModel(defaults: scratchDefaults())
        let pinnedItems = PinnedItemsController(makeItem: { _ in PinnedItemsTests.RecordingItem() })
        try self.init(events: events, shelf: shelf, settings: settings, pinnedItems: pinnedItems, onChange: onChange)
    }
}
