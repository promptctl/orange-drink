import Foundation
import Security
import os

// Compiled into the app and its widget extension: what the app hands its widgets, and where.

/// Where the shelf logs, on either side of it. Not generic, so every widget's publisher shares the one category.
enum ShelfLog {
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "widgets")
}

/// The Mac as the widgets draw it.
///
/// [LAW:types-are-the-program] The app's battery state, so the widget can tell a level from "no more
/// readings". Whether the app is running at all is the shelf's own fact (`Shelved`).
enum MacBattery: Codable, Equatable, Sendable {
    case level(percent: Int, charging: Bool)
    case noBattery
    /// The app is running and has no reading yet.
    case waiting
    /// The app's readings stopped; its panel says why.
    case ended
}

extension MacBattery {
    static let glyph = "laptopcomputer"
    /// What a widget that shows names calls the Mac, in the words the panel and the widget's settings use.
    static let name: Phrase = "This Mac"
    /// Readings that stopped, wherever they are drawn: the menu bar and every widget.
    static let stoppedGlyph = "exclamationmark.triangle"

    /// The Mac as a widget draws it: the empty ring until there is a reading, and the empty ring with a
    /// warning after the readings end, so a stopped Mac never reads as one still waiting. nil when it has
    /// no battery, a desktop Mac.
    var battery: WidgetBattery? {
        switch self {
        case .level(let percent, let charging): WidgetBattery(glyph: Self.glyph, level: BatteryLevel(percent: percent, approximate: false), charging: charging)
        case .waiting: WidgetBattery(glyph: Self.glyph, level: nil, charging: false)
        case .ended: WidgetBattery(glyph: Self.stoppedGlyph, level: nil, charging: false)
        case .noBattery: nil
        }
    }
}

/// One connected device, as the widgets draw it. [LAW:one-source-of-truth] The kind and
/// level are the app's own types (`DeviceKind`, `BatteryLevel`), derived from the one ranking the panel reads.
struct WidgetDevice: Codable, Equatable, Sendable, Identifiable, CustomDebugStringConvertible {
    let id: DeviceID
    let name: String
    let kind: DeviceKind
    /// nil while the device has no level to show: unknown this read, or none reported.
    let level: BatteryLevel?

    /// What the shelf's logs carry, which are public: the kind and level, never the name or identity.
    var debugDescription: String { "\(kind) \(BatteryLevel.text(level).english)" }
}

/// One battery as a widget draws it, whatever the style.
struct WidgetBattery: Equatable, Sendable {
    /// The SF Symbol: the laptop for the Mac, the device's kind for a device.
    let glyph: String
    /// nil while there is no reading.
    let level: BatteryLevel?
    let charging: Bool
    /// What the widget calls it; nil where it shows no names.
    var name: Phrase? = nil
    var appearance: WidgetAppearance = .color
}

extension WidgetBattery {
    /// Devices report no charging state.
    init(_ device: WidgetDevice) {
        self.init(glyph: device.kind.symbol, level: device.level, charging: false)
    }
}

/// Why the Bluetooth list has not arrived. [LAW:types-are-the-program] Each is a list the app could not give, so none of them
/// can reach a widget as a list with nothing on it. Each source names its own reasons: a pair of a source and a reason that
/// means nothing cannot be written.
enum BluetoothNoList: String, CaseIterable, Codable, Equatable, Sendable {
    /// Nothing has read the list yet.
    case waiting
    /// The Bluetooth prompt is open.
    case unanswered
    /// macOS refuses this app Bluetooth.
    case denied
    /// The app's readings stopped; its panel says why.
    case ended
}

/// Why the iPhone list has not arrived: a source with no permission, so it is only ever waiting or ended.
enum IPhoneNoList: String, CaseIterable, Codable, Equatable, Sendable {
    case waiting
    case ended
}

