import Foundation

/// What the user chose about the devices screen and the panel's Connected Devices card.
struct DeviceSettings: Stored {
    static let storageKey = "devices.settings"

    /// design-docs/devices.md: shows or hides the panel's Connected Devices section.
    var showConnectedDevices = true
    /// Devices the user hid from the panel's list; they stay on the Devices screen to be shown again.
    var hidden: Set<DeviceID> = []
    /// Devices whose bell is on: each is held to the Low Battery alerts.
    var alerting: Set<DeviceID> = []
    /// Devices pinned into the menu bar as items of their own.
    var pinned = PinnedOrder()

    init() {}

    /// [LAW:parse-dont-validate] A field a later release adds is absent from what an earlier one
    /// stored; it decodes to its default instead of failing every existing install's launch.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        showConnectedDevices = try values.decodeIfPresent(Bool.self, forKey: .showConnectedDevices) ?? showConnectedDevices
        hidden = try values.decodeIfPresent(Set<DeviceID>.self, forKey: .hidden) ?? hidden
        alerting = try values.decodeIfPresent(Set<DeviceID>.self, forKey: .alerting) ?? alerting
        pinned = try values.decodeIfPresent(PinnedOrder.self, forKey: .pinned) ?? pinned
    }

    mutating func toggleHidden(_ id: DeviceID) {
        if hidden.remove(id) == nil { hidden.insert(id) }
    }

    mutating func toggleAlerting(_ id: DeviceID) {
        if alerting.remove(id) == nil { alerting.insert(id) }
    }

    mutating func togglePinned(_ id: DeviceID) {
        pinned.toggle(id)
    }
}

typealias DeviceSettingsModel = StoredModel<DeviceSettings>
