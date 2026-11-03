import Foundation
import SwiftUI
import Testing
import ViewInspector
import WidgetKit
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is which devices a placed All Batteries widget lists for what Edit Widget holds and
// what the menu bar has pinned, and what it says when that is none. Simulated devices, a shelf in a directory of the test's own.
@MainActor @Suite final class WidgetDeviceSelectionTests {
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

    static func listed(_ settings: AllBatteriesSettings, pinned: WidgetPins = [.bluetooth("B"), .bluetooth("D")], mac: MacBattery = AllBatteriesWidgetTests.onBattery) -> AllBatteries {
        AllBatteries(mac: mac, devices: .connected(five, pinned: pinned), settings: settings)
    }

    static func names(_ all: AllBatteries) -> [String?]? {
        guard case .listed(let batteries, _) = all else { return nil }
        return batteries.map(\.name?.english)
    }

    // MARK: which devices

    @Test func sameAsMenuBarShowsExactlyThePinnedDevices() {
        #expect(Self.names(Self.listed(Self.settings(.sameAsMenuBar))) == ["Device B", "Device D"])
    }

    @Test func sameAsMenuBarKeepsTheBarsOrderOverThePanelsRanking() {
        #expect(Self.names(Self.listed(Self.settings(.sameAsMenuBar), pinned: [.bluetooth("D"), .bluetooth("B")])) == ["Device D", "Device B"])
    }

    @Test func customShowsTheChosenDevicesInTheOrderTheyWereChosen() {
        #expect(Self.names(Self.listed(Self.settings(.custom, chosen: ["C", "A"]))) == ["Device C", "Device A"])
    }

    /// A battery drawn twice would spend a place on nothing, and nothing says Edit Widget refuses a repeat.
    @Test func customDrawsADeviceChosenTwiceOnceInItsFirstPlace() {
        #expect(Self.names(Self.listed(Self.settings(.custom, chosen: ["C", "A", "C"]))) == ["Device C", "Device A"])
    }

    @Test func automaticAtSmallFillsAllFourPlaces() throws {
        let withoutMac = AllBatteriesEntry(date: .now, mac: .success(.running(.noBattery)), devices: .success(.running(.connected(Self.five, pinned: [.bluetooth("B"), .bluetooth("D")]))), settings: Self.settings(.automatic))
        #expect(try AllBatteriesWidgetTests.texts(withoutMac).filter { $0.hasSuffix("%") } == ["30%", "40%", "50%", "60%"])
        let withMac = AllBatteriesEntry(date: .now, mac: .success(.running(.level(percent: 79, charging: false))), devices: .success(.running(.connected(Self.five, pinned: []))), settings: Self.settings(.automatic, includeMac: true))
        #expect(try AllBatteriesWidgetTests.texts(withMac).filter { $0.hasSuffix("%") } == ["79%", "30%", "40%", "50%"])
    }

    @Test func aDeviceOffTheListIsLeftOutAndTheRestKeepTheirOrder() {
        #expect(Self.names(Self.listed(Self.settings(.custom, chosen: ["C", "gone", "A"]))) == ["Device C", "Device A"])
        #expect(Self.names(Self.listed(Self.settings(.sameAsMenuBar), pinned: [.bluetooth("gone"), .bluetooth("D")])) == ["Device D"])
    }

    @Test(arguments: [WidgetDeviceChoice.custom, .sameAsMenuBar]) func theMacStaysAheadOfWhateverIsSelected(choice: WidgetDeviceChoice) {
        let settings = Self.settings(choice, chosen: ["B"], includeMac: true)
        #expect(Self.names(Self.listed(settings, pinned: [.bluetooth("B")])) == [MacBattery.name.english, "Device B"])
    }

    // MARK: when that is none

    /// An unlevelled device is not ranked, so these words have to hold beside one.
    @Test func noDeviceListedSaysWhy() {
        let keyboard = WidgetDevice(id: .bluetooth("silent"), name: "Keyboard", kind: .accessory, level: nil)
        let silent = WidgetDeviceList(ranked: [], pinned: [.bluetooth("silent")], unlevelled: [keyboard], unreadSources: [])
        #expect(silent.listed(by: .sameAsMenuBar) == .failure(.noneReporting))
        #expect(silent.listed(by: .custom([.bluetooth("silent")])) == .failure(.noneReporting))
        #expect(silent.listed(by: .custom([])) == .failure(.noneChosen))
        #expect(WidgetDeviceList.connected(Self.five, pinned: []).listed(by: .sameAsMenuBar) == .failure(.nonePinned))
        #expect(WidgetDeviceList.connected(Self.five, pinned: []).listed(by: .custom([.bluetooth("gone")])) == .failure(.noneReporting))
    }

