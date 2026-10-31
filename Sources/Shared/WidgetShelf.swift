import Foundation
import Security
import os

// Compiled into the app and its widget extension: what the app hands its widgets, and where.

/// What the Mac Battery widget draws.
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

/// One connected device, as the Device Battery widget draws it. [LAW:one-source-of-truth] The kind and
/// level are the app's own types (`DeviceKind`, `BatteryLevel`), derived from the one ranking the panel reads.
struct WidgetDevice: Codable, Equatable, Sendable, Identifiable {
    let address: String
    let name: String
    let kind: DeviceKind
    /// nil while the device's levels are unknown this read.
    let level: BatteryLevel?

    var id: String { address }
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

/// The shelf the app writes and its widgets read: one file per widget, each declared once as an `Item`.
/// [LAW:one-source-of-truth] A file's name, its widget's kind and its value live in the item alone; the
/// directory is a parameter, the group container only at the two composition roots, so a test reads exactly
/// what the widget would from a directory of its own.
enum WidgetShelf {
    struct Item<Value: Codable & Equatable & Sendable>: Sendable {
        /// The file in the shelf directory.
        let file: String
        /// The widget's kind, which the app names when it asks WidgetKit to reload.
        let kind: String
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
    static var macBattery: Self { Self(file: "mac.json", kind: "MacBattery") }
}

extension WidgetShelf.Item where Value == [WidgetDevice] {
    static var devices: Self { Self(file: "devices.json", kind: "DeviceBattery") }
}

/// What the Device Battery widget's settings offer and resolve. [LAW:dataflow-not-control-flow] Pure over
/// the shelf's value, so the extension's AppIntents entity query only maps these and a test calls them.
enum WidgetDevices {
    /// The devices a widget can be set to: the connected ones, none while the app is not running.
    static func choices(in shelf: Shelved<[WidgetDevice]>) -> [WidgetDevice] {
        switch shelf {
        case .running(let devices): devices
        case .appNotRunning: []
        }
    }

    /// One result per id asked for, present or not: a chosen device that has disconnected still resolves
    /// (to nil), so its widget draws "Not connected" instead of losing its choice.
    static func resolve(_ addresses: [String], in shelf: Shelved<[WidgetDevice]>) -> [(address: String, device: WidgetDevice?)] {
        let connected = choices(in: shelf)
        return addresses.map { address in (address, connected.first { $0.address == address }) }
    }
}
