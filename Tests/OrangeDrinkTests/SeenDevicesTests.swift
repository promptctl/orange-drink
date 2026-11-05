import Foundation
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what Edit Widget names and offers after the app has seen a device: through the
// app's wiring to the shelf and the real entity query, from a shelf in a directory of the test's own and a defaults suite of its own.
@MainActor @Suite final class SeenDevicesTests {
    static let buds = device("BB", "Earbuds")
    static let phone = device("AA", "iPhone")
    static let mouse = device("CC", "Mouse")
    static let day: TimeInterval = 86_400
    static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func device(_ address: String, _ name: String, levels: DeviceLevels = .single(BatteryLevel(percent: 50, approximate: false))) -> SourceDevice {
        SourceDevice(id: DeviceID.bluetooth(address), name: name, kind: .accessory, levels: levels)
    }

    static func unavailable() -> String { DeviceQuery.unavailable.resolve(in: .matchSystem) }

    let shelf = FileManager.default.temporaryDirectory.appending(path: "seen-\(UUID().uuidString)")
    let defaults = scratchDefaults()
    let query: DeviceQuery
    let devicesShelf: ShelfPublisher<Shelved<WidgetDeviceList>>
    let seenShelf: ShelfPublisher<SeenDevices>
    /// The app's clock: the test sets the time.
    final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }
    let clock = Clock(SeenDevicesTests.start)

    init() throws {
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
        query = DeviceQuery(directory: .success(shelf), log: .unread)
        devicesShelf = ShelfPublisher(item: .devices, directory: shelf, log: .unread) { _ in }
        seenShelf = ShelfPublisher(item: .seenDevices, directory: shelf, log: .unread) { _ in }
    }

    deinit {
        try? FileManager.default.removeItem(at: shelf)
    }

    /// The app, started over the test's shelf and defaults. A second call is a relaunch.
    func launch() throws -> (model: DevicesModel, send: AsyncThrowingStream<DeviceEvent, any Error>.Continuation) {
        let (events, send) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let model = DevicesModel(
            sources: [.bluetooth: events], shelf: devicesShelf, seenShelf: seenShelf, settings: try DeviceSettingsModel(defaults: defaults),
            seen: try SeenDevicesModel.load(defaults: defaults, adoptingAt: clock.now), language: try AppLanguageModel(defaults: defaults),
            pinnedItems: PinnedItemsController(makeItem: { _ in PinnedItemsTests.RecordingItem() }), log: .unread, now: { [clock] in clock.now })
        return (model, send)
    }

    /// What Edit Widget calls these devices.
    func named(_ addresses: [String]) async throws -> [String] {
        try await query.entities(for: addresses).map(\.name)
    }

    /// What Edit Widget offers.
    func offered() async throws -> [String] {
        try await query.suggestedEntities().map(\.name)
    }

    func connected() throws -> Int? {
        guard case .running(let list) = try WidgetShelf.read(.devices, from: shelf).get() else { return nil }
        return list.ranked.count + list.unlevelled.count
    }

    /// Sweeps `devices`, and waits until the devices file holds them and the seen file holds `addresses`.
    func sweep(_ devices: [SourceDevice], on send: AsyncThrowingStream<DeviceEvent, any Error>.Continuation, seen addresses: [String]) async throws {
        send.yield(.swept(devices))
        #expect(try await eventually {
            try connected() == devices.count && Set(WidgetShelf.read(.seenDevices, from: shelf).get().names.keys) == Set(addresses.map(DeviceID.bluetooth))
        })
    }

    // MARK: a device that has gone

    /// The Done when of orange-widgets-5jo.tvo.
    @Test func aDeviceOffTheShelfIsStillNamedAndOfferedAndOneNeverSeenIsNot() async throws {
        let (model, send) = try launch()
        try await sweep([Self.buds, Self.phone], on: send, seen: ["AA", "BB"])
        try await sweep([Self.phone], on: send, seen: ["AA", "BB"])

        #expect(try await named(["BB", "ZZ"]) == ["Earbuds", Self.unavailable()])
        #expect(try await offered() == ["Earbuds", "iPhone"])
        _ = model
    }

    @Test func theyKeepTheirNamesWhenTheAppHasNoListOrHasQuit() async throws {
        let (model, send) = try launch()
        try await sweep([Self.buds], on: send, seen: ["BB"])

        send.yield(.permission(.denied))
        #expect(try await eventually { try WidgetShelf.read(.devices, from: shelf).get() == .running(.unread(.denied)) })
        #expect(try await named(["BB"]) == ["Earbuds"])

        devicesShelf.publish(.appNotRunning)
        #expect(try await named(["BB"]) == ["Earbuds"])
        #expect(try await offered() == ["Earbuds"])
        _ = model
    }

    @Test func aRelaunchKeepsThemAndAddsToThem() async throws {
        let first = try launch()
        try await sweep([Self.buds], on: first.send, seen: ["BB"])

        let second = try launch()
        try await sweep([Self.phone], on: second.send, seen: ["AA", "BB"])
        #expect(try await offered() == ["Earbuds", "iPhone"])
        _ = (first.model, second.model)
    }

    /// The memory is the app's and the file its mirror, so a file that cannot be read costs nothing the app knows.
    @Test func aSeenFileThatCannotBeReadOffersNothingAndIsWrittenAgainWithItsNames() async throws {
        let (model, send) = try launch()
        try await sweep([Self.buds], on: send, seen: ["BB"])

        try Data("not json".utf8).write(to: shelf.appending(path: WidgetShelf.Item<SeenDevices>.seenDevices.file))
        #expect(try await offered().isEmpty)
        #expect(try await named(["BB"]) == [Self.unavailable()])

        send.yield(.swept([Self.phone]))
        #expect(await eventually { (try? WidgetShelf.read(.seenDevices, from: shelf).get().names) == [.bluetooth("AA"): "iPhone", .bluetooth("BB"): "Earbuds"] })
        _ = model
    }

    // MARK: its name

    /// The list a sweep of `devices` makes.
    static func list(_ devices: [SourceDevice]) -> DeviceList {
        var list = DeviceList(sources: [.bluetooth])
        list.apply(.swept(devices), from: .bluetooth)
        return list
    }

    /// The names after the app knows `known` and sweeps `devices`.
    func names(knowing known: [String: String], after devices: [SourceDevice]) -> [String: String] {
        var seen = SeenDevices(devices: Dictionary(uniqueKeysWithValues: known.map { (DeviceID.bluetooth($0.key), SeenDevice(name: $0.value, lastConnected: Self.start)) }))
        seen.see(Self.list(devices), at: Self.start)
        return Dictionary(uniqueKeysWithValues: seen.names.map { ($0.key.key, $0.value) })
    }

    /// orange-devices-bue.suy: a connected device swept with a blank name, so its name read as its address.
    @Test func aReadWithNoNameKeepsTheNameTheAppKnows() {
        #expect(names(knowing: ["BB": "Earbuds"], after: [Self.device("BB", "BB")]) == ["BB": "Earbuds"])
    }

    @Test func aRenameReplacesTheName() {
        #expect(names(knowing: ["BB": "Earbuds"], after: [Self.device("BB", "Sam's Earbuds")]) == ["BB": "Sam's Earbuds"])
    }

    @Test func aDeviceNeverNamedGoesByItsAddress() {
        #expect(names(knowing: [:], after: [Self.device("BB", "BB")]) == ["BB": "BB"])
    }

    /// A sweep a minute that adds nothing leaves the preferences file alone.
    @Test func anUpdateThatChangesNothingWritesNothing() throws {
        let seen = try SeenDevicesModel(defaults: defaults)
        try seen.update { $0.devices = [.bluetooth("BB"): SeenDevice(name: "Earbuds")] }
        defaults.removeObject(forKey: SeenDevices.storageKey)
        try seen.update { $0.devices = [.bluetooth("BB"): SeenDevice(name: "Earbuds")] }
        #expect(defaults.data(forKey: SeenDevices.storageKey) == nil)
    }

    /// The same sweep every minute of a day, which is what a running app does, leaves it all alone.
    @Test func seeingADeviceAgainWithinTheDayWritesNothing() throws {
        let seen = try SeenDevicesModel(defaults: defaults)
        try seen.update { $0.see(Self.list([Self.buds]), at: Self.start) }
        defaults.removeObject(forKey: SeenDevices.storageKey)
        try seen.update { $0.see(Self.list([Self.buds]), at: Self.start + 60) }
        try seen.update { $0.see(Self.list([Self.buds]), at: Self.start + Self.day - 1) }
        #expect(defaults.data(forKey: SeenDevices.storageKey) == nil)

        try seen.update { $0.see(Self.list([Self.buds]), at: Self.start + Self.day) }
        #expect(seen.value.devices[.bluetooth("BB")]?.lastConnected == Self.start + Self.day)
        #expect(defaults.data(forKey: SeenDevices.storageKey) != nil)
    }

    // MARK: a device's place ends

    /// The Done when of orange-widgets-5jo.6q4.
    @Test func aDeviceNotConnectedForTheWholeWindowIsNoLongerOfferedWhileOneThatMerelyDisconnectedStillIs() async throws {
        let (model, send) = try launch()
        try await sweep([Self.buds, Self.phone, Self.mouse], on: send, seen: ["AA", "BB", "CC"])

        clock.now = Self.start + 20 * Self.day
        try await sweep([Self.phone, Self.mouse], on: send, seen: ["AA", "BB", "CC"])

        clock.now = Self.start + 31 * Self.day
        try await sweep([Self.phone], on: send, seen: ["AA", "CC"])

        #expect(try await offered() == ["iPhone", "Mouse"])
        #expect(try await named(["BB", "CC"]) == [Self.unavailable(), "Mouse"])
        _ = model
    }

    @Test func aDeviceIsLetGoOnlyOnceItsWholeWindowHasPassed() {
        var seen = SeenDevices()
        seen.see(Self.list([Self.buds]), at: Self.start)

        #expect(seen.see(Self.list([]), at: Self.start + SeenDevices.retention) == 0)
        #expect(seen.names.count == 1)
        #expect(seen.see(Self.list([]), at: Self.start + SeenDevices.retention + 1) == 1)
        #expect(seen.names.isEmpty)
    }

    /// A clock set back must not leave a device dated beyond the window's reach.
    @Test func aDateInTheFutureIsRenewedByTheNextSighting() {
        var seen = SeenDevices()
        seen.see(Self.list([Self.buds]), at: Self.start)
        seen.see(Self.list([Self.buds]), at: Self.start - 2 * Self.day)
        #expect(seen.devices[.bluetooth("BB")]?.lastConnected == Self.start - 2 * Self.day)
    }

    /// What the release before wrote has no dates; it gets a whole window from the launch that reads it, then ages out as any.
    @Test func devicesFromBeforeDatesGetAFullWindowFromTheFirstLaunch() throws {
        defaults.set(Data(#"{"names":{"AA":"iPhone"}}"#.utf8), forKey: SeenDevices.storageKey)
        #expect(try SeenDevicesModel(defaults: defaults).value.devices[.bluetooth("AA")]?.lastConnected == nil)

        let model = try SeenDevicesModel.load(defaults: defaults, adoptingAt: Self.start)
        #expect(model.value.devices[.bluetooth("AA")] == SeenDevice(name: "iPhone", lastConnected: Self.start))

        var seen = model.value
        #expect(seen.see(Self.list([]), at: Self.start + 29 * Self.day) == 0)
        #expect(seen.see(Self.list([]), at: Self.start + 31 * Self.day) == 1)
    }

    @Test func theFileKeepsEachDevicesDateAcrossARelaunch() throws {
        let model = try SeenDevicesModel(defaults: defaults)
        try model.update { $0.see(Self.list([Self.buds]), at: Self.start) }

        #expect(try SeenDevicesModel(defaults: defaults).value == model.value)
    }

    // MARK: what is offered

    /// Device Battery draws such a device, so a widget can be set to one.
    @Test func aDeviceWithNoLevelIsNamedAndOffered() async throws {
        let (model, send) = try launch()
        try await sweep([Self.device("EE", "Keyboard", levels: .none)], on: send, seen: ["EE"])
        #expect(try await named(["EE"]) == ["Keyboard"])
        #expect(try await offered() == ["Keyboard"])
        _ = model
    }

    @Test func theOffersRunByNameThenAddress() async throws {
        let (model, send) = try launch()
        try await sweep([Self.device("B", "Same"), Self.device("A", "Same"), Self.device("C", "Another")], on: send, seen: ["A", "B", "C"])
        #expect(try await query.suggestedEntities().map(\.id) == ["bluetooth:C", "bluetooth:A", "bluetooth:B"])
        _ = model
    }

    @Test func theOffersRunInAPersonsAlphabeticalOrder() async throws {
        let (model, send) = try launch()
        try await sweep([Self.device("A", "Zed Mouse"), Self.device("B", "iPhone"), Self.device("C", "AirPods")], on: send, seen: ["A", "B", "C"])
        #expect(try await offered() == ["AirPods", "iPhone", "Zed Mouse"])
        _ = model
    }

    @Test func aMacThatHasSeenNothingOffersNothing() async throws {
        let (model, send) = try launch()
        try await sweep([], on: send, seen: [])
        #expect(try await offered().isEmpty)
        #expect(try await named(["ZZ"]) == [Self.unavailable()])
        _ = model
    }

    // MARK: the log

    @Test func theLogsCarryHowManyAndNeverANameOrAnAddress() {
        let line = String(describing: SeenDevices(devices: [.bluetooth("AA-BB"): SeenDevice(name: "Sam's Earbuds", lastConnected: Self.start)]))
        #expect(line == "1 seen")
    }
}
