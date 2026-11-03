import Foundation
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what survives the move from a Bluetooth address to an identity that names its
// source: what the release before it stored still loads as the same devices, and devices of different sources never merge.
@MainActor @Suite struct DeviceIdentityTests {
    static func device(_ id: DeviceID, _ name: String) -> Device {
        Device(id: id, name: name, kind: .accessory, levels: .single(BatteryLevel(percent: 50, approximate: false)))
    }

    // MARK: what the release before wrote still loads

    /// The bytes that release stored under `devices.settings`: a device was `{"address": …}`, the sets were arrays.
    static let releaseBeforeSettings = #"{"showConnectedDevices":false,"hidden":[{"address":"AA-01"}],"alerting":[{"address":"BB-02"},{"address":"AA-01"}],"pinned":[{"address":"CC-03"},{"address":"AA-01"}]}"#

    @Test func settingsTheReleaseBeforeWroteLoadWithTheSameDevices() throws {
        let defaults = scratchDefaults()
        defaults.set(Data(Self.releaseBeforeSettings.utf8), forKey: DeviceSettings.storageKey)

        let settings = try DeviceSettingsModel(defaults: defaults).value

        #expect(settings.showConnectedDevices == false)
        #expect(settings.hidden == [.bluetooth("AA-01")])
        #expect(settings.alerting == [.bluetooth("BB-02"), .bluetooth("AA-01")])
        #expect(settings.pinned.ids == [.bluetooth("CC-03"), .bluetooth("AA-01")])
    }

    /// The first edit writes identities in their one form, and a relaunch reads that back as the same devices.
    @Test func anEditWritesIdentitiesNamingTheirSourceAndTheyLoadAgain() throws {
        let defaults = scratchDefaults()
        defaults.set(Data(Self.releaseBeforeSettings.utf8), forKey: DeviceSettings.storageKey)
        let model = try DeviceSettingsModel(defaults: defaults)

        try model.update { $0.toggleHidden(.bluetooth("DD-04")) }

        let stored = String(decoding: try #require(defaults.data(forKey: DeviceSettings.storageKey)), as: UTF8.self)
        #expect(stored.contains("bluetooth:AA-01") && !stored.contains("address"))
        #expect(try DeviceSettingsModel(defaults: defaults).value == model.value)
    }

    @Test func seenDevicesTheReleaseBeforeWroteLoadWithTheSameNames() throws {
        let defaults = scratchDefaults()
        defaults.set(Data(#"{"names":{"AA-01":"iPhone","BB-02":"Earbuds"}}"#.utf8), forKey: SeenDevices.storageKey)

        #expect(try SeenDevicesModel(defaults: defaults).value.names == [.bluetooth("AA-01"): "iPhone", .bluetooth("BB-02"): "Earbuds"])
    }

    @Test func aSeenFileWithAnIdentityThisReleaseCannotReadFailsLoudly() {
        let defaults = scratchDefaults()
        defaults.set(Data(#"{"names":{"watch:AA":"Watch"}}"#.utf8), forKey: SeenDevices.storageKey)

        #expect(throws: DecodingError.self) { try SeenDevicesModel(defaults: defaults) }
    }

    /// A widget placed before sources holds a bare address, which the app cannot rewrite.
    @Test func aWidgetChoiceMadeBeforeSourcesNamesTheSameDeviceAsToday() async throws {
        let shelf = FileManager.default.temporaryDirectory.appending(path: "identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: shelf) }
        try WidgetShelf.write(SeenDevices(names: [.bluetooth("AA-01"): "iPhone"]), as: .seenDevices, to: shelf)
        let query = DeviceQuery(directory: .success(shelf))

        let named = try await query.entities(for: ["AA-01", "bluetooth:AA-01"]).map(\.name)

        #expect(named == ["iPhone", "iPhone"])
        #expect(try await query.entities(for: ["AA-01", "watch:AA"]).map(\.id) == ["bluetooth:AA-01", "watch:AA"])
        #expect(try await query.suggestedEntities().map(\.id) == ["bluetooth:AA-01"])
        #expect(DeviceEntity.identities(of: [DeviceEntity(id: "AA-01", name: "x"), DeviceEntity(id: "bluetooth:AA-01", name: "x")]) == [.bluetooth("AA-01")])
    }

    // MARK: sources keep devices apart

    @Test func twoDevicesWithEqualNamesFromDifferentSourcesStayDistinct() throws {
        let bluetooth = DeviceID.bluetooth("AA-01")
        let cabled = DeviceID(source: .iPhone, key: "AA-01")
        var list = DeviceList(sources: DeviceSource.allCases)
        list.apply(.swept([Self.device(bluetooth, "Brandon's iPhone")]), from: .bluetooth)
        list.apply(.swept([Self.device(cabled, "Brandon's iPhone")]), from: .iPhone)

        #expect(list.devices.map(\.id).sorted() == [bluetooth, cabled])
        #expect(DeviceID(source: .iPhone, key: "A") < DeviceID(source: .iPhone, key: "B"))
        #expect(Set([bluetooth, cabled]).count == 2)

        var settings = DeviceSettings()
        settings.togglePinned(bluetooth)
        settings.toggleAlerting(cabled)
        #expect(settings.pinned.ids == [bluetooth] && settings.alerting == [cabled])

        var seen = SeenDevices()
        seen.see(list)
        #expect(seen.names == [bluetooth: "Brandon's iPhone", cabled: "Brandon's iPhone"])
    }

    @Test func aDeviceGoneIsGoneOnlyFromItsOwnSource() {
        var list = DeviceList(sources: DeviceSource.allCases)
        let bluetooth = DeviceID.bluetooth("AA-01")
        let cabled = DeviceID(source: .iPhone, key: "AA-01")
        list.apply(.swept([Self.device(bluetooth, "Phone")]), from: .bluetooth)
        list.apply(.swept([Self.device(cabled, "Phone")]), from: .iPhone)

        list.apply(.gone(bluetooth), from: .bluetooth)

        #expect(list.devices.map(\.id) == [cabled])
    }

    // MARK: the one form

    @Test(arguments: [
        ("AA-01", DeviceID.bluetooth("AA-01")),
        ("bluetooth:AA-01", .bluetooth("AA-01")),
        ("iphone:00008110-001E", DeviceID(source: .iPhone, key: "00008110-001E")),
        ("iphone:a:b", DeviceID(source: .iPhone, key: "a:b")),
    ])
    func anIdentityReadsFromItsFormAndFromTheBareAddressOfTheReleaseBefore(wire: String, expected: DeviceID) throws {
        #expect(DeviceID(wire: wire) == expected)
        #expect(DeviceID(wire: expected.wire) == expected)
        let encoded = try JSONEncoder().encode(expected)
        #expect(try JSONDecoder().decode(DeviceID.self, from: encoded) == expected)
    }

    @Test(arguments: ["", ":AA", "watch:AA", "iphone:", "bluetooth:", "Bluetooth:AA"])
    func anIdentityOfASourceThisReleaseDoesNotKnowOrWithNoKeyIsNotGuessed(wire: String) {
        #expect(DeviceID(wire: wire) == nil)
        #expect(DeviceEntity(id: wire, name: "x").identity == nil)
    }

    @Test func choicesThisReleaseCannotReadAreLeftOut() {
        let entities = ["iphone:XY", "watch:AA", "AA-01"].map { DeviceEntity(id: $0, name: $0) }
        #expect(DeviceEntity.identities(of: entities) == [DeviceID(source: .iPhone, key: "XY"), .bluetooth("AA-01")])
    }
}
