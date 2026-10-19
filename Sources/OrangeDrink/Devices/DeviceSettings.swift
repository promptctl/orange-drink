import Foundation
import Observation

/// What the user chose about the devices screen and the panel's Connected Devices card.
struct DeviceSettings: Codable, Equatable, Sendable {
    /// design-docs/devices.md: shows or hides the panel's Connected Devices section.
    var showConnectedDevices = true
    /// Devices the user hid from the panel's list; they stay on the Devices screen to be shown again.
    var hidden: Set<DeviceID> = []

    init() {}

    /// [LAW:parse-dont-validate] A field a later release adds is absent from what an earlier one
    /// stored; it decodes to its default instead of failing every existing install's launch.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        showConnectedDevices = try values.decodeIfPresent(Bool.self, forKey: .showConnectedDevices) ?? showConnectedDevices
        hidden = try values.decodeIfPresent(Set<DeviceID>.self, forKey: .hidden) ?? hidden
    }

    mutating func toggleHidden(_ id: DeviceID) {
        if hidden.remove(id) == nil { hidden.insert(id) }
    }
}

/// The settings the Devices screen edits and the panel reads, written through to the store on
/// every change.
///
/// [LAW:one-source-of-truth] `settings` is the live copy; this is the only writer.
@Observable @MainActor final class DeviceSettingsModel {
    static let storageKey = "devices.settings"

    private(set) var settings: DeviceSettings
    @ObservationIgnored private let store: DefaultsStore<DeviceSettings>

    /// [LAW:no-silent-failure] Stored settings that do not decode fail the launch loudly.
    init(defaults: UserDefaults) throws {
        store = DefaultsStore(key: Self.storageKey, initial: DeviceSettings(), defaults: defaults)
        settings = try store.load()
    }

    func update(_ edit: (inout DeviceSettings) -> Void) throws {
        var edited = settings
        edit(&edited)
        try store.save(edited)
        settings = edited
    }
}
