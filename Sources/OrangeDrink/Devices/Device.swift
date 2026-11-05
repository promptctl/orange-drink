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
///
/// `permission` and `missing` are one source's own, each of a type only that source has: the kinds of device the iPhone source
/// reaches and cannot list. `missing` is the whole of it, restated by its source whenever it changes, and replaces what the
/// list held; it is not a sweep, which the iPhone source yields once at startup.
enum DeviceEvent: Equatable, Sendable {
    case reported(SourceDevice)
    case gone(DeviceID)
    case swept([SourceDevice])
    case permission(BluetoothPermission)
    case missing(Set<IPhoneMissing>)
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
        case unread(NoList)
    }

    private var byID: [DeviceID: SourceDevice] = [:]
    /// What the iPhone source last said it reaches and cannot list. Replaced whole by each `missing` event; cleared with the
    /// source's devices when its list is no longer coming (`stop`), and by nothing else, so no sweep and no device event
    /// decides it.
    private var missingIPhones: Set<IPhoneMissing> = []
    /// Total over the sources the list was built for, so a source that has not spoken is waiting and cannot be mistaken
    /// for read. A source nothing subscribed to is not in it: it is no source of this list, not one waiting for ever.
    private var readings: [DeviceSource: Reading]

    init(sources: some Collection<DeviceSource>) {
        // A source that has not spoken is waiting, never read.
        readings = Dictionary(uniqueKeysWithValues: sources.map { ($0, Reading.unread(.waiting(of: $0))) })
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
        // A permission is Bluetooth's, so one from another source's stream names nothing this list can hold, as a device of
        // another source is ignored above; `DevicesModel` says so in the log.
        case .permission(let permission) where source == .bluetooth: stop(.bluetooth(BluetoothNoList(permission)))
        case .permission: break
        case .missing(let kinds) where source == .iPhone: missingIPhones = kinds
        case .missing: break
        }
    }

    /// The source's stream ended: no event will follow from it, so nothing of its is kept to go stale.
    mutating func end(_ source: DeviceSource) {
        precondition(readings[source] != nil, "the end of \(source.rawValue), which this list was not built for")
        stop(.ended(of: source))
    }

    /// The source's list is not coming, so nothing of its is kept to go stale, and `reason` is why. A sweep heard before this is
    /// the end of what it read. The reading is keyed by the reason's own source, so the two cannot disagree.
    private mutating func stop(_ reason: NoList) {
        removeDevices(of: reason.source)
        if reason.source == .iPhone { missingIPhones = [] }
        readings[reason.source] = .unread(reason)
    }

    private mutating func removeDevices(of source: DeviceSource) {
        byID = byID.filter { $0.key.source != source }
    }

    /// Why this source's devices are no list of what it has connected, or nil once it has swept; nil too for a source this
    /// list was not built for, which has nothing to say. [LAW:types-are-the-program]
    /// A device reported before the first sweep leaves it unread: one device is not what is connected, and the connect a
    /// registration replays has no order with that sweep.
    func unread(of source: DeviceSource) -> NoList? {
        switch readings[source] {
        case nil, .read?: nil
        case .unread(let reason)?: reason
        }
    }

    /// The sources whose list has not arrived, and why, in `DeviceSource.allCases` order: the one value every surface reads to
    /// say what is missing beside the devices it shows. [LAW:one-source-of-truth] A function of the readings, so there is no
    /// second copy of them and no verdict picked among them; a device reported ahead of its source's first sweep is listed with
    /// the rest in `devices`, and its source is here until it sweeps.
    ///
    /// A source that delivered can still be missing devices it reaches and cannot list (a phone whose identity could not be
    /// read): one entry per kind, after the source's own, so a surface says what is missing and why and never counts devices.
    var unreadSources: [UnreadSource] {
        DeviceSource.allCases.flatMap { source in
            [unread(of: source).map(UnreadSource.noList)].compactMap { $0 } + missing(of: source)
        }
    }

    /// What this source reaches and cannot list, in a stable order. A `switch` on the source, so one that gains a missing side
    /// is named here.
    private func missing(of source: DeviceSource) -> [UnreadSource] {
        switch source {
        case .bluetooth: []
        case .iPhone: IPhoneMissing.allCases.filter(missingIPhones.contains).map(UnreadSource.iPhoneMissing)
        }
    }

    /// What a card of devices says beside its rows. [LAW:single-enforcer] The one place the rule is made: "none connected" is
    /// not a true statement about a list some source has not delivered, so it is said only when nothing is unread, while a
    /// fact about the card's own configuration (`hidden`: every device is hidden) is true whatever a source did and wins.
    func notes(hidden: Phrase? = nil, whenNone: Phrase) -> ListNotes {
        let unread = unreadSources
        return ListNotes(empty: hidden ?? (unread.isEmpty ? whenNone : nil), unread: unread.map(\.explanation))
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
    /// The claimer is read from the device itself, so its kind and levels stand: Bluetooth's level for a phone the claimer
    /// lists is never shown, so a stale one cannot move the level an alert watches. The name is the Bluetooth twin's if it is
    /// one, because that is the user's alias, the name System Settings shows and the one a pin or alert was set under, so it does
    /// not change when a cable is plugged in; else the claimer's if it is one, else the identity's key, as
    /// `Device.name(alias:broadcast:address:)` falls back, so `hasName` reads a presented phone as it reads any device and
    /// `SeenDevices` never stores a UDID as its name.
    static func merged(_ members: [SourceDevice]) -> Device {
        let claimer = members.claimers.first
        let twin = members.first { $0.alsoBluetooth == nil }
        let survivor = claimer ?? members[0]
        let identity = survivor.presentedID
        return Device(
            id: identity, name: [twin, claimer].lazy.compactMap { $0 }.first { $0.device.hasName }?.name ?? identity.key,
            kind: survivor.kind, levels: survivor.levels)
    }
}