/// A device missing from the iPhone list that did arrive, and why. A different fact from `IPhoneNoList`: that source has
/// delivered, and it is a device of it the app could not give. No reason is known yet, so there is no case, and no value;
/// orange-device-sources-rec.70o adds its cases, and the `switch`es over `UnreadSource` that need an arm for each fail to
/// compile until they have one. It stands in `RawRepresentable` by hand because an enum with no cases cannot declare a raw type.
enum IPhoneMissing: Equatable, Sendable, CaseIterable, RawRepresentable {
    init?(rawValue: String) { nil }
    var rawValue: String { switch self {} }
}

/// Why one source's list has not arrived: the source and its own reason, held together.
enum NoList: Equatable, Sendable {
    case bluetooth(BluetoothNoList)
    case iPhone(IPhoneNoList)

    var source: DeviceSource {
        switch self {
        case .bluetooth: .bluetooth
        case .iPhone: .iPhone
        }
    }

    /// Every source has a list that has not been read yet, and one whose readings stopped.
    static func waiting(of source: DeviceSource) -> NoList {
        switch source {
        case .bluetooth: .bluetooth(.waiting)
        case .iPhone: .iPhone(.waiting)
        }
    }

    static func ended(of source: DeviceSource) -> NoList {
        switch source {
        case .bluetooth: .bluetooth(.ended)
        case .iPhone: .iPhone(.ended)
        }
    }

    var isWaiting: Bool { self == .waiting(of: source) }

    /// The wire form of the reason, with its source beside it in `UnreadSource`'s file.
    var reason: String {
        switch self {
        case .bluetooth(let reason): reason.rawValue
        case .iPhone(let reason): reason.rawValue
        }
    }

    /// [LAW:parse-dont-validate] nil for a reason the source has no case for, so a pair that means nothing is not a value.
    init?(source: DeviceSource, reason: String) {
        switch source {
        case .bluetooth: guard let reason = BluetoothNoList(rawValue: reason) else { return nil }; self = .bluetooth(reason)
        case .iPhone: guard let reason = IPhoneNoList(rawValue: reason) else { return nil }; self = .iPhone(reason)
        }
    }

    /// A reading that is coming keeps the devices' glyph; one that will not come warns, as a stopped Mac does.
    var glyph: String {
        switch self {
        case .bluetooth(let reason): reason.glyph
        case .iPhone(let reason): reason.glyph
        }
    }

    /// What a widget says for it. A widget is too small for the panel's sentences, and the panel says why at length.
    var text: Phrase {
        switch self {
        case .bluetooth(let reason): reason.text
        case .iPhone(let reason): reason.text
        }
    }
}

extension BluetoothNoList {
    var glyph: String {
        switch self {
        case .waiting, .unanswered: DeviceKind.accessory.symbol
        case .denied, .ended: MacBattery.stoppedGlyph
        }
    }

    var text: Phrase {
        switch self {
        case .waiting: "Reading devices…"
        case .unanswered: "Answer the Bluetooth prompt"
        case .denied: "Bluetooth is not allowed"
        case .ended: "Bluetooth unavailable"
        }
    }
}

extension IPhoneNoList {
    var glyph: String {
        switch self {
        case .waiting: DeviceKind.accessory.symbol
        case .ended: MacBattery.stoppedGlyph
        }
    }

    var text: Phrase {
        switch self {
        case .waiting: "Reading iPhones…"
        case .ended: "iPhones unavailable"
        }
    }
}

/// What a source could not give the app, and why. [LAW:types-are-the-program] A source's list that has not arrived
/// (`noList`) and a device missing from a list that did (`iPhoneMissing`) are different facts, so they are different cases.
/// The reason is held with the source it is about, so a surface that has devices beside an unread source says which, and the
/// reasons of several sources are a list and not one verdict picked among them. A new reason is a case of one source's own
/// type, and the `switch`es below name every arm that then needs words.
enum UnreadSource: Equatable, Sendable {
    case noList(NoList)
    case iPhoneMissing(IPhoneMissing)

