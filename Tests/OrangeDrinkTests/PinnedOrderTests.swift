import AppKit
import Foundation
import Testing
@testable import OrangeDrink

// [LAW:verifiable-goals] The order the user arranges on the Menu Bar screen, from the stored list
// to the menu bar's items, with simulated devices: no Bluetooth, no menu bar.
@MainActor struct PinnedOrderTests {
    static let a = DeviceID.bluetooth("a"), b = DeviceID.bluetooth("b"), c = DeviceID.bluetooth("c")

    static func list(_ names: [DeviceID: String], percent: Int = 50) -> DeviceList {
        var list = DeviceList(sources: [.bluetooth])
        list.apply(.swept(names.map { id, name in
            SourceDevice(id: id, name: name, kind: .accessory, levels: .single(BatteryLevel(percent: percent, approximate: false)))
        }), from: .bluetooth)
        return list
    }
    static let devices = list([a: "Keyboard", b: "Mouse", c: "AirPods"])

    @Test func theOnlyChangesAreToggleAndSwapAndNoDeviceIsHeldTwice() {
        var order = PinnedOrder()
        order.toggle(Self.a); order.toggle(Self.b); order.toggle(Self.c)
        #expect(order.ids == [Self.a, Self.b, Self.c])
        order.swap(Self.a, with: Self.c)
        #expect(order.ids == [Self.c, Self.b, Self.a])
        order.swap(Self.a, with: DeviceID.bluetooth("not pinned"))
        #expect(order.ids == [Self.c, Self.b, Self.a])
        order.toggle(Self.b)
        #expect(order.ids == [Self.c, Self.a])
        #expect(PinnedOrder([Self.a, Self.b, Self.a]).ids == [Self.a, Self.b])
    }

