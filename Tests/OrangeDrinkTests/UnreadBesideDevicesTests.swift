import Foundation
import Testing
@testable import OrangeDrink

// [LAW:verifiable-goals] The Done when of orange-device-sources-rec.k69: a source that has not delivered is said beside the
// devices the others gave, on every surface that lists devices, and "none connected" is said only of a list that arrived.
struct UnreadBesideDevicesTests {
    private static let phone = SourceDevice(id: DeviceID(source: .iPhone, key: "00008110-A"), name: "Test iPhone", kind: .phone,
                                            levels: .single(BatteryLevel(percent: 62, approximate: false)))

    private static func list(bluetooth: DeviceEvent?, iPhone: DeviceEvent?, ended: [DeviceSource] = []) -> DeviceList {
        var list = DeviceList(sources: DeviceSource.allCases)
        if let bluetooth { list.apply(bluetooth, from: .bluetooth) }
        if let iPhone { list.apply(iPhone, from: .iPhone) }
        for source in ended { list.end(source) }
        return list
    }

    /// Bluetooth refused beside a cabled iPhone: the iPhone's row and the reason, on each card and in the widget's state.
    @Test func bluetoothDeniedBesideAListedIPhoneShowsTheRowAndTheReasonEverywhere() {
        let list = Self.list(bluetooth: .permission(.denied), iPhone: .swept([Self.phone]))
        let denied = ListNotes(empty: nil, unread: [UnreadSource.bluetooth(.denied).explanation])
        let id = Self.phone.id

        let connected = ConnectedDevices(list, settings: DeviceSettings())
        #expect(connected.rows.map(\.id) == [id])
        #expect(connected.notes == denied)
        let detected = DetectedDevices(list, settings: DeviceSettings())
        #expect(detected.entries.map(\.id) == [id])
        #expect(detected.notes == denied)
        let pinned = PinnedDevicesList(list, pinned: [id])
        #expect(pinned.entries.map(\.row.id) == [id])
        #expect(pinned.notes == denied)

        let shelf = WidgetDeviceList(list, pinned: [id])
        #expect(shelf.ranked.map(\.id) == [id])
        #expect(shelf.unreadSources == [.bluetooth(.denied)])
    }

    /// The iPhone reader ended beside Bluetooth, which swept and found nothing: Bluetooth's emptiness is a fact and the reader's
    /// end is another, each said for its own source (orange-device-sources-rec.99q's review).
    @Test func anEndedReaderBesideAnEmptyBluetoothIsNamedAndNeverReadForBluetooth() {
        let list = Self.list(bluetooth: .swept([]), iPhone: nil, ended: [.iPhone])
        #expect(ConnectedDevices(list, settings: DeviceSettings()).notes == .only(.iPhone(.ended)))
        #expect(list.unreadSources == [.iPhone(.ended)])
    }

    @Test func everySourceUnreadSaysOnlyWhyEachIs() {
        let list = Self.list(bluetooth: nil, iPhone: nil)
        #expect(DetectedDevices(list, settings: DeviceSettings()).notes == .only(.bluetooth(.waiting), .iPhone(.waiting)))
    }

    @Test func aListThatArrivedSaysNoneConnectedAndNothingElse() {
        let list = Self.list(bluetooth: .swept([]), iPhone: .swept([]))
        #expect(ConnectedDevices(list, settings: DeviceSettings()).notes == .none("No connected Bluetooth devices to show."))
        #expect(PinnedDevicesList(list, pinned: []).notes == .none("Pin a connected device from the Devices screen to arrange it here."))
    }

