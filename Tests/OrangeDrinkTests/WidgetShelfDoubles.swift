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

extension DevicesModel {
    /// The app's own wiring, for a test that cares about neither the pins nor the menu bar: nothing pinned, in a throwaway suite.
    convenience init<Events: AsyncSequence & Sendable>(
        events: Events, shelf: ShelfPublisher<WidgetDevices>, onChange: @escaping @MainActor (DeviceList) -> Void = { _ in }
    ) throws where Events.Element == DeviceEvent {
        let settings = try DeviceSettingsModel(defaults: UserDefaults(suiteName: "WidgetShelfDoubles.\(UUID())")!)
        let pinnedItems = PinnedItemsController(makeItem: { _ in PinnedItemsTests.RecordingItem() })
        self.init(events: events, shelf: shelf, settings: settings, pinnedItems: pinnedItems, onChange: onChange)
    }
}