    @Test func whatOlderInstallsStoredLoadsAsAnOrderWithRepeatsDropped() throws {
        let defaults = scratchDefaults()
        defaults.set(Data(#"{"pinned":[{"address":"b"},{"address":"a"},{"address":"b"}]}"#.utf8), forKey: DeviceSettings.storageKey)
        let first = try DeviceSettingsModel(defaults: defaults)
        #expect(first.value.pinned.ids == [Self.b, Self.a])
        try first.update { $0.pinned.swap(Self.a, with: Self.b) }
        #expect(try DeviceSettingsModel(defaults: defaults).value.pinned.ids == [Self.a, Self.b])
    }

    @Test func theItemsFollowTheOrderNotTheNames() {
        #expect(PinnedItem.items(Self.devices, pinned: [Self.b, Self.c, Self.a]).map(\.row.name) == ["Mouse", "AirPods", "Keyboard"])
        #expect(PinnedItem.items(Self.devices, pinned: [Self.a, Self.b, Self.c]).map(\.row.name) == ["Keyboard", "Mouse", "AirPods"])
    }

    final class Recording: PinnedStatusItem {
        var shown: PinnedItem?
        func show(_ item: PinnedItem) { shown = item }
        func remove() {}
    }

    /// Pins three devices, reorders them through the Menu Bar screen's list, and reads the bar:
    /// the first item made sits rightmost, so the bar left to right is the items made, reversed.
    @Test func reorderingThePinnedListReordersTheMenuBarItems() throws {
        let settings = try DeviceSettingsModel(defaults: scratchDefaults())
        for id in [Self.a, Self.b, Self.c] { try settings.update { $0.pinned.toggle(id) } }
        var made: [Recording] = []
        let controller = PinnedItemsController(makeItem: { _ in let item = Recording(); made.append(item); return item })
        func bar() -> [String] {
            controller.apply(PinnedItem.items(Self.devices, pinned: settings.value.pinned))
            return made.suffix(3).reversed().compactMap { $0.shown?.row.name }
        }
        #expect(bar() == ["Keyboard", "Mouse", "AirPods"])

        // The screen's own list says who is below the keyboard; its button swaps with that device.
        let screen = PinnedDevicesList(Self.devices, pinned: settings.value.pinned)
        #expect(screen.entries.map(\.row.name) == ["Keyboard", "Mouse", "AirPods"])
        #expect(screen.entries.map(\.above) == [nil, Self.a, Self.b])
        #expect(screen.entries.map(\.below) == [Self.b, Self.c, nil])
        try settings.update { $0.pinned.swap(Self.a, with: screen.entries[0].below!) }
        #expect(bar() == ["Mouse", "Keyboard", "AirPods"])
        try settings.update { $0.pinned.swap(Self.c, with: PinnedDevicesList(Self.devices, pinned: settings.value.pinned).entries[2].above!) }
        #expect(bar() == ["Mouse", "AirPods", "Keyboard"])
    }

    @Test func anEmptyCardSaysWhy() {
        var list = DeviceList(sources: [.bluetooth])
        let note = { PinnedDevicesList(list, pinned: [Self.a]).notes }
        #expect(note() == .only(.bluetooth(.waiting)))
        list.apply(.permission(.notDetermined), from: .bluetooth)
        #expect(note() == .only(.bluetooth(.unanswered)))
        list.apply(.permission(.denied), from: .bluetooth)
        #expect(note() == .only(.bluetooth(.denied)))
        list.apply(.swept([]), from: .bluetooth)
        #expect(note() == .none("Pin a connected device from the Devices screen to arrange it here."))
        list.end(.bluetooth)
        #expect(note() == .only(.bluetooth(.ended)))
    }

    @Test func aLevelChangeRedrawsAnItemWithoutMakingAnyAgain() {
        var made: [Recording] = []
        let controller = PinnedItemsController(makeItem: { _ in let item = Recording(); made.append(item); return item })
        controller.apply(PinnedItem.items(Self.devices, pinned: [Self.a, Self.b]))
        let changed = Self.list([Self.a: "Keyboard", Self.b: "Mouse"], percent: 40)
        controller.apply(PinnedItem.items(changed, pinned: [Self.a, Self.b]))
        #expect(made.count == 2)
        #expect(made.compactMap { $0.shown?.title } == ["40%", "40%"])
    }
}

/// The real menu bar, run by `make position-check`: the real status items in the real bar sit in
/// the order of the list, whether made fresh, reordered, or made over a position AppKit saved when
/// a user ⌘-dragged one. It puts items in the bar for a moment, so it is not part of `make test`.
@MainActor struct PinnedPositionCheck {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["POSITION_CHECK"] != nil, "run by make position-check"))
    func theBarFollowsTheListEvenOverASavedPosition() async throws {
        let ids = ["a", "b", "c"].map { DeviceID.bluetooth("position-check-\($0)") }
        let devices = PinnedOrderTests.list(Dictionary(uniqueKeysWithValues: zip(ids, ["Keyboard", "Mouse", "AirPods"])))
        var made: [DeviceID: NSPinnedStatusItem] = [:]
        let controller = PinnedItemsController(makeItem: { let item = NSPinnedStatusItem(id: $0, log: .unread); made[$0] = item; return item })
        defer { controller.apply([]) }
        // What a ⌘-drag of the middle device to the far right leaves behind, in the settings AppKit reads.
        let key = "NSStatusItem Preferred Position pinned-device-\(ids[1].wire)"
        defer { UserDefaults.standard.removeObject(forKey: key) }

        for order in [ids, [ids[2], ids[0], ids[1]], [ids[1], ids[2], ids[0]]] {
            // Set again each time: the first item made over it clears it.
            UserDefaults.standard.set(30.0, forKey: key)
            controller.apply(PinnedItem.items(devices, pinned: PinnedOrder(order)))
            // An item has no place (x of 0) until the bar has placed it; the wait is on the placement itself.
            func leftToRight() -> [DeviceID]? {
                let lefts = order.compactMap { made[$0]?.left }
                guard lefts.count == order.count, lefts.allSatisfy({ $0 > 0 }) else { return nil }
                return order.sorted { made[$0]!.left! < made[$1]!.left! }
            }
            let deadline = ContinuousClock.now + .seconds(5)
            while leftToRight() != order, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
            #expect(leftToRight() == order, "bar, left to right: \(String(describing: leftToRight()?.map(\.key))), wanted \(order.map(\.key))")
        }
    }
}
