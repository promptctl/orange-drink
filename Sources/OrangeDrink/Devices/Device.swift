import Foundation

/// [LAW:types-are-the-program] What a device reports, and no more: a device with one battery, one
/// with earbuds and a case (each part may be missing, e.g. a bud out of its case), none at all, or
/// not known this read. An unreported level is absent; 0% is a reading, a drained battery.
enum DeviceLevels: Equatable, Sendable {
    case none
    /// Power management did not answer, so this device's levels are unknown, not absent.
    case unread
    case single(BatteryLevel)
    case earbuds(left: BatteryLevel?, right: BatteryLevel?, case: BatteryLevel?)

    /// The level an alert watches: what powers the device. A bud going into its case must not read as
    /// the level falling from the buds' to the case's, so the case is never the level.
    var alertLevel: BatteryLevel? {
        switch self {
        case .none, .unread: nil
        case .single(let level): level
        case .earbuds(let left, let right, _): [left, right].compactMap { $0 }.min { $0.percent < $1.percent }
        }
    }

    /// The level a one-number display shows: the earbud that runs out first; the case only when no
    /// earbud reports, because the case does not power playback.
    var lowest: BatteryLevel? {
        switch self {
        case .none, .unread: nil
        case .single(let level): level
        case .earbuds(let left, let right, let `case`): [left, right].compactMap { $0 }.min { $0.percent < $1.percent } ?? `case`
        }
    }
}

/// A device as the app shows and keys it. `id` is the identity the app's choices about the device (pins, bells, hides, seen
/// names) are keyed by; for a device that no source's claim joins to another, the identity its source read it under. The source
/// of a presented id is not necessarily the source that read the device (`DeviceList.devices`), so nothing routes by it.
struct Device: Equatable, Sendable, Identifiable {
    let id: DeviceID
    let name: String
    let kind: DeviceKind
    let levels: DeviceLevels
    /// [LAW:parse-dont-validate] The one place a device's name is chosen: the user's alias, else the
    /// name the device broadcasts, else its address. IOBluetooth answers "" for a name it does not
    /// have yet (orange-devices-bue.suy), so a blank is no name, never a name.
    static func name(alias: String?, broadcast: String?, address: String) -> String {
        [alias, broadcast].lazy
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? address
    }

    /// False for a device known only by the address `name(alias:broadcast:address:)` fell back to.
    var hasName: Bool { name != id.key }
}

/// A device as one source read it: what that source tells the list, which the list turns into `Device`s.
/// `id` names the source that read it, and `DeviceList` stores it by that.
struct SourceDevice: Equatable, Sendable {
    let id: DeviceID
    let name: String
    let kind: DeviceKind
    let levels: DeviceLevels
    /// The Bluetooth address of this same physical device, for a device another source reads: an iPhone's. A device with one is
    /// the same device as the Bluetooth device at that address, and is presented under it (`DeviceList.devices`).
    /// [LAW:one-source-of-truth] The match is by identity and never by name, which collides and changes.
    let alsoBluetooth: BluetoothAddress?

    /// [LAW:types-are-the-program] A Bluetooth device claiming a Bluetooth address is a mapper bug, stopped here as
    /// `DeviceList.apply` stops an event from a source it was not built for, so the list has no claim to ignore.
    init(id: DeviceID, name: String, kind: DeviceKind, levels: DeviceLevels, alsoBluetooth: BluetoothAddress? = nil) {
        precondition(alsoBluetooth == nil || id.source != .bluetooth, "\(id.wire) is a Bluetooth device and claims a Bluetooth address")
        (self.id, self.name, self.kind, self.levels, self.alsoBluetooth) = (id, name, kind, levels, alsoBluetooth)
    }

    /// The device as it reads when nothing joins it to another.
    var device: Device { Device(id: id, name: name, kind: kind, levels: levels) }
}

