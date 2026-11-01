import Foundation
import SwiftUI
import Testing
import ViewInspector
import WidgetKit
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is which devices a placed All Batteries widget lists for what Edit Widget holds and
// what the menu bar has pinned, and what it says when that is none. Simulated devices, a shelf in a directory of the test's own.
@MainActor @Suite(.timeLimit(.minutes(1))) final class WidgetDeviceSelectionTests {
    let shelf = FileManager.default.temporaryDirectory.appending(path: "selection-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: shelf)
    }

    static let addresses = ["A", "B", "C", "D", "E"]
    /// A to E at 30, 40, 50, 60 and 70 percent, so the panel's ranking is A to E.
    static let five = addresses.enumerated().map { AllBatteriesWidgetTests.device($1, 30 + 10 * $0) }

    /// What Edit Widget holds, through an intent, the one thing that makes settings. The Mac is left out and names are on
    /// unless a test says otherwise, so a list reads as the devices it holds.
    static func settings(_ devices: WidgetDeviceChoice, chosen: [String]? = nil, includeMac: Bool = false) -> AllBatteriesSettings {
        AllBatteriesWidgetTests.settings {
            $0.devices = devices
            $0.chosen = chosen?.map { DeviceEntity(id: $0, name: "Device \($0)") }
            $0.includeMac = includeMac
            $0.showNames = true
        }
    }

    static func listed(_ settings: AllBatteriesSettings, pinned: WidgetPins = ["B", "D"], mac: MacBattery = AllBatteriesWidgetTests.onBattery) -> AllBatteries {
        AllBatteries(mac: mac, devices: .connected(five, pinned: pinned), settings: settings)
    }

    static func names(_ all: AllBatteries) -> [String?]? {
        guard case .listed(let batteries) = all else { return nil }
        return batteries.map(\.name?.english)
    }

    // MARK: which devices

    @Test func sameAsMenuBarShowsExactlyThePinnedDevices() {
        #expect(Self.names(Self.listed(Self.settings(.sameAsMenuBar))) == ["Device B", "Device D"])
    }

    @Test func sameAsMenuBarKeepsTheBarsOrderOverThePanelsRanking() {
        #expect(Self.names(Self.listed(Self.settings(.sameAsMenuBar), pinned: ["D", "B"])) == ["Device D", "Device B"])
    }

    @Test func customShowsTheChosenDevicesInTheOrderTheyWereChosen() {
        #expect(Self.names(Self.listed(Self.settings(.custom, chosen: ["C", "A"]))) == ["Device C", "Device A"])
    }

    /// A battery drawn twice would spend a place on nothing, and nothing says Edit Widget refuses a repeat.
    @Test func customDrawsADeviceChosenTwiceOnceInItsFirstPlace() {
        #expect(Self.names(Self.listed(Self.settings(.custom, chosen: ["C", "A", "C"]))) == ["Device C", "Device A"])
    }

    @Test func automaticAtSmallFillsAllFourPlaces() throws {
        let withoutMac = AllBatteriesEntry(date: .now, mac: .success(.running(.noBattery)), devices: .success(.running(.connected(Self.five, pinned: ["B", "D"]))), settings: Self.settings(.automatic))
        #expect(try AllBatteriesWidgetTests.texts(withoutMac).filter { $0.hasSuffix("%") } == ["30%", "40%", "50%", "60%"])
        let withMac = AllBatteriesEntry(date: .now, mac: .success(.running(.level(percent: 79, charging: false))), devices: .success(.running(.connected(Self.five, pinned: []))), settings: Self.settings(.automatic, includeMac: true))
        #expect(try AllBatteriesWidgetTests.texts(withMac).filter { $0.hasSuffix("%") } == ["79%", "30%", "40%", "50%"])
    }

    @Test func aDeviceOffTheListIsLeftOutAndTheRestKeepTheirOrder() {
        #expect(Self.names(Self.listed(Self.settings(.custom, chosen: ["C", "gone", "A"]))) == ["Device C", "Device A"])
        #expect(Self.names(Self.listed(Self.settings(.sameAsMenuBar), pinned: ["gone", "D"])) == ["Device D"])
    }

    @Test(arguments: [WidgetDeviceChoice.custom, .sameAsMenuBar]) func theMacStaysAheadOfWhateverIsSelected(choice: WidgetDeviceChoice) {
        let settings = Self.settings(choice, chosen: ["B"], includeMac: true)
        #expect(Self.names(Self.listed(settings, pinned: ["B"])) == [MacBattery.name.english, "Device B"])
    }

    // MARK: when that is none

    /// `ranked` holds only what reports a battery, so these words have to hold beside a device that is connected and has no level.
    @Test func noDeviceListedSaysWhy() {
        let keyboard = WidgetDevice(address: "silent", name: "Keyboard", kind: .accessory, level: nil)
        let silent = WidgetDevices.connected(WidgetDeviceList(ranked: [], pinned: ["silent"], unlevelled: [keyboard]))
        #expect(silent.listed(by: .sameAsMenuBar) == .failure(.noneReporting))
        #expect(silent.listed(by: .custom(["silent"])) == .failure(.noneReporting))
        #expect(silent.listed(by: .custom([])) == .failure(.noneChosen))
        #expect(WidgetDevices.connected(Self.five, pinned: []).listed(by: .sameAsMenuBar) == .failure(.nonePinned))
        #expect(WidgetDevices.connected(Self.five, pinned: []).listed(by: .custom(["gone"])) == .failure(.noneReporting))
        #expect(WidgetDevices.unread(.denied).listed(by: .sameAsMenuBar) == .failure(.unread(.denied)))
        #expect(WidgetDevices.unread(.denied).listed(by: .automatic) == .failure(.unread(.denied)))
    }

    @Test func automaticWithNothingToListIsAnEmptyListNotAReason() {
        #expect(WidgetDevices.connected([], pinned: []).listed(by: .automatic) == .success([]))
    }

    @Test func aMacKeepsItsPlaceBesideASelectionThatListsNothing() {
        let settings = Self.settings(.custom, includeMac: true)
        guard case .unlisted(let mac?, .noneChosen) = Self.listed(settings) else {
            Issue.record("a Mac and no reason beside it")
            return
        }
        #expect(mac.name == MacBattery.name)
    }

    // MARK: the settings and the log

    @Test func aWidgetWithNoSavedChoiceIsAutomaticAndEachChoiceKeepsItsName() {
        #expect(AllBatteriesSettings(AllBatteriesIntent()).devices == .automatic)
        #expect(WidgetDeviceChoice.allCases.map(\.rawValue) == ["automatic", "custom", "sameAsMenuBar"])
    }

    @Test func customWithNothingChosenIsAnEmptyChoice() {
        #expect(Self.settings(.custom).devices == .custom([]))
    }

    @Test func aDeviceChosenThenLeftBehindOnAnotherChoiceIsNotRead() {
        #expect(Self.settings(.automatic, chosen: ["C"]).devices == .automatic)
        #expect(Self.settings(.sameAsMenuBar, chosen: ["C"]).devices == .sameAsMenuBar)
    }

    @Test func theLogsCarryHowManyAndNeverAnAddress() {
        #expect(String(describing: WidgetDeviceSelection.custom(["AA-BB", "CC-DD"])) == "custom 2")
        let line = String(describing: Shelved.running(WidgetDevices.connected([], pinned: ["AA-BB"])))
        #expect(!line.contains("AA-BB"))
        #expect(line.contains("1 pinned"))
    }

    @Test func aPinnedDeviceReachesTheShelfWhetherOrNotItIsConnected() {
        var list = DeviceList()
        list.apply(.swept([]))
        let pinned = PinnedOrder([DeviceID(address: "gone"), DeviceID(address: "here")])
        #expect(WidgetDevices(list, pinned: pinned) == .connected([], pinned: ["gone", "here"]))
    }

    // MARK: through the app

    /// What a placed widget set to Same as menu bar draws, read from the shelf the way the widget reads it.
    func sameAsMenuBarSays() throws -> [String] {
        let intent = AllBatteriesIntent()
        intent.devices = .sameAsMenuBar
        intent.includeMac = false
        let entry = AllBatteriesEntry(date: .now, directory: .success(shelf), log: ShelfLog.log, configuration: intent)
        return try AllBatteriesWidgetTests.texts(entry)
    }

    static func pinButton(_ label: String, of screen: DevicesScreen) throws -> InspectableView<ViewType.Button> {
        try screen.inspect().find(ViewType.Button.self, where: { try $0.accessibilityLabel().string() == label })
    }

    @Test func pinningFromTheDevicesScreenChangesASameAsMenuBarWidgetAndAsksItToRedraw() async throws {
        ShelfPublisher<MacBattery>(item: .macBattery, directory: shelf) { _ in }.publish(.noBattery)
        let settings = try DeviceSettingsModel(defaults: UserDefaults(suiteName: "WidgetDeviceSelectionTests.\(UUID())")!)
        try settings.update {
            $0.togglePinned(DeviceID(address: "B"))
            $0.togglePinned(DeviceID(address: "D"))
        }
        var asked: [WidgetKind] = []
        let publisher = ShelfPublisher<WidgetDevices>(item: .devices, directory: shelf) { asked.append($0) }
        let (events, send) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let pinnedItems = PinnedItemsController(makeItem: { _ in PinnedItemsTests.RecordingItem() })
        let model = DevicesModel(events: events, shelf: publisher, settings: settings, pinnedItems: pinnedItems)
        send.yield(.swept(Self.addresses.enumerated().map { index, address in
            Device(id: DeviceID(address: address), name: "Device \(address)", kind: .accessory, levels: .single(BatteryLevel(percent: 30 + 10 * index, approximate: false)))
        }))
        #expect(try await eventually { try sameAsMenuBarSays() == ["40%", "60%"] })

        let screen = DevicesScreen(devices: model, settings: settings, select: { _ in })
        asked = []
        try Self.pinButton("Pin Device C to the menu bar", of: screen).tap()
        #expect(try await eventually { try sameAsMenuBarSays() == ["40%", "60%", "50%"] })
        #expect(asked.contains(.allBatteries))

        asked = []
        try Self.pinButton("Unpin Device C from the menu bar", of: screen).tap()
        #expect(try await eventually { try sameAsMenuBarSays() == ["40%", "60%"] })
        #expect(asked.contains(.allBatteries))
    }
}
