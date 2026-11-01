import Foundation
import Security
import os

// Compiled into the app and its widget extension: what the app hands its widgets, and where.

/// Where the shelf logs, on either side of it. Not generic, so every widget's publisher shares the one category.
enum ShelfLog {
    static let category = "widgets"
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier!, category: category)
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
    static let name = "This Mac"
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
    let address: String
    let name: String
    let kind: DeviceKind
    /// nil while the device's levels are unknown this read.
    let level: BatteryLevel?

    var id: String { address }

    /// What the shelf's logs carry, which are public: the kind and level, never the name or address.
    var debugDescription: String { "\(kind) \(BatteryLevel.text(level))" }
}

/// One battery as a widget draws it, whatever the style.
struct WidgetBattery: Equatable, Sendable {
    /// The SF Symbol: the laptop for the Mac, the device's kind for a device.
    let glyph: String
    /// nil while there is no reading.
    let level: BatteryLevel?
    let charging: Bool
    /// What the widget calls it; nil where it shows no names.
    var name: String? = nil
    var appearance: WidgetAppearance = .color
}

extension WidgetBattery {
    /// Devices report no charging state.
    init(_ device: WidgetDevice) {
        self.init(glyph: device.kind.symbol, level: device.level, charging: false)
    }
}

/// Why the app has no list of what is connected. [LAW:types-are-the-program] Each is a list the app could not
/// give, so none of them can reach a widget as a list with nothing on it.
enum UnreadDevices: String, CaseIterable, Codable, Equatable, Sendable {
    /// Nothing has read the list yet.
    case waiting
    /// The Bluetooth prompt is open.
    case unanswered
    /// macOS refuses this app Bluetooth.
    case denied
    /// The app's readings stopped; its panel says why.
    case ended
}

extension UnreadDevices {
    /// A reading that is coming keeps the devices' glyph; one that will not come warns, as a stopped Mac does.
    var glyph: String {
        switch self {
        case .waiting, .unanswered: DeviceKind.accessory.symbol
        case .denied, .ended: MacBattery.stoppedGlyph
        }
    }

    /// What a widget says for it. A widget is too small for the panel's sentences, and the panel says why at length.
    var text: String {
        switch self {
        case .waiting: "Reading devices…"
        case .unanswered: "Answer the Bluetooth prompt"
        case .denied: "Allow Bluetooth in System Settings, then reopen the app"
        case .ended: "Devices unavailable"
        }
    }
}

/// The devices pinned to the menu bar, in the order their items sit there, connected or not.
struct WidgetPins: Codable, Equatable, Sendable, ExpressibleByArrayLiteral, CustomDebugStringConvertible {
    let addresses: [String]

    init(addresses: [String]) { self.addresses = addresses }
    init(arrayLiteral addresses: String...) { self.init(addresses: addresses) }

    /// What the shelf's logs carry, which are public: how many, never an address.
    var debugDescription: String { "\(addresses.count) pinned" }
}

/// What the app knows of its devices, as the widgets draw them. A list is the devices a sweep read that report a battery, so
/// an empty one says none does, as far as the app has been told (orange-devices-bue.4gw). The app derives it from `DeviceList`.
enum WidgetDevices: Codable, Equatable, Sendable {
    case connected([WidgetDevice], pinned: WidgetPins)
    case unread(UnreadDevices)
}

/// Why an All Batteries widget lists no device. [LAW:types-are-the-program] Each is a list the widget could not draw, so none
/// of them can reach a person as a widget with nothing to say.
enum NoDevicesListed: Error, Equatable, Sendable {
    case unread(UnreadDevices)
    /// Custom, with nothing chosen yet.
    case noneChosen
    /// Same as menu bar, with nothing pinned.
    case nonePinned
    /// Custom or Same as menu bar, and none of those devices is on the list. The list holds only what reports a battery,
    /// so this is as true of a connected device with no level as of one that has gone (orange-widgets-5jo.qak).
    case noneReporting
}

extension NoDevicesListed {
    var glyph: String {
        switch self {
        case .unread(let reason): reason.glyph
        case .noneChosen, .nonePinned, .noneReporting: DeviceKind.accessory.symbol
        }
    }