extension DeviceEvent {
    /// The identity of every device the event names.
    var ids: [DeviceID] {
        switch self {
        case .reported(let device): [device.id]
        case .gone(let id): [id]
        case .swept(let devices): devices.map(\.id)
        case .permission, .missing: []
        }
    }

    /// The one source an event is about, when it is about a source and not about devices: another source's stream cannot say
    /// it. The list ignores such an event from any other source, and `DevicesModel` says so in the log.
    var owner: DeviceSource? {
        switch self {
        case .permission: .bluetooth
        case .missing: .iPhone
        case .reported, .gone, .swept: nil
        }
    }
}

extension BluetoothNoList {
    /// What a sweep is waiting on for this permission: nothing yet when allowed, since the sweep is what reads the list.
    init(_ permission: BluetoothPermission) {
        self = switch permission {
        case .allowed: .waiting
        case .notDetermined: .unanswered
        case .denied: .denied
        }
    }

    var explanation: Phrase {
        switch self {
        case .waiting: "Reading your Bluetooth devices…"
        case .unanswered: "Answer the Bluetooth prompt to see your devices."
        case .denied: "This app isn't allowed to use Bluetooth. Allow it in System Settings → Privacy & Security → Bluetooth, then quit and reopen the app."
        case .ended: "Bluetooth readings stopped. Quit and reopen the app."
        }
    }
}

extension IPhoneMissing {
    var explanation: Phrase {
        switch self {
        case .locked: "An iPhone or iPad is connected but locked, so it can't be listed. Unlock it to see it here."
        case .notTrusted: "An iPhone or iPad is connected but doesn't trust this Mac. Unlock it and tap Trust to see it here."
        case .unreadable: "An iPhone or iPad is connected but couldn't be read."
        }
    }
}

extension IPhoneNoList {
    var explanation: Phrase {
        switch self {
        case .waiting: "Reading your iPhones and iPads…"
        case .ended: "iPhone readings stopped. Quit and reopen the app."
        }
    }
}

extension UnreadSource {
    /// Why a card that lists devices is missing some, or is empty: the panel's sentence, naming the source it is about.
    var explanation: Phrase {
        switch self {
        case .noList(.bluetooth(let reason)): reason.explanation
        case .noList(.iPhone(let reason)): reason.explanation
        case .iPhoneMissing(let missing): missing.explanation
        }
    }
}

/// What a card of devices says besides its rows: why it has none, when saying so is true, and which sources have not delivered.
struct ListNotes: Equatable {
    let empty: Phrase?
    let unread: [Phrase]

    /// The lines a card says: why it has no rows if it has none, then each unread source. Empty for a fully read list with rows.
    func lines(rowsAreEmpty: Bool) -> [Phrase] {
        (rowsAreEmpty ? empty.map { [$0] } ?? [] : []) + unread
    }
}
