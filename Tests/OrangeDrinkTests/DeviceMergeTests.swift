import Foundation
import Observation
import Testing
@testable import OrangeDrink

// [LAW:verifiable-goals] One physical device reached by two sources, each a stand-in: no Bluetooth and no usbmuxd in the room.
// The rule under test is orange-device-sources-rec.j48's: a device read by the iPhone source names the Bluetooth address of the
// same physical device and is presented under it, with the iPhone source's name and level.
private enum Phone {
    static let address = DeviceID.bluetooth("6c-3a-ff-d9-74-42")
    static let udid = DeviceID(source: .iPhone, key: "00008110-A")
    /// The address as lockdown writes it; the claim holds it in IOBluetooth's form.
    static let claim = BluetoothAddress("6C:3A:FF:D9:74:42")!

    static func level(_ percent: Int) -> DeviceLevels { .single(BatteryLevel(percent: percent, approximate: false)) }

    /// The phone as the iPhone reader lists it: by UDID, naming the Bluetooth address it is also listed under.
    static func cabled(_ levels: DeviceLevels, name: String = "Brandon's iPhone") -> SourceDevice {
        SourceDevice(id: udid, name: name, kind: .phone, levels: levels, alsoBluetooth: claim)
    }

    /// The same phone as Bluetooth lists it.
    static func paired(_ levels: DeviceLevels, name: String = "Brandon’s iPhone") -> SourceDevice {
        SourceDevice(id: address, name: name, kind: .phone, levels: levels)
    }

    /// The phone as the list presents it once the iPhone source has listed it: under the address, which is the identity a
    /// pin, a bell or a hide of it is stored under, with the name Bluetooth gives it.
    static func shown(_ levels: DeviceLevels, name: String = "Brandon’s iPhone") -> Device {
        Device(id: address, name: name, kind: .phone, levels: levels)
    }
}

struct DeviceMergeListTests {
    private func list(bluetooth: [SourceDevice], iPhone: [SourceDevice]) -> DeviceList {
        var list = DeviceList(sources: DeviceSource.allCases)
        list.apply(.swept(bluetooth), from: .bluetooth)
        list.apply(.swept(iPhone), from: .iPhone)
        return list
    }

    @Test func theSamePhoneFromBothSourcesIsOneDeviceAtTheIPhonesLevel() {
        let merged = list(bluetooth: [Phone.paired(Phone.level(80))], iPhone: [Phone.cabled(Phone.level(62))])
        #expect(merged.devices == [Phone.shown(Phone.level(62))])
    }

    /// The level is the iPhone source's alone: a stale Bluetooth level never replaces it, so it cannot move the level an alert
    /// watches, and a read that failed is shown as it is, unknown.
    @Test(arguments: [
        (iPhone: DeviceLevels.unread, bluetooth: Phone.level(80)),
        (Phone.level(0), Phone.level(80)),
        (Phone.level(62), .unread),
        (Phone.level(62), .none),
    ])
    func theLevelIsTheIPhonesWhateverBluetoothSays(iPhone: DeviceLevels, bluetooth: DeviceLevels) {
        let merged = list(bluetooth: [Phone.paired(bluetooth)], iPhone: [Phone.cabled(iPhone)])
        #expect(merged.devices.map(\.levels) == [iPhone])
        #expect(merged.devices.map(\.id) == [Phone.address])
    }

    /// The Bluetooth name is the user's alias, the name System Settings shows, so plugging in the cable does not rename the phone;
    /// the iPhone's own name stands only where Bluetooth has none.
    @Test func theNameIsBluetoothsWhenItHasOneElseTheIPhones() {
        let aliased = list(bluetooth: [Phone.paired(Phone.level(80), name: "My Phone")], iPhone: [Phone.cabled(Phone.level(62), name: "Brandon's iPhone")])
        #expect(aliased.devices.map(\.name) == ["My Phone"])
        let unnamed = list(bluetooth: [Phone.paired(Phone.level(80), name: Phone.address.key)], iPhone: [Phone.cabled(Phone.level(62), name: "Brandon's iPhone")])
        #expect(unnamed.devices.map(\.name) == ["Brandon's iPhone"])
        let cabledOnly = list(bluetooth: [], iPhone: [Phone.cabled(Phone.level(62), name: "Brandon's iPhone")])
        #expect(cabledOnly.devices.map(\.name) == ["Brandon's iPhone"])
    }