/// What the Bluetooth edge tells the list: a device's current state, that it is gone, or the
/// complete set of connected devices at one sweep.
///
/// [LAW:no-ambient-temporal-coupling] Connect and disconnect notifications and the sweep arrive from
/// different threads with no order between them, so a disconnect can land before the sweep that read
/// the device as connected. The sweep is the authority: it replaces the list, so any such race
/// is gone by the next sweep instead of leaving a device listed that is not there.
enum DeviceEvent: Equatable, Sendable {
    case reported(SourceDevice)
    case gone(DeviceID)
    case swept([SourceDevice])
    case permission(BluetoothPermission)
}

/// Every connected device the app knows of, from every source. [LAW:one-source-of-truth] The one
/// reduction from events to the list; nothing else holds a device.
///
/// A device is stored once, by its identity, and an identity names its source: which source a device
/// belongs to is read from it and never held a second time. What a source has told the list is its
/// reading; an event is applied *from* a source and touches only the devices whose identity names it, so a
/// source cannot add, remove or keep another's device. [LAW:single-enforcer] Here, in the one reduction.
struct DeviceList: Equatable, Sendable {
    /// [LAW:types-are-the-program] What one source has told the list: it swept, or why it did not.
    private enum Reading: Equatable, Sendable {
        case read
        case unread(UnreadDevices)

        /// A source that has not spoken: waiting, never read.
        static let unheard = Reading.unread(.waiting)
    }

    private var byID: [DeviceID: SourceDevice] = [:]
    /// Total over the sources the list was built for, so a source that has not spoken is waiting and cannot be mistaken
    /// for read. A source nothing subscribed to is not in it: it is no source of this list, not one waiting for ever.
    private var readings: [DeviceSource: Reading]

    init(sources: some Collection<DeviceSource>) {
        readings = Dictionary(uniqueKeysWithValues: sources.map { ($0, Reading.unheard) })
    }

    mutating func apply(_ event: DeviceEvent, from source: DeviceSource) {
        precondition(readings[source] != nil, "an event from \(source.rawValue), which this list was not built for")
        switch event {
        case .reported(let device) where device.id.source == source: byID[device.id] = device
        case .gone(let id) where id.source == source: byID[id] = nil
        case .reported, .gone: break
        case .swept(let devices):
            removeDevices(of: source)
            for device in devices where device.id.source == source { byID[device.id] = device }
            readings[source] = .read
        case .permission(let permission):
            // Heard after a sweep, this is the end of what that sweep read, so nothing is kept to go stale, as in `end(_:)`.
            removeDevices(of: source)
            readings[source] = .unread(UnreadDevices(permission))
        }
    }

    /// The source's stream ended: no event will follow from it, so nothing of its is kept to go stale.
    mutating func end(_ source: DeviceSource) {
        precondition(readings[source] != nil, "the end of \(source.rawValue), which this list was not built for")
        removeDevices(of: source)
        readings[source] = .unread(.ended)
    }

    private mutating func removeDevices(of source: DeviceSource) {
        byID = byID.filter { $0.key.source != source }
    }

    /// Why this source's devices are no list of what it has connected, or nil once it has swept; nil too for a source this
    /// list was not built for, which has nothing to say. [LAW:types-are-the-program]
    /// A device reported before the first sweep leaves it unread: one device is not what is connected, and the connect a
    /// registration replays has no order with that sweep.
    func unread(of source: DeviceSource) -> UnreadDevices? {
        switch readings[source] {
        case nil, .read?: nil
        case .unread(let reason)?: reason
        }
    }

    /// Why a screen with no device to show has no list of what is connected, or nil when it has one to show or nothing is unread:
    /// a function of the readings, so there is no second copy of them. A device of a source that has swept is something to show;
    /// one reported ahead of its source's first sweep is not, as it is not the list. Otherwise the reason is the first source, in
    /// `DeviceSource.allCases` order, that was denied or ended; waiting only when none was.
    ///
    /// A source unread beside listed devices is shown nowhere yet: orange-device-sources-rec.k69.
    var unread: UnreadDevices? {
        let reasons = DeviceSource.allCases.filter { readings[$0] != nil }.map { ($0, unread(of: $0)) }
        guard reasons.contains(where: { $0.1 != nil }) else { return nil }
        let showsDevice = reasons.contains { source, reason in reason == nil && byID.keys.contains { $0.source == source } }
        guard !showsDevice else { return nil }
        return reasons.lazy.compactMap(\.1).first { $0 != .waiting } ?? .waiting
    }