    /// "Every device is hidden" is true whatever a source did, so an unread source does not take it away.
    @Test func hidingEveryDeviceIsStillSaidBesideAnUnreadSource() {
        let list = Self.list(bluetooth: .permission(.denied), iPhone: .swept([Self.phone]))
        var settings = DeviceSettings()
        settings.hidden = [Self.phone.id]
        let connected = ConnectedDevices(list, settings: settings)
        #expect(connected.rows.isEmpty)
        #expect(connected.notes == ListNotes(empty: "Every device is hidden. Show them again in Settings → Devices.",
                                             unread: [UnreadSource.bluetooth(.denied).explanation]))
    }

    // [LAW:verifiable-goals] The Done when of orange-device-sources-rec.70o: a reachable iPhone whose identity read failed is said
    // beside the devices that did list, on every surface that lists devices, by its reader and the kind of failure, never by
    // the phone's name or address.

    private static let unreadableUDID = "00008110-SYNTHETIC-7F3A"

    /// The list as the real mapper builds it from what the reader said of a phone it reached and could not read, beside a Bluetooth
    /// mouse that listed.
    private static func listWithAnUnreadablePhone(_ error: IPhoneReadError) -> DeviceList {
        var list = DeviceList(sources: DeviceSource.allCases)
        list.apply(.swept([DeviceListTests.mouse.source]), from: .bluetooth)
        var mapper = IPhoneDevices()
        for event in [IPhoneEvent.reachable(udid: unreadableUDID, over: .usb), .readFailed(udid: unreadableUDID, over: .usb, error), .listed] {
            for told in mapper.apply(event) { list.apply(told, from: .iPhone) }
        }
        return list
    }

    @Test(arguments: [
        (IPhoneReadError.refused("PasswordProtected"), IPhoneMissing.locked),
        (.refused("InvalidHostID"), .notTrusted),
        (.lockdown("a-string-the-phone-sent"), .unreadable),
    ])
    func aReachablePhoneThatCouldNotBeIdentifiedIsSaidBesideTheDevicesThatListed(error: IPhoneReadError, kind: IPhoneMissing) {
        let list = Self.listWithAnUnreadablePhone(error)
        let said = ListNotes(empty: nil, unread: [UnreadSource.iPhoneMissing(kind).explanation])
        let mouse = DeviceListTests.mouse.id

        #expect(list.devices.map(\.id) == [mouse])
        let connected = ConnectedDevices(list, settings: DeviceSettings())
        #expect(connected.rows.map(\.id) == [mouse])
        #expect(connected.notes == said)
        let detected = DetectedDevices(list, settings: DeviceSettings())
        #expect(detected.entries.map(\.id) == [mouse])
        #expect(detected.notes == said)
        let pinned = PinnedDevicesList(list, pinned: [mouse])
        #expect(pinned.notes == said)
        #expect(WidgetDeviceList(list, pinned: [mouse]).unreadSources == [.iPhoneMissing(kind)])

        // The reader and the kind are named; the phone and what its error carried are not.
        let words = [UnreadSource.iPhoneMissing(kind).explanation.english, UnreadSource.iPhoneMissing(kind).text.english]
        for word in words {
            #expect(word.contains("iPhone"))
            #expect(!word.contains(Self.unreadableUDID))
            #expect(!word.contains("a-string-the-phone-sent"))
        }
    }

    /// The phone is not listed, so with nothing else listed "none connected" would be false: a phone is connected.
    @Test func anUnreadablePhoneAloneIsNotNoneConnected() {
        var list = DeviceList(sources: DeviceSource.allCases)
        list.apply(.swept([]), from: .bluetooth)
        list.apply(.swept([]), from: .iPhone)
        list.apply(.missing([.locked]), from: .iPhone)
        #expect(ConnectedDevices(list, settings: DeviceSettings()).notes == .only(.iPhoneMissing(.locked)))
        #expect(WidgetDeviceList(list, pinned: []).listed(by: .automatic) == .failure(.unread(.iPhoneMissing(.locked))))
    }

    /// Each source is named by what the user sees it as, never as another source's.
    @Test func eachUnreadSourceExplainsItselfInItsOwnWords() {
        #expect(UnreadSource.iPhone(.waiting).explanation.english == "Reading your iPhones and iPads…")
        #expect(UnreadSource.iPhone(.ended).explanation.english == "iPhone readings stopped. Quit and reopen the app.")
        #expect(UnreadSource.bluetooth(.ended).explanation.english == "Bluetooth readings stopped. Quit and reopen the app.")
        #expect(UnreadSource.iPhone(.ended).text.english == "iPhones unavailable")
        #expect(UnreadSource.bluetooth(.ended).text.english == "Bluetooth unavailable")
    }
}