    @Test func theKindIsTheIPhonesOwn() {
        let merged = list(bluetooth: [SourceDevice(id: Phone.address, name: "iPhone", kind: .accessory, levels: Phone.level(80))], iPhone: [Phone.cabled(Phone.level(62))])
        #expect(merged.devices.map(\.kind) == [.phone])
    }

    // [LAW:one-source-of-truth] What the user attached to the phone is stored under one identity, and whichever sources list
    // the phone, that is the identity it is presented under. The panel, the Devices screen and the alert engine read nothing else.
    @Test(arguments: [
        (bluetooth: true, iPhone: true), (true, false), (false, true),
    ])
    func theSameIdentityIsPresentedWhicheverSourcesListThePhone(bluetooth: Bool, iPhone: Bool) {
        let merged = list(bluetooth: bluetooth ? [Phone.paired(Phone.level(80))] : [], iPhone: iPhone ? [Phone.cabled(Phone.level(62))] : [])
        #expect(merged.devices.map(\.id) == [Phone.address])

        var settings = DeviceSettings()
        settings.hidden = [Phone.address]
        settings.alerting = [Phone.address]
        settings.togglePinned(Phone.address)
        let entry = DetectedDevices(merged, settings: settings).entries.first
        #expect(entry.map { [$0.isHidden, $0.isAlerting, $0.isPinned] } == [true, true, true])
        #expect(ConnectedDevices(merged, settings: settings).rows.isEmpty)
    }

    @Test func whenTheIPhoneSourceStopsListingThePhoneItsBluetoothEntryStandsAsItWas() {
        var merged = list(bluetooth: [Phone.paired(Phone.level(80))], iPhone: [Phone.cabled(Phone.level(62))])
        merged.apply(.gone(Phone.udid), from: .iPhone)
        #expect(merged.devices == [Phone.paired(Phone.level(80)).device])

        merged.apply(.reported(Phone.cabled(Phone.level(61))), from: .iPhone)
        #expect(merged.devices == [Phone.shown(Phone.level(61))])
        merged.apply(.swept([]), from: .iPhone)
        #expect(merged.devices == [Phone.paired(Phone.level(80)).device])
    }

    @Test func whenBluetoothStopsListingThePhoneTheIPhoneIsStillPresentedUnderTheAddress() {
        var merged = list(bluetooth: [Phone.paired(Phone.level(80))], iPhone: [Phone.cabled(Phone.level(62))])
        merged.apply(.gone(Phone.address), from: .bluetooth)
        #expect(merged.devices == [Phone.shown(Phone.level(62), name: "Brandon's iPhone")])
        merged.end(.bluetooth)
        #expect(merged.devices == [Phone.shown(Phone.level(62), name: "Brandon's iPhone")])
    }

    @Test func aPhoneNamingAnAddressNobodyListsIsPresentedUnderIt() {
        #expect(list(bluetooth: [], iPhone: [Phone.cabled(Phone.level(62))]).devices == [Phone.shown(Phone.level(62), name: "Brandon's iPhone")])
    }

    @Test func otherDevicesAreUntouchedByAPhonesClaim() {
        let merged = list(bluetooth: [DeviceListTests.mouse.source, Phone.paired(Phone.level(80)), DeviceListTests.pods.source], iPhone: [Phone.cabled(Phone.level(62))])
        #expect(Set(merged.devices.map(\.id)) == [DeviceListTests.mouse.id, DeviceListTests.pods.id, Phone.address])
        #expect(merged.devices.filter { $0.id != Phone.address }.sorted { $0.name < $1.name } == [DeviceListTests.pods, DeviceListTests.mouse])
    }

    /// The match is identity: a device that merely has the same name is another device, however likely it looks.
    @Test func equalNamesWithNoClaimStayTwoDevices() {
        let bare = SourceDevice(id: Phone.udid, name: "iPhone", kind: .phone, levels: Phone.level(62))
        let merged = list(bluetooth: [Phone.paired(Phone.level(80), name: "iPhone")], iPhone: [bare])
        #expect(Set(merged.devices.map(\.id)) == [Phone.udid, Phone.address])
    }