    static func bluetooth(_ reason: BluetoothNoList) -> UnreadSource { .noList(.bluetooth(reason)) }
    static func iPhone(_ reason: IPhoneNoList) -> UnreadSource { .noList(.iPhone(reason)) }
}

extension UnreadSource {
    var source: DeviceSource {
        switch self {
        case .noList(let list): list.source
        case .iPhoneMissing: .iPhone
        }
    }

    var glyph: String {
        switch self {
        case .noList(let list): list.glyph
        }
    }

    var text: Phrase {
        switch self {
        case .noList(let list): list.text
        }
    }

    /// True for a source that has not delivered its first reading, which is no failure.
    var isWaiting: Bool {
        switch self {
        case .noList(let list): list.isWaiting
        }
    }
}

/// The widget file holds `{"source": <DeviceSource>, "reason": <string>}`, as every release since sources has written it.
/// [LAW:parse-dont-validate] The one crossing: the reason is read as its source's own type, and a pair that means nothing
/// fails the file loudly, as any unreadable shelf does, instead of being a value.
extension UnreadSource: Codable {
    private enum Keys: String, CodingKey { case source, reason }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        let source = try values.decode(DeviceSource.self, forKey: .source)
        let reason = try values.decode(String.self, forKey: .reason)
        if let list = NoList(source: source, reason: reason) {
            self = .noList(list)
        } else if let missing = Self.missing(source: source, reason: reason) {
            self = missing
        } else {
            throw DecodingError.dataCorruptedError(forKey: .reason, in: values, debugDescription: "\(source.rawValue) has no reason \(reason)")
        }
    }

    private static func missing(source: DeviceSource, reason: String) -> UnreadSource? {
        switch source {
        case .bluetooth: nil
        case .iPhone: IPhoneMissing(rawValue: reason).map(UnreadSource.iPhoneMissing)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: Keys.self)
        try values.encode(source, forKey: .source)
        switch self {
        case .noList(let list): try values.encode(list.reason, forKey: .reason)
        case .iPhoneMissing(let missing): try values.encode(missing.rawValue, forKey: .reason)
        }
    }
}

extension [UnreadSource] {
    /// The one source a one-line widget surface speaks for: the first, in source order, that is not merely waiting for its
    /// first reading, else the first. A presentation choice at the narrowest surface; nothing stores it.
    var headline: UnreadSource? { first { !$0.isWaiting } ?? first }
}

/// The devices pinned to the menu bar, in the order their items sit there, connected or not.
struct WidgetPins: Codable, Equatable, Sendable, ExpressibleByArrayLiteral, CustomDebugStringConvertible {
    let ids: [DeviceID]

    init(ids: [DeviceID]) { self.ids = ids }
    init(arrayLiteral ids: DeviceID...) { self.init(ids: ids) }

    /// What the shelf's logs carry, which are public: how many, never which.
    var debugDescription: String { "\(ids.count) pinned" }
}

/// Every device the app has seen, connected now or not: what Edit Widget names and offers. [LAW:types-are-the-program] Not
/// `Shelved`: a device's name stays true after the app quits, and Edit Widget needs it then.
struct SeenDevices: Codable, Equatable, Sendable, CustomDebugStringConvertible {
    /// Each device's name.
    var names: [DeviceID: String] = [:]

    init() {}
    init(names: [DeviceID: String]) { self.names = names }

    private enum CodingKeys: CodingKey { case names }

    /// The file keys each name by the device's wire form. [LAW:parse-dont-validate] A key with no source is a Bluetooth address
    /// from before sources, and one this release cannot read fails the file loudly rather than lose a device's name.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let wired = try values.decode([String: String].self, forKey: .names)
        names = try Dictionary(wired.map { wire, name in
            guard let id = DeviceID(wire: wire) else {
                throw DecodingError.dataCorruptedError(forKey: .names, in: values, debugDescription: "not a device identity: \(wire)")
            }
            return (id, name)
        }, uniquingKeysWith: { _, later in later })
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Dictionary(uniqueKeysWithValues: names.map { ($0.key.wire, $0.value) }), forKey: .names)
    }

    /// What the shelf's logs carry, which are public: how many, never a name or an address.
    var debugDescription: String { "\(names.count) seen" }
}

