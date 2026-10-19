import AppKit
import Foundation
import Testing
@testable import OrangeDrink

// [LAW:verifiable-goals] The pinned items from simulated devices: no Bluetooth in the room.
@MainActor struct PinnedItemsTests {
    static let mouse = DeviceID(address: "m")
    static let pods = DeviceID(address: "p")

    private func list(_ levels: [DeviceID: BatteryLevel?]) -> DeviceList {
        var list = DeviceList()
        list.apply(.swept(levels.map { id, level in
            Device(id: id, name: id == Self.mouse ? "Magic Mouse" : "AirPods", kind: .accessory,
                   levels: level.map { .single($0) } ?? .none)
        }))
        return list
    }
    private func level(_ percent: Int, approximate: Bool = false) -> BatteryLevel { BatteryLevel(percent: percent, approximate: approximate) }

    final class RecordingItem: PinnedStatusItem {
        var shown: PinnedItem?
        var removed = false
        func show(_ item: PinnedItem) { shown = item }
        func remove() { removed = true }
    }
    final class Items { var made: [RecordingItem] = [] }

    private func controller(_ items: Items) -> PinnedItemsController {
        PinnedItemsController(makeItem: { _ in let item = RecordingItem(); items.made.append(item); return item })
    }

    /// Spins until `condition` holds or five seconds pass, so a failure fails instead of hanging the run.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            await Task.yield()
        }
        return true
    }

    @Test func aPinnedDeviceShowsItsLevelAndFollowsAChange() {
        let items = Items()
        let controller = controller(items)
        controller.apply(PinnedItem.items(list([Self.mouse: level(37)]), pinned: [Self.mouse]))
        #expect(items.made.count == 1)
        #expect(items.made[0].shown?.row.percent == "37%")
        controller.apply(PinnedItem.items(list([Self.mouse: level(30)]), pinned: [Self.mouse]))
        #expect(items.made.count == 1)
        #expect(items.made[0].shown?.row.percent == "30%")
    }

    @Test func anApproximateLevelIsMarked() {
        #expect(PinnedItem.items(list([Self.mouse: level(50, approximate: true)]), pinned: [Self.mouse]).map(\.row.percent) == ["~50%"])
    }

    @Test func onlyPinnedConnectedDevicesWithALevelHaveAnItem() {
        let devices = list([Self.mouse: level(37), Self.pods: nil])
        #expect(PinnedItem.items(devices, pinned: []).isEmpty)
        #expect(PinnedItem.items(devices, pinned: [Self.pods]).isEmpty)
        #expect(PinnedItem.items(devices, pinned: [DeviceID(address: "gone")]).isEmpty)
        #expect(PinnedItem.items(devices, pinned: [Self.mouse, Self.pods]).map(\.row.name) == ["Magic Mouse"])
    }

    @Test func unpinningOrDisconnectingRemovesTheItem() {
        let items = Items()
        let controller = controller(items)
        let devices = list([Self.mouse: level(37)])
        controller.apply(PinnedItem.items(devices, pinned: [Self.mouse]))
        controller.apply(PinnedItem.items(devices, pinned: []))
        #expect(items.made[0].removed)
        controller.apply(PinnedItem.items(devices, pinned: [Self.mouse]))
        controller.apply(PinnedItem.items(DeviceList(), pinned: [Self.mouse]))
        #expect(items.made.count == 2)
        #expect(items.made[1].removed)
    }

    @Test func aSecondPinnedDeviceAddsASecondItem() {
        let items = Items()
        let controller = controller(items)
        controller.apply(PinnedItem.items(list([Self.mouse: level(37), Self.pods: level(80)]), pinned: [Self.mouse, Self.pods]))
        #expect(items.made.map { $0.shown?.row.percent } == ["80%", "37%"] || items.made.map { $0.shown?.row.percent } == ["37%", "80%"])
        #expect(items.made.count == 2)
    }

    @Test func theControllerFollowsTheModelAndThePinsThroughObservation() async throws {
        let (events, send) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let model = DevicesModel(events: events)
        let defaults = UserDefaults(suiteName: "PinnedItemsTests.\(UUID())")!
        let settings = try DeviceSettingsModel(defaults: defaults)
        let items = Items()
        let controller = controller(items)
        // The observation holds the controller weakly, so keep it alive to the end of the test.
        defer { withExtendedLifetime(controller) {} }
        do {
            controller.follow(devices: model, settings: settings)
            try settings.update { $0.togglePinned(Self.mouse) }
            send.yield(.swept(list([Self.mouse: level(37)]).devices))
            #expect(await eventually { items.made.first?.shown?.row.percent == "37%" })
            send.yield(.swept(list([Self.mouse: level(30)]).devices))
            #expect(await eventually { items.made.first?.shown?.row.percent == "30%" })
            try settings.update { $0.togglePinned(Self.mouse) }
            #expect(await eventually { items.made.first?.removed == true })
            #expect(items.made.count == 1)
        }
    }

    @Test func thePinPersistsAndAnOlderStoredValueWithoutItStillLoads() throws {
        let defaults = UserDefaults(suiteName: "PinnedItemsTests.\(UUID())")!
        defaults.set(Data(#"{"showConnectedDevices":true}"#.utf8), forKey: DeviceSettings.storageKey)
        let first = try DeviceSettingsModel(defaults: defaults)
        #expect(first.value.pinned.ids.isEmpty)
        try first.update { $0.togglePinned(Self.mouse) }
        #expect(try DeviceSettingsModel(defaults: defaults).value.pinned == [Self.mouse])
    }

    @Test func theMenuBarItemShowsTheLevelAndRemovesCleanly() {
        let item = NSPinnedStatusItem(id: Self.mouse)
        func pinned(_ percent: Int) -> PinnedItem {
            PinnedItem.items(list([Self.mouse: level(percent)]), pinned: [Self.mouse])[0]
        }
        item.show(pinned(37))
        #expect(item.title == "37%")
        item.show(pinned(30))
        #expect(item.title == "30%")
        item.remove()
    }

    @Test func anUnchangedItemIsNotRedrawn() {
        final class Counting: PinnedStatusItem {
            var shows = 0
            func show(_ item: PinnedItem) { shows += 1 }
            func remove() {}
        }
        let counting = Counting()
        let controller = PinnedItemsController(makeItem: { _ in counting })
        let items = PinnedItem.items(list([Self.mouse: level(37)]), pinned: [Self.mouse])
        controller.apply(items)
        controller.apply(items)
        #expect(counting.shows == 1)
        controller.apply(PinnedItem.items(list([Self.mouse: level(36)]), pinned: [Self.mouse]))
        #expect(counting.shows == 2)
    }

    @Test func eachDeviceIsMadeItsOwnItemByItsId() {
        var made: [DeviceID] = []
        let controller = PinnedItemsController(makeItem: { made.append($0); return RecordingItem() })
        controller.apply(PinnedItem.items(list([Self.mouse: level(37), Self.pods: level(80)]), pinned: [Self.mouse, Self.pods]))
        #expect(made == [Self.pods, Self.mouse])
    }
}