    /// Two devices of one source naming one identity name no one: the rows stay apart, beside the Bluetooth row, where a mapper
    /// bug shows, and not merged by a tie-break; the address is named for the log.
    @Test func twoDevicesNamingOneAddressAreNotMerged() {
        let other = SourceDevice(id: DeviceID(source: .iPhone, key: "00008110-B"), name: "Second", kind: .phone, levels: Phone.level(30), alsoBluetooth: Phone.claim)
        let merged = list(bluetooth: [Phone.paired(Phone.level(80))], iPhone: [Phone.cabled(Phone.level(62)), other])
        #expect(Set(merged.devices.map(\.id)) == [Phone.address, Phone.udid, other.id])
        #expect(merged.contested == [Phone.address.key])
        #expect(list(bluetooth: [Phone.paired(Phone.level(80))], iPhone: [Phone.cabled(Phone.level(62))]).contested.isEmpty)
    }

    /// A device known only by the key it was found under has no name; presented under another key it must not read as having one.
    @Test func aPhoneNamedByItsUDIDIsPresentedWithNoNameAndSeenDevicesStoresNone() {
        let unnamed = Phone.cabled(Phone.level(62), name: Phone.udid.key)
        let alone = list(bluetooth: [], iPhone: [unnamed])
        #expect(alone.devices.map(\.hasName) == [false])
        #expect(alone.devices.map(\.name) == [Phone.address.key])
        var seen = SeenDevices()
        seen.see(alone)
        #expect(seen.names == [Phone.address: Phone.address.key])

        // Bluetooth's name is a name.
        let named = list(bluetooth: [Phone.paired(Phone.level(80))], iPhone: [unnamed])
        #expect(named.devices.map(\.name) == ["Brandon’s iPhone"])
        #expect(named.devices.map(\.hasName) == [true])
    }

    @Test func aSourceWhoseOnlyDeviceIsPresentedUnderAnothersIdentityHasStillSwept() {
        var merged = DeviceList(sources: DeviceSource.allCases)
        merged.apply(.swept([Phone.cabled(Phone.level(62))]), from: .iPhone)
        merged.apply(.permission(.denied), from: .bluetooth)
        #expect(merged.unreadSources == [.bluetooth(.denied)])
        #expect(merged.unread(of: .iPhone) == nil)
    }

    @Test func theRankingListsTheMergedDeviceOnceAtItsLevel() {
        let merged = list(bluetooth: [Phone.paired(Phone.level(80))], iPhone: [Phone.cabled(Phone.level(62))])
        #expect(DeviceRanking.rows(merged).map(\.id) == [Phone.address])
        #expect(DeviceRanking.rows(merged).map(\.level?.percent) == [62])
        #expect(DeviceRanking.unlevelled(merged).isEmpty)
    }

    /// The phone is watched under the address it is presented under, and its alert state is the same device's before and after
    /// the cable is pulled: a fall through the threshold across that transition is announced, once.
    @Test func aMergedDevicesAlertStateSurvivesTheCableBeingPulled() {
        var engine = DeviceAlertEngine()
        let alert = AlertEngineTests.low(20)
        let watching: Set = [Phone.address]
        let cabled = list(bluetooth: [Phone.paired(Phone.level(25))], iPhone: [Phone.cabled(Phone.level(21))])
        #expect(engine.observe(cabled, watching: watching, alerts: [alert]).isEmpty)

        let pulled = list(bluetooth: [Phone.paired(Phone.level(19))], iPhone: [])
        #expect(engine.observe(pulled, watching: watching, alerts: [alert]).map(\.name) == ["Brandon’s iPhone"])
        #expect(engine.observe(cabled, watching: watching, alerts: [alert]).isEmpty)
    }

    /// Bluetooth's level for the phone, stale or not, never moves the level an alert watches while the iPhone source lists it:
    /// 18% beside a stale 25% is one fall through 20%, and a read that fails and recovers does not announce it again.
    @Test func aDifferingBluetoothLevelOrAFailedReadNeverReannouncesAnAlert() {
        var engine = DeviceAlertEngine()
        let alert = AlertEngineTests.low(20)
        let watching: Set = [Phone.address]
        let stale = Phone.paired(Phone.level(25))
        var announced: [DeviceFiring] = []
        for levels in [Phone.level(21), Phone.level(18), .unread, Phone.level(18), .unread, Phone.level(17)] {
            announced += engine.observe(list(bluetooth: [stale], iPhone: [Phone.cabled(levels)]), watching: watching, alerts: [alert])
        }
        #expect(announced.map(\.level.percent) == [18])
    }
}

@MainActor struct DeviceMergeModelTests {
    /// The list once `accepted` holds for it. [LAW:no-ambient-temporal-coupling] Awaited through Observation, never polled.
    private func list(of model: DevicesModel, once accepted: (DeviceList) -> Bool) async -> DeviceList {
        let (changes, change) = AsyncStream.makeStream(of: Void.self)
        var next = changes.makeAsyncIterator()
        while !accepted(model.list) {
            withObservationTracking { _ = model.list } onChange: { change.yield() }
            guard await next.next() != nil else { break }
        }
        return model.list
    }