    /// One precedence: a choice not yet made is a fact about configuration and wins over an unread source; an empty pick with a
    /// source unread says that source, since the pick may be empty for want of it.
    @Test func anUnreadSourceExplainsAnEmptyPickButNeverAChoiceNotYetMade() {
        let denied = WidgetDeviceList.unread(.denied)
        #expect(denied.listed(by: .sameAsMenuBar) == .failure(.nonePinned))
        #expect(denied.listed(by: .custom([])) == .failure(.noneChosen))
        #expect(denied.listed(by: .automatic) == .failure(.unread(.bluetooth(.denied))))
        #expect(denied.listed(by: .custom([.bluetooth("AA")])) == .failure(.unread(.bluetooth(.denied))))
        let pinned = WidgetDeviceList(ranked: [], pinned: [.bluetooth("AA")], unlevelled: [], unreadSources: [.iPhone(.ended)])
        #expect(pinned.listed(by: .sameAsMenuBar) == .failure(.unread(.iPhone(.ended))))
    }

    @Test func devicesAreListedBesideTheSourcesUnreadWithTheirOwnReasons() {
        let unread: [UnreadSource] = [.bluetooth(.denied), .iPhone(.ended)]
        let list = WidgetDeviceList(ranked: Self.five, pinned: [Self.five[1].id], unlevelled: [], unreadSources: unread)
        #expect(list.listed(by: .automatic) == .success(WidgetListing(devices: Self.five, unread: unread)))
        #expect(list.listed(by: .sameAsMenuBar) == .success(WidgetListing(devices: [Self.five[1]], unread: unread)))
        #expect(list.listed(by: .custom([Self.five[2].id])) == .success(WidgetListing(devices: [Self.five[2]], unread: unread)))
    }

    /// One line for a one-line surface: the first source not merely waiting, else the first.
    @Test func theOneLineASmallSurfaceSaysIsTheFirstSourceNotMerelyWaiting() {
        #expect([UnreadSource.bluetooth(.waiting), .iPhone(.ended)].headline == .iPhone(.ended))
        #expect([UnreadSource.bluetooth(.denied), .iPhone(.ended)].headline == .bluetooth(.denied))
        #expect([UnreadSource.bluetooth(.waiting), .iPhone(.waiting)].headline == .bluetooth(.waiting))
        #expect([UnreadSource]().headline == nil)
    }

    @Test func automaticWithNothingToListIsAnEmptyListNotAReason() {
        #expect(WidgetDeviceList.connected([], pinned: []).listed(by: .automatic) == .success(WidgetListing(devices: [], unread: [])))
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
        #expect(String(describing: WidgetDeviceSelection.custom([.bluetooth("AA-BB"), .bluetooth("CC-DD")])) == "custom 2")
        let line = String(describing: Shelved.running(WidgetDeviceList.connected([], pinned: [.bluetooth("AA-BB")])))
        #expect(!line.contains("AA-BB"))
        #expect(line.contains("1 pinned"))
    }

    @Test func aPinnedDeviceReachesTheShelfWhetherOrNotItIsConnected() {
        var list = DeviceList(sources: [.bluetooth])
        list.apply(.swept([]), from: .bluetooth)
        let pinned = PinnedOrder([DeviceID.bluetooth("gone"), DeviceID.bluetooth("here")])
        #expect(WidgetDeviceList(list, pinned: pinned) == .connected([], pinned: [.bluetooth("gone"), .bluetooth("here")]))
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
        ShelfPublisher<Shelved<MacBattery>>(item: .macBattery, directory: shelf) { _ in }.publish(.running(.noBattery))
        let settings = try DeviceSettingsModel(defaults: scratchDefaults())
        try settings.update {
            $0.togglePinned(DeviceID.bluetooth("B"))
            $0.togglePinned(DeviceID.bluetooth("D"))
        }
        var asked: [WidgetKind] = []
        let publisher = ShelfPublisher<Shelved<WidgetDeviceList>>(item: .devices, directory: shelf) { asked.append($0) }
        let (events, send) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let pinnedItems = PinnedItemsController(makeItem: { _ in PinnedItemsTests.RecordingItem() })
        let model = try DevicesModel(sources: [.bluetooth: events], shelf: publisher, settings: settings, pinnedItems: pinnedItems)
        send.yield(.swept(Self.addresses.enumerated().map { index, address in
            SourceDevice(id: DeviceID.bluetooth(address), name: "Device \(address)", kind: .accessory, levels: .single(BatteryLevel(percent: 30 + 10 * index, approximate: false)))
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