/// What a sweep read of what is connected, as the widgets draw it. [LAW:locality-or-seam] One value, so a new fact about
/// the list touches only what reads it.
struct WidgetDeviceList: Codable, Equatable, Sendable {
    /// The panel's ranking: the devices with a level, and those whose level is unknown this read. So an empty list says none
    /// reports a battery.
    let ranked: [WidgetDevice]
    let pinned: WidgetPins
    /// The connected devices the ranking leaves out, with no level to rank: one settling after a reconnect, or one power
    /// management has no source for. Device Battery draws one it is set to; All Batteries lists only `ranked`, so a device
    /// with no battery gains no row.
    let unlevelled: [WidgetDevice]
    /// The sources whose list has not arrived, and why, beside the devices the others gave. [LAW:one-source-of-truth] Derived
    /// from the one `DeviceList`; a widget that lists devices says these beside them and never "not connected" alone.
    let unreadSources: [UnreadSource]

    /// [LAW:one-source-of-truth] Where Device Battery finds its device: nil only for a device that is not connected.
    func device(_ id: DeviceID) -> WidgetDevice? {
        (ranked + unlevelled).first { $0.id == id }
    }
}

extension WidgetDeviceList {
    private enum Keys: String, CodingKey { case ranked, pinned, unlevelled, unreadSources }
    /// The previous release's two shapes, an enum's wire form. Read so a file it wrote still draws until the app rewrites it
    /// at launch. Owner: this file. Cap: these two. Delete in the release after the one that ships this.
    private enum Previous: String, CodingKey { case connected, unread }
    private struct Boxed<Value: Decodable>: Decodable { let _0: Value }

    init(from decoder: any Decoder) throws {
        let previous = try decoder.container(keyedBy: Previous.self)
        if previous.contains(.connected) {
            self = try previous.decode(Boxed<WidgetDeviceList>.self, forKey: .connected)._0
        } else if previous.contains(.unread) {
            // The previous release had one source, Bluetooth, and its unread file carried no devices and no pins.
            let reason = try previous.decode(Boxed<BluetoothNoList>.self, forKey: .unread)._0
            self.init(ranked: [], pinned: WidgetPins(ids: []), unlevelled: [], unreadSources: [.bluetooth(reason)])
        } else {
            let values = try decoder.container(keyedBy: Keys.self)
            // A list the previous release wrapped in `connected` has no unread sources.
            self.init(ranked: try values.decode([WidgetDevice].self, forKey: .ranked), pinned: try values.decode(WidgetPins.self, forKey: .pinned),
                      unlevelled: try values.decode([WidgetDevice].self, forKey: .unlevelled),
                      unreadSources: try values.decodeIfPresent([UnreadSource].self, forKey: .unreadSources) ?? [])
        }
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: Keys.self)
        try values.encode(ranked, forKey: .ranked)
        try values.encode(pinned, forKey: .pinned)
        try values.encode(unlevelled, forKey: .unlevelled)
        try values.encode(unreadSources, forKey: .unreadSources)
    }
}

/// What a widget selection lists: the devices it picked, and the sources unread beside them.
struct WidgetListing: Equatable, Sendable {
    let devices: [WidgetDevice]
    let unread: [UnreadSource]
}