    @Test(.timeLimit(.minutes(1))) func thePhoneReportedByBothStandInSourcesAppearsOnceWithTheLevelTheRulePicks() async {
        let (bluetooth, sendBluetooth) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let (iPhone, sendIPhone) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let model = DevicesModel(sources: [.bluetooth: bluetooth, .iPhone: iPhone])
        sendBluetooth.yield(.swept([Phone.paired(Phone.level(80)), DeviceListTests.mouse.source]))
        sendIPhone.yield(.swept([Phone.cabled(Phone.level(62))]))
        // Both sources have swept: with only Bluetooth's in, the phone is listed once for a different reason.
        let merged = await list(of: model) { $0.unread(of: .iPhone) == nil && $0.unread(of: .bluetooth) == nil }

        #expect(merged.devices.count == 2)
        #expect(ConnectedDevices(merged, settings: DeviceSettings()).rows.map(\.id) == [DeviceListTests.mouse.id, Phone.address])
        #expect(ConnectedDevices(merged, settings: DeviceSettings()).rows.map(\.level?.percent) == [37, 62])
        #expect(Set(DetectedDevices(merged, settings: DeviceSettings()).entries.map(\.id)) == [DeviceListTests.mouse.id, Phone.address])

        // Unplugged: the source drops the phone, and it is the same device at Bluetooth's level.
        sendIPhone.yield(.gone(Phone.udid))
        let unplugged = await list(of: model) { $0.devices.first { $0.id == Phone.address }?.levels == Phone.level(80) }
        #expect(Set(unplugged.devices.map(\.id)) == [DeviceListTests.mouse.id, Phone.address])
    }

    @Test(.timeLimit(.minutes(1))) func twoDevicesClaimingOneAddressAreLoggedAndNotMerged() async throws {
        let log = try await TestLog()
        let (bluetooth, sendBluetooth) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let (iPhone, sendIPhone) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let model = DevicesModel(sources: [.bluetooth: bluetooth, .iPhone: iPhone], log: log.logger)
        sendBluetooth.yield(.swept([Phone.paired(Phone.level(80))]))
        let other = SourceDevice(id: DeviceID(source: .iPhone, key: "00008110-B"), name: "Second", kind: .phone, levels: Phone.level(30), alsoBluetooth: Phone.claim)
        sendIPhone.yield(.swept([Phone.cabled(Phone.level(62)), other]))
        let list = await list(of: model) { $0.devices.count == 3 }
        #expect(list.contested == [Phone.address.key])
        #expect(try await log.logged("more than one device claims Bluetooth address"))
    }
}

// [LAW:parse-dont-validate] The one place another source's Bluetooth address becomes the identity Bluetooth names a device by.
struct BluetoothAddressTests {
    @Test(arguments: ["6c-3a-ff-d9-74-42", "6C:3A:FF:D9:74:42", "6c:3a:FF:d9:74:42", "6C-3A-FF-D9-74-42"])
    func anAddressInEitherSeparatorOrCaseIsIOBluetoothsForm(address: String) {
        #expect(BluetoothAddress(address)?.identity == Phone.address)
    }

    @Test(arguments: ["", "6c-3a-ff-d9-74", "6c-3a-ff-d9-74-42-01", "6c:3a-ff:d9-74:42", "6c3aff-d97442", "6g-3a-ff-d9-74-42", "6c-3a-ff-d9-74-4", "６c-3a-ff-d9-74-42", " 6c-3a-ff-d9-74-42", "6c--ff-d9-74-42"])
    func anythingElseIsNotAnAddress(address: String) {
        #expect(BluetoothAddress(address) == nil)
    }

    /// What IOBluetooth's `addressString` returned for paired devices on the Mac this was written on: lowercase, dash-separated.
    /// The claim is compared with it as a string, so it must parse to itself.
    @Test(arguments: ["04-9d-05-79-50-8d", "08-ff-44-03-d1-8d", "08-ff-44-3c-c8-81"])
    func anAddressInTheFormIOBluetoothWritesIsItself(recorded: String) {
        #expect(BluetoothAddress(recorded)?.key == recorded)
        #expect(BluetoothAddress(recorded)?.identity == .bluetooth(recorded))
    }
}
