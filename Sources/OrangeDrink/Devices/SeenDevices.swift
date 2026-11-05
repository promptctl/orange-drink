import Foundation

/// [LAW:one-source-of-truth] The app's memory of its devices, kept across launches. The shelf mirrors it for Edit Widget, so a
/// shelf file that is lost or unreadable is written again from here.
extension SeenDevices: Stored {
    static let storageKey = "devices.seen"

    /// How long a device keeps its place in Edit Widget after the app last saw it connected: a guest's phone or a sold pair of
    /// earbuds leaves, and one that has merely been off for a while stays.
    static let retentionDays = 30
    private static let day: TimeInterval = 86_400
    static var retention: TimeInterval { TimeInterval(retentionDays) * day }
    /// A device's date is renewed no oftener than this, so the app seeing it on every sweep leaves this value equal and
    /// costs no write to the defaults, the shelf or a widget reload. Eviction is up to this late.
    static let stampEvery = day

    /// Takes in every device on the list, then lets go of those not seen connected for `retention`; returns how many it let go.
    /// A read with no name leaves a known one: `Device.name` is the address until IOBluetooth has a name, and a device that
    /// leaves then would stay in Edit Widget as an address.
    @discardableResult
    mutating func see(_ list: DeviceList, at now: Date) -> Int {
        for device in list.devices {
            var seen = devices[device.id] ?? SeenDevice(name: device.name)
            if device.hasName { seen.name = device.name }
            // A stamp from the future (the clock was set ahead) is renewed once its device is seen connected; one whose device
            // stays off is kept until the clock reaches it, since evicting on a clock that moved back would evict every device.
            let current = seen.lastConnected.map { ($0..<$0.addingTimeInterval(Self.stampEvery)).contains(now) } ?? false
            if !current { seen.lastConnected = now }
            devices[device.id] = seen
        }
        let before = devices.count
        devices = devices.filter { _, seen in seen.lastConnected.map { now.timeIntervalSince($0) <= Self.retention } ?? true }
        return before - devices.count
    }

    /// Dates every device the app has not dated yet, those of a file written before dates: each gets a whole `retention` from
    /// `now` and not instant eviction.
    mutating func dateUndated(at now: Date) {
        devices = devices.mapValues { SeenDevice(name: $0.name, lastConnected: $0.lastConnected ?? now) }
    }
}

typealias SeenDevicesModel = StoredModel<SeenDevices>

extension SeenDevicesModel {
    /// The one load that dates what the last release left undated; the plain `init(defaults:)` reads a file as it is.
    static func load(defaults: UserDefaults, adoptingAt now: Date) throws -> SeenDevicesModel {
        let model = try SeenDevicesModel(defaults: defaults)
        try model.update { $0.dateUndated(at: now) }
        return model
    }
}
