import Foundation
import Testing
@testable import OrangeDrink

// [LAW:verifiable-goals] The Devices screen's behaviour from simulated devices and a throwaway
// settings suite: no Bluetooth in the room.
@MainActor struct DevicesScreenTests {
    private func device(_ address: String, _ percent: Int) -> Device {
        Device(id: DeviceID(address: address), name: "Device \(address)", kind: .accessory,
               levels: .single(BatteryLevel(percent: percent, approximate: false)))
    }
    /// 95, 37, 54, and 49 percent, in that arrival order.
    private var list: DeviceList {
        var list = DeviceList()
        list.apply(.swept([device("a", 95), device("b", 37), device("c", 54), device("d", 49)]))
        return list
    }
    private func model() throws -> DeviceSettingsModel {
        try DeviceSettingsModel(defaults: UserDefaults(suiteName: "DevicesScreenTests.\(UUID().uuidString)")!)
    }

    @Test func detectedDevicesRunLowestFirst() {
        #expect(DetectedDevices(list, settings: DeviceSettings()).entries.map(\.row.percent) == ["37%", "49%", "54%", "95%"])
    }

    @Test func hidingADeviceRemovesItFromThePanelButNotFromDetectedDevices() throws {
        let settings = try model()
        try settings.update { $0.toggleHidden(DeviceID(address: "c")) }
        #expect(ConnectedDevices(list, settings: settings.settings).rows.map(\.percent) == ["37%", "49%", "95%"])
        let detected = DetectedDevices(list, settings: settings.settings).entries
        #expect(detected.map(\.row.percent) == ["37%", "49%", "54%", "95%"])
        #expect(detected.map(\.isHidden) == [false, false, true, false])
    }

    @Test func showingAHiddenDeviceAgainRestoresItsPanelRow() throws {
        let settings = try model()
        try settings.update { $0.toggleHidden(DeviceID(address: "c")) }
        try settings.update { $0.toggleHidden(DeviceID(address: "c")) }
        #expect(ConnectedDevices(list, settings: settings.settings).rows.map(\.percent) == ["37%", "49%", "54%", "95%"])
    }

    @Test func theSwitchRemovesAndRestoresThePanelSection() throws {
        let settings = try model()
        #expect(ConnectedDevices(list, settings: settings.settings).isShown)
        try settings.update { $0.showConnectedDevices = false }
        #expect(!ConnectedDevices(list, settings: settings.settings).isShown)
        try settings.update { $0.showConnectedDevices = true }
        #expect(ConnectedDevices(list, settings: settings.settings).isShown)
    }

    /// A suite no other test or run shares, removed when the test ends however it ends.
    private func scratchDefaults() -> (UserDefaults, cleanup: () -> Void) {
        let name = "DevicesScreenTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    @Test func settingsSurviveARelaunch() throws {
        let (defaults, cleanup) = scratchDefaults()
        defer { cleanup() }
        let first = try DeviceSettingsModel(defaults: defaults)
        try first.update { $0.showConnectedDevices = false; $0.toggleHidden(DeviceID(address: "c")) }
        let second = try DeviceSettingsModel(defaults: defaults)
        #expect(second.settings == first.settings)
        #expect(second.settings.hidden == [DeviceID(address: "c")])
    }

    @Test func storedSettingsThatDoNotDecodeFailTheLoad() {
        let (defaults, cleanup) = scratchDefaults()
        defer { cleanup() }
        defaults.set(Data("not json".utf8), forKey: DeviceSettingsModel.storageKey)
        #expect(throws: (any Error).self) { try DeviceSettingsModel(defaults: defaults) }
    }

    @Test func theMenuBarSettingsLinkOpensTheMenuBarScreen() throws {
        let link = try #require(DevicesHelpLine.all.compactMap(\.link).first)
        #expect(link.title == "Menu Bar settings")
        #expect(DevicesHelpLine.screen(for: DevicesHelpLine.url(for: link.screen)) == .menuBar)
        #expect(DevicesHelpLine.screen(for: URL(string: "https://example.com/menuBar")!) == nil)
    }

    @Test func theHelpListHasTheSixLinesOfTheDesignDoc() {
        #expect(DevicesHelpLine.all.count == 6)
    }

    @Test func settingsStoredBeforeAFieldExistedStillLoad() throws {
        let (defaults, cleanup) = scratchDefaults()
        defer { cleanup() }
        defaults.set(Data(#"{"showConnectedDevices":false}"#.utf8), forKey: DeviceSettingsModel.storageKey)
        let loaded = try DeviceSettingsModel(defaults: defaults).settings
        #expect(!loaded.showConnectedDevices)
        #expect(loaded.hidden.isEmpty)
    }

    @Test func aHiddenDeviceThatIsNotConnectedChangesNothing() throws {
        let settings = try model()
        try settings.update { $0.toggleHidden(DeviceID(address: "gone")) }
        #expect(ConnectedDevices(list, settings: settings.settings).rows.count == 4)
        #expect(ConnectedDevices(list, settings: settings.settings).hiddenCount == 0)
    }

    @Test func hidingEveryDeviceIsCountedSoTheCardCanSaySo() throws {
        let settings = try model()
        try settings.update { for id in ["a", "b", "c", "d"] { $0.toggleHidden(DeviceID(address: id)) } }
        let card = ConnectedDevices(list, settings: settings.settings)
        #expect(card.rows.isEmpty)
        #expect(card.hiddenCount == 4)
    }
}