    var text: String {
        switch self {
        case .unread(let reason): reason.text
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
    case listed([WidgetBattery])
    /// The Mac, nil when it has no battery, and why no device is listed. It keeps its place beside the reason:
    /// it is the one thing the widget can show a person who keeps Bluetooth refused.
    case unlisted(mac: WidgetBattery?, NoDevicesListed)

    init(mac: MacBattery, devices: WidgetDevices, settings: AllBatteriesSettings) {
        let mac = (settings.includeMac ? mac.battery : nil).map { settings.drawn($0, named: MacBattery.name) }
        self = switch devices.listed(by: settings.devices) {
        case .success(let devices): .listed([mac].compactMap(\.self) + devices.map { settings.drawn(WidgetBattery($0), named: $0.name) })
        case .failure(let reason): .unlisted(mac: mac, reason)
        }
    }
}

/// A widget's kind, the name a placed widget is saved under.
enum WidgetKind: String, Sendable {
    case macBattery = "MacBattery"
    case deviceBattery = "DeviceBattery"
    case allBatteries = "AllBatteries"
}

/// What a shelf file holds: a widget's value and the app's own lifetime, so the widget can tell a value
/// from "the app quit". [LAW:one-source-of-truth] Every widget's file says it the one way. An end that
/// skips the quit (a crash, a kill) writes nothing, and the last value stays drawn until the app runs again.
enum Shelved<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable, CustomStringConvertible {
    case running(Value)
    case appNotRunning

    /// What the shelf logs: the value as it is, not wrapped in its envelope.
    var description: String {
        switch self {
        case .running(let value): String(describing: value)
        case .appNotRunning: "appNotRunning"
        }
    }
}

/// The shelf the app writes and its widgets read: one file per value, each declared once as an `Item`.
/// [LAW:one-source-of-truth] A file's name, its readers and its value live in the item alone; the
/// directory is a parameter, the group container only at the two composition roots, so a test reads exactly
/// what the widget would from a directory of its own.
enum WidgetShelf {
    struct Item<Value: Codable & Equatable & Sendable>: Sendable {
        /// The file in the shelf directory.
        let file: String
        /// The widgets that draw this file, which the app names when it asks WidgetKit to reload.
        let readers: [WidgetKind]
    }

    static func write<Value>(_ shelved: Shelved<Value>, as item: Item<Value>, to directory: URL) throws {
        try JSONEncoder().encode(shelved).write(to: directory.appending(path: item.file), options: .atomic)
    }

    static func read<Value>(_ item: Item<Value>, from directory: URL) -> Result<Shelved<Value>, any Error> {
        Result { try JSONDecoder().decode(Shelved<Value>.self, from: Data(contentsOf: directory.appending(path: item.file))) }
    }

    /// What a widget draws from. [LAW:no-silent-failure] Logged either way: a failure is drawn as
    /// "Open the app", and the log carries its cause.
    static func load<Value>(_ item: Item<Value>, from directory: Result<URL, any Error>, log: Logger) -> Result<Shelved<Value>, any Error> {
        let shelved = directory.flatMap { read(item, from: $0) }
        switch shelved {
        case .success(let value): log.info("widget shelf read: \(String(describing: value), privacy: .public)")
        case .failure(let error): log.error("widget shelf unreadable: \(String(describing: error), privacy: .public)")
        }
        return shelved
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

extension WidgetShelf.Item where Value == MacBattery {
    static var macBattery: Self { Self(file: "mac.json", readers: [.macBattery, .allBatteries]) }
}

extension WidgetShelf.Item where Value == WidgetDevices {
    static var devices: Self { Self(file: "devices.json", readers: [.deviceBattery, .allBatteries]) }
}

/// What the Device Battery widget's settings offer and resolve. [LAW:dataflow-not-control-flow] Pure over
/// the shelf's value, so the extension's AppIntents entity query only maps these and a test calls them.
extension WidgetDevices {
    /// The devices a widget can be set to: the connected ones, none while the app has no list or is not running.
    static func choices(in shelf: Shelved<WidgetDevices>) -> [WidgetDevice] {
        switch shelf {
        case .running(.connected(let devices, _)): devices
        case .running(.unread), .appNotRunning: []
        }
    }

    /// One result per id asked for, present or not: a chosen device that has disconnected still resolves
    /// (to nil), so a widget keeps its choice while the device is away.
    static func resolve(_ addresses: [String], in shelf: Shelved<WidgetDevices>) -> [(address: String, device: WidgetDevice?)] {
        let connected = choices(in: shelf)
        return addresses.map { address in (address, connected.first { $0.address == address }) }
    }

    /// The devices a widget's selection lists, or why it lists none. [LAW:one-type-per-behavior] Custom and Same as menu
    /// bar differ only in where their addresses come from.
    func listed(by selection: WidgetDeviceSelection) -> Result<[WidgetDevice], NoDevicesListed> {
        switch (self, selection) {
        case (.unread(let reason), _): .failure(.unread(reason))
        case (.connected(let devices, _), .automatic): .success(devices)
        case (.connected(let devices, _), .custom(let addresses)): Self.picked(addresses, from: devices, unset: .noneChosen)
        case (.connected(let devices, let pinned), .sameAsMenuBar): Self.picked(pinned.addresses, from: devices, unset: .nonePinned)
        }
    }

    /// As the pinned menu bar items do, an address not on the list is left out and the rest keep their order.
    private static func picked(_ addresses: [String], from list: [WidgetDevice], unset: NoDevicesListed) -> Result<[WidgetDevice], NoDevicesListed> {
        let devices = addresses.compactMap { address in list.first { $0.address == address } }
        return devices.isEmpty ? .failure(addresses.isEmpty ? unset : .noneReporting) : .success(devices)
    }
}