    /// Each physical device once, in a stable order, by name then identity, so a view never reshuffles equal rows.
    ///
    /// [LAW:one-source-of-truth] Stored is what each source listed; the merge is read off it here and held nowhere, so a
    /// source that stops listing a phone leaves the other's entry as it was, with nothing to undo. A device that claims a
    /// Bluetooth address and the Bluetooth device at it are one device, presented under that address (`presentedID`)
    /// whichever of them are listed. Everything the user attached to a device is keyed by that identity, so none of it moves
    /// when a cable is pulled. Two claimers of one address name no one, so nothing in that group is merged: the rows stay
    /// apart, where a mapper bug shows, and `contested` names the address for the log.
    ///
    /// `unread` reads `byID` and not this: it asks what each source has listed, and a source's device counts as that source
    /// showing one even when another source's twin is the one presented. A group always presents its survivor, so a source
    /// that listed a device is never wholly out of view.
    var devices: [Device] {
        Dictionary(grouping: byID.values, by: \.presentedID).values
            .flatMap { members in members.claimers.count > 1 ? members.map(\.device) : [Device.merged(members)] }
            .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    /// The Bluetooth addresses more than one device claims, in a stable order: a fault of the sources, for the log.
    var contested: [String] {
        Dictionary(grouping: byID.values.compactMap(\.alsoBluetooth), by: \.key).filter { $0.value.count > 1 }.keys.sorted()
    }
}

private extension SourceDevice {
    /// The identity the list presents this device under: the Bluetooth address it claims, else its own. Taken from the claim
    /// and not from which twin is listed, so it is the same whether one source or both list the device. A Bluetooth address is
    /// the identity every stored pin, bell and hide of a phone already has.
    var presentedID: DeviceID { alsoBluetooth?.identity ?? id }
}

private extension Array where Element == SourceDevice {
    var claimers: [SourceDevice] { filter { $0.alsoBluetooth != nil } }
}

private extension Device {
    /// One device from the source devices that share an identity: at most one claimer and the Bluetooth device at its address.
    /// The claimer is read from the device itself, so it comes first, and its kind and levels stand: Bluetooth's level for a
    /// phone the claimer lists is never shown, so a stale one cannot move the level an alert watches. The name is the first
    /// that is one, else the identity's key, as `Device.name(alias:broadcast:address:)` falls back, so `hasName` reads a
    /// presented phone as it reads any device and `SeenDevices` never stores a UDID as its name.
    static func merged(_ members: [SourceDevice]) -> Device {
        let ordered = members.sorted { $0.alsoBluetooth != nil && $1.alsoBluetooth == nil }
        let survivor = ordered[0]
        let identity = survivor.presentedID
        return Device(
            id: identity, name: ordered.first(where: { $0.device.hasName })?.name ?? identity.key, kind: survivor.kind,
            levels: survivor.levels)
    }
}

extension DeviceEvent {
    /// The identity of every device the event names.
    var ids: [DeviceID] {
        switch self {
        case .reported(let device): [device.id]
        case .gone(let id): [id]
        case .swept(let devices): devices.map(\.id)
        case .permission: []
        }
    }
}

extension UnreadDevices {
    /// What a sweep is waiting on for this permission: nothing yet when allowed, since the sweep is what reads the list.
    init(_ permission: BluetoothPermission) {
        self = switch permission {
        case .allowed: .waiting
        case .notDetermined: .unanswered
        case .denied: .denied
        }
    }

    /// Why a card that lists devices is empty.
    var explanation: Phrase {
        switch self {
        case .waiting: "Reading your Bluetooth devices…"
        case .unanswered: "Answer the Bluetooth prompt to see your devices."
        case .denied: "This app isn't allowed to use Bluetooth. Allow it in System Settings → Privacy & Security → Bluetooth, then quit and reopen the app."
        case .ended: "Device readings stopped. Quit and reopen the app."
        }
    }
}