/// Why an All Batteries widget lists no device. [LAW:types-are-the-program] Each is a list the widget could not draw, so none
/// of them can reach a person as a widget with nothing to say.
enum NoDevicesListed: Error, Equatable, Sendable {
    /// Nothing to list, and a source's list that has not arrived is why it may be so. The one source a one-line surface says
    /// (`[UnreadSource].headline`), so there is no empty case.
    case unread(UnreadSource)
    /// Custom, with nothing chosen yet.
    case noneChosen
    /// Same as menu bar, with nothing pinned.
    case nonePinned
    /// Custom or Same as menu bar, and none of those devices is ranked: each is unlevelled, or has gone.
    case noneReporting
}

extension NoDevicesListed {
    var glyph: String {
        switch self {
        case .unread(let source): source.glyph
        case .noneChosen, .nonePinned, .noneReporting: DeviceKind.accessory.symbol
        }
    }

    var text: Phrase {
        switch self {
        case .unread(let source): source.text
        case .noneChosen: "Choose devices: right-click → Edit Widget"
        case .nonePinned: "Pin a device on the Devices screen"
        case .noneReporting: "This widget's devices aren't reporting a battery"
        }
    }
}

/// What the All Batteries widget draws, whatever its style. [LAW:dataflow-not-control-flow] Pure over the
/// shelf's two values.
enum AllBatteries: Equatable, Sendable {
    /// The Mac first, so a full widget never pushes it out, then the devices in the panel's ranking, so the
    /// lowest are the ones that fit, or in the order a widget's selection gives. Empty when no device reports a
    /// battery and the Mac is left out or has none.
    case listed([WidgetBattery], unread: [UnreadSource])
    /// The Mac, nil when it has no battery, and why no device is listed. It keeps its place beside the reason:
    /// it is the one thing the widget can show a person who keeps Bluetooth refused.
    case unlisted(mac: WidgetBattery?, NoDevicesListed)

    init(mac: MacBattery, devices: WidgetDeviceList, settings: AllBatteriesSettings) {
        let mac = (settings.includeMac ? mac.battery : nil).map { settings.drawn($0, named: MacBattery.name) }
        self = switch devices.listed(by: settings.devices) {
        case .success(let listing):
            .listed([mac].compactMap(\.self) + listing.devices.map { settings.drawn(WidgetBattery($0), named: "\($0.name)") }, unread: listing.unread)
        case .failure(let reason): .unlisted(mac: mac, reason)
        }
    }
}

/// A widget's kind, the name a placed widget is saved under, in the order the Widgets screen offers them.
enum WidgetKind: String, CaseIterable, Sendable {
    case allBatteries = "AllBatteries"
    case macBattery = "MacBattery"
    case deviceBattery = "DeviceBattery"
}

/// What a file a widget draws holds: its value and the app's own lifetime, so the widget can tell a value
/// from "the app quit". [LAW:one-source-of-truth] Every widget's file says it the one way. An end that
/// skips the quit (a crash, a kill) writes nothing, and the last value stays drawn until the app runs again.
enum Shelved<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable, CustomStringConvertible {
    case running(Value)
    /// The app ended normally: its widgets say so rather than keep drawing the last value.
    case appNotRunning

    /// What the shelf logs: the value as it is, not wrapped in its envelope.
    var description: String {
        switch self {
        case .running(let value): String(describing: value)
        case .appNotRunning: "appNotRunning"
        }
    }
}

/// The shelf the app writes and its widgets read: one file per value, each declared once as an `Item`, which names what the
/// file holds.
/// [LAW:one-source-of-truth] A file's name, its readers and its value live in the item alone; the
/// directory is a parameter, the group container only at the two composition roots, so a test reads exactly
/// what the widget would from a directory of its own.
enum WidgetShelf {
    struct Item<Contents: Codable & Equatable & Sendable>: Sendable {
        /// The file in the shelf directory.
        let file: String
        /// The widgets that draw this file, which the app names when it asks WidgetKit to reload.
        let readers: [WidgetKind]
    }

    static func write<Contents>(_ contents: Contents, as item: Item<Contents>, to directory: URL) throws {
        try JSONEncoder().encode(contents).write(to: directory.appending(path: item.file), options: .atomic)
    }

    static func read<Contents>(_ item: Item<Contents>, from directory: URL) -> Result<Contents, any Error> {
        Result { try JSONDecoder().decode(Contents.self, from: Data(contentsOf: directory.appending(path: item.file))) }
    }

    /// What a widget draws from. [LAW:no-silent-failure] Logged either way: a failure is drawn as
    /// "Open the app", and the log carries its cause.
    static func load<Contents>(_ item: Item<Contents>, from directory: Result<URL, any Error>, log: Logger) -> Result<Contents, any Error> {
        let contents = directory.flatMap { read(item, from: $0) }
        switch contents {
        case .success(let value): log.info("widget shelf read: \(String(describing: value), privacy: .public)")
        case .failure(let error): log.error("widget shelf unreadable: \(String(describing: error), privacy: .public)")
        }
        return contents
    }

    /// The container of the app group this process is signed into. [LAW:one-source-of-truth] The
    /// group is read off the process's own entitlement, which project.yml's APP_GROUP fills, so
    /// neither target spells it.
    static func groupContainer() throws -> URL {
        let entitlement = "com.apple.security.application-groups"
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil) as? [String],
              let group = groups.first else {
            throw ShelfError.noGroupEntitlement
        }
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw ShelfError.noContainer(group: group)
        }
        return container
    }
}

enum ShelfError: Error {
    /// The process is signed without an application group: a broken build.
    case noGroupEntitlement
    case noContainer(group: String)
}

extension WidgetShelf.Item where Contents == Shelved<MacBattery> {
    static var macBattery: Self { Self(file: "mac.json", readers: [.macBattery, .allBatteries]) }
}

extension WidgetShelf.Item where Contents == Shelved<WidgetDeviceList> {
    static var devices: Self { Self(file: "devices.json", readers: [.deviceBattery, .allBatteries]) }
}

extension WidgetShelf.Item where Contents == SeenDevices {
    /// No widget draws it: Edit Widget reads it when it opens.
    static var seenDevices: Self { Self(file: "seen-devices.json", readers: []) }
}

extension WidgetDeviceList {
    /// The devices a widget's selection lists with the sources unread beside them, or why it lists none. [LAW:one-type-per-behavior]
    /// Custom and Same as menu bar differ only in where their devices come from.
    ///
    /// One precedence for every widget: a choice not yet made (nothing chosen, nothing pinned) is a fact about configuration and
    /// wins; then an empty pick with a source unread says that source, since the pick may be empty for want of it; then
    /// the devices, with the unread sources beside them.
    func listed(by selection: WidgetDeviceSelection) -> Result<WidgetListing, NoDevicesListed> {
        switch selection {
        case .automatic: listing(ranked, emptyIs: nil)
        case .custom(let ids): picked(ids, unset: .noneChosen)
        case .sameAsMenuBar: picked(pinned.ids, unset: .nonePinned)
        }
    }

    /// As the pinned menu bar items do, a device not on the list is left out and the rest keep their order.
    private func picked(_ ids: [DeviceID], unset: NoDevicesListed) -> Result<WidgetListing, NoDevicesListed> {
        ids.isEmpty ? .failure(unset) : listing(ids.compactMap { id in ranked.first { $0.id == id } }, emptyIs: .noneReporting)
    }

    /// `devices` beside the unread sources. With none: the unread source that may explain it, else `reason`, else an empty
    /// listing (an automatic selection of a Mac with no device that reports a battery).
    private func listing(_ devices: [WidgetDevice], emptyIs reason: NoDevicesListed?) -> Result<WidgetListing, NoDevicesListed> {
        guard devices.isEmpty else { return .success(WidgetListing(devices: devices, unread: unreadSources)) }
        if let headline = unreadSources.headline { return .failure(.unread(headline)) }
        return reason.map { .failure($0) } ?? .success(WidgetListing(devices: [], unread: []))
    }
}
